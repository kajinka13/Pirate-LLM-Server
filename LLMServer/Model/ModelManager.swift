import Foundation
import Combine

final class ModelManager: NSObject, ObservableObject, @unchecked Sendable {

    static let defaultModelURL = "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf"
    static let modelFileName = "Qwen3.5-2B-Q4_K_M.gguf"

    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case completed
        case failed(String)
    }

    @Published var downloadState: DownloadState = .idle
    @Published var modelExists = false
    @Published var modelSizeFormatted = ""

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?

    var modelPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(Self.modelFileName).path
    }

    override init() {
        super.init()
        checkModelExists()
    }

    func checkModelExists() {
        let fm = FileManager.default
        let path = modelPath

        if fm.fileExists(atPath: path) {
            modelExists = true
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64 {
                modelSizeFormatted = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            }
        } else {
            modelExists = false
            modelSizeFormatted = ""
        }
    }

    func findGGUFFiles() -> [String] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "gguf" }.map { $0.lastPathComponent }
    }

    func pathForModel(named name: String) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(name).path
    }

    var onLog: ((String) -> Void)?

    func downloadModel(from urlString: String? = nil) {
        let urlStr = urlString ?? Self.defaultModelURL
        guard let url = URL(string: urlStr) else {
            downloadState = .failed("Invalid URL")
            return
        }

        onLog?("Starting download from: \(urlStr)")
        downloadState = .downloading(progress: 0)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 86400
        config.allowsCellularAccess = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        downloadTask = session?.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        downloadState = .idle
    }

    func deleteModel() {
        try? FileManager.default.removeItem(atPath: modelPath)
        checkModelExists()
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destURL = URL(fileURLWithPath: modelPath)

        do {
            if FileManager.default.fileExists(atPath: modelPath) {
                try FileManager.default.removeItem(atPath: modelPath)
            }
            try FileManager.default.moveItem(at: location, to: destURL)
            DispatchQueue.main.async {
                self.onLog?("Download completed")
                self.downloadState = .completed
                self.checkModelExists()
            }
        } catch {
            DispatchQueue.main.async {
                self.downloadState = .failed("Failed to save: \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0
        }
        let totalMB = Double(totalBytesWritten) / 1_000_000.0
        DispatchQueue.main.async {
            self.downloadState = .downloading(progress: progress)
            if Int(totalMB) % 100 == 0 {
                self.onLog?("Downloaded \(String(format: "%.0f", totalMB)) MB")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                if (error as NSError).code != NSURLErrorCancelled {
                    self.onLog?("Download error: \(error.localizedDescription)")
                    self.downloadState = .failed(error.localizedDescription)
                }
            }
        }
    }
}
