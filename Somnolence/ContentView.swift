//
//  ContentView.swift
//  Somnolence
//
//  Created by Frank van Praag on 17/12/2024.
//

import SwiftUI
import AVFoundation
import UserNotifications

struct Alarm: Identifiable, Codable {
    let id: UUID
    var time: Date
    var isEnabled: Bool
    var soundName: String
    var days: Set<Int> // 1 = Sunday, 2 = Monday, etc.
    var snoozedUntil: Date?
    var name: String
    
    init(id: UUID = UUID(), time: Date = Date(), isEnabled: Bool = true, soundName: String = "system_alarm", days: Set<Int> = Set(1...7), snoozedUntil: Date? = nil, name: String = "Alarm") {
        self.id = id
        self.time = time
        self.isEnabled = isEnabled
        self.soundName = soundName
        self.days = days
        self.snoozedUntil = snoozedUntil
        self.name = name
    }
}

struct ContentView: View {
    static let shared = ContentViewState()
    @StateObject private var state = ContentViewState()
    
    class ContentViewState: ObservableObject {
        @Published var alarms: [Alarm] = []
        private var lastPendingNotifications: String? // Track last notification state
        
        // Add static helper function for day names
        private static func dayName(_ weekday: Int) -> String {
            let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            return days[weekday - 1]
        }
        
        // Add logging function with timestamp
        private func log(_ message: String) {
            let timestamp = formatDate(Date())
            print("[\(timestamp)] \(message)")
        }
        
        init() {
            loadAlarms()
            // Ensure notifications are scheduled for all enabled alarms
            rescheduleAllAlarms()
            
            // Register for app termination notification
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppTermination),
                name: UIApplication.willTerminateNotification,
                object: nil
            )
            
