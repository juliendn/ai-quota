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
            existingLabels: AccountRegistry.accounts(for: provider).filter { $0.id != a