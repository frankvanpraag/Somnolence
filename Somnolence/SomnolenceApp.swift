//
//  SomnolenceApp.swift
//  Somnolence
//
//  Created by Ming Bow on 17/12/2024.
//

import SwiftUI
import UserNotifications
import AVFoundation
import BackgroundTasks

@main
struct SomnolenceApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    private var isBackgroundTaskRegistered = false
    
    private func getBackgroundIdentifier(for task: String) -> String {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.vanpraag.miso.Somnolence"
        return "\(bundleId).\(task)"
    }
    
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        print("Registering background task scheduler in AppDelegate...")
        
        if #available(iOS 13.0, *) {
            // Register both refresh and processing tasks
            let tasks = ["refresh", "processing"]
            
            for task in tasks {
                let identifier = getBackgroundIdentifier(for: task)
                BGTaskScheduler.shared.register(
                    forTaskWithIdentifier: identifier,
                    using: nil
                ) { task in
                    if let refreshTask = task as? BGAppRefreshTask {
                        self.handleBackgroundRefresh(refreshTask)
                    } else if let processingTask = task as? BGProcessingTask {
                        self.handleBackgroundProcessing(processingTask)
                    }
                }
            }
            
            isBackgroundTaskRegistered = true
            print("✅ Background task scheduler registered successfully")
            
            // Schedule initial tasks
            self.scheduleBackgroundTasks()
        }
        
        return true
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Configure notification handling
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = NotificationDelegate.shared
        
        // Request notification authorization
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            guard let self = self else { return }
            
            if granted {
                print("✅ Notification permission granted")
                // Only configure AlarmScheduler if background task is registered
                DispatchQueue.main.async {
                    if self.isBackgroundTaskRegistered {
                        print("🔄 Configuring AlarmScheduler after successful registration")
                        AlarmScheduler.shared.configure()
                        // Initialize audio session after AlarmScheduler is configured
                        self.initializeAudioSession()
                    } else {
                        print("⚠️ Cannot configure AlarmScheduler - background task not registered")
                    }
                }
            } else if let error = error {
                print("❌ Failed to get notification permission: \(error)")
            }
        }
        
        return true
    }
    
    private func initializeAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // First deactivate the session to ensure clean configuration
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            
            // Configure for alarm playback with high priority
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: []  // Remove all options to avoid conflicts
            )
            
            // Configure audio routing for maximum volume
            try audioSession.overrideOutputAudioPort(.speaker)
            
            // Set audio session to critical playback
            if #available(iOS 15.0, *) {
                try audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)
            }
            
            // Finally activate the session
            try audioSession.setActive(true)
            
            print("✅ Audio session configured successfully")
        } catch {
            print("❌ Failed to set up audio session: \(error)")
        }
    }
    
    private func scheduleBackgroundTasks() {
        let logger = DebugLogger.shared
        logger.log("Attempting to schedule background tasks", type: .info)
        
        // Check if tasks are already scheduled
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let refreshIdentifier = self.getBackgroundIdentifier(for: "refresh")
            let processingIdentifier = self.getBackgroundIdentifier(for: "processing")
            
            let isRefreshScheduled = requests.contains { $0.identifier == refreshIdentifier }
            let isProcessingScheduled = requests.contains { $0.identifier == processingIdentifier }
            
            if isRefreshScheduled {
                logger.log("Refresh task is already scheduled", type: .info)
            } else {
                let refreshRequest = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
                refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)
                
                do {
                    try BGTaskScheduler.shared.submit(refreshRequest)
                    logger.log("✅ Refresh task scheduled successfully", type: .info)
                } catch {
                    logger.logBackgroundTaskError(error, identifier: refreshRequest.identifier)
                }
            }
            
            if isProcessingScheduled {
                logger.log("Processing task is already scheduled", type: .info)
            } else {
                let processingRequest = BGProcessingTaskRequest(identifier: processingIdentifier)
                processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)
                processingRequest.requiresNetworkConnectivity = false
                processingRequest.requiresExternalPower = false
                
                do {
                    try BGTaskScheduler.shared.submit(processingRequest)
                    logger.log("✅ Processing task scheduled successfully", type: .info)
                } catch {
                    logger.logBackgroundTaskError(error, identifier: processingRequest.identifier)
                }
            }
        }
    }
    
    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        // Handle refresh task
        task.expirationHandler = {
            // Clean up any unfinished tasks
        }
        
        // Schedule next refresh
        scheduleBackgroundTasks()
        
        // Mark task complete
        task.setTaskCompleted(success: true)
    }
    
    private func handleBackgroundProcessing(_ task: BGProcessingTask) {
        // Handle processing task
        task.expirationHandler = {
            // Clean up any unfinished tasks
        }
        
        // Schedule next processing task
        scheduleBackgroundTasks()
        
        // Mark task complete
        task.setTaskCompleted(success: true)
    }
}
