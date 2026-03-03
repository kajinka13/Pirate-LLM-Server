import Foundation
import ReadiumGCDWebServer

final class APIServer: @unchecked Sendable {

    private var webServer: ReadiumGCDWebServer?
    private let engine: LLMEngine
    private let port: UInt = 8080

    var onLog: ((String) -> Void)?
    var isRunning: Bool { webServer?.isRunning ?? false }
    var serverURL: String? {
        guard let server = webServer, server.isRunning else { return nil }
        if let ip = Self.getLocalIPAddress() {
            return "http://\(ip):\(port)"
        }
        return server.serverURL?.absoluteString
    }

    init(engine: LLMEngine) {
        self.engine = engine
    }

    func start() throws {
        let server = ReadiumGCDWebServer()
        webServer = server

        setupRoutes(server: server)

        let options: [String: Any] = [
            ReadiumGCDWebServerOption_Port: port,
            ReadiumGCDWebServerOption_BonjourName: "LLM Server",
            ReadiumGCDWebServerOption_BonjourType: "_http._tcp",
            ReadiumGCDWebServerOption_AutomaticallySuspendInBackground: false
        ]

        try server.start(options: options)
        onLog?("Server started on port \(port)")
    }

    func stop() {
        webServer?.stop()
        webServer = nil
        onLog?("Server stopped")
    }

    private func setupRoutes(server: ReadiumGCDWebServer) {
        // GET / - Status page
        server.addHandler(forMethod: "GET", path: "/", request: ReadiumGCDWebServerRequest.self) { [weak self] _ in
            self?.handleStatusPage() ?? ReadiumGCDWebServerDataResponse(statusCode: 500)
        }

        // GET /v1/models - List models
        server.addHandler(forMethod: "GET", path: "/v1/models", request: ReadiumGCDWebServerRequest.self) { [weak self] _ in
            self?.handleListModels() ?? ReadiumGCDWebServerDataResponse(statusCode: 500)
        }

        // POST /v1/chat/completions - Chat completion
        server.addHandler(forMethod: "POST", path: "/v1/chat/completions", request: ReadiumGCDWebServerDataRequest.self) { [weak self] request in
            guard let self = self, let dataRequest = request as? ReadiumGCDWebServerDataRequest else {
                return self?.errorResponse(message: "Invalid request", status: 400) ?? ReadiumGCDWebServerDataResponse(statusCode: 400)
            }
            return self.handleChatCompletion(request: dataRequest)
        }

        // OPTIONS for CORS
        server.addDefaultHandler(forMethod: "OPTIONS", request: ReadiumGCDWebServerRequest.self) { _ in
            let response = ReadiumGCDWebServerResponse(statusCode: 204)
            response.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
            response.setValue("GET, POST, OPTIONS", forAdditionalHeader: "Access-Control-Allow-Methods")
            response.setValue("Content-Type, Authorization", forAdditionalHeader: "Access-Control-Allow-Headers")
            return response
        }
    }

    // MARK: - Handlers

