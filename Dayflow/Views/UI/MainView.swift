//
//  MainView.swift
//  Dayflow
//
//  Timeline UI with transparent design
//

import SwiftUI
import AVKit
import AVFoundation
import AppKit
import Sentry

struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var categoryStore: CategoryStore
    @State private var selectedIcon: SidebarIcon = .timeline
    @State private var selectedDate = timelineDisplayDate(from: Date())
    @State private var showDatePicker = false
    @State private var selectedActivity: TimelineActivity? = nil
    @State private var scrollToNowTick: Int = 0
    @State private var hasAnyActivities: Bool = true
    @ObservedObject private var inactivity = InactivityMonitor.shared
    
    // Animation states for orchestrated entrance - Emil Kowalski principles
    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0
    @State private var timelineOffset: CGFloat = -20
    @State private var timelineOpacity: Double = 0
    @State private var sidebarOffset: CGFloat = -30
    @State private var sidebarOpacity: Double = 0
    @State private var contentOpacity: Double = 0
    
    // Track if we've performed the initial scroll to current time
    @State private var didInitialScroll = false
    @State private var previousDate = timelineDisplayDate(from: Date())
    @State private var lastDateNavMethod: String? = nil
    // Minute tick to handle civil-day rollover (header updates + jump to today)
    @State private var dayChangeTimer: Timer? = nil
    @State private var lastObservedCivilDay: String = {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; return fmt.string(from: Date())
    }()
    @State private var showCategoryEditor = false

    private static let maxDateTitleWidth: CGFloat = {
        let referenceText = "Today, Sep 30"
        let font = NSFont(name: "InstrumentSerif-Regular", size: 36) ?? NSFont.systemFont(ofSize: 36)
        let width = referenceText.size(withAttributes: [.font: font]).width
        return ceil(width) + 4 // small buffer so arrows never nudge
    }()

    var body: some View {
        // Two-column layout: left logo + sidebar; right white panel with header, filters, timeline
        HStack(alignment: .top, spacing: 0) {
            // Left column: Logo on top, sidebar centered
            VStack(spacing: 0) {
                // Logo area (keeps same animation)
                LogoBadgeView(imageName: "DayflowLogoMainApp", size: 36)
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                Spacer(minLength: 0)

                // Sidebar in fixed-width gutter
                VStack {
                    Spacer()
                    SidebarView(selectedIcon: $selectedIcon)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .offset(y: sidebarOffset)
                        .opacity(sidebarOpacity)
                    Spacer()
                }
                Spacer(minLength: 0)
            }
            .frame(width: 100)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity)
            .layoutPriority(1)

            // Right column: Main white panel including header + content
            ZStack {
                switch selectedIcon {
                case .settings:
                    SettingsView()
                        .padding(15)
                case .dashboard:
                    DashboardView()
                        .padding(15)
                case .journal:
                    JournalView()
                        .padding(15)
                case .bug:
                    BugReportView()
                        .padding(15)
                case .timeline:
                    GeometryReader { geo in
                        HStack(alignment: .top, spacing: 0) {
                            // Left column: header + chips + timeline
                            VStack(alignment: .leading, spacing: 18) {
                                // Header: Date navigation + Recording toggle
                                HStack(alignment: .center) {
                                    HStack(spacing: 16) {
                                        Text(formatDateForDisplay(selectedDate))
                                            .font(.custom("InstrumentSerif-Regular", size: 36))
                                            .foregroundColor(Color.black)
                                            .frame(width: Self.maxDateTitleWidth, alignment: .leading)

                                        HStack(spacing: 3) {
                                            Button(action: {
                                                let from = selectedDate
                                                let to = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                                                previousDate = selectedDate
                                                setSelectedDate(to)
                                                lastDateNavMethod = "prev"
                                                AnalyticsService.shared.capture("date_navigation", [
                                                    "method": "prev",
                                                    "from_day": dayString(from),
                                                    "to_day": dayString(to)
                                                ])
                                            }) {
                                                Image("CalendarLeftButton")
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 26, height: 26)
                                            }
                                            .buttonStyle(PlainButtonStyle())

                                            Button(action: {
                                                guard canNavigateForward(from: selectedDate) else { return }
                                                let from = selectedDate
                                                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                                                previousDate = selectedDate
                                                setSelectedDate(tomorrow)
                                                lastDateNavMethod = "next"
                                                AnalyticsService.shared.capture("date_navigation", [
                                                    "method": "next",
                                                    "from_day": dayString(from),
                                                    "to_day": dayString(tomorrow)
                                                ])
                                            }) {
                                                Image("CalendarRightButton")
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 26, height: 26)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                            .disabled(!canNavigateForward(from: selectedDate))
                                        }
                                    }
                                    .offset(x: timelineOffset)
                                    .opacity(timelineOpacity)

                                    Spacer()

                                    // Recording toggle (now inline with header)
                                    HStack(spacing: 4) {
                                        Text("Record")
                                            .font(
                                                Font.custom("Nunito", size: 12)
                                                    .weight(.medium)
                                            )
                                            .foregroundColor(Color(red: 0.62, green: 0.44, blue: 0.36))

                                        Toggle("Record", isOn: $appState.isRecording)
                                            .labelsHidden()
                                            .toggleStyle(SunriseGlassPillToggleStyle())
                                            .scaleEffect(0.7)
                                            .accessibilityLabel(Text("Recording"))
                                    }
                                }
                                .padding(.horizontal, 10)

                                // Content area: chips + timeline
                                VStack(alignment: .leading, spacing: 12) {
                                    TabFilterBar(
                                        categories: categoryStore.editableCategories,
                                        idleCategory: categoryStore.idleCategory,
                                        onManageCategories: { showCategoryEditor = true }
                                    )
                                    .padding(.leading, 10)
                                    .opacity(contentOpacity)

                                    CanvasTimelineDataView(
                                        selectedDate: $selectedDate,
                                        selectedActivity: $selectedActivity,
                                        scrollToNowTick: $scrollToNowTick,
                                        hasAnyActivities: $hasAnyActivities
                                    )
                                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                                    .environmentObject(categoryStore)
                                    .opacity(contentOpacity)
                                }
                                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.top, 15)
                            .padding(.bottom, 15)
                            .padding(.leading, 15)
                            .padding(.trailing, 5)

                            // Divider
                            Rectangle()
                                .fill(Color(hex: "ECECEC") ?? Color.gray)
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)

                            // Right column: activity detail card — spans full height
                            ZStack(alignment: .topLeading) {
                                Color.white.opacity(0.7)

                                ActivityCard(
                                    activity: selectedActivity,
                                    maxHeight: geo.size.height,
                                    scrollSummary: true,
                                    hasAnyActivities: hasAnyActivities
                                )
                                .opacity(contentOpacity)
                            }
                            .clipShape(
                                UnevenRoundedRectangle(
                                    cornerRadii: .init(
                                        topLeading: 0,
                                        bottomLeading: 0, bottomTrailing: 8, topTrailing: 8
                                    )
                                )
                            )
                            .contentShape(
                                UnevenRoundedRectangle(
                                    cornerRadii: .init(
                                        topLeading: 0,
                                        bottomLeading: 0, bottomTrailing: 8, topTrailing: 8
                                    )
                                )
                            )
                            .frame(minWidth: 195, idealWidth: 285, maxWidth: 315, maxHeight: .infinity)
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
            }
            .padding(0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 0)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white)
                        .blendMode(.destinationOut)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.22))
                }
                .compositingGroup()
            )
        }
        .padding([.top, .trailing, .bottom], 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .ignoresSafeArea()
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet(
                selectedDate: Binding(
                    get: { selectedDate },
                    set: {
                        lastDateNavMethod = "picker"
                        setSelectedDate($0)
                    }
                ),
                isPresented: $showDatePicker
            )
        }
        .onAppear {
            // screen viewed and initial timeline view
            AnalyticsService.shared.screen("timeline")
            AnalyticsService.shared.withSampling(probability: 0.01) {
                AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": dayString(selectedDate)])
            }
            // Orchestrated entrance animations following Emil Kowalski principles
            // Fast, under 300ms, natural spring motion
            
            // Logo appears first with scale and fade
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)) {
                logoScale = 1.0
                logoOpacity = 1
            }
            
            // Timeline text slides in from left
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.1)) {
                timelineOffset = 0
                timelineOpacity = 1
            }
            
            // Sidebar slides up
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.15)) {
                sidebarOffset = 0
                sidebarOpacity = 1
            }
            
            // Main content fades in last
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0).delay(0.2)) {
                contentOpacity = 1
            }
            
            // Perform initial scroll to current time on cold start
            if !didInitialScroll {
                performInitialScrollIfNeeded()
            }

            // Start minute-level tick to detect civil-day rollover (midnight)
            startDayChangeTimer()
        }
        // Trigger reset when idle fired and timeline is visible
        .onChange(of: inactivity.pendingReset) { fired in
            if fired, selectedIcon != .settings {
                performIdleResetAndScroll()
                InactivityMonitor.shared.markHandledIfPending()
            }
        }
        .onChange(of: selectedIcon) { newIcon in
            // tab selected + screen viewed
            let tabName: String
            switch newIcon {
            case .timeline: tabName = "timeline"
            case .dashboard: tabName = "dashboard"
            case .journal: tabName = "journal"
            case .bug: tabName = "bug_report"
            case .settings: tabName = "settings"
            }

            // Add Sentry context for app state tracking
            SentryHelper.configureScope { scope in
                scope.setContext(value: [
                    "active_view": tabName,
                    "selected_date": dayString(selectedDate),
                    "is_recording": appState.isRecording
                ], key: "app_state")
            }

            // Add breadcrumb for view navigation
            let navBreadcrumb = Breadcrumb(level: .info, category: "navigation")
            navBreadcrumb.message = "Navigated to \(tabName)"
            navBreadcrumb.data = ["view": tabName]
            SentryHelper.addBreadcrumb(navBreadcrumb)

            AnalyticsService.shared.capture("tab_selected", ["tab": tabName])
            AnalyticsService.shared.screen(tabName)
            if newIcon == .timeline {
                AnalyticsService.shared.withSampling(probability: 0.01) {
                    AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": dayString(selectedDate)])
                }
            }
        }
        .onChange(of: selectedDate) { newDate in
            // If changed via picker, emit navigation now
            if let method = lastDateNavMethod, method == "picker" {
                AnalyticsService.shared.capture("date_navigation", [
                    "method": method,
                    "from_day": dayString(previousDate),
                    "to_day": dayString(newDate)
                ])
            }
            previousDate = newDate
            AnalyticsService.shared.withSampling(probability: 0.01) {
                AnalyticsService.shared.capture("timeline_viewed", ["date_bucket": dayString(newDate)])
            }
        }
        .onChange(of: selectedActivity?.id) { _ in
            guard let a = selectedActivity else { return }
            let dur = a.endTime.timeIntervalSince(a.startTime)
            AnalyticsService.shared.capture("activity_card_opened", [
                "activity_type": a.category,
                "duration_bucket": AnalyticsService.shared.secondsBucket(dur),
                "has_video": a.videoSummaryURL != nil
            ])
        }
        // If user returns from Settings and a reset was pending, perform it once
        .onChange(of: selectedIcon) { newIcon in
            if newIcon != .settings, inactivity.pendingReset {
                performIdleResetAndScroll()
                InactivityMonitor.shared.markHandledIfPending()
            }
        }
        .onDisappear {
            // Safety: stop timer if view disappears
            stopDayChangeTimer()
        }
        .overlay {
            if showCategoryEditor {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            showCategoryEditor = false
                        }

                    ColorOrganizerRoot(
                        backgroundStyle: .color(.clear),
                        onDismiss: { showCategoryEditor = false }
                    )
                    .environmentObject(categoryStore)
                    // Removed .contentShape(Rectangle()) and .onTapGesture to allow keyboard input
                }
            }
        }
    }
    
    private func formatDateForDisplay(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let formatter = DateFormatter()

        let displayDate = timelineDisplayDate(from: date, now: now)
        let timelineToday = timelineDisplayDate(from: now, now: now)

        if calendar.isDate(displayDate, inSameDayAs: timelineToday) {
            formatter.dateFormat = "'Today,' MMM d"
        } else {
            formatter.dateFormat = "E, MMM d"
        }

        return formatter.string(from: displayDate)
    }

    private func setSelectedDate(_ date: Date) {
        selectedDate = normalizedTimelineDate(date)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum SidebarIcon: CaseIterable {
    case timeline
    case dashboard
    case journal
    case bug
    case settings

    var assetName: String? {
        switch self {
        case .timeline: return "TimelineIcon"
        case .dashboard: return "DashboardIcon"
        case .journal: return "JournalIcon"
        case .bug: return nil
        case .settings: return nil
        }
    }

    var systemNameFallback: String? {
        switch self {
        case .bug: return "exclamationmark.bubble"
        case .settings: return "gearshape"
        default: return nil
        }
    }
}

struct SidebarView: View {
    @Binding var selectedIcon: SidebarIcon
    
    var body: some View {
        VStack(alignment: .center, spacing: 10.501) {
            ForEach(SidebarIcon.allCases, id: \.self) { icon in
                SidebarIconButton(
                    icon: icon,
                    isSelected: selectedIcon == icon,
                    action: { selectedIcon = icon }
                )
                .frame(width: 40, height: 40)
            }
        }
        // Outer rounded container removed per design
    }
}

struct SidebarIconButton: View {
    let icon: SidebarIcon
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Image("IconBackground")
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.original)
                }

                if let asset = icon.assetName {
                    Image(asset)
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.template)
                        .foregroundColor(isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } else if let sys = icon.systemNameFallback {
                    Image(systemName: sys)
                        .font(.system(size: 18))
                        .foregroundColor(isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
    }
}

