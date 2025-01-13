import Foundation
import BackgroundTasks
import UserNotifications
import AVFoundation

/// Manages alarm scheduling and background refresh for the Somnolence app
final class AlarmScheduler {
    // MARK: - Properties
    
    static let shared = AlarmScheduler()
    let backgroundTaskIdentifier = "com.vanpraag.miso.Somnolence.refresh"
    private let backgroundQueue = DispatchQueue(label: "com.vanpraag.miso.Somnolence.alarmScheduler", qos: .userInitiated)
    private var isConfigured = false
    private var hasAttemptedConfiguration = false
    
    // Add dictionary to track notifications by alarm ID
    private var scheduledNotifications: [UUID: String] = [:]
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Configures the alarm scheduler after background task registration is complete
    func configure() {
        // Prevent multiple configuration attempts
        guard !hasAttemptedConfiguration else {
            print("⚠️ AlarmScheduler configuration already attempted")
            return
        }
        
        print("Configuring AlarmScheduler...")
        hasAttemptedConfiguration = true
        
        // Ensure we're on iOS 13 or later for background tasks
        guard #available(iOS 13.0, *) else {
            print("⚠️ Background tasks require iOS 13.0 or later")
            return
        }
        
        // Mark as configured
        isConfigured = true
        print("✅ AlarmScheduler configured successfully")
    }
    
    /// Handles a background refresh task
    func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        print("Checking for pending alarms in background refresh...")
        
        checkPendingAlarms { success, error in
            if let error = error {
                print("❌ Error checking pending alarms: \(error)")
                task.setTaskCompleted(success: false)
            } else {
                print("✅ Successfully checked pending alarms")
                task.setTaskCompleted(success: true)
            }
        }
    }
    
    /// Schedules an alarm for the specified date
    /// - Parameters:
    ///   - date: The date when the alarm should trigger
    ///   - soundName: The name of the sound file to play
    ///   - completion: Called with success status and optional error
    func scheduleAlarm(for date: Date, soundName: String, completion: @escaping (Bool, Error?) -> Void) {
        let notificationId = UUID().uuidString
        
        let content = UNMutableNotificationContent()
        content.title = "Alarm"
        content.sound = .none // We'll handle custom sound playback ourselves
        content.userInfo = [
            "alarmId": UUID().uuidString,
            "soundName": soundName
        ]
        content.interruptionLevel = .timeSensitive // Ensure notification can break through Focus modes
        
        // Create date components for precise timing
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        // Create and add the notification request
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                DebugLogger.shared.log("Failed to schedule alarm notification: \(error)", type: .error)
                completion(false, error)
            } else {
                // Store the notification ID for tracking
                if let alarmId = content.userInfo["alarmId"] as? String {
                    self?.scheduledNotifications[UUID(uuidString: alarmId) ?? UUID()] = notificationId
                }
                
                // Only schedule background refresh if we're configured
                if self?.isConfigured == true {
                    self?.scheduleNextBackgroundRefresh()
                }
                completion(true, nil)
            }
        }
    }
    
    /// Cancels all pending alarms
    func cancelAllAlarms() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    
    /// Checks for any pending alarms that need to be triggered
    /// - Parameter completion: Called with success status and optional error when check is complete
    func checkPendingAlarms(completion: @escaping (Bool, Error?) -> Void) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] requests in
            let now = Date()
            let calendar = Calendar.current
            
            for request in requests {
                guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                      let triggerDate = calendar.date(from: trigger.dateComponents) else {
                    continue
                }
                
                // If the alarm should have triggered in the last minute
                if triggerDate <= now && triggerDate > calendar.date(byAdding: .minute, value: -1, to: now)! {
                    self?.triggerAlarm(request: request)
                }
            }
            
            completion(true, nil)
        }
    }
    
    /// Schedules the next background refresh task
    func scheduleNextBackgroundRefresh() {
        guard #available(iOS 13.0, *) else { return }
        
        // Cancel any existing tasks before scheduling a new one
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
        
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60) // Schedule next refresh in 1 minute
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("✅ Next background refresh scheduled for 1 minute from now")
        } catch {
            print("❌ Failed to schedule next background refresh: \(error)")
            // Retry after 10 seconds if we're still configured
            if isConfigured {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                    guard let self = self else { return }
                    print("🔄 Retrying background refresh task scheduling...")
                    self.scheduleNextBackgroundRefresh()
                }
            }
        }
    }
    
    func cancelAlarm(for alarmId: UUID) {
        // Get the notification identifier for this alarm
        if let notificationId = scheduledNotifications[alarmId] {
            // Remove the scheduled notification
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationId])
            
            // Remove from our tracking dictionary
            scheduledNotifications.removeValue(forKey: alarmId)
            
            DebugLogger.shared.log("Cancelled alarm with ID: \(alarmId)", type: .info)
        }
    }
    
    // Helper method to get current alarm ID
    private func getCurrentAlarmId() -> UUID? {
        // This should be implemented based on your alarm management logic
        // For example, you might want to pass the alarm ID when scheduling
        return nil // Implement this based on your needs
    }
    
    // MARK: - Private Methods
    
    private func triggerAlarm(request: UNNotificationRequest) {
        guard let alarmId = request.content.userInfo["alarmId"] as? String,
              let soundName = request.content.userInfo["soundName"] as? String else {
            return
        }
        
        // Remove the notification since we're handling it manually
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [request.identifier])
        
        // Ensure we're on the main thread for UI updates
        DispatchQueue.main.async {
            NotificationDelegate.shared.showAlarmModal(soundName: soundName, alarmId: alarmId)
        }
    }
} 
