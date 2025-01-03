import AVFoundation
import UIKit
import MediaPlayer

class AudioManager {
    static let shared = AudioManager()
    private var audioPlayer: AVAudioPlayer?
    private var systemSoundTimer: Timer?
    private var previewVolume: Float = 0.5
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var originalVolume: Float?
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        // Monitor route changes (e.g., headphones connected/disconnected)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        restoreOriginalVolume()
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
    
    @objc private func handleRouteChange(notification: Notification) {
        // When audio route changes, ensure volume is still at maximum for active alarms
        if audioPlayer?.isPlaying == true && !isPreviewMode {
            ensureMaximumVolume()
        }
    }
    
    private var isPreviewMode: Bool = false
    
    private func setupAudioSession(forPreview: Bool) {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            if forPreview {
                // For previews, use standard playback
                try audioSession.setCategory(
                    .playback,
                    mode: .default,
                    options: [.mixWithOthers]
                )
            } else {
                // For actual alarms, use more aggressive settings
                try audioSession.setCategory(
                    .playback,
                    mode: .default,
                    options: [.duckOthers]
                )
                
                if #available(iOS 15.0, *) {
                    try audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)
                }
            }
            
            try audioSession.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    private func ensureMaximumVolume() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Store original volume if not already stored
            if originalVolume == nil {
                originalVolume = audioSession.outputVolume
            }
            
            // Set system volume to maximum for the alarm
            try audioSession.setActive(true)
            let volumeView = MPVolumeView()
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.value = 1.0
            }
        } catch {
            print("Error setting maximum volume: \(error)")
        }
    }
    
    private func restoreOriginalVolume() {
        if let volume = originalVolume {
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setActive(true)
                let volumeView = MPVolumeView()
                if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                    slider.value = volume
                }
                originalVolume = nil
            } catch {
                print("Error restoring original volume: \(error)")
            }
        }
    }
    
    func playAlarmSound(named soundName: String, isPreview: Bool = false) {
        isPreviewMode = isPreview
        
        if !isPreview {
            startBackgroundTask()
        }
        
        setupAudioSession(forPreview: isPreview)
        
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
        
        if !isPreview {
            ensureMaximumVolume()
        }
    }
    
    func stopAlarmSound() {
        // Stop audio player if active
        audioPlayer?.stop()
        audioPlayer = nil
        
        // Stop system sound loop if active
        systemSoundTimer?.invalidate()
        systemSoundTimer = nil
        
        // Restore original volume if this wasn't a preview
        if !isPreviewMode {
            restoreOriginalVolume()
        }
        
        // Deactivate audio session
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
        
        endBackgroundTask()
        isPreviewMode = false
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
            
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            
            if !isPreview {
                ensureMaximumVolume()
            }
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