struct TabFilterBar: View {
    let categories: [TimelineCategory]
    let idleCategory: TimelineCategory?
    let onManageCategories: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(categories) { category in
                        CategoryChip(category: category, isIdle: false)
                    }

                    if let idleCategory {
                        CategoryChip(category: idleCategory, isIdle: true)
                    }

                    // Spacer for edit button (8px natural spacing)
                    Color.clear.frame(width: 8)
                }
                .padding(.leading, 1)
                .padding(.trailing, 34) // 26 (button width) + 8 (spacing)
            }
            .frame(height: 26)

            // Gradient fade for overflow
            HStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    gradient: Gradient(colors: [Color.clear, Color(hex: "FFF8F1") ?? Color.white]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 40)
                .allowsHitTesting(false)

                Color(hex: "FFF8F1")
                    .frame(width: 26)
                    .allowsHitTesting(false)
            }

            // Edit button always visible on right
            Button(action: onManageCategories) {
                Image("CategoryEditButton")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(height: 26)
    }

    struct CategoryChip: View {
        let category: TimelineCategory
        let isIdle: Bool

        var body: some View {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hex: category.colorHex) ?? .blue)
                    .frame(width: 10, height: 10)

                Text(category.name)
                    .font(
                        Font.custom("Nunito", size: 13)
                            .weight(.medium)
                    )
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(height: 26)
            .background(.white.opacity(0.76))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .inset(by: 0.25)
                    .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 0.5)
            )
        }
    }
}

