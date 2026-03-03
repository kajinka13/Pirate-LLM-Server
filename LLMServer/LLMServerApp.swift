import SwiftUI

@main
struct LLMServerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    let engine = LLMEngine()
    let modelManager = ModelManager()
    lazy var server = APIServer(engine: engine)
    let keepAlive = BackgroundKeepAlive()

    @Published var isServerRunning = false
    @Published var serverURL: String = ""
    @Published var logMessages: [LogEntry] = []
    @Published var isModelLoaded = false
    @Published var keepScreenOn = true {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String

        var timeString: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: timestamp)
        }
    }

    init() {
        UIApplication.shared.isIdleTimerDisabled = true

        engine.onLog = { [weak self] message in
            DispatchQueue.main.async {
                self?.addLog(message)
            }
        }

        modelManager.onLog = { [weak self] message in
            DispatchQueue.main.async {
                self?.addLog(message)
            }
        }
    }

    func addLog(_ message: String) {
        let entry = LogEntry(timestamp: Date(), message: message)
        logMessages.append(entry)
        // Keep last 200 entries
        if logMessages.count > 200 {
            logMessages.removeFirst(logMessages.count - 200)
        }
    }

    func loadModel(path: String) {
        addLog("Loading model...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.engine.loadModel(at: path)
                DispatchQueue.main.async {
                    self?.isModelLoaded = true
                    self?.addLog("Model loaded successfully")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isModelLoaded = false
                    self?.addLog("Failed to load model: \(error.localizedDescription)")
                }
            }
        }
    }

    func startServer() {
        guard engine.isLoaded else {
            addLog("Cannot start server: model not loaded")
            return
        }

        server.onLog = { [weak self] message in
            DispatchQueue.main.async {
                self?.addLog(message)
            }
        }

        do {
            try server.start()
            isServerRunning = true
            serverURL = server.serverURL ?? "http://localhost:8080"
            keepAlive.start()
            addLog("Server running at \(serverURL)")
        } catch {
            addLog("Failed to start server: \(error.localizedDescription)")
        }
    }

    func stopServer() {
        server.stop()
        isServerRunning = false
        serverURL = ""
        keepAlive.stop()
        addLog("Server stopped")
    }
}
