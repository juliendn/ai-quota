import Foundation
import AppKit
import CoreGraphics
import Network
import os
import AIQuotaKit
import MobileAccessCore
import WidgetKit

@MainActor
@Observable
final class QuotaViewModel {

    private let logger = Logger(subsystem: "ai.quota", category: "refresh")

    // MARK: - Codex (OpenAI)

    var isReadOnlyPreview = false
    private(set) var isManualRefreshing = false
    var showsManualRefreshProgress: Bool {
        isManualRefreshing || additionalAccounts.contains { $0.isManualRefreshing }
    }
    var codexTokenHistory: AIQuotaKit.CodexTokenHistory?
    var isTokenHistoryLoading = false
    var tokenHistoryUnavailable = false
    var tokenHistoryFailed = false
    private var tokenHistoryTask: Task<Void, Never>?
    private var tokenHistoryAttempt: Date?
    private var tokenHistoryGeneration = 0
    private var tokenHistoryScope = AIQuotaKit.CodexTokenHistoryScope()

    func refreshTokenHistory(force: Bool = false) {
        guard !isReadOnlyPreview, !Self.isDemoBuild, isCodexAuthenticated else { return }
        guard tokenHistoryTask == nil else { return }
        if codexTokenHistory == nil { isTokenHistoryLoading = true }
        let generation = tokenHistoryGeneration
        tokenHistoryTask = Task {
            defer {
                if generation == tokenHistoryGeneration {
                    isTokenHistoryLoading = false
                    tokenHistoryTask = nil
                }
            }
            var verifiedAccount = false
            var requestScopeID: String?
            do {
                let scopeID = try await codexClient.tokenHistoryScopeID()
                guard !Task.isCancelled, generation == tokenHistoryGeneration, isCodexAuthenticated else { return }
                if tokenHistoryScope.update(scopeID: scopeID) {
                    codexTokenHistory = nil
                    tokenHistoryAttempt = nil
                    tokenHistoryUnavailable = false
                    tokenHistoryFailed = false
                }
                verifiedAccount = true
                requestScopeID = scopeID
                if !force, let attempt = tokenHistoryAttempt, Date.now.timeIntervalSince(attempt) < 900 { return }
                tokenHistoryAttempt = .now
                isTokenHistoryLoading = true
                let history = try await codexClient.fetchTokenHistory()
                let currentScopeID = try await codexClient.tokenHistoryScopeID()
                guard !Task.isCancelled, generation == tokenHistoryGeneration, isCodexAuthenticated else { return }
                guard currentScopeID == scopeID, history == nil || history?.scopeID == scopeID else {
                    codexTokenHistory = nil
                    tokenHistoryAttempt = nil
                    _ = tokenHistoryScope.update(scopeID: currentScopeID)
                    return
                }
                codexTokenHistory = history
                tokenHistoryUnavailable = history == nil
                tokenHistoryFailed = false
            } catch {
                let currentScopeID = try? await codexClient.tokenHistoryScopeID()
                guard !Task.isCancelled, generation == tokenHistoryGeneration else { return }
                if !verifiedAccount || requestScopeID == nil || currentScopeID != requestScopeID {
                    codexTokenHistory = nil
                    tokenHistoryAttempt = nil
                }
                tokenHistoryFailed = true
            }
        }
    }

    private func clearTokenHistory() {
        tokenHistoryGeneration += 1
        tokenHistoryScope = AIQuotaKit.CodexTokenHistoryScope()
        tokenHistoryTask?.cancel()
        tokenHistoryTask = nil
        codexTokenHistory = nil
        tokenHistoryAttempt = nil
        isTokenHistoryLoading = false
        tokenHistoryUnavailable = false
        tokenHistoryFailed = false
    }

    var codexUsageHistory: CodexUsageHistory?
    var isUsageHistoryLoading = false
    var usageHistoryFailed = false
    private var usageHistoryTask: Task<Void, Never>?
    private var usageHistoryAttempt: Date?
    private var usageHistoryGeneration = 0
    private var usageHistoryScope = AIQuotaKit.CodexTokenHistoryScope()

