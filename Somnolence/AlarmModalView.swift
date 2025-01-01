import SwiftUI
import UIKit

struct AlarmModalView: View {
    let alarm: Alarm
    let triggerTime: Date
    let onStop: () -> Void
    let onSnooze: () -> Void
    
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 40) {
                Text(timeString)
                    .font(.system(size: 80, weight: .thin, design: .rounded))
                    .foregroundColor(.white)
                    .onReceive(timer) { _ in
                        currentTime = Date()
                    }
                
                VStack(spacing: 8) {
                    Text(alarm.name)
                        .font(.title)
                        .foregroundColor(.white)
                    
                    Text(alarmStatusText)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    
                    Text(elapsedTimeString)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                HStack(spacing: 30) {
                    Button(action: onSnooze) {
                        VStack {
                            Image(systemName: "zzz")
                                .font(.title)
                            Text("Snooze")
                        }
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.blue.opacity(0.3))
                        .cornerRadius(15)
                    }
                    
                    Button(action: onStop) {
                        VStack {
                            Image(systemName: "stop.circle")
                                .font(.title)
                            Text("Stop")
                        }
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.red.opacity(0.3))
                        .cornerRadius(15)
                    }
                }
            }
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: currentTime)
    }
    
    private var alarmTimeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: triggerTime)
    }
    
    private var elapsedTimeString: String {
        let elapsed = Int(currentTime.timeIntervalSince(triggerTime))
        let minutes = elapsed / 60
        
        if minutes == 0 {
            return "Just now"
        } else if minutes == 1 {
            return "1 minute ago"
        } else {
            return "\(minutes) minutes ago"
        }
    }
    
    private var alarmStatusText: String {
        if let snoozedUntil = alarm.snoozedUntil,
           snoozedUntil.timeIntervalSince(triggerTime) < 60 {
            return "Snoozed alarm"
        } else {
            return "Alarm set for \(alarmTimeString)"
        }
    }
}

class AlarmModalViewController: UIHostingController<AlarmModalView> {
    init(alarm: Alarm, triggerTime: Date, onStop: @escaping () -> Void, onSnooze: @escaping () -> Void) {
        super.init(rootView: AlarmModalView(
            alarm: alarm,
            triggerTime: triggerTime,
            onStop: onStop,
            onSnooze: onSnooze
        ))
        self.modalPresentationStyle = .fullScreen
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
} 
