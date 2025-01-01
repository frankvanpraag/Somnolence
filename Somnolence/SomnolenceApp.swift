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
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Set up notification delegate first
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        
        // Initialize audio session
        initializeAudioSession()
        
        // Enable background processing
        setupBackgroundTasks()
        
        return true
    }
    
    private func initializeAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Configure for playback without mixing
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: []  // Remove mixing options since we're using long-form audio
            )
            
            // Set audio session to critical playback
            if #available(iOS 15.0, *) {
                try audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)
            }
            
            // Activate the session after configuration
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Enable background audio
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }
    
    private func setupBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.vanpraag.miso.Somnolence.alarm.refresh",
                using: nil
            ) { task in
                self.handleBackgroundTask(task as! BGAppRefreshTask)
            }
            
            scheduleBackgroundTask()
        } else {
            // Fallback for older iOS versions
            UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        }
    }
    
    private func scheduleBackgroundTask() {
        if #available(iOS 13.0, *) {
            let request = BGAppRefreshTaskRequest(identifier: "com.vanpraag.miso.Somnolence.alarm.refresh")
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
            
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                print("Mmmm. Not running on iOS 13.0 so no need to schedule background task")
            }
        }
    }
    
    // Handle background fetch
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        checkPendingAlarms()
        completionHandler(.newData)
    }
    
    // Handle background task expiration
    func applicationDidEnterBackground(_ application: UIApplication) {
        startBackgroundTask()
    }
    
    private func startBackgroundTask() {
        // End previous task if any
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        
        // Start new background task
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    private func checkPendingAlarms() {
        // Load alarms and check for any that should be triggered
        if let savedAlarms = UserDefaults.standard.data(forKey: "SavedAlarms"),
           let alarms = try? JSONDecoder().decode([Alarm].self, from: savedAlarms) {
            
            for alarm in alarms {
                if let snoozedUntil = alarm.snoozedUntil, snoozedUntil > Date() {
                    scheduleLocalNotification(for: alarm, at: snoozedUntil)
                }
            }
        }
    }
    
    private func scheduleLocalNotification(for alarm: Alarm, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Wake Up!"
        content.body = "Time to rise and shine"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("\(alarm.soundName).wav"))
        content.userInfo = ["soundName": alarm.soundName, "alarmId": alarm.id.uuidString]
        content.categoryIdentifier = "ALARM_CATEGORY"
        
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: date.timeIntervalSinceNow,
            repeats: false
        )
        
        let request = UNNotificationRequest(
            identifier: "alarm-\(alarm.id)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func handleBackgroundTask(_ task: BGAppRefreshTask) {
        // Schedule next background task
        scheduleBackgroundTask()
        
        // Check and update alarms
        checkPendingAlarms()
        
        task.setTaskCompleted(success: true)
    }
}