    func refreshUsageHistory(force: Bool = false) {
        guard !isReadOnlyPreview, !Self.isDemoBuild, isCodexAuthenticated else { return }
        guard usageHistoryTask == nil else { return }
        if codexUsageHistory == nil { isUsageHistoryLoading = true }
        let generation = usageHistoryGeneration
        usageHistoryTask = Task {
            defer {
                if generation == usageHistoryGeneration {
                    isUsageHistoryLoading = false
                    usageHistoryTask = nil
                }
            }
            var verifiedAccount = false
            var requestScopeID: String?
            do {
                let scopeID = try await codexClient.tokenHistoryScopeID()
                guard !Task.isCancelled, generation == usageHistoryGeneration, isCodexAuthenticated else { return }
                if usageHistoryScope.update(scopeID: scopeID) {
                    codexUsageHistory = nil
                    usageHistoryAttempt = nil
                    usageHistoryFailed = false
                }
                verifiedAccount = true
                requestScopeID = scopeID
                if !force, let attempt = usageHistoryAttempt, Date.now.timeIntervalSince(attempt) < 900 { return }
                usageHistoryAttempt = .now
                isUsageHistoryLoading = true
                let history = try await codexClient.fetchUsageHistory()
                let currentScopeID = try await codexClient.tokenHistoryScopeID()
                guard !Task.isCancelled, generation == usageHistoryGeneration, isCodexAuthenticated else { return }
                guard currentScopeID == scopeID else {
                    codexUsageHistory = nil
                    usageHistoryAttempt = nil
                    _ = usageHistoryScope.update(scopeID: currentScopeID)
                    return
                }
                codexUsageHistory = history
                usageHistoryFailed = false
            } catch {
                let currentScopeID = try? await codexClient.tokenHistoryScopeID()
                guard !Task.isCancelled, generation == usageHistoryGeneration else { return }
                if !verifiedAccount || requestScopeID == nil || currentScopeID != requestScopeID {
                    codexUsageHistory = nil
                    usageHistoryAttempt = nil
                }
                usageHistoryFailed = true
            }
        }
    }

    private func clearUsageHistory() {
        usageHistoryGeneration += 1
        usageHistoryScope = AIQuotaKit.CodexTokenHistoryScope()
        usageHistoryTask?.cancel()
        usageHistoryTask = nil
        codexUsageHistory = nil
        usageHistoryAttempt = nil
        isUsageHistoryLoading = false
        usageHistoryFailed = false
    }

    var codexUsage: CodexUsage?
    var codexAutoReload: CodexAutoReload?
    var isCodexLoading = false
    var codexError: NetworkError?

    let codexCoordinator: CodexAuthCoordinator
    private let codexClient: OpenAIClient

    // MARK: - Claude

    var claudeUsage: ClaudeUsage?
    var isClaudeLoading = false
    var claudeError: NetworkError?

    var claudeEnterpriseSpend: ScopedClaudeEnterpriseSpend?
    var claudeEnterpriseSkills: ScopedClaudeEnterpriseSkills?
    var isClaudeSpendLoading = false
    var isClaudeSkillsLoading = false
    var claudeSpendFailed = false
    var claudeSkillsFailed = false
    var isClaudeEnterpriseReconnectLoading = false
    private(set) var claudeEnterpriseReconnectRequired = false
    private var claudeEnterpriseReconnectExpectedOrganizationID: String?
    private var claudeEnterpriseReconnectPromptPolicy = ClaudeEnterpriseReconnectPromptPolicy()
    var isClaudeEnterpriseReconnectPromptPresented: Bool {
        claudeEnterpriseReconnectPromptPolicy.isPresented
    }
    private var claudeDetailScopeID: String?
    private var claudeDetailAllowanceSource: ClaudeUsage.Source?
    private var claudeSpendTask: Task<Void, Never>?
    private var claudeSkillsTask: Task<Void, Never>?
    private var claudeSpendAttempt: Date?
    private var claudeSkillsAttempt: Date?
    private var claudeDetailGeneration = 0