struct DateNavigationControls: View {
    @Binding var selectedDate: Date
    @Binding var showDatePicker: Bool
    @Binding var lastDateNavMethod: String?
    @Binding var previousDate: Date

    var body: some View {
        HStack(spacing: 12) {
            DayflowCircleButton {
                let from = selectedDate
                let to = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                previousDate = selectedDate
                selectedDate = normalizedTimelineDate(to)
                lastDateNavMethod = "prev"
                AnalyticsService.shared.capture("date_navigation", [
                    "method": "prev",
                    "from_day": dayString(from),
                    "to_day": dayString(to)
                ])
            } content: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.3))
            }

            Button(action: { showDatePicker = true; lastDateNavMethod = "picker" }) {
                DayflowPillButton(
                    text: formatDateForDisplay(selectedDate),
                    fixedWidth: calculateOptimalPillWidth()
                )
            }
            .buttonStyle(PlainButtonStyle())

            DayflowCircleButton {
                guard canNavigateForward(from: selectedDate) else { return }
                let from = selectedDate
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                previousDate = selectedDate
                selectedDate = normalizedTimelineDate(tomorrow)
                lastDateNavMethod = "next"
                AnalyticsService.shared.capture("date_navigation", [
                    "method": "next",
                    "from_day": dayString(from),
                    "to_day": dayString(tomorrow)
                ])
            } content: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(
                        canNavigateForward(from: selectedDate)
                        ? Color(red: 0.3, green: 0.3, blue: 0.3)
                        : Color.gray.opacity(0.3)
                    )
            }
        }
    }

    private func formatDateForDisplay(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let formatter = DateFormatter()

        let displayDate = timelineDisplayDate(from: date, now: now)
        let timelineToday = timelineDisplayDate(from: now, now: now)

        if calendar.isDate(displayDate, inSameDayAs: timelineToday) {
            formatter.dateFormat = "'Today,' MMM d"
        } else {
            formatter.dateFormat = "E, MMM d"
        }

        return formatter.string(from: displayDate)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func calculateOptimalPillWidth() -> CGFloat {
        let sampleText = "Today, Sep 30"
        let nsFont = NSFont(name: "InstrumentSerif-Regular", size: 18) ?? NSFont.systemFont(ofSize: 18)
        let textSize = sampleText.size(withAttributes: [.font: nsFont])
        let horizontalPadding: CGFloat = 11.77829 * 2
        return textSize.width + horizontalPadding + 8
    }
}


extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

extension MainView {
    private func startDayChangeTimer() {
        stopDayChangeTimer()
        dayChangeTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            handleMinuteTickForDayChange()
        }
    }

    private func stopDayChangeTimer() {
        dayChangeTimer?.invalidate()
        dayChangeTimer = nil
    }

    private func handleMinuteTickForDayChange() {
        // Detect civil day rollover regardless of what day user is viewing
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let currentCivilDay = fmt.string(from: Date())
        if currentCivilDay != lastObservedCivilDay {
            lastObservedCivilDay = currentCivilDay

            // Jump to current civil day and re-scroll near now
            setSelectedDate(timelineDisplayDate(from: Date()))
            selectedActivity = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    scrollToNowTick &+= 1
                }
            }
        }
    }

    private func performIdleResetAndScroll() {
        // Switch to today
        setSelectedDate(timelineDisplayDate(from: Date()))
        // Clear selection
        selectedActivity = nil
        // Nudge timeline to scroll to now after it reloads
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            #if DEBUG
            print("[MainView] performIdleResetAndScroll -> nudging scrollToNowTick")
            #endif
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollToNowTick &+= 1
            }
        }
    }
    
    private func performInitialScrollIfNeeded() {
        // Check all conditions for initial scroll:
        // 1. Timeline is visible (not in settings)
        // 2. No modal is open
        // 3. Selected date is today
        guard selectedIcon != .settings,
              !showDatePicker,
              timelineIsToday(selectedDate) else {
            return
        }
        
        // Mark that we've attempted initial scroll
        didInitialScroll = true
        
        // Wait for layout to settle after animations complete
        // Increased delay to ensure ScrollView is fully ready on cold start
        #if DEBUG
        print("[MainView] performInitialScrollIfNeeded scheduled with 1.5s delay")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            #if DEBUG
            print("[MainView] performInitialScrollIfNeeded firing -> nudging scrollToNowTick")
            #endif
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollToNowTick &+= 1
            }
        }
    }
}

