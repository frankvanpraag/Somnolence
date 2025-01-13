import Foundation
import UserNotifications
import UIKit

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    private var activeAlarmModal: AlarmModalViewController?
    private let modalQueue = DispatchQueue(label: "com.vanpraag.miso.Somnolence.modalQueue")
    private var isProcessingAction = false
    
    override init() {
        super.init()
        setupNotificationCategories()
    }
    
    private func setupNotificationCategories() {
        let snoozeAction = UNNotificationAction(
            identifier: "SNOOZE_ACTION",
            title: "Snooze 5 Minutes",
            options: [.foreground]
        )
        
        let stopAction = UNNotificationAction(
            identifier: "STOP_ACTION",
            title: "Stop Alarm",
            options: [.foreground, .destructive]
        )
        
        let category = UNNotificationCategory(
            identifier: "ALARM_CATEGORY",
            actions: [snoozeAction, stopAction],
            intentIdentifiers: [],
            options: [.customDismissAction, .hiddenPreviewsShowTitle]
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        
        if let soundName = userInfo["soundName"] as? String,
           let alarmId = userInfo["alarmId"] as? String {
            showAlarmModal(soundName: soundName, alarmId: alarmId)
        }
        
        // Don't show the notification banner since we're showing the modal
        completionHandler([])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Stop sound IMMEDIATELY for snooze or stop actions
        if response.actionIdentifier == "SNOOZE_ACTION" || response.actionIdentifier == "STOP_ACTION" {
            AudioManager.shared.stopAlarmSound()
        }
        
        // Then process the action
        modalQueue.async { [weak self] in
            guard let self = self, !self.isProcessingAction else {
                completionHandler()
                return
            }
            
            self.isProcessingAction = true
            let userInfo = response.notification.request.content.userInfo
            
            switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                if let soundName = userInfo["soundName"] as? String,
                   let alarmId = userInfo["alarmId"] as? String {
                    self.showAlarmModal(soundName: soundName, alarmId: alarmId)
                }
                
            case "STOP_ACTION":
                // Modal dismissal only - sound already stopped
                DispatchQueue.main.async {
                    self.dismissAlarmModal {
                        self.isProcessingAction = false
                        completionHandler()
                    }
                }
                return
                
            case "SNOOZE_ACTION":
                if let soundName = userInfo["soundName"] as? String,
                   let alarmId = userInfo["alarmId"] as? String {
                    // Schedule snooze - sound already stopped
                    self.scheduleSnoozeAlarm(soundName: soundName, alarmId: alarmId)
                    self.dismissAlarmModal {
                        self.isProcessingAction = false
                        completionHandler()
                    }
                    return
                }
                
            default:
                break
            }
            
            self.isProcessingAction = false
            completionHandler()
        }
    }
    
    private func dismissAlarmModal(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let modalVC = self.activeAlarmModal else {
                completion?()
                return
            }
            
            modalVC.dismiss(animated: true) {
                self.activeAlarmModal = nil
                completion?()
            }
        }
    }
    
    private func scheduleSnoozeAlarm(soundName: String, alarmId: String) {
        let snoozeUntil = Date().addingTimeInterval(5 * 60)
        
        // Schedule the snooze using AlarmScheduler
        AlarmScheduler.shared.scheduleAlarm(for: snoozeUntil, soundName: soundName) { success, error in
            if let error = error {
                print("Failed to schedule snooze alarm: \(error)")
            } else {
                // Update alarm state
                if let alarmUUID = UUID(uuidString: alarmId),
                   let index = ContentView.shared.alarms.firstIndex(where: { $0.id == alarmUUID }) {
                    DispatchQueue.main.async {
                        ContentView.shared.alarms[index].snoozedUntil = snoozeUntil
                        ContentView.shared.saveAlarms()
                        ContentView.shared.refreshNotificationStatus()
                    }
                }
            }
        }
    }
    
    func showAlarmModal(soundName: String, alarmId: String) {
        modalQueue.async { [weak self] in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                // Check if there's already an active modal
                if self.activeAlarmModal != nil {
                    print("Alarm modal already active, not showing new one")
                    return
                }
                
                // First play the sound
                AudioManager.shared.playAlarmSound(named: soundName)
                
                // Then ensure we show the modal
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let window = windowScene.windows.first,
                      let rootVC = window.rootViewController else {
                    return
                }
                
                // Ensure no other modal is currently presented
                if rootVC.presentedViewController != nil {
                    print("Another modal is presented, dismissing it first")
                    rootVC.dismiss(animated: true) { [weak self] in
                        self?.presentNewAlarmModal(rootVC: rootVC, soundName: soundName, alarmId: alarmId)
                    }
                } else {
                    self.presentNewAlarmModal(rootVC: rootVC, soundName: soundName, alarmId: alarmId)
                }
            }
        }
    }
    
    private func presentNewAlarmModal(rootVC: UIViewController, soundName: String, alarmId: String) {
        // Find the actual alarm from storage to get its name
        let alarmUUID = UUID(uuidString: alarmId) ?? UUID()
        let alarm = ContentView.shared.alarms.first { $0.id == alarmUUID } ??
            Alarm(id: alarmUUID, soundName: soundName)
        
        let modalVC = AlarmModalViewController(
            alarm: alarm,
            triggerTime: Date(),
            onStop: { [weak self] in
                AudioManager.shared.stopAlarmSound()
                rootVC.dismiss(animated: true) {
                    self?.activeAlarmModal = nil
                }
            },
            onSnooze: { [weak self] in
                AudioManager.shared.stopAlarmSound()
                self?.scheduleSnoozeAlarm(soundName: soundName, alarmId: alarmId)
                rootVC.dismiss(animated: true) {
                    self?.activeAlarmModal = nil
                }
            }
        )
        
        // Store reference to current modal
        self.activeAlarmModal = modalVC
        
        // Present the modal
        rootVC.present(modalVC, animated: true)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }
    
    // Clean up when app goes to background
    func cleanupActiveModal() {
        DispatchQueue.main.async { [weak self] in
            if let activeModal = self?.activeAlarmModal {
                activeModal.dismiss(animated: false) {
                    self?.activeAlarmModal = nil
                }
            }
        }
    }
} 