    /// Additional accounts keep their own coordinators, snapshots, and refresh state.
    /// The original coordinator for each provider remains the legacy connection.
    var additionalAccounts: [AdditionalAccountSession] = []

    var hasAdditionalAccounts: Bool { !additionalAccounts.isEmpty }

    func primaryAccount(for provider: ServiceType) -> ConnectedAccount? {
        AccountRegistry.accounts(for: provider).first { $0.connectionKind == .legacyPrimary }
    }

    private func ensurePrimaryAccount(for provider: ServiceType, selectNewAccount: Bool = true) {
        guard primaryAccount(for: provider) == nil else { return }
        let existingIDs = AccountRegistry.accounts().map(\.id)
        let account = AccountRegistry.upsert(
            provider: provider,
            displayLabel: "Personal",
            authSource: .webSession,
            connectionKind: .legacyPrimary
        )
        if selectNewAccount {
            settings.registerMenuBarAccount(id: account.id, existingAccountIDs: existingIDs)
            saveSettings()
        }
        if AccountRegistry.selectedAccountID(for: provider) == nil {
            AccountRegistry.selectAccount(id: account.id, for: provider)
        }
    }

    private func initializeMenuBarAccountsIfNeeded() {
        guard settings.menuBarAccountIDs == nil else { return }
        let primary = AccountRegistry.orderedAccounts().filter {
            $0.connectionKind == .legacyPrimary && enrolledServices.contains($0.provider)
        }
        let preferred: [ConnectedAccount]
        if settings.menuBarDisplayMode == .both {
            preferred = ServiceType.allCases.compactMap { service in
                primary.first { $0.provider == service }
            }
        } else {
            preferred = primary.filter { $0.provider == settings.menuBarService }
        }
        let selected = Array((preferred.isEmpty ? primary : preferred).prefix(2).map(\.id))
        guard !selected.isEmpty else { return }
        settings.menuBarAccountIDs = selected
        SharedDefaults.saveSettings(settings)
    }

    private func nameFromConnectedPlan(for provider: ServiceType, accountID: String, plan: String?) -> String {
        AccountNameSuggestion.make(
            service: provider.displayName,
            plan: plan,
            existingLabels: AccountRegistry.accounts(for: provider).filter { $0.id != accountID }.map(\.displayLabel)
        )
    }

    /// Explains why an add-account attempt ended without a new account.
    var connectAccountNotice: String?