            // Register for time change notifications
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSignificantTimeChange),
                name: UIApplication.significantTimeChangeNotification,
                object: nil
            )
        }
        
        @objc public func handleAppTermination() {
            // Save current state
            saveAlarms()
            
            // Ensure all notifications are properly scheduled
            rescheduleAllAlarms()
        }
        
        @objc public func handleSignificantTimeChange() {
            // Reschedule all alarms when time changes significantly (e.g., timezone change)
            rescheduleAllAlarms()
        }
        
        public func rescheduleAllAlarms() {
            // First, cancel all existing notifications
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            
            // Then reschedule all enabled alarms
            for alarm in alarms where alarm.isEnabled {
                scheduleAlarm(alarm)
            }
            
            // Force a refresh of the notification status
            refreshNotificationStatus()
        }
        
        // Add function to force notification status refresh
        func refreshNotificationStatus() {
            // Force refresh by clearing last known state
            self.lastPendingNotifications = nil
            loadAlarms()
        }
        
        func loadAlarms() {
            if let savedAlarms = UserDefaults.standard.data(forKey: "SavedAlarms"),
               let decodedAlarms = try? JSONDecoder().decode([Alarm].self, from: savedAlarms) {
                self.alarms = decodedAlarms
                
                // Get pending notifications to cross-reference
                UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                    // Clean up orphaned notifications
                    let validAlarmIds = Set(self.alarms.map { $0.id.uuidString })
                    
                    // Group all notifications by alarm ID
                    let notificationsByAlarm = Dictionary(grouping: requests) { request -> String in
                        request.content.userInfo["alarmId"] as? String ?? "unknown"
                    }
                    
                    // Find orphaned notifications
                    let orphanedNotifications = requests.filter { request in
                        guard let alarmId = request.content.userInfo["alarmId"] as? String else {
                            return true // Remove notifications without alarmId
                        }
                        return !validAlarmIds.contains(alarmId)
                    }
                    
                    // Find notifications that don't match current alarm settings
                    var invalidNotifications: [(notification: UNNotificationRequest, reason: String)] = []
                    
                    for (alarmId, notifications) in notificationsByAlarm {
                        guard let alarm = self.alarms.first(where: { $0.id.uuidString == alarmId }) else {
                            continue // Already handled by orphaned notifications
                        }
                        
                        for notification in notifications {
                            // Check if it's a snooze notification
                            if notification.identifier.starts(with: "snooze-") {
                                if alarm.snoozedUntil == nil {
                                    invalidNotifications.append((notification, "Snooze notification exists but alarm is not snoozed"))
                                }
                                continue
                            }
                            
                            // Check regular alarm notifications
                            guard let trigger = notification.trigger as? UNCalendarNotificationTrigger,
                                  let weekday = trigger.dateComponents.weekday else {
                                invalidNotifications.append((notification, "Invalid trigger type or missing weekday"))
                                continue
                            }
                            
                            // Verify the weekday is still selected for this alarm
                            if !alarm.days.contains(weekday) {
                                invalidNotifications.append((notification, "Notification exists for unselected day \(Self.dayName(weekday))"))
                            }
                            
                            // Verify the time matches
                            let alarmHour = Calendar.current.component(.hour, from: alarm.time)
                            let alarmMinute = Calendar.current.component(.minute, from: alarm.time)
                            if trigger.dateComponents.hour != alarmHour || trigger.dateComponents.minute != alarmMinute {
                                invalidNotifications.append((notification, "Time mismatch - notification: \(trigger.dateComponents.hour ?? 0):\(trigger.dateComponents.minute ?? 0), alarm: \(alarmHour):\(alarmMinute)"))
                            }
                        }
                    }
                    
                    // Remove invalid notifications
                    if !invalidNotifications.isEmpty {
                        self.log("\n=== CLEANING UP INVALID NOTIFICATIONS ===")
                        self.log("Found \(invalidNotifications.count) invalid notifications")
                        
                        let identifiersToRemove = invalidNotifications.map { $0.notification.identifier }
                        UNUserNotificationCenter.current().removePendingNotificationRequests(
                            withIdentifiers: identifiersToRemove
                        )
                        
                        // Print details of removed notifications
                        for (notification, reason) in invalidNotifications {
                            self.log("\nRemoved notification:")
                            self.log("ID: \(notification.identifier)")
                            self.log("Alarm ID: \(notification.content.userInfo["alarmId"] as? String ?? "unknown")")
                            self.log("Title: \(notification.content.title)")
                            self.log("Reason: \(reason)")
                            if let trigger = notification.trigger as? UNCalendarNotificationTrigger,
                               let nextTrigger = trigger.nextTriggerDate() {
                                self.log("Next trigger: \(self.formatDate(nextTrigger))")
                            }
                        }
                        self.log("-----------------------------")
                        
                        // Reschedule notifications for affected alarms
                        let affectedAlarmIds = Set(invalidNotifications.compactMap { 
                            $0.notification.content.userInfo["alarmId"] as? String 
                        })
                        for alarmId in affectedAlarmIds {
                            if let alarm = self.alarms.first(where: { $0.id.uuidString == alarmId }) {
                                self.scheduleAlarm(alarm)
                            }
                        }
                    }
                    
                    // Handle orphaned notifications (existing code)
                    if !orphanedNotifications.isEmpty {
                        self.log("\n=== CLEANING UP ORPHANED NOTIFICATIONS ===")
                        self.log("Found \(orphanedNotifications.count) orphaned notifications")
                        
                        let identifiersToRemove = orphanedNotifications.map { $0.identifier }
                        UNUserNotificationCenter.current().removePendingNotificationRequests(
                            withIdentifiers: identifiersToRemove
                        )
                        
                        // Print details of removed notifications
                        for notification in orphanedNotifications {
                            self.log("\nRemoved notification:")
                            self.log("ID: \(notification.identifier)")
                            self.log("Alarm ID: \(notification.content.userInfo["alarmId"] as? String ?? "unknown")")
                            self.log("Title: \(notification.content.title)")
                            if let trigger = notification.trigger as? UNCalendarNotificationTrigger,
                               let nextTrigger = trigger.nextTriggerDate() {
                                self.log("Next trigger: \(self.formatDate(nextTrigger))")
                            }
                        }
                        self.log("-----------------------------")
                    }
                    
                    // Create a string representation of current notifications
                    let currentNotifications = requests.compactMap { request -> String? in
                        guard let alarmId = request.content.userInfo["alarmId"] as? String,
                              let trigger = request.trigger as? UNCalendarNotificationTrigger,
                              let nextTrigger = trigger.nextTriggerDate() else {
                            return nil
                        }
                        
                        return """
                            id: \(alarmId)
                            trigger: \(self.formatDate(nextTrigger))
                            sound: \(request.content.userInfo["soundName"] as? String ?? "None")
                            """
                    }.joined(separator: "\n---\n")
                    
                    // Only print if notifications have changed
                    if currentNotifications != self.lastPendingNotifications {
                        self.log("\n=== PENDING NOTIFICATIONS CHANGED ===")
                        self.log("Total Notifications: \(requests.count)")
                        self.log("Timestamp: \(self.formatDate(Date()))")
                        self.log("Notifications by Day:")
                        self.log("-----------------------------")
                        
                        // Group notifications by alarm ID
                        let groupedRequests = Dictionary(grouping: requests) { request -> String in
                            request.content.userInfo["alarmId"] as? String ?? "unknown"
                        }
                        
                        for (alarmId, alarmRequests) in groupedRequests {
                            // Find the corresponding alarm object to get snooze info
                            let alarm = self.alarms.first { $0.id.uuidString == alarmId }
                            
                            if let firstRequest = alarmRequests.first {
                                self.log("Alarm ID: \(alarmId)")
                                self.log("Title: \(firstRequest.content.userInfo["alarmName"] as? String ?? firstRequest.content.title)")
                                if let alarm = alarm {
                                    self.log("AlarmTime: \(self.formatTime(alarm.time))")
                                }
                                self.log("Sound: \(firstRequest.content.userInfo["soundName"] as? String ?? "None")")
                                self.log("Interruption Level: \(firstRequest.content.interruptionLevel.rawValue)")
                                
                                // Add snooze status if available
                                if let alarm = alarm,
                                   let snoozedUntil = alarm.snoozedUntil {
                                    let now = Date()
                                    if snoozedUntil > now {
                                        self.log("Snooze Status: Active")
                                        self.log("Snoozed Until: \(self.formatDate(snoozedUntil))")
                                        let timeRemaining = snoozedUntil.timeIntervalSince(now)
                                        let minutes = Int(timeRemaining) / 60
                                        let seconds = Int(timeRemaining) % 60
                                        self.log("Snooze Remaining: \(minutes)m \(seconds)s")
                                    } else {
                                        self.log("Snooze Status: Expired")
                                        self.log("Last Snooze Time: \(self.formatDate(snoozedUntil))")
                                    }
                                } else {
                                    self.log("Snooze Status: None")
                                }
                                
                                // self.log("Scheduled Times:")
                            }
                            
                            // Sort requests by next trigger date
                            let sortedRequests = alarmRequests.compactMap { request -> (Int, Date)? in
                                guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                                      let nextTrigger = trigger.nextTriggerDate(),
                                      let weekday = trigger.dateComponents.weekday else {
                                    return nil
                                }
                                return (weekday, nextTrigger)
                            }.sorted { $0.0 < $1.0 }
                            
                            // Print scheduled days in compact format
                            let scheduledDays = sortedRequests.map { $0.0 }
                            let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]
                            let scheduleString = scheduledDays.map { dayLetters[$0 - 1] }.joined(separator: " ")
                            self.log("Schedule: \(scheduleString)")
                            self.log("-----------------------------")
                        }
                        
                        // Update last known state
                        self.lastPendingNotifications = currentNotifications
                    }
                }
            } else {
                self.log("No saved alarms found.")
            }
        }
        
        private func formatDate(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            return formatter.string(from: date)
        }
        
        private func formatTime(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        
        func saveAlarms() {
            if let encoded = try? JSONEncoder().encode(alarms) {
                UserDefaults.standard.set(encoded, forKey: "SavedAlarms")
            }
        }
        
        func scheduleAlarm(_ alarm: Alarm) {
            // First ensure the alarm is saved in state without affecting other alarms
            if let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
                // Update existing alarm
                alarms[index] = alarm
            } else {
                // Add new alarm without affecting existing ones
                alarms.append(alarm)
            }
            
            // Save all alarms
            saveAlarms()
            
            // Then handle notifications
            // First cancel existing notifications for this alarm only
            for day in 1...7 {
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: ["\(alarm.id)-\(day)"]
                )
            }
            
            // Don't schedule notifications if no days are selected, but keep the alarm
            guard !alarm.days.isEmpty else { 
                refreshNotificationStatus()
                return 
            }
            
            let content = UNMutableNotificationContent()
            content.title = alarm.name
            content.body = alarm.name.lowercased().contains("wake") ? 
                "Time to rise and shine" : 
                "Your alarm '\(alarm.name)' is ringing"
            content.categoryIdentifier = "ALARM_CATEGORY"
            content.userInfo = [
                "soundName": alarm.soundName,
                "alarmId": alarm.id.uuidString,
                "alarmName": alarm.name
            ]
            content.interruptionLevel = .timeSensitive
            
            // Handle system sounds differently
            if alarm.soundName.starts(with: "system_") {
                content.sound = UNNotificationSound.default
            } else {
                let soundName = UNNotificationSoundName("\(alarm.soundName).wav")
                if #available(iOS 15.0, *) {
                    content.sound = UNNotificationSound.criticalSoundNamed(soundName)
                } else {
                    content.sound = UNNotificationSound(named: soundName)
                }
            }
            
            // Create notifications for each selected day
            let dispatchGroup = DispatchGroup()
            var scheduledCount = 0
            _ = alarm.days.count
            
            for day in alarm.days.sorted() {
                dispatchGroup.enter()
                var dateComponents = Calendar.current.dateComponents([.hour, .minute], from: alarm.time)
                dateComponents.weekday = day
                
                let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
                let request = UNNotificationRequest(
                    identifier: "\(alarm.id)-\(day)",
                    content: content,
                    trigger: trigger
                )
                
                UNUserNotificationCenter.current().add(request) { [weak self] error in
                    if let error = error {
                        self?.log("Error scheduling alarm '\(alarm.name)' for \(Self.dayName(day)): \(error)")
                    } else {
                        self?.log("Successfully scheduled '\(alarm.name)' for \(Self.dayName(day))")
                    }
                    
                    scheduledCount += 1
                    dispatchGroup.leave()
                }
            }
            
            // Wait for all notifications to be scheduled before refreshing UI
            dispatchGroup.notify(queue: .main) { [weak self] in
                self?.refreshNotificationStatus()
            }
        }
        
        func cancelAlarm(_ alarm: Alarm) {
            // Remove notifications for all days
            for day in 1...7 {
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: ["\(alarm.id)-\(day)"]
                )
            }
            
            // Also remove any snooze notifications
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["snooze-\(alarm.id)"]
            )
            
            AudioManager.shared.stopAlarmSound()
            saveAlarms()
            
            // Refresh notification status after cancellation
            DispatchQueue.main.async { [weak self] in
                self?.refreshNotificationStatus()
            }
        }
        
        private func prettyPrintAlarms(_ alarms: [Alarm]) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // Sort keys for pretty printing
            
            // Create a sorted array of dictionaries for each alarm
            let sortedAlarms = alarms.map { alarm -> [String: Any] in
                let dict: [String: Any] = [
                    "id": alarm.id.uuidString, // Keep id at the top
                    "time": formatDate(alarm.time), // Convert Date to String
                    "isEnabled": alarm.isEnabled,
                    "soundName": alarm.soundName,
                    "days": Array(alarm.days).sorted(), // Sort days
                    "snoozedUntil": alarm.snoozedUntil.map { formatDate($0) } as Any, // Handle optional with map
                    "name": alarm.name
                ]
                
                return dict
            }
            
            // Convert the sorted array of dictionaries to JSON
            let jsonData = try JSONSerialization.data(withJSONObject: sortedAlarms, options: .prettyPrinted)
            return String(data: jsonData, encoding: .utf8) ?? "Error converting to string"
        }
        
        // Add a public method for background task handling
        public func handleBackgroundRefresh() {
            // Verify and update all alarm states
            loadAlarms()
            
            // Clean up any expired snoozes
            let now = Date()
            for (index, alarm) in alarms.enumerated() {
                if let snoozedUntil = alarm.snoozedUntil, snoozedUntil < now {
                    alarms[index].snoozedUntil = nil
                }
            }
            
            // Ensure all notifications are properly scheduled
            rescheduleAllAlarms()
            
            // Save any changes
            saveAlarms()
        }
    }
    
    @State private var showingAddAlarm = false
    @State private var notificationGranted = false
    @AppStorage("selectedTab") private var selectedTab = 0
    
    init() {
        requestNotificationPermission()
    }
    
    private var isLandscape: Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }
        let bounds = windowScene.coordinateSpace.bounds
        return bounds.width > bounds.height
    }
    
    // Add binding function
    private func binding(for alarm: Alarm) -> Binding<Alarm> {
        guard let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) else {
            fatalError("Alarm not found")
        }
        return $state.alarms[index]
    }
    
    var body: some View {
        NavigationView {
            if state.alarms.isEmpty {
                AlarmsView(state: state)
            } else {
                StatusView(state: state)
            }
        }
        .navigationViewStyle(.stack)
    }
    
    private func requestNotificationPermission() {
        let options: UNAuthorizationOptions = [
            .alert,
            .sound,
            .badge,
            .criticalAlert,
            .provisional
        ]
        
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
            DispatchQueue.main.async {
                if !granted {
                    // Show alert explaining the importance of notifications
                    print("Notifications not granted")
                }
            }
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
}

