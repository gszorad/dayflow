//
//  DayflowApp.swift
//  Dayflow
//

import SwiftUI
import Sparkle

struct AppRootView: View {
    @EnvironmentObject private var categoryStore: CategoryStore
    @State private var whatsNewNote: ReleaseNote? = nil
    @State private var activeWhatsNewVersion: String? = nil
    private let isWhatsNewEnabled = false

    var body: some View {
        MainView()
            .environmentObject(AppState.shared)
            .environmentObject(categoryStore)
            .onAppear {
                guard isWhatsNewEnabled else { return }
                // Check if we should show What's New automatically
                if whatsNewNote == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let note = WhatsNewView.shouldShowWhatsNew() {
                            whatsNewNote = note
                            activeWhatsNewVersion = note.version
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
                guard isWhatsNewEnabled else { return }
                // Manual trigger from menu - show latest release notes
                if let latestNote = releaseNotes.first {
                    whatsNewNote = latestNote
                    activeWhatsNewVersion = latestNote.version

                    // Analytics: track manual view
                    AnalyticsService.shared.capture("whats_new_viewed_manual", [
                        "version": latestNote.version
                    ])
                }
            }
            .sheet(item: $whatsNewNote, onDismiss: handleWhatsNewDismissed) { note in
                ZStack {
                    // Backdrop
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    WhatsNewView(releaseNote: note) {
                        closeWhatsNew()
                    }
                }
            }
    }

    private func closeWhatsNew() {
        whatsNewNote = nil
    }

    private func handleWhatsNewDismissed() {
        guard isWhatsNewEnabled else { return }
        guard activeWhatsNewVersion != nil else { return }
        WhatsNewView.markAsSeen()
        activeWhatsNewVersion = nil
    }
}

@main
struct DayflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("didOnboard") private var didOnboard = false
    @AppStorage("useBlankUI") private var useBlankUI = false
    @State private var showVideoLaunch = true
    @State private var contentOpacity = 0.0
    @State private var contentScale = 0.98
    @StateObject private var categoryStore = CategoryStore()
    
    init() {
        // Comment out for production - only use for testing onboarding
        // UserDefaults.standard.set(false, forKey: "didOnboard")
    }
    
    // Sparkle updater manager
    private let updaterManager = UpdaterManager.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Main app UI or onboarding with entrance animation
                Group {
                    if didOnboard {
                        // Show UI after onboarding
                        AppRootView()
                            .environmentObject(categoryStore)
                            .environmentObject(updaterManager)
                    } else {
                        OnboardingFlow()
                            .environmentObject(AppState.shared)
                            .environmentObject(categoryStore)
                            .environmentObject(updaterManager)
                    }
                }
                .opacity(contentOpacity)
                .scaleEffect(contentScale)
                .animation(.easeOut(duration: 0.3).delay(0.15), value: contentOpacity)
                .animation(.easeOut(duration: 0.3).delay(0.15), value: contentScale)

                // Video overlay on top with scale + opacity exit
                if showVideoLaunch {
                    VideoLaunchView()
                        .onVideoComplete {
                            // Overlapping animations for smooth handoff
                            withAnimation(.easeOut(duration: 0.25)) {
                                // Start revealing content while video fades
                                contentOpacity = 1.0
                                contentScale = 1.0
                            }
                            
                            // Slightly delayed video exit for overlap
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeIn(duration: 0.2)) {
                                    showVideoLaunch = false
                                }
                            }
                        }
                        .opacity(showVideoLaunch ? 1 : 0)
                        .scaleEffect(showVideoLaunch ? 1 : 1.02)
                        .animation(.easeIn(duration: 0.2), value: showVideoLaunch)
                }
            }
            // Inline background behind the main app UI only
            .background {
                if didOnboard {
                    Image("MainUIBackground")
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Remove the "New Window" command if you want a single window app
            CommandGroup(replacing: .newItem) { }
            
            // Add custom menu items after the app info section
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Reset Onboarding") {
                    // Reset the onboarding flag
                    UserDefaults.standard.set(false, forKey: "didOnboard")
                    // Reset the saved onboarding step to start from beginning
                    UserDefaults.standard.set(0, forKey: "onboardingStep")
                    // Reset the selected LLM provider to default
                    UserDefaults.standard.set("gemini", forKey: "selectedLLMProvider")
                    // Force quit and restart the app to show onboarding
                    Task { @MainActor in
                        AppDelegate.allowTermination = true
                        NSApp.terminate(nil)
                    }
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
            }
            
            // Add Sparkle's update menu item
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterManager.checkForUpdates(showUI: true)
                }

                Button("View Release Notes") {
                    // Activate the app and bring to foreground
                    NSApp.activate(ignoringOtherApps: true)

                    // Post notification to show What's New modal
                    NotificationCenter.default.post(name: .showWhatsNew, object: nil)
                }
                .keyboardShortcut("N", modifiers: [.command, .shift])
            }
        }
        .defaultSize(width: 1200, height: 800)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showWhatsNew = Notification.Name("showWhatsNew")
}
