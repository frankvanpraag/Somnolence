import SwiftUI
import UIKit

struct LogViewer: View {
    @State private var logContents: String = "Loading logs..."
    @State private var showingShareSheet = false
    @State private var showingCopiedAlert = false
    @State private var isAutoRefreshEnabled = true
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss
    
    // Timer for auto-refresh
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    
    var filteredLogs: String {
        if searchText.isEmpty {
            return logContents
        }
        return logContents.components(separatedBy: .newlines)
            .filter { $0.localizedCaseInsensitiveContains(searchText) }
            .joined(separator: "\n")
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Debug Info Header
                VStack(spacing: 8) {
                    debugInfoSection
                }
                .padding()
                .background(Color(.systemGroupedBackground))
                
                // Log Contents
                ScrollViewReader { proxy in
                    List {
                        Text(filteredLogs)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .id("logs")
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                    .listStyle(.plain)
                    .refreshable {
                        loadLogContents()
                    }
                    
                    // Jump to bottom button
                    if !logContents.isEmpty {
                        Button(action: {
                            withAnimation {
                                proxy.scrollTo("logs", anchor: .bottom)
                            }
                        }) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Color.accentColor)
                                .clipShape(Circle())
                                .shadow(radius: 2)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Section {
                            Button(action: copyLogs) {
                                Label("Copy Logs", systemImage: "doc.on.doc")
                            }
                            
                            Button(action: shareLogs) {
                                Label("Share Logs", systemImage: "square.and.arrow.up")
                            }
                        }
                        
                        Section {
                            Toggle(isOn: $isAutoRefreshEnabled) {
                                Label("Auto Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        
                        Section {
                            Button(action: clearLogs) {
                                Label("Clear Logs", systemImage: "trash")
                                    .foregroundColor(.red)
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .onAppear(perform: loadLogContents)
            .onReceive(timer) { _ in
                if isAutoRefreshEnabled {
                    loadLogContents()
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(activityItems: [createLogFile()])
                    .presentationDetents([.medium, .large])
            }
            .alert("Logs Copied", isPresented: $showingCopiedAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Log contents have been copied to your clipboard")
            }
        }
    }
    
    private var debugInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug Information")
                .font(.headline)
            
            Group {
                debugInfoRow("App Version", getAppVersion())
                debugInfoRow("Device", UIDevice.current.model)
                debugInfoRow("iOS Version", UIDevice.current.systemVersion)
                debugInfoRow("Free Space", getFreeDiskSpace())
                debugInfoRow("Log Size", getLogFileSize())
            }
            .font(.system(.caption, design: .monospaced))
        }
    }
    
    private func debugInfoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
    
    private func loadLogContents() {
        logContents = DebugLogger.shared.getLogContents()
    }
    
    private func clearLogs() {
        DebugLogger.shared.clearLogs()
        // Add slight delay to ensure logs are cleared before reloading
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            loadLogContents()
        }
    }
    
    private func copyLogs() {
        UIPasteboard.general.string = logContents
        showingCopiedAlert = true
    }
    
    private func shareLogs() {
        showingShareSheet = true
    }
    
    private func createLogFile() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let logFile = tempDir.appendingPathComponent("debug_logs.txt")
        
        do {
            try logContents.write(to: logFile, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to create log file: \(error)")
        }
        
        return logFile
    }
    
    private func getAppVersion() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
    
    private func getFreeDiskSpace() -> String {
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let freeSpace = systemAttributes[.systemFreeSize] as? Int64 ?? 0
            return ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
        } catch {
            return "Unknown"
        }
    }
    
    private func getLogFileSize() -> String {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: createLogFile().path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        } catch {
            return "Unknown"
        }
    }
}

// ShareSheet wrapper for UIActivityViewController
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
} 