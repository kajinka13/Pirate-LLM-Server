import Foundation
import llama

// Batch helpers (from official llama.cpp Swift example)
private func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
    batch.token   [Int(batch.n_tokens)] = id
    batch.pos     [Int(batch.n_tokens)] = pos
    batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
    for i in 0..<seq_ids.count {
        batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i]
    }
    batch.logits  [Int(batch.n_tokens)] = logits ? 1 : 0
    batch.n_tokens += 1
}

final class LLMEngine: @unchecked Sendable {

    enum EngineError: Error, LocalizedError {
        case modelNotLoaded
        case failedToLoadModel(String)
        case failedToCreateContext
        case tokenizationFailed
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "Model is not loaded"
            case .failedToLoadModel(let path): return "Failed to load model: \(path)"
            case .failedToCreateContext: return "Failed to create llama context"
            case .tokenizationFailed: return "Tokenization failed"
            case .generationFailed(let msg): return "Generation failed: \(msg)"
            }
        }
    }

    struct GenerationParams {
        var maxTokens: Int = 512
        var temperature: Float = 0.7
        var topP: Float = 0.9
        var topK: Int32 = 40
        var repeatPenalty: Float = 1.1
        var stream: Bool = false
    }

    private let queue = DispatchQueue(label: "com.llmserver.engine", qos: .userInitiated)
    private var model: OpaquePointer?
    private var vocab: OpaquePointer?

    private(set) var isLoaded = false
    private(set) var modelName = ""

    var onLog: ((String) -> Void)?

    init() {
        llama_backend_init()
    }

    deinit {
        unloadModel()
        llama_backend_free()
    }

    func loadModel(at path: String) throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: path) else {
                throw EngineError.failedToLoadModel(path)
            }

            if model != nil {
                unloadModelInternal()
            }

            onLog?("Loading model from: \(path)")

            var modelParams = llama_model_default_params()
            // use_mmap = true is the default, let the OS page in what's needed
            #if targetEnvironment(simulator)
            modelParams.n_gpu_layers = 0
            #endif

            guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
                throw EngineError.failedToLoadModel(path)
            }

            model = loadedModel
            vocab = llama_model_get_vocab(loadedModel)
            isLoaded = true
            modelName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent

            onLog?("Model loaded: \(modelName)")
        }
    }

    func unloadModel() {
        queue.sync {
            unloadModelInternal()
        }
    }

    private func unloadModelInternal() {
        if let m = model { llama_model_free(m); model = nil }
        vocab = nil
        isLoaded = false
        modelName = ""
    }

    func generate(
        prompt: String,
        params: GenerationParams,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Int, Int) -> Void
    ) throws {
        guard model != nil else { throw EngineError.modelNotLoaded }

        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.performGeneration(prompt: prompt, params: params, onToken: onToken)
                onComplete(result.0, result.1)
            } catch {
                self.onLog?("Generation error: \(error.localizedDescription)")
                onComplete(0, 0)
            }
        }
    }

    func generateSync(
        prompt: String,
        params: GenerationParams,
        onToken: ((String) -> Void)? = nil
    ) throws -> (text: String, promptTokens: Int, completionTokens: Int) {
        guard model != nil else { throw EngineError.modelNotLoaded }

        var result = ""
        var promptToks = 0
        var completionToks = 0
        let semaphore = DispatchSemaphore(value: 0)

        queue.async { [weak self] in
            do {
                let gen = try self?.performGeneration(prompt: prompt, params: params, onToken: { token in
                    result += token
                    onToken?(token)
                })
                promptToks = gen?.0 ?? 0
                completionToks = gen?.1 ?? 0
            } catch {
                self?.onLog?("GenerateSync error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }

        semaphore.wait()
        return (result, promptToks, completionToks)
    }

    // Context created per-request, destroyed after - saves RAM
    private func performGeneration(
        prompt: String,
        params: GenerationParams,
        onToken: @escaping (String) -> Void
    ) throws -> (Int, Int) {
        guard let model = model, let vocab = vocab else {
            throw EngineError.modelNotLoaded
        }

        // 1. Tokenize
        let tokens = tokenize(text: prompt, addBos: true)
        guard !tokens.isEmpty else { throw EngineError.tokenizationFailed }

        let promptCount = tokens.count
        onLog?("Prompt: \(promptCount) tokens")

        // 2. Create context (per-request to save memory)
        let nThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048  // 2B model fits easily in 6GB RAM
        ctxParams.n_threads = Int32(nThreads)
        ctxParams.n_threads_batch = Int32(nThreads)

        guard let ctx = llama_init_from_model(model, ctxParams) else {
            throw EngineError.failedToCreateContext
        }
        defer { llama_free(ctx) }  // free immediately after generation

        let nCtx = Int(llama_n_ctx(ctx))
        guard promptCount < nCtx else {
            throw EngineError.generationFailed("Prompt too long: \(promptCount) > \(nCtx)")
        }

        let maxGen = min(params.maxTokens, nCtx - promptCount)

        // 3. Create batch
        var batch = llama_batch_init(Int32(max(promptCount, 1)), 0, 1)
        defer { llama_batch_free(batch) }

        // 4. Fill batch with prompt
        llama_batch_clear(&batch)
        for i in 0..<tokens.count {
            llama_batch_add(&batch, tokens[i], Int32(i), [0], false)
        }
        batch.logits[Int(batch.n_tokens) - 1] = 1

        onLog?("Decoding prompt...")
        if llama_decode(ctx, batch) != 0 {
            throw EngineError.generationFailed("llama_decode() failed")
        }

        // 5. Create sampler (per-request)
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else {
            throw EngineError.generationFailed("Failed to create sampler")
        }
        defer { llama_sampler_free(sampler) }

        llama_sampler_chain_add(sampler, llama_sampler_init_temp(params.temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        // 6. Generate
        onLog?("Generating (max \(maxGen) tokens)...")
        var nCur = batch.n_tokens
        var completionCount = 0
        var tempChars: [CChar] = []

        for _ in 0..<maxGen {
            let newTokenId = llama_sampler_sample(sampler, ctx, batch.n_tokens - 1)

            if llama_vocab_is_eog(vocab, newTokenId) || nCur >= Int32(nCtx) {
                if !tempChars.isEmpty {
                    onToken(String(cString: tempChars + [0]))
                }
                break
            }

            // Token to piece (handles multi-byte UTF8)
            let piece = tokenToPiece(token: newTokenId)
            tempChars.append(contentsOf: piece)

            if let validStr = String(validatingUTF8: tempChars + [0]) {
                tempChars.removeAll()
                onToken(validStr)
            }

            completionCount += 1

            // Next decode
            llama_batch_clear(&batch)
            llama_batch_add(&batch, newTokenId, nCur, [0], true)
            nCur += 1

            if llama_decode(ctx, batch) != 0 {
                onLog?("Decode failed at token \(completionCount)")
                break
            }
        }

        onLog?("Done: \(completionCount) tokens")
        return (promptCount, completionCount)
    }

    private func tokenize(text: String, addBos: Bool) -> [llama_token] {
        guard let vocab = vocab else { return [] }
        let utf8Count = text.utf8.count
        let nTokens = utf8Count + (addBos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: nTokens)
        defer { tokens.deallocate() }

        let count = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(nTokens), addBos, true)
        if count < 0 { return [] }

        return (0..<Int(count)).map { tokens[$0] }
    }

    private func tokenToPiece(token: llama_token) -> [CChar] {
        guard let vocab = vocab else { return [] }
        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        buf.initialize(repeating: 0, count: 8)
        defer { buf.deallocate() }

        let n = llama_token_to_piece(vocab, token, buf, 8, 0, false)
        if n < 0 {
            let buf2 = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-n))
            buf2.initialize(repeating: 0, count: Int(-n))
            defer { buf2.deallocate() }
            let n2 = llama_token_to_piece(vocab, token, buf2, -n, 0, false)
            return Array(UnsafeBufferPointer(start: buf2, count: Int(n2)))
        }
        return Array(UnsafeBufferPointer(start: buf, count: Int(n)))
    }
}
