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

private struct AccountsSettingsPane: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var accounts = AccountRegistry.orderedAccounts()
    @State private var selected: String?
    @State private var connectedAccount: ConnectedAccount?
    @State private var connecting = false
    @State private var hoveredAddProvider: ServiceType?

    var body: some View {
        VStack(spacing: 0) {
            if let selected, let account = AccountRegistry.account(id: selected) {
                HStack(spacing: 12) {
                    Button { self.selected = nil } label: {
                        Label("Accounts", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to Accounts")
                    .accessibilityLabel("Back to Accounts")
                    .accessibilityIdentifier("settingsAccountsBack")
                    Text(account.displayLabel).font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider()
                SettingsAccountDetail(account: account, back: {
                    if self.selected == account.id { self.selected = nil }
                })
                    .disabled(viewModel.isReadOnlyPreview)
            } else {
                Form {
                    ForEach(ServiceType.allCases, id: \.self) { provider in
                        Section {
                            let serviceAccounts = accounts.filter { $0.provider == provider }
                            if serviceAccounts.isEmpty {
                                Text("No accounts yet").foregroundStyle(.secondary)
                            }
                            ForEach(serviceAccounts) { account in
                                accountRow(account)
                            }
                            Button { connect(provider) } label: {
                                HStack {
                                    Label("Add \(provider.displayName) Account…", systemImage: "plus")
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .background(hoveredAddProvider == provider ? Color.brand.opacity(0.08) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.brand)
                            .disabled(connecting || viewModel.isReadOnlyPreview)
                            .onHover { hoveredAddProvider = $0 ? provider : nil }
                        } header: {
                            Text(provider.displayName)
                        } footer: {
                            if provider == .claude, !accounts.isEmpty {
                                Text("Drag account cards in the menu bar popover to change their order. Open an account to manage its connection and menu bar gauge.")
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in reloadAccounts() }
        .onChange(of: viewModel.additionalAccounts.map(\.id)) { reloadAccounts() }
        .onChange(of: viewModel.enrolledServices) { reloadAccounts() }
        .onChange(of: selected) { _, id in if id == nil { reloadAccounts() } }
        .onAppear(perform: reloadAccounts)
        .sheet(item: $connectedAccount) { account in
            ConnectedAccountNameSheet(account: account, dismiss: { connectedAccount = nil }) { name, showInMenuBar in
                viewModel.saveConnectedAccount(id: account.id, name: name, showInMenuBar: showInMenuBar)
                connectedAccount = nil
                reloadAccounts()
            }
        }
        .alert(viewModel.connectAccountNotice ?? "", isPresented: Binding(
            get: { viewModel.connectAccountNotice != nil },
            set: { if !$0 { viewModel.connectAccountNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Nothing new was added. Sign in with a different account to connect another one.")
        }
    }

    private func connect(_ provider: ServiceType) {
        connecting = true
        Task {
            connectedAccount = await viewModel.connectAccount(for: provider)
            connecting = false
            reloadAccounts()
        }
    }

    private func reloadAccounts() { accounts = AccountRegistry.orderedAccounts() }

    private func accountRow(_ account: ConnectedAccount) -> some View {
        let status = AccountConnectionStatus(account: account, viewModel: viewModel)
        let needsDisambiguation = accounts.filter {
            $0.provider == account.provider && $0.displayLabel == account.displayLabel
        }.count > 1
        let shownInMenuBar = viewModel.settings.menuBarAccountIDs?.contains(account.id) == true
        return Button { selected = account.id } label: {
            HStack(spacing: 12) {
                Image(account.provider == .codex ? "logo-openai" : account.provider == .claude ? "logo-claude" : "logo-cursor")
                    .resizable().scaledToFit().frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayLabel)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if needsDisambiguation {
                        Text("ID …" + String((account.workspaceID ?? account.id).suffix(6)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if shownInMenuBar {
                        Text("Shown in menu bar")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: status.symbol).foregroundStyle(status.color)
                    Text(status.summary).foregroundStyle(.secondary)
                }
                .font(.callout).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(account.provider.displayName), \(account.displayLabel), \(status.summary)\(shownInMenuBar ? ", shown in menu bar" : "")")
        .accessibilityHint("Open account settings")
    }
}

@MainActor
struct AccountConnectionStatus {
    let account: ConnectedAccount
    let viewModel: QuotaViewModel
    var session: AdditionalAccountSession? {
        account.connectionKind == .isolated ? viewModel.additionalAccounts.first { $0.id == account.id } : nil
    }
    var connected: Bool {
        if account.connectionKind == .isolated { return session?.isAuthenticated == true }
        return account.provider == .codex ? viewModel.isCodexAuthenticated : viewModel.isClaudeAuthenticated
    }
    var issue: String? {
        if account.connectionKind == .isolated { return session?.issue }
        return account.provider == .codex ? viewModel.codexError?.localizedDescription : viewModel.claudeError?.localizedDescription
    }
    var summary: String { !connected ? "Not signed in" : issue == nil ? "Connected" : "Couldn’t refresh usage" }
    var symbol: String { !connected ? "minus.circle" : issue == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill" }
    var color: Color { !connected ? .secondary : issue == nil ? .green : .orange }
}

private struct SettingsAccountDetail: View {
    @Environment(QuotaViewModel.self) private var viewModel
    let account: ConnectedAccount
    let back: () -> Void
    @State private var name = ""
    @State private var pendingAction: String?
    @State private var busy = false
    @AppStorage(ClaudeOAuthKeychainReader.consentDefaultsKey) private var reuseClaudeCodeKeychain = false

    var body: some View {
        let status = AccountConnectionStatus(account: account, viewModel: viewModel)
        Form {
            Section("Account") {
                TextField("Display name", text: $name)
                    .onSubmit(saveName)
                LabeledContent("Service", value: account.provider.displayName)
                if let identity = account.workspaceID {
                    LabeledContent("Workspace ID", value: identity).textSelection(.enabled)
                }
                Toggle("Show in menu bar", isOn: Binding(get: {
                    viewModel.settings.menuBarAccountIDs?.contains(account.id) == true
                }, set: { shown in
                    var ids = viewModel.settings.menuBarAccountIDs ?? []
                    ids.removeAll { $0 == account.id }
                    if shown { ids.append(account.id) }
                    viewModel.settings.menuBarAccountIDs = ids
                }))
            }
            Section("Connection") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(status.connected ? "Signed in" : "Not signed in", systemImage: status.connected ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(status.connected ? Color.green : .secondary)
                    if let issue = status.issue {
                        Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                if busy { ProgressView().controlSize(.small) }
                else if status.connected {
                    Button("Refresh Usage") {
                        if let session = status.session { Task { await session.refresh(userInitiated: true) } }
                        else { viewModel.manualRefresh() }
                    }
                    .settingsAction()
                    if account.provider == .codex,
                       (account.connectionKind == .isolated ? status.session?.issue != nil : viewModel.codexError?.needsReconnect == true) {
                        Button("Reconnect…", action: reconnect).settingsAction()
                    }
                    Button("Sign Out…", role: .destructive) { pendingAction = "Sign Out" }
                        .settingsAction()
                } else {
                    Button("Sign In…", action: reconnect)
                    .settingsAction()
                }
                if account.provider == .claude, account.connectionKind == .legacyPrimary,
                   AppDistribution.allowsHostCredentialDiscovery {
                    Toggle(isOn: $reuseClaudeCodeKeychain) {
                        Text("Reuse Claude Code Keychain credentials")
                        Text("Uses Claude Code’s saved sign-in when macOS allows access without a permission prompt.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Reuse Claude Code Keychain credentials")
                }
            }
            if account.provider == .codex {
                Section { Link("Codex Resets…", destination: CodexResetNotice.website).foregroundColor(.brand) }
            }
            if account.connectionKind == .isolated {
                Section {
                    Button("Remove Account…", role: .destructive) { pendingAction = "Remove Account" }
                        .settingsAction()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = AccountRegistry.account(id: account.id)?.displayLabel ?? account.displayLabel }
        .onDisappear(perform: saveName)
        .confirmationDialog("\(pendingAction ?? "Remove Account")?", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button(pendingAction ?? "Remove Account", role: .destructive) {
                let action = pendingAction
                pendingAction = nil
                busy = true
                Task {
                    if account.connectionKind == .legacyPrimary {
                        if account.provider == .codex { viewModel.signOut() }
                        else { viewModel.signOutClaude() }
                    } else if action == "Remove Account" { await viewModel.removeAccount(id: account.id) }
                    else { await viewModel.signOutAccount(id: account.id) }
                    back()
                }
            }
        } message: {
            Text(pendingAction == "Remove Account" ? "Removes this account’s local connection and cached usage." : "You can reconnect this account at any time.")
        }
    }
    private func reconnect() {
        busy = true
        Task {
            if account.connectionKind == .isolated { await viewModel.reconnectAccount(id: account.id) }
            else if account.provider == .codex { await viewModel.signIn() }
            else if account.provider == .claude { await viewModel.signInClaude() }
            else { await viewModel.signInCursor() }
            busy = false
        }
    }
    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !viewModel.isReadOnlyPreview, !trimmed.isEmpty,
              trimmed != AccountRegistry.account(id: account.id)?.displayLabel else { return }
        viewModel.renameAccount(id: account.id, to: trimmed)
    }
}

private struct NotificationsSettingsPane: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    private var allowed: Bool { authorization == .authorized || authorization == .provisional }

    var body: some View {
        @Bindable var vm = viewModel
        Form {
            Section {
                Toggle("Enable notifications", isOn: $vm.settings.notifications.enabled)
                    .onChange(of: vm.settings.notifications.enabled) { _, enabled in
                        if enabled && !viewModel.isReadOnlyPreview { Task { await NotificationManager.shared.requestPermission(); await checkPermission() } }
                    }
                if !allowed {
                    Button(authorization == .denied ? "Open System Settings…" : "Allow Notifications…") {
                        if authorization == .denied {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        } else { Task { await NotificationManager.shared.requestPermission(); await checkPermission() } }
                    }
                    .settingsAction()
                    .disabled(viewModel.isReadOnlyPreview)
                }
            } footer: {
                if !allowed {
                    Text(authorization == .denied ? "Notifications are disabled in System Settings." : "Allow notifications to receive usage alerts and reset reminders.")
                }
            }
            if vm.settings.notifications.enabled {
                if viewModel.isCodexEnrolled {
                    Section("Codex") {
                        Toggle("Allow Codex notifications", isOn: $vm.settings.notifications.codexEnabled)
                        NotificationInlineControls(service: .codex, preferences: $vm.settings.notifications)
                            .disabled(!vm.settings.notifications.codexEnabled)
                    }
                }
                if viewModel.isClaudeEnrolled {
                    Section("Claude Code") {
                        Toggle("Allow Claude Code notifications", isOn: $vm.settings.notifications.claudeEnabled)
                        NotificationInlineControls(service: .claude, preferences: $vm.settings.notifications)
                            .disabled(!vm.settings.notifications.claudeEnabled)
                    }
                }
                if viewModel.isCursorEnrolled {
                    Section("Cursor") {
                        Toggle("Allow Cursor notifications", isOn: $vm.settings.notifications.cursorEnabled)
                        NotificationInlineControls(service: .cursor, preferences: $vm.settings.notifications)
                            .disabled(!vm.settings.notifications.cursorEnabled)
                    }
                }
                Section {} footer: {
                    Text("One usage alert per window when usage reaches your threshold. Reset reminders are separate. On Mac, alerts follow the original connection for each service.")
                }
                if viewModel.enrolledServices.isEmpty {
                    ContentUnavailableView("Connect an account", systemImage: "bell",
                                           description: Text("Notification options appear after you connect a service."))
                }
            }
        }
        .formStyle(.grouped)
        .task { await checkPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkPermission() }
        }
    }
    private func checkPermission() async { authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
}

struct AboutSettingsPane: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image("AppBrandIcon").resizable().scaledToFit().frame(width: 96, height: 96)
                    .shadow(color: Color.brand.opacity(0.2), radius: 25)
                    .accessibilityHidden(true)
                Text("AIQuota").font(.system(size: 32, weight: .bold)).padding(.top, 20)
                Text("Know your limits.\nKeep your flow.")
                    .font(.title3).foregroundStyle(.secondary).padding(.top, 10)
                Text("Version \(version) (\(build))").font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.top, 24)
                Text("Made by John Niedermeyer, with a little help from Claude, Codex, and friends.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 330).padding(.top, 24)
                VStack(spacing: 12) {
                    Link("Website", destination: URL(string: "https://aiquota.app")!)
                    Link("Report an Issue", destination: URL(string: "https://github.com/niederme/ai-quota/issues")!)
                    Link("@niederme on X", destination: URL(string: "https://x.com/niederme")!)
                }
                .foregroundColor(.brand).padding(.top, 24)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.vertical, 44)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
