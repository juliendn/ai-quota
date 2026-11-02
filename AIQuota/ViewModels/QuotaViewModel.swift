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

    var claudeState: AuthStat