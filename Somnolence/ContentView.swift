//
//  ContentView.swift
//  Somnolence
//
//  Created by Frank van Praag on 17/12/2024.
//

import SwiftUI
import AVFoundation
import UserNotifications
import Intents

struct Alarm: Identifiable, Codable {
    let id: UUID
    var time: Date
    var isEnabled: Bool
    var soundName: String
    var days: Set<Int> // 1 = Sunday, 2 = Monday, etc.
    var snoozedUntil: Date?
    var name: String
    
    // Add static function to find default sound
    static func defaultSound() -> String {
        // Get custom sounds
        let fileManager = FileManager.default
        guard let resourcePath = Bundle.main.resourcePath else { return "system_alarm" }
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: resourcePath)
            let catSounds = files.compactMap { file -> String? in
                guard file.hasSuffix(".wav") || file.hasSuffix(".mp3") else { return nil }
                let name = (file as NSString).deletingPathExtension
                return name.lowercased().contains("cat") ? name : nil
            }
            
            // Return shortest cat sound name or system_alarm if none found
            return catSounds.min(by: { $0.count < $1.count }) ?? "system_alarm"
        } catch {
            return "system_alarm"
        }
    }
    
    init(id: UUID = UUID(), 
         time: Date = Date(), 
         isEnabled: Bool = true, 
         soundName: String? = nil,  // Make soundName optional in init
         days: Set<Int> = Set(1...7), 
         snoozedUntil: Date? = nil, 
         name: String = "Alarm") {
        self.id = id
        self.time = time
        self.isEnabled = isEnabled
        self.soundName = soundName ?? Self.defaultSound()  // Use defaultSound if no sound specified
        self.days = days
        self.snoozedUntil = snoozedUntil
        self.name = name
    }
}

struct ContentView: View {
    static let shared = ContentViewState()
    @StateObject private var state = ContentViewState()
    @State private var showingNotificationWarning = false
    @State private var notificationIssues: [NotificationIssue] = []
    @Environment(\.scenePhase) var scenePhase
    @State private var showingAboutView = false
    
    enum NotificationIssue: Identifiable {
        case notificationsDisabled
        case criticalAlertsDisabled
        case soundDisabled
        case volumeLow
        case dndEnabled
        case focusEnabled
        
        var id: String {
            switch self {
            case .notificationsDisabled: return "notifications"
            case .criticalAlertsDisabled: return "critical"
            case .soundDisabled: return "sound"
            case .volumeLow: return "volume"
            case .dndEnabled: return "dnd"
            case .focusEnabled: return "focus"
            }
        }
        
        var title: String {
            switch self {
            case .notificationsDisabled: return "Notifications Disabled"
            case .criticalAlertsDisabled: return "Critical Alerts Disabled"
            case .soundDisabled: return "Sound Disabled"
            case .volumeLow: return "Volume Too Low"
            case .dndEnabled: return "Do Not Disturb Active"
            case .focusEnabled: return "Focus Mode Active"
            }
        }
        
        var message: String {
            switch self {
            case .notificationsDisabled: 
                return "Alarms require notifications to be enabled"
            case .criticalAlertsDisabled:
                return "Critical alerts ensure alarms work even in silent mode"
            case .soundDisabled:
                return "Alarm sounds are currently disabled"
            case .volumeLow:
                return "System volume is very low. Alarms will still sound at full volume but you may not hear alarm previews"
            case .dndEnabled:
                return "Do Not Disturb may prevent alarms from sounding"
            case .focusEnabled:
                return "Focus mode may prevent alarms from sounding"
            }
        }
        
        var icon: String {
            switch self {
            case .notificationsDisabled: return "bell.slash"
            case .criticalAlertsDisabled: return "exclamationmark.triangle"
            case .soundDisabled: return "speaker.slash"
            case .volumeLow: return "speaker.wave.1"
            case .dndEnabled: return "moon.fill"
            case .focusEnabled: return "person.crop.circle"
            }
        }
        
        var actionText: String {
            switch self {
            case .notificationsDisabled: return "Enable Notifications"
            case .criticalAlertsDisabled: return "Enable Critical Alerts"
            case .soundDisabled: return "Enable Sound"
            case .volumeLow: return "Adjust Volume"
            case .dndEnabled: return "Disable Do Not Disturb"
            case .focusEnabled: return "Adjust Focus Settings"
            }
        }
    }
    
