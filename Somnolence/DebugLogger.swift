import Foundation
import BackgroundTasks

class DebugLogger {
    static let shared = DebugLogger()
    private var logFile: URL?
    private let queue = DispatchQueue(label: "com.vanpraag.miso.Somnolence.logger")
    
    private init() {
        setupLogFile()
    }
    
    private func setupLogFile() {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Failed to get documents directory")
            return
        }
        
        logFile = documentsDirectory.appendingPathComponent("debug.log")
        
        // Rotate log file if it gets too large (>5MB)
        if let size = try? FileManager.default.attributesOfItem(atPath: logFile?.path ?? "")[.size] as? Int64,
           size > 5_000_000 {
            try? FileManager.default.removeItem(at: logFile!)
        }
    }
    
    func log(_ message: String, type: LogType = .info, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let filename = (file as NSString).lastPathComponent
        let logMessage = "[\(timestamp)] [\(type.rawValue)] [\(filename):\(line)] \(function): \(message)"
        
        queue.async { [weak self] in
            guard let self = self, let logFile = self.logFile else { return }
            
            print(logMessage) // Also print to console
            
            do {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write("\(logMessage)\n".data(using: .utf8)!)
                    handle.closeFile()
                } else {
                    try logMessage.appendLineToURL(fileURL: logFile)
                }
            } catch {
                print("❌ Failed to write to log file: \(error)")
            }
        }
    }
    
    func logBackgroundTaskError(_ error: Error, identifier: String) {
        let errorCode = (error as NSError).code
        let errorDomain = (error as NSError).domain
        let errorMessage = """
        Background Task Error:
        - Identifier: \(identifier)
        - Domain: \(errorDomain)
        - Code: \(errorCode)
        - Description: \(error.localizedDescription)
        - Debug Description: \((error as NSError).debugDescription)
        - User Info: \((error as NSError).userInfo)
        """
        
        log(errorMessage, type: .error)
        
        // Additional BGTaskScheduler specific debugging
        if errorDomain == BGTaskScheduler.errorDomain {
            switch errorCode {
            case 1:
                log("BGTaskScheduler Error: Invalid task identifier or not registered properly", type: .error)
                validateTaskIdentifier(identifier)
            case 2:
                log("BGTaskScheduler Error: Too many pending tasks", type: .error)
            case 3:
                log("BGTaskScheduler Error: Not permitted to run in background", type: .error)
                validateBackgroundPermissions()
            default:
                log("BGTaskScheduler Error: Unknown error code \(errorCode)", type: .error)
            }
        }
    }
    
    private func validateTaskIdentifier(_ identifier: String) {
        // Check if identifier matches bundle ID pattern
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        log("Bundle Identifier: \(bundleId)", type: .debug)
        log("Task Identifier: \(identifier)", type: .debug)
        
        // Check Info.plist configuration
        if let infoPlistPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
           let infoPlist = NSDictionary(contentsOfFile: infoPlistPath) {
            if let permittedIdentifiers = infoPlist["BGTaskSchedulerPermittedIdentifiers"] as? [String] {
                log("Permitted identifiers in Info.plist: \(permittedIdentifiers)", type: .debug)
                if !permittedIdentifiers.contains(identifier) {
                    log("❌ Task identifier not found in BGTaskSchedulerPermittedIdentifiers", type: .error)
                }
            } else {
                log("❌ No BGTaskSchedulerPermittedIdentifiers found in Info.plist", type: .error)
            }
        }
    }
    
    private func validateBackgroundPermissions() {
        if let infoPlistPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
           let infoPlist = NSDictionary(contentsOfFile: infoPlistPath) {
            if let backgroundModes = infoPlist["UIBackgroundModes"] as? [String] {
                log("Configured background modes: \(backgroundModes)", type: .debug)
                
                let requiredModes = ["fetch", "processing", "audio"]
                let missingModes = requiredModes.filter { !backgroundModes.contains($0) }
                
                if !missingModes.isEmpty {
                    log("❌ Missing required background modes: \(missingModes)", type: .error)
                }
            } else {
                log("❌ No UIBackgroundModes found in Info.plist", type: .error)
            }
        }
    }
    
    func getLogContents() -> String {
        guard let logFile = logFile else {
            return "Log file not found."
        }
        
        do {
            return try String(contentsOf: logFile, encoding: .utf8)
        } catch {
            return "Failed to load logs: \(error.localizedDescription)"
        }
    }
    
    func clearLogs() {
        guard let logFile = logFile else { return }
        
        queue.async {
            do {
                try "".write(to: logFile, atomically: true, encoding: .utf8)
                self.log("Logs cleared", type: .info)
            } catch {
                self.log("Failed to clear logs: \(error)", type: .error)
            }
        }
    }
    
    enum LogType: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }
}

// Helper extension for writing to log file
extension String {
    func appendLineToURL(fileURL: URL) throws {
        try (self + "\n").appendToURL(fileURL: fileURL)
    }
    
    func appendToURL(fileURL: URL) throws {
        let data = self.data(using: String.Encoding.utf8)!
        try data.append(to: fileURL)
    }
}

extension Data {
    func append(to fileURL: URL) throws {
        if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            defer {
                fileHandle.closeFile()
            }
            fileHandle.seekToEndOfFile()
            fileHandle.write(self)
        } else {
            try write(to: fileURL, options: .atomic)
        }
    }
} 