    /// Connect and fetch this account's plan before offering its name in onboarding or Settings.
    func connectAccount(for provider: ServiceType) async -> ConnectedAccount? {
        guard !isReadOnlyPreview, !Self.isDemoBuild else { return nil }
        if primaryAccount(for: provider) == nil {
            switch provider {
            case .codex: await signIn()
            case .claude: await signInClaude()
            case .cursor: await signInCursor()
            }
            // The auth-state observer can start the first refresh before signIn's
            // refresh call. Wait for that request too, so naming sees its plan.
            while {
                switch provider {
                case .codex: isCodexLoading
                case .claude: isClaudeLoading
                case .cursor: isCursorLoading
                }
            }() {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return nil }
            }
            let authenticated: Bool = {
                switch provider {
                case .codex: isCodexAuthenticated
                case .claude: isClaudeAuthenticated
                case .cursor: isCursorAuthenticated
                }
            }()
            guard authenticated, !Task.isCancelled else { return nil }
            ensurePrimaryAccount(for: provider)
            guard let account = primaryAccount(for: provider) else { return nil }
            let plan: String? = {
                switch provider {
                case .codex: codexUsage?.displayPlan
                case .claude: claudeUsage?.planDisplayName
                case .cursor: cursorUsage?.planDisplayName
                }
            }()
            renameAccount(id: account.id, to: nameFromConnectedPlan(for: provider, accountID: account.id, plan: plan))
            return AccountRegistry.account(id: account.id)
        } else {
            if provider == .cursor {
                connectAccountNotice = "Multiple Cursor accounts aren't supported yet."
                return nil
            }
            return await addAccount(for: provider)
        }
    }

    private func addAccount(for provider: ServiceType) async -> ConnectedAccount? {
        await bindPrimaryIdentity(for: provider)
        let existingIDs = AccountRegistry.accounts().map(\.id)
        let account = AccountRegistry.upsert(
            provider: provider,
            displayLabel: AccountNameSuggestion.make(
                service: provider.displayName, plan: nil,
                existingLabels: AccountRegistry.accounts(for: provider).map(\.displayLabel)
            ),
            authSource: .webSession
        )
        settings.registerMenuBarAccount(id: account.id, existingAccountIDs: existingIDs)
        saveSettings()
        let session = AdditionalAccountSession(account: account)
        additionalAccounts.append(session)
        await session.signIn()
        guard session.isAuthenticated, session.account.workspaceID != nil, !Task.isCancelled else {
            // Never keep a card that did not finish connecting. A duplicate
            // would otherwise sit beside the original as "Couldn't load allowance".
            if session.isDuplicateIdentity {
                connectAccountNotice = "That \(provider == .codex ? "Codex" : "Claude") account is already connected."
            }
            await removeAccount(id: account.id)
            return nil
        }
        let plan = provider == .codex ? session.codexUsage?.displayPlan : session.claudeUsage?.planDisplayName
        renameAccount(id: account.id, to: nameFromConnectedPlan(for: provider, accountID: account.id, plan: plan))
        startAutoRefresh(immediateRefresh: false)
        return AccountRegistry.account(id: account.id)
    }

    func saveConnectedAccount(id: String, name: String, showInMenuBar: Bool?) {
        renameAccount(id: id, to: name)
        if let showInMenuBar {
            var ids = settings.menuBarAccountIDs ?? []
            ids.removeAll { $0 == id }
            if showInMenuBar { ids.append(id) }
            settings.menuBarAccountIDs = ids
            saveSettings()
        }
    }

    private func bindPrimaryIdentity(for provider: ServiceType) async {
        guard var account = primaryAccount(for: provider) else { return }
        let identity: String?
        switch provider {
        case .codex:
            identity = try? await codexCoordinator.accessContext().accountID
        case .claude:
            identity = try? await claudeCoordinator.requestContext().orgId
        case .cursor:
            if let context = try? await cursorCoordinator.requestContext() {
                identity = context.email ?? (try? CursorAPI.jwtSubject(context.accessToken))
            } else {
                identity = nil
            }
        }
        guard let identity, !identity.isEmpty else { return }
        if provider == .codex {
            guard account.workspaceID == nil,
                  !AccountRegistry.accounts(for: provider).contains(where: {
                      $0.id != account.id && $0.workspaceID == identity
                  }) else { return }
        }
        account.workspaceID = identity
        account.updatedAt = .now
        AccountRegistry.save(account)
    }

    func reconnectAccount(id: String) async {
        guard let session = additionalAccounts.first(where: { $0.id == id }) else { return }
        await session.signIn()
        if session.isAuthenticated { startAutoRefresh(immediateRefresh: false) }
    }

    func signOutAccount(id: String) async {
        guard let session = additionalAccounts.first(where: { $0.id == id }) else { return }
        await session.signOut()
        if !isCodexAuthenticated && !isClaudeAuthenticated &&
            !additionalAccounts.contains(where: { $0.isAuthenticated }) {
            stopAutoRefresh()
        }
    }

    func removeAccount(id: String) async {
        guard let session = additionalAccounts.first(where: { $0.id == id }) else { return }
        await session.signOut()
        AccountRegistry.remove(id: id)
        await QuotaInsightStore.shared.remove(accountID: id)
        additionalAccounts.removeAll { $0.id == id }
        if var selected = settings.menuBarAccountIDs, selected.contains(id) {
            selected.removeAll { $0 == id }
            settings.menuBarAccountIDs = selected
            saveSettings()
        }
        if !isCodexAuthenticated && !isClaudeAuthenticated &&
            !additionalAccounts.contains(where: { $0.isAuthenticated }) {
            stopAutoRefresh()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func renameAccount(id: String, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var account = AccountRegistry.account(id: id) else { return }
        account.displayLabel = name
        account.updatedAt = .now
        AccountRegistry.save(account)
        additionalAccounts.first { $0.id == id }?.updateAccount(account)
        WidgetCenter.shared.reloadAllTimelines()
    }

    let claudeCoordinator: ClaudeAuthCoordinator
    private let claudeClient: ClaudeClient

    // MARK: - Cursor

    var cursorUsage: CursorUsage?
    var isCursorLoading = false
    var cursorError: NetworkError?
    let cursorCoordinator: CursorAuthCoordinator
    private let cursorClient: CursorClient
    private var cursorRefreshGeneration = 0

    // MARK: - Auth state (derived from coordinator streams)

    var claudeState: AuthState = .unknown
    var codexState:  AuthState = .unknown
    var cursorState: AuthState = .unknown

    var isClaudeAuthenticated: Bool { claudeState == .authenticated }
    var isCodexAuthenticated:  Bool { codexState  == .authenticated }
    var isCursorAuthenticated: Bool { cursorState == .authenticated }
    var isCodexRecovering: Bool { isCodexRecoveryPending || codexState == .unknown || codexState == .restoringSession || codexState == .signingIn }
    var isClaudeRecovering: Bool { isClaudeRecoveryPending || claudeState == .unknown || claudeState == .restoringSession }
    var isCursorRecovering: Bool { isCursorRecoveryPending || cursorState == .unknown || cursorState == .restoringSession }
    var isRestoringSession: Bool {
        isCodexRecovering || isClaudeRecovering || isCursorRecovering
    }

    private let resetCoordinator: AppResetCoordinator

    // MARK: - Shared state

    var settings: AppSettings = SharedDefaults.loadSettings()
    private var lastSavedSettings: AppSettings = SharedDefaults.loadSettings()
    /// Which service's panel is visible in the popover.
    var activeService: ServiceType = .codex

    // MARK: - Enrollment

    /// Persisted in SharedDefaults (app-group) so the widget can read it.
    /// Populated from first successful sign-in; cleared only on explicit Sign Out or reset.
    var enrolledServices: Set<ServiceType> = SharedDefaults.loadEnrolledServices()

    var isCodexEnrolled: Bool { enrolledServices.contains(.codex) }
    var isClaudeEnrolled: Bool { enrolledServices.contains(.claude) }
    var isCursorEnrolled: Bool { enrolledServices.contains(.cursor) }
    private var isCodexRecoveryPending = false
    private var isClaudeRecoveryPending = false
    private var isCursorRecoveryPending = false
    /// Set when enrolled-session recovery definitively failed (all sources
    /// rejected). Blocks popover-open recovery retries — which would just replay
    /// the same spinner — until fresh Claude Code credentials appear or the user
    /// signs in.
    private var claudeRecoveryExhausted = false

    // MARK: - Onboarding

    /// True if the user has never completed the onboarding wizard.
    var shouldShowOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: "onboarding.v1.hasCompleted")
            && !onboardingTriggeredThisSession
    }

    /// Set to true after the window has been opened once per session,
    /// so clicking the menu bar icon repeatedly doesn't re-open it.
    private(set) var onboardingTriggeredThisSession = false

    private var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "onboarding.v1.hasCompleted")
    }

    func markOnboardingTriggered() {
        onboardingTriggeredThisSession = true
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboarding.v1.hasCompleted")
        onboardingTriggeredThisSession = true
        trackAnalytics(
            "onboarding_completed",
            extraParams: [
                "completed_from": "guided_setup",
                "has_connected_service": boolString(!enrolledServices.isEmpty)
            ]
        )
    }

    /// "codex", "claude", "both", or "none" — used as an analytics param.
    var analyticsServicesParam: String {
        switch enrolledServices.count {
        case 0:  return "none"
        case 1:  return enrolledServices.first!.rawValue
        default: return "both"
        }
    }

    var analyticsContextParams: [String: String] {
        [
            "services": analyticsServicesParam,
            "service_count": String(enrolledServices.count),
            "active_service": activeService.rawValue,
            "menu_bar_service": settings.menuBarService.rawValue,
            "menu_bar_display": settings.menuBarDisplayMode.rawValue,
            "notifications_enabled": boolString(settings.notifications.enabled),
            "onboarding_completed": boolString(hasCompletedOnboarding)
        ]
    }

    func recordDailyActiveIfNeeded() {
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let key = "analytics.lastActiveDate"
        guard UserDefaults.standard.string(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)
        trackAnalytics("app_active", extraParams: ["surface": "popover"])
    }

    func resetOnboardingForReplay() {
        // Called from Settings "Guided Setup…" button — lets the user re-run
        // the wizard without wiping any auth or settings state.
        onboardingTriggeredThisSession = false
    }

    /// Full reset: signs out all services, clears cached data, resets settings
    /// and onboarding state — the app behaves exactly like a fresh install.
    func resetToNewUser() async {
        clearTokenHistory()
        clearUsageHistory()
        clearClaudeEnterpriseDetails()
        // Step 1: stop refresh and await quiescence.
        // Capture the task reference *before* stopAutoRefresh() sets refreshTask = nil,
        // otherwise the await below is always a no-op.
        let inFlight = refreshTask
        stopAutoRefresh()
        await inFlight?.value  // actually suspends until the in-flight refresh completes

        for account in additionalAccounts {
            await account.signOut()
        }
        additionalAccounts.removeAll()
        for account in AccountRegistry.accounts() {
            AccountRegistry.remove(id: account.id)
        }

        // Step 2: auth reset
        let result = await resetCoordinator.reset()
        await NotificationManager.shared.clearResetHistory(for: .codex)
        await NotificationManager.shared.clearResetHistory(for: .claude)
        if !result.warnings.isEmpty {
            logger.warning("[Reset] warnings: \(result.warnings.joined(separator: "; "))")
        }

        // Step 3: product state reset (only after auth reset completes)
        await QuotaInsightStore.shared.clear()
        claudeUsage     = nil
        codexUsage      = nil
        codexAutoReload = nil
        SharedDefaults.clearUsage()
        if let account = primaryAccount(for: .codex) {
            SharedDefaults.clearUsage(forAccountID: account.id)
        }
        SharedDefaults.clearClaudeUsage()
        if let account = primaryAccount(for: .claude) {
            SharedDefaults.clearClaudeUsage(forAccountID: account.id)
        }
        SharedDefaults.clearCodexSourceAttempts()
        SharedDefaults.clearClaudeSourceAttempts()
        settings = .default
        UserDefaults.standard.removeObject(forKey: ClaudeOAuthKeychainReader.consentDefaultsKey)
        // Persist settings directly — calling saveSettings() would invoke startAutoRefresh(),
        // which must not fire while the auth coordinators are still in the resetting state.
        SharedDefaults.saveSettings(settings)
        enrolledServices = []
        SharedDefaults.clearEnrolledServices()
        UserDefaults.standard.removeObject(forKey: "onboarding.v1.hasCompleted")
        onboardingTriggeredThisSession = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Backward-compatible aliases (used by MenuBarIconView / AIQuotaApp)

    var usage: CodexUsage? { codexUsage }
    var isLoading: Bool {
        isCodexLoading || isClaudeLoading || additionalAccounts.contains(where: { $0.isLoading })
    }
    var error: NetworkError? {
        get { codexError }
        set { codexError = newValue }
    }
    var isAuthenticated: Bool { isCodexAuthenticated }

    // MARK: - Last refreshed

    var lastRefreshedAt: Date?

    // MARK: - Private

    private var refreshTask: Task<Void, Never>?
    /// Incremented on each manual refresh so the previous task's `defer` doesn't
    /// clear `isLoading` after the new request has already started.
    private var codexRefreshGeneration = 0
    private var claudeRefreshGeneration = 0

    /// Tracks whether the last known network path was unsatisfied so we can
    /// detect a transition back online and refresh immediately.
    private var wasOffline = false
    /// Set to true once NWPathMonitor fires its first update. Prevents false-positive
    /// "No network connection" banners at launch before the monitor has settled.
    private var pathMonitorReady = false
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "ai.quota.pathmonitor")
    private var appLifecycleObservers: [NSObjectProtocol] = []
    private var workspaceLifecycleObservers: [NSObjectProtocol] = []
    private let popoverOpenRefreshMinimumInterval: TimeInterval = 30
    private let recentServiceActivityDuration: TimeInterval = 10 * 60
    private var lastServiceActivityAt: Date?

    // MARK: - Init

    init(readOnlyPreview: Bool = false) {
        let claude = ClaudeAuthCoordinator()
        let codex  = CodexAuthCoordinator()
        let cursor = CursorAuthCoordinator()

        self.claudeCoordinator = claude
        self.codexCoordinator  = codex
        self.cursorCoordinator = cursor
        self.claudeClient      = ClaudeClient(coordinator: claude)
        self.codexClient       = OpenAIClient(coordinator: codex)
        self.cursorClient      = CursorClient(coordinator: cursor)
        self.resetCoordinator  = AppResetCoordinator(claude: claude, codex: codex, cursor: cursor)
        #if DEBUG
        isReadOnlyPreview = readOnlyPreview
        if readOnlyPreview { return }
        #endif
        Task { await QuotaInsightStore.shared.prepare() }
        AccountRegistry.migrateLegacyAccountsIfNeeded()
        for provider in enrolledServices { ensurePrimaryAccount(for: provider, selectNewAccount: false) }
        self.additionalAccounts = AccountRegistry.accounts()
            .filter { $0.connectionKind == .isolated }
            .map(AdditionalAccountSession.init(account:))
        initializeMenuBarAccountsIfNeeded()
        self.isCodexRecoveryPending = enrolledServices.contains(.codex)
        self.isClaudeRecoveryPending = enrolledServices.contains(.claude)
        self.isCursorRecoveryPending = enrolledServices.contains(.cursor)

        #if !DEMO_MODE
        // Load cached data immediately
        if let account = primaryAccount(for: .codex), let identity = account.workspaceID,
           let cached = SharedDefaults.loadCachedUsage(forAccountID: account.id), cached.accountID == identity {
            codexUsage = cached
        }
        claudeUsage = SharedDefaults.loadCachedClaudeUsage()
        cursorUsage = SharedDefaults.loadCachedCursorUsage()

        // Normalise any mixed per-threshold notification state from pre-consolidation builds.
        // OR-resolves each group (any=true → all-true) so aggregate toggles always see
        // a clean on/off state from the first render.
        let preNorm = settings
        settings.notifications.normalizeThresholds()
        if settings != preNorm { SharedDefaults.saveSettings(settings) }

        // Observe coordinator state streams and drive UI state + auto-refresh.
        Task { [weak self] in
            guard let self else { return }
            for await state in claudeCoordinator.stateStream {
                await MainActor.run {
                    self.claudeState = state
                    if state == .signingIn || state == .signingOut || state == .resetting {
                        self.claudeRefreshGeneration += 1
                        self.isClaudeLoading = false
                    }
                    // Auto-enroll on first successful auth (handles migration from pre-enrollment builds)
                    if state == .authenticated && !self.enrolledServices.contains(.claude) {
                        self.enrolledServices.insert(.claude)
                        SharedDefaults.enrollService(.claude)
                        self.trackServiceConnected(.claude)
                    }
                    if state == .authenticated {
                        self.ensurePrimaryAccount(for: .claude)
                        self.initializeMenuBarAccountsIfNeeded()
                        self.claudeRecoveryExhausted = false
                        if self.refreshTask == nil {
                            self.startAutoRefresh()
                        }
                    }
                    if state == .signedOutByUser ||
                        (state == .unauthenticated && !self.isClaudeRecoveryPending) {
                        self.clearClaudeUsageSnapshot()
                    }
      