struct ActivityCard: View {
    let activity: TimelineActivity?
    var maxHeight: CGFloat? = nil
    var scrollSummary: Bool = false
    var hasAnyActivities: Bool = true
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var categoryStore: CategoryStore

    @State private var isRetrying = false
    @State private var retryProgress: String = ""
    @State private var retryError: String? = nil

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
    
    var body: some View {
        if let activity = activity {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.title)
                            .font(
                                Font.custom("Nunito", size: 16)
                                    .weight(.semibold)
                            )
                            .foregroundColor(.black)

                        Text("\(timeFormatter.string(from: activity.startTime)) to \(timeFormatter.string(from: activity.endTime))")
                            .font(
                                Font.custom("Nunito", size: 12)
                            )
                            .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                    }

                    Spacer()

                    // Retry button centered between title and time (only for failed cards)
                    if isFailedCard(activity) {
                        retryButtonInline(for: activity)
                    }
                }

                // Error message (if retry failed)
                if isFailedCard(activity), let error = retryError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 12))

                        Text(error)
                            .font(.custom("Nunito", size: 11))
                            .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                            .lineLimit(2)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.05))
                    .cornerRadius(6)
                }

                // Video thumbnail placeholder
                if let videoURL = activity.videoSummaryURL {
                    VideoThumbnailView(
                        videoURL: videoURL,
                        title: activity.title,
                        startTime: activity.startTime,
                        endTime: activity.endTime
                    )
                        .id(videoURL)
                        .frame(height: 200)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.1))
                        .frame(height: 200)
                        .overlay(
                            VStack {
                                Image(systemName: "video.slash")
                                    .font(.system(size: 30))
                                    .foregroundColor(.gray.opacity(0.5))
                                Text("No video available")
                                    .font(.caption)
                                    .foregroundColor(.gray.opacity(0.5))
                            }
                        )
                }
                
                // Summary section (scrolls internally when constrained)
                Group {
                    if scrollSummary {
                        ScrollView(.vertical, showsIndicators: false) {
                            summaryContent(for: activity)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .id(activity.id) // Reset scroll position whenever the selected activity changes
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        summaryContent(for: activity)
                    }
                }
            }
            .padding(16)
            .if(maxHeight != nil) { view in
                view.frame(maxHeight: maxHeight!)
            }
        } else {
            // Empty state
            VStack(spacing: 10) {
                Spacer()
                if hasAnyActivities {
                    Text("Select an activity to view details")
                        .font(.custom("Nunito", size: 15))
                        .fontWeight(.regular)
                        .foregroundColor(.gray.opacity(0.5))
                } else {
                    if appState.isRecording {
                        VStack(spacing: 6) {
                            Text("No cards yet")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.gray.opacity(0.7))
                            Text("Cards are generated about every 15 minutes. If Dayflow is on and no cards show up within 30 minutes, please report a bug.")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.gray.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Text("Recording is off")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.gray.opacity(0.7))
                            Text("Dayflow recording is currently turned off, so cards aren’t being produced.")
                                .font(.custom("Nunito", size: 13))
                                .foregroundColor(.gray.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .if(maxHeight != nil) { view in
                view.frame(maxHeight: maxHeight!)
            }
        }
    }

    @ViewBuilder
    private func summaryContent(for activity: TimelineActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SUMMARY")
                    .font(
                        Font.custom("Nunito", size: 12)
                            .weight(.semibold)
                    )
                    .foregroundColor(Color(red: 0.55, green: 0.55, blue: 0.55))

                renderMarkdownText(activity.summary)
                    .font(
                        Font.custom("Nunito", size: 12)
                    )
                    .foregroundColor(.black)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !activity.detailedSummary.isEmpty && activity.detailedSummary != activity.summary {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DETAILED SUMMARY")
                        .font(
                            Font.custom("Nunito", size: 12)
                                .weight(.semibold)
                        )
                        .foregroundColor(Color(red: 0.55, green: 0.55, blue: 0.55))

                    renderMarkdownText(activity.detailedSummary)
                        .font(
                            Font.custom("Nunito", size: 12)
                        )
                        .foregroundColor(.black)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func renderMarkdownText(_ content: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: content, options: options) {
            return Text(parsed)
        }
        return Text(content)
    }

    private func categoryBadge(for raw: String) -> (name: String, background: Color, textColor: Color)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased()
        let categories = categoryStore.categories
        let matched = categories.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }
        guard let category = matched ?? categories.first else { return nil }

        let nsColor = NSColor(hex: category.colorHex) ?? NSColor(hex: "#4F80EB") ?? .systemBlue
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let brightness = (0.299 * r) + (0.587 * g) + (0.114 * b)

        let background: Color
        let textColor: Color
        if category.isIdle {
            background = Color.white.opacity(0.8)
            textColor = Color(nsColor: nsColor).opacity(0.9)
        } else {
            background = Color(nsColor: nsColor).opacity(0.85)
            textColor = brightness > 0.6 ? Color.black.opacity(0.8) : .white
        }

        return (name: category.name, background: background, textColor: textColor)
    }

    // MARK: - Retry Functionality

    private func isFailedCard(_ activity: TimelineActivity) -> Bool {
        return activity.title == "Processing failed"
    }

    @ViewBuilder
    private func retryButtonInline(for activity: TimelineActivity) -> some View {
        if isRetrying {
            // Processing state - beige pill with spinner
            HStack(alignment: .center, spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)

                Text("Processing")
                    .font(.custom("Nunito", size: 13))
                    .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.91, green: 0.85, blue: 0.8))
            .cornerRadius(200)
        } else {
            // Retry button - orange pill
            Button(action: { handleRetry(for: activity) }) {
                HStack(alignment: .center, spacing: 4) {
                    Text("Retry")
                        .font(.custom("Nunito", size: 13).weight(.medium))
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(red: 1, green: 0.54, blue: 0.17))
                .cornerRadius(200)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func handleRetry(for activity: TimelineActivity) {
        guard let batchId = activity.batchId else {
            retryError = "Cannot retry: batch information missing"
            return
        }

        isRetrying = true
        retryProgress = "Preparing to retry..."
        retryError = nil

        AnalysisManager.shared.reprocessSpecificBatches(
            [batchId],
            progressHandler: { progress in
                DispatchQueue.main.async {
                    self.retryProgress = progress
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    self.isRetrying = false

                    switch result {
                    case .success:
                        self.retryProgress = ""
                        self.retryError = nil
                        // Timeline will auto-refresh when batch completes

                    case .failure(let error):
                        self.retryProgress = ""
                        self.retryError = "Retry failed: \(error.localizedDescription)"

                        // Clear error after 10 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            self.retryError = nil
                        }
                    }
                }
            }
        )
    }
}

