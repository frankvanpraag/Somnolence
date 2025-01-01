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
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let backgroundTaskIdentifier = "com.somnolence.refresh"
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Set up notification delegate first
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        
        // Initialize audio session
        initializeAudioSession()
        
        // Register background task
        registerBackgroundTask()
        
        // Handle launch from notification
        if let notification = launchOptions?[.remoteNotification] as? [String: AnyObject] {
            handleNotificationLaunch(notification)
        }
        
        return true
    }
    
    private func initializeAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Configure for playback without mixing
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: []
            )
            
            // Set audio session to critical playback
            if #available(iOS 15.0, *) {
                try audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)
            }
            
            // Activate the session after configuration
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }
    
    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleBackgroundTask(task as! BGAppRefreshTask)
        }
        scheduleBackgroundTask()
    }
    
    private func scheduleBackgroundTask() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule background task: \(error)")
        }
    }
    
    private func handleBackgroundTask(_ task: BGAppRefreshTask) {
        // Schedule the next background refresh
        scheduleBackgroundTask()
        
        // Add task expiration handler
        task.expirationHandler = { [weak self] in
            self?.endBackgroundTask()
        }
        
        // Perform background refresh
        ContentView.shared.handleBackgroundRefresh()
        
        // Mark task complete
        task.setTaskCompleted(success: true)
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Start background task
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        
        // Schedule next background refresh
        scheduleBackgroundTask()
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        ContentView.shared.handleAppTermination()
        endBackgroundTask()
    }
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    private func handleNotificationLaunch(_ notification: [String: AnyObject]) {
        if let alarmId = notification["alarmId"] as? String,
           let soundName = notification["soundName"] as? String {
            NotificationDelegate.shared.showAlarmModal(soundName: soundName, alarmId: alarmId)
        }
    }
}
