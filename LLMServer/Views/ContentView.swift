import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    serverStatusCard
                    modelSection
                    controlsSection
                    settingsSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("Pirate LLM Server")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("by pinperepette")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    // MARK: - Server Status Card

    private var serverStatusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(appState.isServerRunning ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(appState.isServerRunning ? "Server Running" : "Server Stopped")
                    .font(.headline)
                Spacer()
            }

            if appState.isServerRunning, !appState.serverURL.isEmpty {
                VStack(spacing: 4) {
                    Text(appState.serverURL)
                        .font(.system(.title2, design: .monospaced))
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                    Text("Use this URL to connect from other devices")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            memoryIndicator
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var memoryIndicator: some View {
        let mem = NetworkInfo.getMemoryUsage()
        let usedPct = Double(mem.used) / Double(mem.total)

        return VStack(spacing: 4) {
            HStack {
                Text("RAM")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(NetworkInfo.formatBytes(mem.used)) / \(NetworkInfo.formatBytes(mem.total))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            ProgressView(value: usedPct)
                .tint(usedPct > 0.85 ? .red : usedPct > 0.7 ? .orange : .blue)
        }
    }

    // MARK: - Model Section

    private var modelSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "cpu")
                Text("Model")
                    .font(.headline)
                Spacer()
            }

            if appState.isModelLoaded {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(appState.engine.modelName)
                            .font(.subheadline)
                        Spacer()
                        Text("Loaded")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    HStack {
                        Spacer()
                        Button {
                            appState.engine.unloadModel()
                            appState.isModelLoaded = false
                            if appState.isServerRunning {
                                appState.stopServer()
                            }
                        } label: {
                            Label("Unload from memory", systemImage: "eject")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                }
            } else {
                modelLoadOptions
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    @State private var fileToDelete: String?
    @State private var showDeleteAlert = false

    @ViewBuilder
    private var modelLoadOptions: some View {
        VStack(spacing: 8) {
            let ggufFiles = appState.modelManager.findGGUFFiles()

            if !ggufFiles.isEmpty {
                ForEach(ggufFiles, id: \.self) { file in
                    HStack(spacing: 8) {
                        Button {
                            let path = appState.modelManager.pathForModel(named: file)
                            appState.loadModel(path: path)
                        } label: {
                            HStack {
                                Image(systemName: "doc.fill")
                                Text(file)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text("Load")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button {
                            fileToDelete = file
                            showDeleteAlert = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                Divider()
            }

            downloadSection
        }
        .alert("Delete Model", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let file = fileToDelete {
                    let path = appState.modelManager.pathForModel(named: file)
                    try? FileManager.default.removeItem(atPath: path)
                    appState.modelManager.checkModelExists()
                    appState.addLog("Deleted: \(file)")
                }
            }
        } message: {
            Text("Delete \(fileToDelete ?? "")? This cannot be undone.")
        }
    }

    private var downloadSection: some View {
        VStack(spacing: 8) {
            switch appState.modelManager.downloadState {
            case .idle:
                VStack(spacing: 8) {
                    Text("No model found. Transfer via USB or download:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        appState.modelManager.downloadModel()
                    } label: {
                        Label("Download Qwen3.5-2B Q4_K_M (~1.5 GB)", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .downloading(let progress):
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                    HStack {
                        Text("Downloading... \(Int(progress * 100))%")
                            .font(.caption)
                        Spacer()
                        Button("Cancel") {
                            appState.modelManager.cancelDownload()
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    }
                }

            case .completed:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Download complete")
                        .font(.subheadline)
                    Spacer()
                    Button("Load Model") {
                        appState.loadModel(path: appState.modelManager.modelPath)
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                }

            case .failed(let error):
                VStack(spacing: 4) {
                    Text("Download failed: \(error)")
                        .font(.caption)
                        .foregroundColor(.red)
                    Button("Retry") {
                        appState.modelManager.downloadModel()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "play.circle")
                Text("Server Controls")
                    .font(.headline)
                Spacer()
            }

            Button {
                if appState.isServerRunning {
                    appState.stopServer()
                } else {
                    appState.startServer()
                }
            } label: {
                HStack {
                    Image(systemName: appState.isServerRunning ? "stop.fill" : "play.fill")
                    Text(appState.isServerRunning ? "Stop Server" : "Start Server")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.isServerRunning ? .red : .green)
            .disabled(!appState.isModelLoaded)

            if !appState.isModelLoaded {
                Text("Load a model first to start the server")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Settings Section

    private var settingsSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "gear")
                Text("Settings")
                    .font(.headline)
                Spacer()
            }

            Toggle(isOn: $appState.keepScreenOn) {
                HStack {
                    Image(systemName: "sun.max")
                    Text("Keep Screen On")
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Log Section

    private var logSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "text.alignleft")
                Text("Log")
                    .font(.headline)
                Spacer()
                if !appState.logMessages.isEmpty {
                    Button("Clear") {
                        appState.logMessages.removeAll()
                    }
                    .font(.caption)
                }
            }

            if appState.logMessages.isEmpty {
                Text("No log entries yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.logMessages.suffix(50)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.timeString)
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                            Text(entry.message)
                                .font(.caption2)
                                .foregroundColor(.primary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}
