import AVFoundation
import UIKit

class AudioManager {
    static let shared = AudioManager()
    private var audioPlayer: AVAudioPlayer?
    private var systemSoundTimer: Timer?
    private var previewVolume: Float = 0.5
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // Audio session interrupted, handle cleanup
            stopAlarmSound()
        case .ended:
            // Check if we should resume
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // Resume audio session
                    try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                }
            }
        @unknown default:
            break
        }
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    func playAlarmSound(named soundName: String, isPreview: Bool = false) {
        if !isPreview {
            startBackgroundTask()
        }
        
        if let customSound = loadCustomSound(named: soundName) {
            playSound(customSound, isPreview: isPreview)
            return
        }
        
        // For system sound, we need to create a continuous loop
        if !isPreview {
            // Create a repeating timer to keep playing the system sound
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                AudioServicesPlaySystemSound(1005)
                // Store timer to stop it later
                self?.systemSoundTimer = timer
            }
        } else {
            AudioServicesPlaySystemSound(1005)
        }
    }
    
    func stopAlarmSound() {
        audioPlayer?.stop()
        audioPlayer = nil
        
        // Stop system sound loop if active
        systemSoundTimer?.invalidate()
        systemSoundTimer = nil
        
        endBackgroundTask()
    }
    
    private func loadCustomSound(named soundName: String) -> URL? {
        // Try both wav and mp3
        if let wavURL = Bundle.main.url(forResource: soundName, withExtension: "wav") {
            return wavURL
        }
        if let mp3URL = Bundle.main.url(forResource: soundName, withExtension: "mp3") {
            return mp3URL
        }
        return nil
    }
    
    private func playSound(_ url: URL, isPreview: Bool) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.volume = isPreview ? previewVolume : 1.0
            
            // Always loop for alarms, never for previews
            audioPlayer?.numberOfLoops = isPreview ? 0 : -1
            
            // Ensure audio session is active and properly configured
            try AVAudioSession.sharedInstance().setActive(true)
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .duckOthers]
            )
            
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            print("Failed to play sound: \(error)")
            // Fall back to system sound with loop
            playAlarmSound(named: "system_alarm", isPreview: isPreview)
        }
    }
    
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
} 