    private func handleStatusPage() -> ReadiumGCDWebServerDataResponse {
        let modelStatus = engine.isLoaded ? "Loaded: \(engine.modelName)" : "Not loaded"
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Pirate LLM Server</title>
            <style>
                body { font-family: -apple-system, sans-serif; max-width: 600px; margin: 40px auto; padding: 0 20px; background: #1a1a2e; color: #eee; }
                .status { padding: 20px; border-radius: 12px; background: #16213e; margin: 20px 0; }
                .badge { display: inline-block; padding: 4px 12px; border-radius: 20px; font-size: 14px; }
                .badge.ok { background: #00b894; color: #fff; }
                .badge.err { background: #e17055; color: #fff; }
                h1 { color: #74b9ff; }
                code { background: #0d1b2a; padding: 2px 8px; border-radius: 4px; }
            </style>
        </head>
        <body>
            <h1>Pirate LLM Server</h1>
            <p style="color:#a0a0a0; font-size:13px;">by pinperepette</p>
            <div class="status">
                <p>Status: <span class="badge \(engine.isLoaded ? "ok" : "err")">\(engine.isLoaded ? "Running" : "Model not loaded")</span></p>
                <p>Model: <code>\(modelStatus)</code></p>
            </div>
            <h3>API Endpoints</h3>
            <ul>
                <li><code>GET /v1/models</code></li>
                <li><code>POST /v1/chat/completions</code></li>
            </ul>
        </body>
        </html>
        """
        let response = ReadiumGCDWebServerDataResponse(html: html)!
        response.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
        return response
    }

    private func handleListModels() -> ReadiumGCDWebServerDataResponse {
        let modelId = engine.isLoaded ? engine.modelName : "none"
        let modelsResp = ModelsResponse(
            object: "list",
            data: engine.isLoaded ? [
                ModelsResponse.ModelInfo(
                    id: modelId,
                    object: "model",
                    created: Int(Date().timeIntervalSince1970),
                    ownedBy: "local"
                )
            ] : []
        )

        return jsonResponse(modelsResp)
    }

    private func handleChatCompletion(request: ReadiumGCDWebServerDataRequest) -> ReadiumGCDWebServerResponse {
        guard engine.isLoaded else {
            onLog?("Request rejected: model not loaded")
            return errorResponse(message: "Model not loaded", status: 503)
        }

        let data = request.data

        onLog?("Raw body (\(data.count) bytes): \(String(data: data, encoding: .utf8) ?? "not utf8")")

        let chatRequest: ChatCompletionRequest
        do {
            chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)
        } catch let decodingError as DecodingError {
            let detail: String
            switch decodingError {
            case .keyNotFound(let key, _):
                detail = "Missing key: \(key.stringValue)"
            case .typeMismatch(let type, let ctx):
                detail = "Type mismatch: expected \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            case .valueNotFound(let type, let ctx):
                detail = "Value not found: \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            case .dataCorrupted(let ctx):
                detail = "Data corrupted: \(ctx.debugDescription)"
            @unknown default:
                detail = decodingError.localizedDescription
            }
            onLog?("JSON decode error: \(detail)")
            return errorResponse(message: "Invalid JSON: \(detail)", status: 400)
        } catch {
            onLog?("Invalid JSON: \(error.localizedDescription)")
            return errorResponse(message: "Invalid JSON: \(error.localizedDescription)", status: 400)
        }

        let prompt = buildPrompt(from: chatRequest.messages)
        let shouldStream = chatRequest.stream ?? false

        onLog?("Request: \(chatRequest.messages.last?.content.prefix(80) ?? "empty") (stream: \(shouldStream))")

        let params = LLMEngine.GenerationParams(
            maxTokens: chatRequest.maxTokens ?? 512,
            temperature: Float(chatRequest.temperature ?? 0.7),
            topP: Float(chatRequest.topP ?? 0.9),
            stream: shouldStream
        )

        if shouldStream {
            return handleStreamingCompletion(prompt: prompt, params: params, model: chatRequest.model ?? engine.modelName)
        } else {
            return handleNonStreamingCompletion(prompt: prompt, params: params, model: chatRequest.model ?? engine.modelName)
        }
    }

    private func handleNonStreamingCompletion(prompt: String, params: LLMEngine.GenerationParams, model: String) -> ReadiumGCDWebServerDataResponse {
        do {
            let result = try engine.generateSync(prompt: prompt, params: params)

            let response = ChatCompletionResponse.create(
                model: model,
                content: result.text,
                finishReason: "stop",
                promptTokens: result.promptTokens,
                completionTokens: result.completionTokens
            )

            onLog?("Response: \(result.completionTokens) tokens generated")
            return jsonResponse(response)
        } catch {
            onLog?("Generation error: \(error.localizedDescription)")
            return errorResponse(message: error.localizedDescription, status: 500)
        }
    }

    private func handleStreamingCompletion(prompt: String, params: LLMEngine.GenerationParams, model: String) -> ReadiumGCDWebServerResponse {
        let responseReady = DispatchSemaphore(value: 0)
        var streamResponse: ReadiumGCDWebServerStreamedResponse?

        let tokenBuffer = TokenBuffer()

        // Start generation in the engine queue
        do {
            try engine.generate(prompt: prompt, params: params, onToken: { token in
                tokenBuffer.append(token)
            }, onComplete: { _, _ in
                tokenBuffer.markDone()
            })
        } catch {
            return errorResponse(message: error.localizedDescription, status: 500)
        }

        streamResponse = ReadiumGCDWebServerStreamedResponse(contentType: "text/event-stream", asyncStreamBlock: { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                // Send initial role chunk
                if tokenBuffer.isFirst {
                    tokenBuffer.isFirst = false
                    let roleChunk = ChatCompletionChunk.create(model: model, content: nil, role: "assistant")
                    if let data = try? JSONEncoder().encode(roleChunk) {
                        let line = "data: \(String(data: data, encoding: .utf8)!)\n\n"
                        completion(line.data(using: .utf8)!, nil)
                        return
                    }
                }

                // Try to get next token
                if let token = tokenBuffer.next(timeout: 30.0) {
                    let chunk = ChatCompletionChunk.create(model: model, content: token)
                    if let data = try? JSONEncoder().encode(chunk) {
                        let line = "data: \(String(data: data, encoding: .utf8)!)\n\n"
                        completion(line.data(using: .utf8)!, nil)
                    }
                } else if tokenBuffer.isDone {
                    // Send finish chunk
                    let finishChunk = ChatCompletionChunk.create(model: model, content: nil, finishReason: "stop")
                    if let data = try? JSONEncoder().encode(finishChunk) {
                        var final_data = "data: \(String(data: data, encoding: .utf8)!)\n\n"
                        final_data += "data: [DONE]\n\n"
                        completion(final_data.data(using: .utf8)!, nil)
                    } else {
                        completion("data: [DONE]\n\n".data(using: .utf8)!, nil)
                    }
                    completion(Data(), nil) // Signal end of stream
                }
            }
        })

        streamResponse?.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
        streamResponse?.setValue("no-cache", forAdditionalHeader: "Cache-Control")
        streamResponse?.setValue("keep-alive", forAdditionalHeader: "Connection")

        return streamResponse ?? errorResponse(message: "Failed to create stream", status: 500)
    }

    // MARK: - Prompt Building

    private func buildPrompt(from messages: [ChatMessage]) -> String {
        // Qwen chat template format
        var prompt = ""

        for message in messages {
            switch message.role {
            case "system":
                prompt += "<|im_start|>system\n\(message.content)<|im_end|>\n"
            case "user":
                prompt += "<|im_start|>user\n\(message.content)<|im_end|>\n"
            case "assistant":
                prompt += "<|im_start|>assistant\n\(message.content)<|im_end|>\n"
            default:
                prompt += "<|im_start|>\(message.role)\n\(message.content)<|im_end|>\n"
            }
        }

        // Add the assistant turn start
        prompt += "<|im_start|>assistant\n"

        return prompt
    }

    // MARK: - Helpers

    private func jsonResponse<T: Encodable>(_ value: T, status: Int = 200) -> ReadiumGCDWebServerDataResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else {
            return ReadiumGCDWebServerDataResponse(statusCode: 500)
        }
        let response = ReadiumGCDWebServerDataResponse(data: data, contentType: "application/json")
        response.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
        return response
    }

    private func errorResponse(message: String, status: Int) -> ReadiumGCDWebServerDataResponse {
        let err = ErrorResponse.create(message: message)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(err) else {
            return ReadiumGCDWebServerDataResponse(statusCode: status)
        }
        let response = ReadiumGCDWebServerDataResponse(data: data, contentType: "application/json")
        response.statusCode = status
        response.setValue("*", forAdditionalHeader: "Access-Control-Allow-Origin")
        return response
    }

    static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" { // WiFi
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }

        return address
    }
}

// Thread-safe token buffer for streaming
private class TokenBuffer {
    private var tokens: [String] = []
    private var readIndex = 0
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private(set) var isDone = false
    var isFirst = true

    func append(_ token: String) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
        semaphore.signal()
    }

    func markDone() {
        lock.lock()
        isDone = true
        lock.unlock()
        semaphore.signal()
    }

    func next(timeout: TimeInterval) -> String? {
        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return nil }

        lock.lock()
        defer { lock.unlock() }

        if readIndex < tokens.count {
            let token = tokens[readIndex]
            readIndex += 1
            return token
        }
        return nil
    }
}