// Add a constant for max alarms
extension ContentView {
    static let maxAlarms = 1
}

// Create a new AlarmsView to hold the existing alarms list
struct AlarmsView: View {
    @ObservedObject var state: ContentView.ContentViewState
    @State private var showingAddAlarm = false
    @State private var notificationGranted = false
    @State private var alarmToDisable: Alarm? = nil
    @State private var showingDisableConfirmation = false
    @State private var showingSnoozedDialog = false
    @State private var selectedSnoozedAlarm: Alarm?
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            if state.alarms.isEmpty {
                EmptyStateView(showingAddAlarm: $showingAddAlarm)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(sortedAlarms) { alarm in
                            HStack {
                                if let snoozedUntil = alarm.snoozedUntil,
                                   snoozedUntil > Date() {
                                    // For snoozed alarms, show a button that triggers the snooze dialog
                                    Button(action: {
                                        selectedSnoozedAlarm = alarm
                                        showingSnoozedDialog = true
                                    }) {
                                        AlarmCard(
                                            alarm: binding(for: alarm),
                                            onToggle: { isEnabled in
                                                if !isEnabled && alarm.snoozedUntil != nil {
                                                    alarmToDisable = alarm
                                                    showingDisableConfirmation = true
                                                } else {
                                                    toggleAlarm(alarm, isEnabled: isEnabled)
                                                }
                                            },
                                            onDelete: {
                                                deleteAlarm(alarm)
                                            }
                                        )
                                    }
                                } else {
                                    // For non-snoozed alarms, use NavigationLink for editing
                                    NavigationLink(destination: AlarmEditView(
                                        alarm: binding(for: alarm),
                                        isNew: false
                                    )) {
                                        AlarmCard(
                                            alarm: binding(for: alarm),
                                            onToggle: { isEnabled in
                                                if !isEnabled && alarm.snoozedUntil != nil {
                                                    alarmToDisable = alarm
                                                    showingDisableConfirmation = true
                                                } else {
                                                    toggleAlarm(alarm, isEnabled: isEnabled)
                                                }
                                            },
                                            onDelete: {
                                                deleteAlarm(alarm)
                                            }
                                        )
                                    }
                                }
                                
                                Button(action: {
                                    withAnimation {
                                        deleteAlarm(alarm)
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.title2)
                                }
                                .padding(.leading, 8)
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical, 4)
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle("Alarms")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingAddAlarm = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .disabled(state.alarms.count >= ContentView.maxAlarms)
                .opacity(state.alarms.count >= ContentView.maxAlarms ? 0.5 : 1)
            }
        }
        .alert("Cancel Snoozed Alarm?", isPresented: $showingDisableConfirmation) {
            Button("Cancel", role: .cancel) {
                if let alarm = alarmToDisable,
                   let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                    state.alarms[index].isEnabled = true
                }
            }
            Button("Disable", role: .destructive) {
                if let alarm = alarmToDisable {
                    withAnimation {
                        toggleAlarm(alarm, isEnabled: false)
                    }
                }
            }
        } message: {
            Text("This alarm is currently snoozed. Disabling it will cancel the snooze.")
        }
        .sheet(isPresented: $showingAddAlarm) {
            if state.alarms.count < ContentView.maxAlarms {
                AlarmEditView(
                    alarm: .constant(Alarm()),
                    isNew: true,
                    onAdd: { newAlarm in
                        state.alarms.append(newAlarm)
                        scheduleAlarm(newAlarm)
                    }
                )
            }
        }
        .confirmationDialog(
            "Snoozed Alarm",
            isPresented: $showingSnoozedDialog,
            titleVisibility: .visible
        ) {
            Button("Dismiss Alarm", role: .destructive) {
                if let alarm = selectedSnoozedAlarm,
                   let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                    state.alarms[index].snoozedUntil = nil
                    state.saveAlarms()
                    
                    // Cancel any pending snooze notifications
                    UNUserNotificationCenter.current().removePendingNotificationRequests(
                        withIdentifiers: ["snooze-\(alarm.id)"]
                    )
                }
            }
            Button("Close", role: .cancel) { }
        } message: {
            if let alarm = selectedSnoozedAlarm {
                Text("\(alarm.name)\nSet for \(formatTime(alarm.time))\nCurrently snoozed until \(formatTime(alarm.snoozedUntil ?? Date()))")
            }
        }
    }
    
    private var sortedAlarms: [Alarm] {
        state.alarms.sorted { a, b in
            let aTime = getNextTriggerTime(for: a)
            let bTime = getNextTriggerTime(for: b)
            return aTime < bTime
        }
    }
    
    private func getNextTriggerTime(for alarm: Alarm) -> Date {
        // If alarm is snoozed, use snooze time
        if let snoozedUntil = alarm.snoozedUntil, snoozedUntil > Date() {
            return snoozedUntil
        }
        
        // Otherwise calculate next occurrence based on schedule
        let calendar = Calendar.current
        let now = Date()
        
        // Get current weekday (1 = Sunday, 2 = Monday, etc.)
        let currentWeekday = calendar.component(.weekday, from: now)
        
        // Get hour and minute components from the alarm time
        let alarmHour = calendar.component(.hour, from: alarm.time)
        let alarmMinute = calendar.component(.minute, from: alarm.time)
        
        // Create a date for the alarm time today
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = alarmHour
        components.minute = alarmMinute
        components.second = 0
        
        guard let todayAlarmTime = calendar.date(from: components) else {
            return now
        }
        
        // If alarm is not enabled, put it at the end
        if !alarm.isEnabled {
            return Date.distantFuture
        }
        
        // If alarm is set for later today, return that time
        if todayAlarmTime > now {
            if alarm.days.contains(currentWeekday) {
                return todayAlarmTime
            }
        }
        
        // Find the next day the alarm should ring
        var daysToAdd = 1
        var nextWeekday = currentWeekday
        for _ in 1...7 {
            nextWeekday = nextWeekday % 7 + 1
            if alarm.days.contains(nextWeekday) {
                guard let nextDate = calendar.date(byAdding: .day, value: daysToAdd, to: todayAlarmTime) else {
                    return now
                }
                return nextDate
            }
            daysToAdd += 1
        }
        
        return Date.distantFuture
    }
    
    private func binding(for alarm: Alarm) -> Binding<Alarm> {
        guard let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) else {
            fatalError("Alarm not found")
        }
        return $state.alarms[index]
    }
    
    private func requestNotificationPermission() {
        let options: UNAuthorizationOptions = [
            .alert,
            .sound,
            .badge,
            .criticalAlert,
            .provisional
        ]
        
        UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
            DispatchQueue.main.async {
                self.notificationGranted = granted
                if !granted {
                    // Show alert explaining the importance of notifications
                    // and guide user to Settings
                }
            }
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    private func scheduleAlarm(_ alarm: Alarm) {
        cancelAlarm(alarm)
        
        let content = UNMutableNotificationContent()
        content.title = "Wake Up!"
        content.body = "Time to rise and shine"
        content.categoryIdentifier = "ALARM_CATEGORY"
        content.userInfo = ["soundName": alarm.soundName, "alarmId": alarm.id.uuidString]
        content.interruptionLevel = .timeSensitive
        
        // Handle system sounds differently
        if alarm.soundName.starts(with: "system_") {
            content.sound = UNNotificationSound.default
        } else {
            // Create a critical notification sound that will play even in silent mode
            let soundName = UNNotificationSoundName("\(alarm.soundName).wav")
            if #available(iOS 15.0, *) {
                content.sound = UNNotificationSound.criticalSoundNamed(soundName)
            } else {
                content.sound = UNNotificationSound(named: soundName)
            }
        }
        
        // Create notifications for each selected day
        for day in alarm.days {
            let calendar = Calendar.current
            var dateComponents = calendar.dateComponents([.hour, .minute], from: alarm.time)
            dateComponents.weekday = day // 1 = Sunday, 2 = Monday, etc.
            
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(
                identifier: "\(alarm.id)-\(day)",
                content: content,
                trigger: trigger
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error scheduling notification: \(error)")
                }
            }
        }
        
        // Save alarms to persistent storage
        state.saveAlarms()
    }
    
    private func cancelAlarm(_ alarm: Alarm) {
        // Remove notifications for all days
        for day in 1...7 {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["\(alarm.id)-\(day)"]
            )
        }
        AudioManager.shared.stopAlarmSound()
        state.saveAlarms()
    }
    
    private func deleteAlarm(_ alarm: Alarm) {
        withAnimation {
            // First cancel any notifications
            ContentView.shared.cancelAlarm(alarm)
            
            // Then remove from storage
            if let index = ContentView.shared.alarms.firstIndex(where: { $0.id == alarm.id }) {
                ContentView.shared.alarms.remove(at: index)
                ContentView.shared.saveAlarms()
            }
        }
    }
    
    private func toggleAlarm(_ alarm: Alarm, isEnabled: Bool) {
        if let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
            let newAlarm = Alarm(
                id: alarm.id,
                time: alarm.time,
                isEnabled: isEnabled,
                soundName: alarm.soundName,
                days: alarm.days,
                snoozedUntil: isEnabled ? alarm.snoozedUntil : nil,  // Clear snooze if disabling
                name: alarm.name  // Preserve the original name
            )
            state.alarms[index] = newAlarm
            
            if isEnabled {
                scheduleAlarm(newAlarm)
            } else {
                cancelAlarm(newAlarm)
            }
            
            state.saveAlarms()
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// Create a new StatusView
struct StatusView: View {
    @ObservedObject var state: ContentView.ContentViewState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var showingAbout = false
    @State private var showingSnoozedDialog = false
    @State private var selectedSnoozedAlarm: Alarm?
    
    // Add timer to update countdown
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    // Add computed property to determine if we should show stat cards
    private var shouldShowStatCards: Bool {
        // Get the current window scene
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }
        
        // Get the current window bounds
        let bounds = windowScene.coordinateSpace.bounds
        
        // Check if width is less than height (portrait)
        return bounds.width < bounds.height
    }
    
    // Add computed property for orientation
    private var isLandscape: Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }
        let bounds = windowScene.coordinateSpace.bounds
        return bounds.width > bounds.height
    }
    
    // Add binding function
    private func binding(for alarm: Alarm) -> Binding<Alarm> {
        guard let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) else {
            fatalError("Alarm not found")
        }
        return $state.alarms[index]
    }
    
    var body: some View {
        List {
            if state.alarms.isEmpty {
                Section {
                    VStack(spacing: 20) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                        
                        Text("No Alarms Set")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        
                        NavigationLink(destination: AlarmsView(state: state)) {
                            Text("Add Alarm")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(12)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                // Quick Status Card
                Section {
                    if isLandscape {
                        // Landscape layout
                        HStack(spacing: 20) {
                            // Only show StatCards in portrait mode
                            if shouldShowStatCards {
                                Button(action: {
                                    // Navigate programmatically
                                    let alarmsView = AlarmsView(state: state)
                                    let hostingController = UIHostingController(rootView: alarmsView)
                                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                       let window = windowScene.windows.first,
                                       let rootVC = window.rootViewController as? UINavigationController {
                                        rootVC.pushViewController(hostingController, animated: true)
                                    }
                                }) {
                                    HStack(spacing: 20) {
                                        StatCard(
                                            title: "Total",
                                            value: "\(state.alarms.count)",
                                            icon: "bell.fill"
                                        )
                                        
                                        StatCard(
                                            title: "Snoozed",
                                            value: "\(snoozedAlarms.count)",
                                            icon: "zzz"
                                        )
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // Next Alarm Card - Make it look like a button
                            if let nextAlarm = nextScheduledAlarm {
                                Group {
                                    if let snoozedUntil = nextAlarm.snoozedUntil,
                                       snoozedUntil > currentTime {
                                        // If next alarm is snoozed, show button that triggers snooze dialog
                                        Button(action: {
                                            selectedSnoozedAlarm = nextAlarm
                                            showingSnoozedDialog = true
                                        }) {
                                            NextAlarmContent(alarm: nextAlarm, currentTime: currentTime, isLandscape: true)
                                        }
                                    } else {
                                        // If not snoozed, use NavigationLink to edit view
                                        NavigationLink(destination: AlarmEditView(
                                            alarm: binding(for: nextAlarm),
                                            isNew: false
                                        )) {
                                            NextAlarmContent(alarm: nextAlarm, currentTime: currentTime, isLandscape: true)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        // Portrait layout (existing code)
                        VStack(spacing: 16) {
                            // Only show StatCards in portrait mode
                            if shouldShowStatCards {
                                Button(action: {
                                    // Navigate programmatically
                                    let alarmsView = AlarmsView(state: state)
                                    let hostingController = UIHostingController(rootView: alarmsView)
                                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                       let window = windowScene.windows.first,
                                       let rootVC = window.rootViewController as? UINavigationController {
                                        rootVC.pushViewController(hostingController, animated: true)
                                    }
                                }) {
                                    HStack(spacing: 20) {
                                        StatCard(
                                            title: "Total",
                                            value: "\(state.alarms.count)",
                                            icon: "bell.fill"
                                        )
                                        
                                        StatCard(
                                            title: "Snoozed",
                                            value: "\(snoozedAlarms.count)",
                                            icon: "zzz"
                                        )
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // Next Alarm Card - Make it look like a button
                            if let nextAlarm = nextScheduledAlarm {
                                Group {
                                    if let snoozedUntil = nextAlarm.snoozedUntil,
                                       snoozedUntil > currentTime {
                                        // If next alarm is snoozed, show button that triggers snooze dialog
                                        Button(action: {
                                            selectedSnoozedAlarm = nextAlarm
                                            showingSnoozedDialog = true
                                        }) {
                                            NextAlarmContent(alarm: nextAlarm, currentTime: currentTime, isLandscape: false)
                                        }
                                    } else {
                                        // If not snoozed, use NavigationLink to edit view
                                        NavigationLink(destination: AlarmEditView(
                                            alarm: binding(for: nextAlarm),
                                            isNew: false
                                        )) {
                                            NextAlarmContent(alarm: nextAlarm, currentTime: currentTime, isLandscape: false)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                // Active Alarms Section
                Section {
                    // Show title and alarms when there are active alarms
                    if !state.alarms.filter({ $0.isEnabled && $0.snoozedUntil == nil }).isEmpty {
                        HStack {
                            Text("Active Alarms")
                                .font(.headline)
                            Spacer()
                        }
                        
                        ForEach(state.alarms.filter { 
                            $0.isEnabled && $0.snoozedUntil == nil
                        }) { alarm in
                            NavigationLink(destination: AlarmEditView(
                                alarm: binding(for: alarm),
                                isNew: false
                            )) {
                                ActiveAlarmRow(alarm: alarm)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // Show Manage Alarms button if not at max capacity
                    if state.alarms.count < ContentView.maxAlarms {
                        NavigationLink(destination: AlarmsView(state: state)) {
                            Text("Manage Alarms")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(12)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    } else {
                        Text("Maximum number of alarms reached")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical)
                    }
                }
                
            }
        }
        // .navigationTitle(isLandscape ? "" : "Somnolence")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if !isLandscape {
                    Text("Somnolence")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isLandscape {
                    Button(action: { showingAbout = true }) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .confirmationDialog(
            "Snoozed Alarm",
            isPresented: $showingSnoozedDialog,
            titleVisibility: .visible
        ) {
            Button("Dismiss Alarm", role: .destructive) {
                if let alarm = selectedSnoozedAlarm,
                   let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                    state.alarms[index].snoozedUntil = nil
                    state.saveAlarms()
                    
                    // Cancel any pending snooze notifications
                    UNUserNotificationCenter.current().removePendingNotificationRequests(
                        withIdentifiers: ["snooze-\(alarm.id)"]
                    )
                }
            }
            Button("Close", role: .cancel) { }
        } message: {
            if let alarm = selectedSnoozedAlarm {
                Text("\(alarm.name)\nSet for \(formatTime(alarm.time))\nCurrently snoozed until \(formatTime(alarm.snoozedUntil ?? Date()))")
            }
        }
        .onReceive(timer) { _ in
            currentTime = Date()
            refreshData()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                refreshData()
            }
        }
        .onAppear {
            refreshData()
        }
        .refreshable {
            refreshData()
        }
    }
    
    private func refreshData() {
        // Reload alarms from storage
        state.loadAlarms()
        
        // Clean up expired snoozes
        for (index, alarm) in state.alarms.enumerated() {
            if let snoozedUntil = alarm.snoozedUntil, snoozedUntil < currentTime {
                state.alarms[index].snoozedUntil = nil
            }
        }
        
        // Force UI update - use state's objectWillChange instead
        DispatchQueue.main.async {
            state.objectWillChange.send()
        }
        
        // Save any changes
        state.saveAlarms()
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private var nextScheduledAlarm: Alarm? {
        // Filter to only enabled alarms
        let activeAlarms = state.alarms.filter { $0.isEnabled }
        
        // Return the alarm with the earliest upcoming time
        return activeAlarms.min { a, b in
            let aTime = getNextTriggerTime(for: a)
            let bTime = getNextTriggerTime(for: b)
            return aTime < bTime
        }
    }
    
    private func getNextTriggerTime(for alarm: Alarm) -> Date {
        // If alarm is snoozed, use snooze time
        if let snoozedUntil = alarm.snoozedUntil, snoozedUntil > Date() {
            return snoozedUntil
        }
        
        return nextOccurrence(for: alarm)
    }
    
    private var timeUntilNextAlarm: String {
        guard let nextAlarm = nextScheduledAlarm else { return "" }
        
        let targetDate: Date
        if let snoozedUntil = nextAlarm.snoozedUntil, snoozedUntil > Date() {
            targetDate = snoozedUntil
        } else {
            targetDate = nextOccurrence(for: nextAlarm)
        }
        
        let diff = targetDate.timeIntervalSince(currentTime)
        
        if diff < 0 {
            return "Overdue"
        }
        
        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60
        let seconds = Int(diff) % 60
        
        if hours > 0 {
            return "Rings in \(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "Rings in \(minutes)m \(seconds)s"
        } else {
            return "Rings in \(seconds)s"
        }
    }
    
    private var timeUntilNextAlarmColor: Color {
        guard let nextAlarm = nextScheduledAlarm else { return .secondary }
        
        let targetDate: Date
        if let snoozedUntil = nextAlarm.snoozedUntil, snoozedUntil > Date() {
            targetDate = snoozedUntil
        } else {
            targetDate = nextOccurrence(for: nextAlarm)
        }
        
        let diff = targetDate.timeIntervalSince(currentTime)
        
        if diff < 0 {
            return .red
        } else if diff < 300 { // Less than 5 minutes
            return .orange
        } else if diff < 900 { // Less than 15 minutes
            return .yellow
        } else {
            return .secondary
        }
    }
    
    private var snoozedAlarms: [Alarm] {
        return state.alarms
            .filter {
                guard let snoozedUntil = $0.snoozedUntil else { return false }
                return snoozedUntil > currentTime
            }
            .sorted { a, b in
                guard let aTime = a.snoozedUntil, let bTime = b.snoozedUntil else {
                    return false
                }
                return aTime < bTime
            }
    }
    
    private func daysString(for alarm: Alarm) -> String {
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return alarm.days.sorted()
            .map { days[$0 - 1] }
            .joined(separator: ", ")
    }
    
    private func nextOccurrence(for alarm: Alarm) -> Date {
        let calendar = Calendar.current
        let now = Date()
        
        // Get current weekday (1 = Sunday, 2 = Monday, etc.)
        let currentWeekday = calendar.component(.weekday, from: now)
        
        // Get hour and minute components from the alarm time
        let alarmHour = calendar.component(.hour, from: alarm.time)
        let alarmMinute = calendar.component(.minute, from: alarm.time)
        
        // Create a date for the alarm time today
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = alarmHour
        components.minute = alarmMinute
        components.second = 0
        
        guard let todayAlarmTime = calendar.date(from: components) else {
            return now
        }
        
        // If alarm is set for later today, return that time
        if todayAlarmTime > now {
            if alarm.days.contains(currentWeekday) {
                return todayAlarmTime
            }
        }
        
        // Find the next day the alarm should ring
        var daysToAdd = 1
        var nextWeekday = currentWeekday
        for _ in 1...7 {
            nextWeekday = nextWeekday % 7 + 1  // Move to next day, wrapping around to Sunday
            if alarm.days.contains(nextWeekday) {
                guard let nextDate = calendar.date(byAdding: .day, value: daysToAdd, to: todayAlarmTime) else {
                    return now
                }
                return nextDate
            }
            daysToAdd += 1
        }
        
        return now
    }
    
    private func timeUntilSnooze(_ snoozeTime: Date) -> String {
        let diff = snoozeTime.timeIntervalSince(currentTime)
        
        if diff < 0 {
            return "Overdue"
        }
        
        let minutes = Int(diff) / 60
        let seconds = Int(diff) % 60
        
        if minutes > 0 {
            return "Rings in \(minutes)m \(seconds)s"
        } else {
            return "Rings in \(seconds)s"
        }
    }
}

// Add custom button style for cards
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

// Update StatCard to be more visually appealing
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.blue)
                .frame(width: 40, height: 40)
                .background(Color.blue.opacity(0.1))
                .clipShape(Circle())
            
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

struct ActiveAlarmRow: View {
    let alarm: Alarm
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.name)
                    .font(.headline)
                
                HStack(spacing: 8) {
                    Text(timeString)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(daysString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Image(systemName: "bell.fill")
                .foregroundColor(.blue)
        }
        .contentShape(Rectangle())
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: alarm.time)
    }
    
    private var daysString: String {
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return alarm.days.sorted()
            .map { days[$0 - 1] }
            .joined(separator: ", ")
    }
}

struct SnoozedAlarmRow: View {
    let alarm: Alarm
    @State private var showingDialog = false
    @ObservedObject var state: ContentView.ContentViewState
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.name)
                    .font(.headline)
                
                HStack(spacing: 8) {
                    Text(timeString)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    if let snoozedUntil = alarm.snoozedUntil {
                        Text("Snoozed until \(formatTime(snoozedUntil))")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
            
            Spacer()
            
            Image(systemName: "zzz")
                .foregroundColor(.blue)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showingDialog = true
        }
        .confirmationDialog(
            "Snoozed Alarm",
            isPresented: $showingDialog,
            titleVisibility: .visible
        ) {
            Button("Dismiss Alarm", role: .destructive) {
                if let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                    state.alarms[index].snoozedUntil = nil
                    state.saveAlarms()
                    
                    // Cancel any pending snooze notifications
                    UNUserNotificationCenter.current().removePendingNotificationRequests(
                        withIdentifiers: ["snooze-\(alarm.id)"]
                    )
                }
            }
            Button("Close", role: .cancel) { }
        } message: {
            Text("\(alarm.name)\nSet for \(timeString)\nCurrently snoozed until \(formatTime(alarm.snoozedUntil ?? Date()))")
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: alarm.time)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct EmptyStateView: View {
    @Binding var showingAddAlarm: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.blue.opacity(0.8))
            
            Text("No Alarms Set")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("Add your first alarm to get started")
                .foregroundColor(.secondary)
            
            Button(action: { showingAddAlarm = true }) {
                Label("Add Alarm", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: 200)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.top)
        }
        .padding()
    }
}

struct AlarmCard: View {
    @Binding var alarm: Alarm
    @State private var showingEditSheet = false
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    @ObservedObject var state = ContentView.shared  // Add state reference
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(alarm.name)
                        .font(.headline)
                        .foregroundColor(alarm.isEnabled ? .primary : .secondary)
                    
                    Text(timeString)
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .foregroundColor(alarm.isEnabled ? .primary : .secondary)
                    
                    if let snoozedUntil = alarm.snoozedUntil, snoozedUntil > Date() {
                        HStack(spacing: 4) {
                            Image(systemName: "zzz")
                                .font(.caption)
                            Text("Snoozed until \(formatTime(snoozedUntil))")
                            
                            Spacer()
                            
                            Button(action: cancelSnooze) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(6)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                
                Spacer()
            }
            
            HStack {
                // Days
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        Text(dayLetter(for: day))
                            .font(.caption)
                            .frame(width: 11, height: 11)
                            .padding(6)
                            .background(
                                Circle()
                                    .fill(alarm.days.contains(day) ? Color.blue : Color.clear)
                                    .opacity(alarm.days.contains(day) ? 0.2 : 0)
                            )
                            .foregroundColor(alarm.days.contains(day) ? .blue : .secondary)
                    }
                }
                
                Spacer()
                
                // Sound name
                Label(alarm.soundName.replacingOccurrences(of: "_", with: " ").capitalized,
                      systemImage: "music.note")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .onTapGesture {
            // Only allow editing if not snoozed
            if alarm.snoozedUntil == nil || alarm.snoozedUntil! <= Date() {
                showingEditSheet = true
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            AlarmEditView(
                alarm: $alarm,
                isNew: false,
                onDelete: onDelete
            )
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: alarm.time)
    }
    
    private func dayLetter(for day: Int) -> String {
        let days = ["S", "M", "T", "W", "T", "F", "S"]
        return days[(day - 1) % 7]
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func cancelSnooze() {
        withAnimation {
            // Update the alarm in the state
            if let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                state.alarms[index].snoozedUntil = nil
                
                // Cancel any pending snooze notifications
                UNUserNotificationCenter.current().removePendingNotificationRequests(
                    withIdentifiers: ["snooze-\(alarm.id)"]
                )
                
                // Save the changes
                state.saveAlarms()
                
                // Update the binding to reflect the change
                alarm.snoozedUntil = nil
            }
        }
    }
}

struct AlarmEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var alarm: Alarm
    let isNew: Bool
    var onAdd: ((Alarm) -> Void)?
    var onDelete: (() -> Void)?
    
    @State private var selectedTime: Date
    @State private var selectedSound: String
    @State private var selectedDays: Set<Int>
    @State private var showingSoundPicker = false
    @State private var alarmName: String
    
    init(alarm: Binding<Alarm>, isNew: Bool, onAdd: ((Alarm) -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self._alarm = alarm
        self.isNew = isNew
        self.onAdd = onAdd
        self.onDelete = onDelete
        
        // Add one minute to current time and round to nearest minute
        let calendar = Calendar.current
        let now = Date()
        let oneMinuteLater = calendar.date(byAdding: .minute, value: 1, to: now) ?? now
        let roundedTime = calendar.date(
            bySetting: .second,
            value: 0,
            of: oneMinuteLater
        ) ?? oneMinuteLater
        
        if isNew {
            // Set default time to rounded one minute from now
            self._selectedTime = State(initialValue: roundedTime)
            
            // Format default name with the rounded time
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let timeString = formatter.string(from: roundedTime)
            self._alarmName = State(initialValue: "Alarm at \(timeString)")
        } else {
            self._selectedTime = State(initialValue: alarm.wrappedValue.time)
            self._alarmName = State(initialValue: alarm.wrappedValue.name)
        }
        self._selectedSound = State(initialValue: alarm.wrappedValue.soundName)
        self._selectedDays = State(initialValue: alarm.wrappedValue.days)
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        TextField("Alarm Name", text: $alarmName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .textContentType(.none)
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                            .onChange(of: alarmName) { _, _ in
                                // Limit name length to prevent layout issues
                                if alarmName.count > 50 {
                                    alarmName = String(alarmName.prefix(50))
                                }
                            }
                    }
                }
                
                Section {
                    DatePicker("Time", selection: $selectedTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxHeight: 200)
                        .onChange(of: selectedTime) { oldValue, newValue in
                            if isNew {
                                // Only update the name if it's still using the default format
                                let formatter = DateFormatter()
                                formatter.timeStyle = .short
                                let oldTimeString = formatter.string(from: oldValue)
                                let newTimeString = formatter.string(from: newValue)
                                
                                if alarmName == "Alarm at \(oldTimeString)" {
                                    alarmName = "Alarm at \(newTimeString)"
                                }
                            }
                        }
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repeat")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        WeekdaySelector(selectedDays: $selectedDays)
                    }
                }
                
                Section {
                    Button(action: { showingSoundPicker = true }) {
                        HStack {
                            Text("Sound")
                            Spacer()
                            Text(selectedSound.replacingOccurrences(of: "_", with: " ").capitalized)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            // First cancel any notifications
                            ContentView.shared.cancelAlarm(alarm)
                            
                            // Then remove from storage
                            if let index = ContentView.shared.alarms.firstIndex(where: { $0.id == alarm.id }) {
                                ContentView.shared.alarms.remove(at: index)
                                ContentView.shared.saveAlarms()
                            }
                            
                            // Finally dismiss the view
                            dismiss()
                        } label: {
                            Text("Delete Alarm")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAlarm()
                    }
                }
            }
            .sheet(isPresented: $showingSoundPicker) {
                SoundPickerView(selectedSound: $selectedSound)
            }
        }
    }
    
    private func saveAlarm() {
        let updatedAlarm = Alarm(
            id: alarm.id,
            time: selectedTime,
            isEnabled: true,
            soundName: selectedSound,
            days: selectedDays,
            snoozedUntil: alarm.snoozedUntil,
            name: alarmName
        )
        
        if isNew {
            // For new alarms, add to shared state first
            ContentView.shared.alarms.append(updatedAlarm)
            ContentView.shared.saveAlarms()
            ContentView.shared.scheduleAlarm(updatedAlarm)
            
            // Then notify through callback if provided
            onAdd?(updatedAlarm)
        } else {
            // Update the local binding first
            alarm = updatedAlarm
            
            // Then update storage and reschedule
            if let index = ContentView.shared.alarms.firstIndex(where: { $0.id == alarm.id }) {
                // Update in storage first
                ContentView.shared.alarms[index] = updatedAlarm
                ContentView.shared.saveAlarms()
                
                // Then handle notifications
                ContentView.shared.scheduleAlarm(updatedAlarm)
                
                // Schedule a check after 2 seconds to verify days are selected
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if updatedAlarm.days.isEmpty {
                        // Delete the alarm if no days are selected
                        withAnimation {
                            // First cancel any notifications
                            ContentView.shared.cancelAlarm(updatedAlarm)
                            
                            // Then remove from storage
                            if let index = ContentView.shared.alarms.firstIndex(where: { $0.id == updatedAlarm.id }) {
                                ContentView.shared.alarms.remove(at: index)
                                ContentView.shared.saveAlarms()
                                
                                // Force a refresh of the notification status
                                ContentView.shared.refreshNotificationStatus()
                            }
                        }
                    }
                }
            }
        }
        dismiss()
    }
}

struct WeekdaySelector: View {
    @Binding var selectedDays: Set<Int>
    let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7) { index in
                let day = index + 1
                Button(action: {
                    toggleDay(day)
                }) {
                    Text(dayLabels[index])
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.medium)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(selectedDays.contains(day) ? Color.blue : Color.clear)
                                .opacity(selectedDays.contains(day) ? 1 : 0.1)
                        )
                        .foregroundColor(selectedDays.contains(day) ? .white : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .animation(.easeInOut(duration: 0.2), value: selectedDays.contains(day))
            }
        }
        .padding(.vertical, 4)
    }
    
    private func toggleDay(_ day: Int) {
        if selectedDays.contains(day) {
            selectedDays.remove(day)
        } else {
            selectedDays.insert(day)
        }
    }
}

struct SoundPickerView: View {
    @Binding var selectedSound: String
    @Environment(\.dismiss) var dismiss
    @State private var playingSound: String?
    
    var soundOptions: [String] {
        // Add system defaults
        let systemSounds = ["system_alarm", "system_chime", "system_bell"]
        
        // Get custom sounds
        let fileManager = FileManager.default
        guard let resourcePath = Bundle.main.resourcePath else { return systemSounds }
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: resourcePath)
            let customSounds = files.compactMap { file -> String? in
                guard file.hasSuffix(".wav") || file.hasSuffix(".mp3") else { return nil }
                return (file as NSString).deletingPathExtension
            }
            
            return systemSounds + customSounds
        } catch {
            print("Error reading sound files: \(error)")
            return systemSounds
        }
    }
    
    var body: some View {
        NavigationView {
            Group {
                if soundOptions.isEmpty {
                    VStack(spacing: 24) {
                        Image(systemName: "speaker.slash.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 16) {
                            Text("No Sound Files Found")
                                .font(.title2)
                                .fontWeight(.medium)
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("To add sounds:")
                                    .font(.headline)
                                    .padding(.bottom, 4)
                                
                                ForEach(["Add .wav or .mp3 files to your Xcode project",
                                        "Make sure to check 'Copy items if needed'",
                                        "Add to target 'Somnolence'"], id: \.self) { instruction in
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 6))
                                            .padding(.top, 6)
                                        Text(instruction)
                                    }
                                }
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(16)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(soundOptions, id: \.self) { sound in
                            HStack {
                                Button(action: {
                                    selectedSound = sound
                                    dismiss()
                                }) {
                                    HStack {
                                        Image(systemName: "music.note")
                                            .foregroundColor(.blue)
                                        Text(sound.replacingOccurrences(of: "_", with: " ").capitalized)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        if sound == selectedSound {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.blue)
                                        }
                                    }
                                }
                                
                                // Add preview button
                                Button(action: {
                                    if playingSound == sound {
                                        AudioManager.shared.stopAlarmSound()
                                        playingSound = nil
                                    } else {
                                        if playingSound != nil {
                                            AudioManager.shared.stopAlarmSound()
                                        }
                                        AudioManager.shared.playAlarmSound(named: sound)
                                        playingSound = sound
                                    }
                                }) {
                                    Image(systemName: playingSound == sound ? "stop.circle.fill" : "play.circle.fill")
                                        .foregroundColor(playingSound == sound ? .red : .blue)
                                        .font(.title2)
                                }
                                .buttonStyle(.borderless)
                                .padding(.leading)
                            }
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                }
            }
            .navigationTitle("Select Sound")
            .navigationBarItems(trailing: Button("Done") {
                if playingSound != nil {
                    AudioManager.shared.stopAlarmSound()
                }
                dismiss()
            })
        }
        // Stop playing sound when view disappears
        .onDisappear {
            if playingSound != nil {
                AudioManager.shared.stopAlarmSound()
                playingSound = nil
            }
        }
    }
}

extension ContentView {
    func handleNotification() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }
}

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    private var activeAlarmModal: AlarmModalViewController?
    private let modalQueue = DispatchQueue(label: "com.somnolence.modalQueue")
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
        let snoozeIdentifier = "snooze-\(alarmId)"
        
        // Update the alarm state
        if let alarmUUID = UUID(uuidString: alarmId),
           let index = ContentView.shared.alarms.firstIndex(where: { $0.id == alarmUUID }) {
            let snoozeUntil = Date().addingTimeInterval(5 * 60)
            
            // Cancel any existing snooze notifications first
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["snooze-\(alarmId)"]
            )
            
            // Update state and save
            DispatchQueue.main.async {
                ContentView.shared.alarms[index].snoozedUntil = snoozeUntil
                ContentView.shared.saveAlarms()
                
                // Schedule the new notification
                let content = UNMutableNotificationContent()
                content.title = "Snoozed Alarm"
                content.body = "Wake up! (Snoozed alarm)"
                content.sound = UNNotificationSound(named: UNNotificationSoundName("\(soundName).wav"))
                content.userInfo = ["soundName": soundName, "alarmId": alarmId]
                content.categoryIdentifier = "ALARM_CATEGORY"
                
                if #available(iOS 15.0, *) {
                    content.interruptionLevel = .timeSensitive
                }
                
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: 5 * 60,
                    repeats: false
                )
                
                let request = UNNotificationRequest(
                    identifier: snoozeIdentifier,
                    content: content,
                    trigger: trigger
                )
                
                // Schedule the new snooze notification
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        print("[\(self.formatDate(Date()))] Error scheduling snooze notification: \(error)")
                    } else {
                        print("[\(self.formatDate(Date()))] Successfully scheduled snooze notification")
                    }
                    
                    // Force a refresh of the notification status
                    DispatchQueue.main.async {
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
            alarm: alarm,  // Now using the actual alarm with its name
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

// First, add a new view for filtered alarms
struct FilteredAlarmsView: View {
    @ObservedObject var state: ContentView.ContentViewState
    let filter: AlarmFilter
    
    enum AlarmFilter {
        case snoozed
        case active
        case all
        
        var title: String {
            switch self {
            case .snoozed: return "Snoozed Alarms"
            case .active: return "Active Alarms"
            case .all: return "All Alarms"
            }
        }
    }
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            if filteredAlarms.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: emptyStateIcon)
                        .font(.system(size: 50))
                        .foregroundColor(.blue)
                    Text(emptyStateMessage)
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(filteredAlarms) { alarm in
                            HStack {
                                AlarmCard(
                                    alarm: binding(for: alarm),
                                    onToggle: { isEnabled in
                                        if !isEnabled {
                                            withAnimation {
                                                cancelSnooze(alarm)
                                            }
                                        }
                                    },
                                    onDelete: {
                                        deleteAlarm(alarm)
                                    }
                                )
                                
                                Button(action: {
                                    withAnimation {
                                        cancelSnooze(alarm)
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                        .font(.title2)
                                }
                                .padding(.leading, 8)
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical, 4)
                    }
                    .padding(.vertical)
                }
            }
        }
        .navigationTitle(filter.title)
    }
    
    private var filteredAlarms: [Alarm] {
        switch filter {
        case .snoozed:
            return state.alarms.filter { alarm in
                guard let snoozedUntil = alarm.snoozedUntil else { return false }
                return snoozedUntil > Date()
            }.sorted { a, b in
                (a.snoozedUntil ?? .distantFuture) < (b.snoozedUntil ?? .distantFuture)
            }
        case .active:
            return state.alarms.filter { $0.isEnabled }
                .sorted { getNextTriggerTime(for: $0) < getNextTriggerTime(for: $1) }
        case .all:
            return state.alarms.sorted { getNextTriggerTime(for: $0) < getNextTriggerTime(for: $1) }
        }
    }
    
    private func binding(for alarm: Alarm) -> Binding<Alarm> {
        guard let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) else {
            fatalError("Alarm not found")
        }
        return $state.alarms[index]
    }
    
    private func cancelSnooze(_ alarm: Alarm) {
        if let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
            state.alarms[index].snoozedUntil = nil
            state.saveAlarms()
            
            // Cancel any pending snooze notifications
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["snooze-\(alarm.id)"]
            )
        }
    }
    
    private func deleteAlarm(_ alarm: Alarm) {
        withAnimation {
            // First cancel any notifications
            ContentView.shared.cancelAlarm(alarm)
            
            // Then remove from storage
            if let index = ContentView.shared.alarms.firstIndex(where: { $0.id == alarm.id }) {
                ContentView.shared.alarms.remove(at: index)
                ContentView.shared.saveAlarms()
            }
        }
    }
    
    private var emptyStateIcon: String {
        switch filter {
        case .snoozed: return "zzz"
        case .active: return "bell.slash"
        case .all: return "bell"
        }
    }
    
    private var emptyStateMessage: String {
        switch filter {
        case .snoozed: return "No snoozed alarms"
        case .active: return "No active alarms"
        case .all: return "No alarms set"
        }
    }
    
    private func getNextTriggerTime(for alarm: Alarm) -> Date {
        // If alarm is snoozed, use snooze time
        if let snoozedUntil = alarm.snoozedUntil, snoozedUntil > Date() {
            return snoozedUntil
        }
        
        // Otherwise calculate next occurrence based on schedule
        let calendar = Calendar.current
        let now = Date()
        
        // Get current weekday (1 = Sunday, 2 = Monday, etc.)
        let currentWeekday = calendar.component(.weekday, from: now)
        
        // Get hour and minute components from the alarm time
        let alarmHour = calendar.component(.hour, from: alarm.time)
        let alarmMinute = calendar.component(.minute, from: alarm.time)
        
        // Create a date for the alarm time today
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = alarmHour
        components.minute = alarmMinute
        components.second = 0
        
        guard let todayAlarmTime = calendar.date(from: components) else {
            return now
        }
        
        // If alarm is not enabled, put it at the end
        if !alarm.isEnabled {
            return Date.distantFuture
        }
        
        // If alarm is set for later today, return that time
        if todayAlarmTime > now {
            if alarm.days.contains(currentWeekday) {
                return todayAlarmTime
            }
        }
        
        // Find the next day the alarm should ring
        var daysToAdd = 1
        var nextWeekday = currentWeekday
        for _ in 1...7 {
            nextWeekday = nextWeekday % 7 + 1
            if alarm.days.contains(nextWeekday) {
                guard let nextDate = calendar.date(byAdding: .day, value: daysToAdd, to: todayAlarmTime) else {
                    return now
                }
                return nextDate
            }
            daysToAdd += 1
        }
        
        return Date.distantFuture
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {
                    // App Info
                    VStack(spacing: 24) {
                        Text("Somnolence")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        
                        VStack(spacing: 16) {
                            InfoCard(
                                icon: "bell.fill",
                                title: "Reliable Wake-ups",
                                description: "This app makes sure you wake up when you really need to wake up, every time!"
                            )
                            
                            InfoCard(
                                icon: "speaker.wave.3.fill",
                                title: "Effective Alarms",
                                description: "The alarm sounds can be pretty alarming, but that's the point — they'll definitely get you out of bed. Pick your alarm sound wisely!"
                            )
                            
                            InfoCard(
                                icon: "heart.fill",
                                title: "Made with Love",
                                description: "I created this app just for fun, and I hope you love it and find it super useful."
                            )
                        }
                        .padding(.horizontal)
                    }
                    
                    // Support Message
                    VStack(spacing: 16) {
                        Text("Support Development")
                            .font(.headline)
                        
                        Text("If you enjoy using Somnolence, please consider the one-time in-app purchase. It will make Apple rich and help me buy more expensive pet food, which will make them very happy! 🐱🐶")
                            .multilineTextAlignment(.center)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                    .padding(.top)
                }
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct InfoCard: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

#Preview {
    ContentView()
}

// String extension for padding
extension String {
    func padRight(toLength length: Int) -> String {
        if self.count >= length {
            return self
        }
        return self + String(repeating: " ", count: length - self.count)
    }
}

// Add a new view for the Next Alarm content
struct NextAlarmContent: View {
    let alarm: Alarm
    let currentTime: Date
    let isLandscape: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isLandscape {
                Text("Next Alarm")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Text(alarm.name)
                .font(.system(size: 34, weight: .medium, design: .rounded))
            
            // Show either snooze countdown or regular alarm countdown
            if let snoozedUntil = alarm.snoozedUntil,
               snoozedUntil > currentTime {
                // Snooze countdown
                HStack {
                    Image(systemName: "zzz")
                        .font(.caption)
                    Text(timeUntilSnooze(snoozedUntil))
                }
                .font(.subheadline)
                .foregroundColor(.blue)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            } else {
                // Regular alarm countdown
                HStack {
                    Image(systemName: "clock")
                        .font(.caption)
                    Text(timeUntilNextAlarm(alarm))
                }
                .font(.subheadline)
                .foregroundColor(.green)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    
    private func timeUntilSnooze(_ snoozeTime: Date) -> String {
        let diff = snoozeTime.timeIntervalSince(currentTime)
        
        if diff < 0 {
            return "Overdue"
        }
        
        let minutes = Int(diff) / 60
        let seconds = Int(diff) % 60
        
        if minutes > 0 {
            return "Rings in \(minutes)m \(seconds)s"
        } else {
            return "Rings in \(seconds)s"
        }
    }
    
    private func timeUntilNextAlarm(_ alarm: Alarm) -> String {
        let targetDate = nextOccurrence(for: alarm)
        let diff = targetDate.timeIntervalSince(currentTime)
        
        if diff < 0 {
            return "Overdue"
        }
        
        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60
        let seconds = Int(diff) % 60
        
        if hours > 0 {
            return "Rings in \(hours)h \(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "Rings in \(minutes)m \(seconds)s"
        } else {
            return "Rings in \(seconds)s"
        }
    }
    
    private func nextOccurrence(for alarm: Alarm) -> Date {
        let calendar = Calendar.current
        let now = currentTime
        
        // Get current weekday (1 = Sunday, 2 = Monday, etc.)
        let currentWeekday = calendar.component(.weekday, from: now)
        
        // Get hour and minute components from the alarm time
        let alarmHour = calendar.component(.hour, from: alarm.time)
        let alarmMinute = calendar.component(.minute, from: alarm.time)
        
        // Create a date for the alarm time today
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = alarmHour
        components.minute = alarmMinute
        components.second = 0
        
        guard let todayAlarmTime = calendar.date(from: components) else {
            return now
        }
        
        // If alarm is set for later today, return that time
        if todayAlarmTime > now {
            if alarm.days.contains(currentWeekday) {
                return todayAlarmTime
            }
        }
        
        // Find the next day the alarm should ring
        var daysToAdd = 1
        var nextWeekday = currentWeekday
        for _ in 1...7 {
            nextWeekday = nextWeekday % 7 + 1
            if alarm.days.contains(nextWeekday) {
                guard let nextDate = calendar.date(byAdding: .day, value: daysToAdd, to: todayAlarmTime) else {
                    return now
                }
                return nextDate
            }
            daysToAdd += 1
        }
        
        return now
    }
}

// Add helper view to remove NavigationLink chevron
struct NavigationLinkRemoveChevron: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        DispatchQueue.main.async {
            if let parentCell = view.findParentListCell() {
                parentCell.accessoryType = .none
            }
        }
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension UIView {
    func findParentListCell() -> UITableViewCell? {
        if let cell = self.superview as? UITableViewCell {
            return cell
        }
        return superview?.findParentListCell()
    }
}