struct MetricRow: View {
    let label: String
    let value: Int
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.45))
            
            HStack {
                Text("\(value)%")
                    .font(.title3)
                    .fontWeight(.semibold)
                
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(color)
                            .frame(width: geometry.size.width * CGFloat(value) / 100, height: 8)
                    }
                }
                .frame(height: 8)
            }
        }
    }
}

// Background view moved to separate file: MainUIBackgroundView.swift

func canNavigateForward(from date: Date, now: Date = Date()) -> Bool {
    let calendar = Calendar.current
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
    let timelineToday = timelineDisplayDate(from: now, now: now)
    return calendar.compare(tomorrow, to: timelineToday, toGranularity: .day) != .orderedDescending
}

func normalizedTimelineDate(_ date: Date) -> Date {
    let calendar = Calendar.current
    if let normalized = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) {
        return normalized
    }
    let startOfDay = calendar.startOfDay(for: date)
    return calendar.date(byAdding: DateComponents(hour: 12), to: startOfDay) ?? date
}

func timelineDisplayDate(from date: Date, now: Date = Date()) -> Date {
    let calendar = Calendar.current
    var normalizedDate = normalizedTimelineDate(date)
    let normalizedNow = normalizedTimelineDate(now)
    let nowHour = calendar.component(.hour, from: now)

    if nowHour < 4 && calendar.isDate(normalizedDate, inSameDayAs: normalizedNow) {
        normalizedDate = calendar.date(byAdding: .day, value: -1, to: normalizedDate) ?? normalizedDate
    }

    return normalizedDate
}

func timelineIsToday(_ date: Date, now: Date = Date()) -> Bool {
    let calendar = Calendar.current
    let timelineDate = timelineDisplayDate(from: date, now: now)
    let timelineToday = timelineDisplayDate(from: now, now: now)
    return calendar.isDate(timelineDate, inSameDayAs: timelineToday)
}