    private func checkNotificationSettings() {
        // Check notification settings
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                var issues: [NotificationIssue] = []
                
                // Check if notifications are enabled
                if settings.authorizationStatus != .authorized {
                    issues.append(.notificationsDisabled)
                }
                
                // Check notification sound settings
                if settings.soundSetting != .enabled {
                    issues.append(.soundDisabled)
                }
                
//                // Check for critical alerts (iOS 15+)
//                if #available(iOS 15.0, *) {
//                    if settings.criticalAlertSetting != .enabled {
//                        issues.append(.criticalAlertsDisabled)
//                    }
//                }
                
                // Check system volume
                let audioSession = AVAudioSession.sharedInstance()
                do {
                    try audioSession.setActive(true)
//                    let volume = audioSession.outputVolume
//                    if volume < 0.3 { // Consider volumes below 30% too low
//                        issues.append(.volumeLow)
//                    }
                } catch {
                    print("Error checking volume: \(error)")
                }
                
                // Check for DND/Focus (iOS 15+)
                if #available(iOS 15.0, *) {
                    Task {
                        let center = INFocusStatusCenter.default
                        let status = center.focusStatus
                        if status.isFocused ?? false {
                            issues.append(.focusEnabled)
                        }
                    }
                }
                
                notificationIssues = issues
                showingNotificationWarning = !issues.isEmpty
            }
        }
    }
    
    class ContentViewState: ObservableObject {
        @Published var alarms: [Alarm] = []
        
        init() {
            loadAlarms()
        }
        
        func loadAlarms() {
            if let savedAlarms = UserDefaults.standard.data(forKey: "SavedAlarms"),
               let decodedAlarms = try? JSONDecoder().decode([Alarm].self, from: savedAlarms) {
                self.alarms = decodedAlarms
            }
        }
        
        func saveAlarms() {
            if let encodedData = try? JSONEncoder().encode(alarms) {
                UserDefaults.standard.set(encodedData, forKey: "SavedAlarms")
            }
        }
        
        func refreshNotificationStatus() {
            loadAlarms()
        }
        
        func scheduleAlarm(_ alarm: Alarm) {
            DebugLogger.shared.log("Scheduling alarm: \(alarm.name) for \(alarm.time)", type: .info)
            
            AlarmScheduler.shared.scheduleAlarm(for: alarm.time, soundName: alarm.soundName) { success, error in
                if let error = error {
                    DebugLogger.shared.log("Failed to schedule alarm: \(error)", type: .error)
                } else {
                    DebugLogger.shared.log("Successfully scheduled alarm for \(alarm.time)", type: .info)
                }
            }
            
            saveAlarms()
        }
        
        func cancelAlarm(_ alarm: Alarm) {
            DebugLogger.shared.log("Cancelling alarm: \(alarm.name)", type: .info)
            
            // Only cancel this specific alarm, not all alarms
            AlarmScheduler.shared.cancelAlarm(for: alarm.id)
            
            // Stop sound only if this is the currently playing alarm
            if AudioManager.shared.isPlayingAlarmSound {
                AudioManager.shared.stopAlarmSound()
            }
            
            saveAlarms()
        }
        
        func cancelAllAlarms() {
            DebugLogger.shared.log("Cancelling all alarms", type: .warning)
            AlarmScheduler.shared.cancelAllAlarms()
            AudioManager.shared.stopAlarmSound()
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
    
    // Create a shared toolbar view
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 16) {
                // Add Alarm Button
                Button(action: { showingAddAlarm = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .disabled(state.alarms.count >= ContentView.maxAlarms)
                .opacity(state.alarms.count >= ContentView.maxAlarms ? 0.5 : 1)
                
                // Info/About Button
                Button(action: { showingAboutView = true }) {
                    Image(systemName: "info.circle")
                        .font(.title3) // KEEP!
                }
            }
        }
    }
    
    var body: some View {
        NavigationView {
            if state.alarms.isEmpty {
                AlarmsView(state: state)
                    .toolbar {
                        toolbarContent
                    }
            } else {
                StatusView(state: state)
                    .toolbar {
                        toolbarContent
                    }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showingAddAlarm) {
            if state.alarms.count < ContentView.maxAlarms {
                AlarmEditView(
                    alarm: .constant(Alarm()),
                    isNew: true,
                    onAdd: { newAlarm in
                        state.alarms.append(newAlarm)
                        state.scheduleAlarm(newAlarm)
                    }
                )
            }
        }
        .sheet(isPresented: $showingAboutView) {
            AboutView()
        }
        .onAppear {
            checkNotificationSettings()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                checkNotificationSettings()
            }
        }
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
//        .navigationTitle("Alarms")
//        .toolbar {
//            ToolbarItem(placement: .navigationBarTrailing) {
//                Button(action: { showingAddAlarm = true }) {
//                    Image(systemName: "plus.circle.fill")
//                        .font(.title3)
//                }
//                .disabled(state.alarms.count >= ContentView.maxAlarms)
//                .opacity(state.alarms.count >= ContentView.maxAlarms ? 0.5 : 1)
//            }
//        }
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
                        state.scheduleAlarm(newAlarm)
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
                    
                    // Cancel alarms using AlarmScheduler
                    AlarmScheduler.shared.cancelAllAlarms()
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
    
    private func toggleAlarm(_ alarm: Alarm, isEnabled: Bool) {
        if let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
            state.alarms[index].isEnabled = isEnabled
            if isEnabled {
                state.scheduleAlarm(state.alarms[index])
            } else {
                state.cancelAlarm(state.alarms[index])
            }
        }
    }
    
    private func deleteAlarm(_ alarm: Alarm) {
        withAnimation {
            state.cancelAlarm(alarm)
            if let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                state.alarms.remove(at: index)
                state.saveAlarms()
            }
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
//            ToolbarItem(placement: .navigationBarTrailing) {
//                if !isLandscape {
//                    Button(action: { showingAbout = true }) {
//                        Image(systemName: "info.circle")
//                            .foregroundColor(.blue)
//                    }
//                }
//            }
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
                    
                    // Cancel alarms using AlarmScheduler
                    AlarmScheduler.shared.cancelAllAlarms()
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
    @State private var selectedSnoozedAlarm: Alarm?
    
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
                if let alarm = selectedSnoozedAlarm,
                   let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                    state.alarms[index].snoozedUntil = nil
                    state.saveAlarms()
                    
                    // Cancel alarms using AlarmScheduler
                    AlarmScheduler.shared.cancelAllAlarms()
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
            if let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                state.alarms[index].snoozedUntil = nil
                state.saveAlarms()
                
            // Cancel any pending snooze notifications using AlarmScheduler
            AlarmScheduler.shared.cancelAllAlarms()
        }
    }
}

