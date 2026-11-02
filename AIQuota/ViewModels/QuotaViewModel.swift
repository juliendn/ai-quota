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
                if !force, let atte