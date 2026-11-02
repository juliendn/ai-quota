import SwiftUI
import ServiceManagement
import UserNotifications
import AIQuotaKit
import MobileAccessCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", accounts = "Accounts", notifications = "Notifications", about = "About"
    var id: Self { self }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .notifications: "bell"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var page: SettingsPage = .general

    var body: some View {
        TabView(selection: $page) {
            ForEach(SettingsPage.allCases) { item in
                Group {
                    switch item {
                    case .general: GeneralSettingsPane()
                    case .accounts: AccountsSettingsPane()
                    case .notifications: NotificationsSettingsPane()
                    case .about: AboutSettingsPane()
                    }
                }
                .tabItem { Label(item.rawValue, systemImage: item.icon) }
                .tag(item)
            }
        }
        .background(SettingsWindowPresentation())
        .frame(minWidth: 540, idealWidth: 600, minHeight: 560, idealHeight: 650)
        .tint(Color.brand)
        .onChange(of: viewModel.settings) {
            if !viewModel.isReadOnlyPreview { viewModel.saveSettings() }
        }
    }
}

/// Keep Settings above other windows while it is open, including when another
/// app becomes active.
private struct SettingsWindowPresentation: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowObserver { SettingsWindowObserver() }
    func updateNSView(_ nsView: SettingsWindowObserver, context: Context) {}
}

private final class SettingsWindowObserver: NSView {
    private weak var settingsWindow: NSWindow?
    private var originalLevel: NSWindow.Level = .normal

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== settingsWindow else { return }
        if let settingsWindow { settingsWindow.level = originalLevel }
        settingsWindow = window
        guard let window else { return }
        originalLevel = window.level
        window.level = .floating
    }
}

private extension View {
    /// Native bezels distinguish actions from links and grouped row backgrounds.
    @ViewBuilder func settingsAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
                .tint(nil)
                .foregroundStyle(.primary)
                .controlSize(.regular)
        } else {
            buttonStyle(.bordered)
                .tint(nil)
                .foregroundStyle(.primary)
                .controlSize(.regular)
        }
    }
}

private struct GeneralSettingsPane: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(UpdaterViewModel.self) private var updater
    @Environment(\.openWindow) private var openWindow
    @State private var confirmReset = false
    @State private var resetting = false

    var body: some View {
        @Bindable var vm = viewModel
        @Bindable var updates = updater
        Form {
            Section {
                LaunchAtLoginToggle().disabled(viewModel.isReadOnlyPreview)
                Picker("Refresh usage", selection: $vm.settings.refreshIntervalMinutes) {
                    Text("Automatically").tag(0)
                    Text("Every minute").tag(1)
                    ForEach([5, 10, 30], id: \.self) { Text("Every \($0) minutes").tag($0) }
                }
            } header: { Text("Application") } footer: {
                if vm.settings.usesAdaptiveRefresh {
                    Text("Checks every 5 minutes, more often near a limit, and less often when your Mac is idle.")
                }
            }
            #if !APP_STORE
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .settingsAction()
                    .disabled(!updater.canCheckForUpdates)
            }
            #endif
            Section {
                Toggle("Share anonymous usage data", isOn: $vm.settings.analyticsEnabled)
            } header: { Text("Privacy") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Helps improve AIQuota. Includes app activity and version, never prompts, credentials, or personal information.")
                    Link("Privacy Policy", destination: URL(string: "https://aiquota.app/privacy/")!)
                        .foregroundColor(.brand)
                }
            }
            Section("Troubleshooting") {
                SettingsDiagnostics()
            }
            Section("Setup & Reset") {
                LabeledContent {
                    Button("Guided Setup…") {
                        viewModel.resetOnboardingForReplay()
                        openWindow(id: "onboarding")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .settingsAction()
                    .disabled(viewModel.isReadOnlyPreview)
                } label: {
                    Text("Revisit setup")
                    Text("Keeps your accounts and preferences.").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent {
                    Button("Reset AIQuota…", role: .destructive) { confirmReset = true }
                        .settingsAction()
                        .disabled(viewModel.isReadOnlyPreview)
                } label: {
                    Text("Start over")
                    Text("Signs out and clears local settings and data.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(resetting)
        .confirmationDialog("Reset AIQuota?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset AIQuota", role: .destructive) {
                resetting = true
                Task {
                    await viewModel.resetToNewUser()
                    resetting = false
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } message: {
            Text("This signs out of every account, clears cached data, and restores default settings. System notification permissions are unchanged.")
        }
    }
}