struct AlarmEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var alarm: Alarm
    let isNew: Bool
    var onAdd: ((Alarm) -> Void)?
    var onDelete: (() -> Void)?
    @ObservedObject private var state = ContentView.shared
    
    @State private var selectedTime: Date
    @State private var selectedSound: String
    @State private var selectedDays: Set<Int>
    @State private var showingSoundPicker = false
    @State private var alarmName: String
    
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
            state.alarms.append(updatedAlarm)
            state.saveAlarms()
            state.scheduleAlarm(updatedAlarm)
            
            // Then notify through callback if provided
            onAdd?(updatedAlarm)
        } else {
            // Update the local binding first
            alarm = updatedAlarm
            
            // Then update storage and reschedule
            if let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                // Update in storage first
                state.alarms[index] = updatedAlarm
                state.saveAlarms()
                
                // Then handle notifications
                state.scheduleAlarm(updatedAlarm)
                
                // Schedule a check after 2 seconds to verify days are selected
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if updatedAlarm.days.isEmpty {
                        // Delete the alarm if no days are selected
                        withAnimation {
                            // First cancel any notifications
                            state.cancelAlarm(updatedAlarm)
                            
                            // Then remove from storage
                            if let index = state.alarms.firstIndex(where: { $0.id == updatedAlarm.id }) {
                                state.alarms.remove(at: index)
                                state.saveAlarms()
                                
                                // Force a refresh of the notification status
                                state.refreshNotificationStatus()
                            }
                        }
                    }
                }
            }
        }
        dismiss()
    }
    
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
        guard let resourcePath = Bundle.main.resourcePath else { return systemSounds.sorted() }
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: resourcePath)
            let customSounds = files.compactMap { file -> String? in
                guard file.hasSuffix(".wav") || file.hasSuffix(".mp3") else { return nil }
                return (file as NSString).deletingPathExtension
            }
            
            // If we have custom sounds, only use those, otherwise fall back to system sounds
            return customSounds.isEmpty ? systemSounds.sorted() : customSounds.sorted()
        } catch {
            print("Error reading sound files: \(error)")
            return systemSounds.sorted()
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
        let delegate = NotificationDelegate.shared as UNUserNotificationCenterDelegate
        UNUserNotificationCenter.current().delegate = delegate
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
            
            // Cancel any pending snooze notifications using AlarmScheduler
            AlarmScheduler.shared.cancelAllAlarms()
        }
    }
    
    private func deleteAlarm(_ alarm: Alarm) {
        withAnimation {
            // First cancel any notifications
            state.cancelAlarm(alarm)
            
            // Then remove from storage
            if let index = state.alarms.firstIndex(where: { $0.id == alarm.id }) {
                state.alarms.remove(at: index)
                state.saveAlarms()
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
    @State private var showingLogViewer = false
    
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
                                description: "The alarm sounds can be pretty alarming, but that's the point — it'll definitely get you out of bed. Pick sounds that work for you wisely!"
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
                        
                        Text("If you enjoy using Somnolence, please consider making a one-time donation to developer@vanpraag.com. It will help buy more expensive pet food, which will make them very happy! 🐱🐶")
                            .multilineTextAlignment(.center)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                    .padding(.top)
                    
                    // Add Debug Section
                    #if DEBUG || targetEnvironment(simulator)
                    VStack(spacing: 16) {
                        Text("Debug Options")
                            .font(.headline)
                        
                        Button(action: {
                            showingLogViewer = true
                        }) {
                            HStack {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text("View Debug Logs")
                            }
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.gray)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.top)
                    #endif
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
            .sheet(isPresented: $showingLogViewer) {
                LogViewer()
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

