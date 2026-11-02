import SwiftUI
import Charts
import AIQuotaKit
import MobileAccessCore

/// Uses the same analytics cards and category destinations as the iOS sheet.
struct ServiceDetailView: View {
    let service: ServiceType
    let height: CGFloat
    let close: () -> Void
    let reconnect: () -> Void
    @Environment(QuotaViewModel.self) private var viewModel

    private var isCodex: Bool { service == .codex }
    private var isCursor: Bool { service == .cursor }
    private var name: String { service.displayName }
    private var busy: Bool {
        switch service {
        case .codex:
            viewModel.isCodexLoading || viewModel.isUsageHistoryLoading || viewModel.isCodexRecovering
        case .claude:
            viewModel.isClaudeLoading || viewModel.isClaudeSpendLoading
                || viewModel.isClaudeSkillsLoading || viewModel.isClaudeEnterpriseReconnectLoading
        case .cursor:
            viewModel.isCursorLoading || viewModel.isCursorRecovering
        }
    }
    private var connected: Bool {
        switch service {
        case .codex: viewModel.isCodexAuthenticated
        case .claude: viewModel.isClaudeAuthenticated
        case .cursor: viewModel.isCursorAuthenticated
        }
    }
    private var error: NetworkError? {
        switch service {
        case .codex: viewModel.codexError
        case .claude: viewModel.claudeError
        case .cursor: viewModel.cursorError
        }
    }
    private var reading: QuotaReading? {
        #if DEMO_MODE
        return MacAnalyticsDemo.reading(service)
        #else
        if isCodex, let usage = viewModel.codexUsage {
            let monthlyBudget = (usage.reportedWindowShape == nil ? usage.displayableMonthlyBudget : nil).flatMap {
                MobileAccessCore.MonthlyBudget(used: $0.used, limit: $0.limit,
                    unit: $0.unit, resetsAt: $0.resetAt)
            }
            return QuotaReading(fetchedAt: usage.fetchedAt, shortTerm: nil, weekly: nil,
                metadata: AccountMetadata(plan: usage.planType, balanceUSD: usage.creditBalance,
                    usageSpent: usage.bonusCreditsSpentThisMonth.map { $0 / 25 }, usageCurrency: "USD"),
                monthlyBudget: monthlyBudget)
        }
        if service == .claude, let usage = viewModel.claudeUsage {
            let monthlyBudget = usage.spendLimit.flatMap {
                MobileAccessCore.MonthlyBudget(used: $0.used, limit: $0.limit,
                    unit: $0.currencyCode)
            }
            return QuotaReading(fetchedAt: usage.fetchedAt, shortTerm: nil, weekly: nil,
                metadata: AccountMetadata(plan: usage.planDisplayName, balanceUSD: nil,
                    usageSpent: usage.usageCredits?.spent, usageCurrency: usage.usageCredits?.currencyCode),
                claudeBreakdown: usage.weeklyBreakdown, monthlyBudget: monthlyBudget)
        }
        if isCursor, let usage = viewModel.cursorUsage {
            return CursorAPI.makeReading(from: usage)
        }
        return nil
        #endif
    }
    private var history: CodexUsageHistory? {
        #if DEMO_MODE
        MacAnalyticsDemo.history
        #else
        viewModel.codexUsageHistory
        #endif
    }
    private var showsClaudeEnterpriseDetails: Bool {
        guard service == .claude else { return false }
        return viewModel.claudeUsage?.planLabel == .enterprise
            || viewModel.claudeUsage?.spendLimit != nil
            || viewModel.claudeEnterpriseSpend != nil
            || viewModel.claudeEnterpriseSkills != nil
    }
    private var canFetchClaudeDetails: Bool {
        connected && viewModel.claudeUsage?.source != nil
            && viewModel.claudeUsage?.source != .unknown
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: close) {
                    Image(systemName: "chevron.left").frame(width: 16, height: 16)
                }
                .buttonStyle(AnalyticsHoverButtonStyle()).accessibilityLabel("Back to overview").help("Back to overview")
                Image(isCodex ? "logo-openai" : isCursor ? "logo-cursor" : "logo-claude")
                    .resizable().scaledToFit().frame(width: 22, height: 22)
                    .foregroundStyle(Color.gaugeAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(reading?.metadata?.displayPlan.map { "\($0) plan" } ?? "Plan not reported")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(action: refresh) { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }
                    .buttonStyle(AnalyticsHoverButtonStyle()).disabled(busy || !connected)
                    .accessibilityLabel("Refresh \(name) details").help(refreshHelp)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let account = viewModel.primaryAccount(for: isCodex ? .codex : .claude) {
                MacQuotaInsightRow(accountID: account.id)
            }
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !connected {
                            Label("Reconnect to update details. Your last reading is retained.", systemImage: "person.crop.circle.badge.exclamationmark")
                                .foregroundStyle(Color.warningAmber)
                        }
                        if isCodex, connected {
                            CodexAnalyticsView(reading: reading, history: history,
                                historyUnavailable: viewModel.usageHistoryFailed,
                                busy: busy || (history == nil && !viewModel.usageHistoryFailed), refresh: refresh)
                        } else if !isCodex, reading?.claudeBreakdown != nil {
                            ClaudeAnalyticsView(reading: reading, busy: busy, failed: error != nil || !connected, refresh: refresh)
                        }
                        if showsClaudeEnterpriseDetails {
                            ClaudeEnterpriseSpendView(
                                snapshot: viewModel.claudeEnterpriseSpend,
                                busy: viewModel.isClaudeSpendLoading
                                    || (canFetchClaudeDetails && viewModel.claudeEnterpriseSpend == nil
                                        && !viewModel.claudeSpendFailed),
                                failed: viewModel.claudeSpendFailed,
                                retry: { viewModel.refreshClaudeSpendDetails(force: true) }
                            )
                            ClaudeEnterpriseSkillsView(
                                snapshot: viewModel.claudeEnterpriseSkills,
                                currency: viewModel.claudeEnterpriseSpend?.report.currency,
                                busy: viewModel.isClaudeSkillsLoading
                                    || (canFetchClaudeDetails && viewModel.claudeEnterpriseSkills == nil
                                        && !viewModel.claudeSkillsFailed),
                                failed: viewModel.claudeSkillsFailed,
                                retry: { viewModel.refreshClaudeSkillsDetails(force: true) }
                            )
                        }
                        if let error {
                            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(Color.warningAmber)
                        }
                        if !connected || isCodex { Divider() }
                        if !connected || (isCodex && error?.needsReconnect == true) {
                            Button(action: reconnect) {
                                Label("Reconnect \(name)", systemImage: "person.crop.circle")
                            }
                            .disabled(busy)
                        }
                        if isCodex {
                            Button { NSWorkspace.shared.open(CodexResetNotice.website) } label: {
                                Label("Check Codex resets", systemImage: "arrow.up.right")
                            }
                        } else {
                            Button { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) } label: {
                                Label("Open Claude usage settings", systemImage: "arrow.up.right")
                            }
                        }
                    }.padding(16)
                }
                .defaultScrollAnchor(.top, for: .sizeChanges)
            }
            // Analytics can grow while history and enterprise data arrive.
            // Keep the scroll viewport bounded so the header stays in place.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .tint(Color.gaugeAccent)
        .frame(height: height, alignment: .top)
        .clipped()
        .accessibilityIdentifier("serviceDetailView")
        .task(id: connected) {
            if isCodex, connected {
                viewModel.refreshUsageHistory()
            } else if connected, showsClaudeEnterpriseDetails {
                viewModel.refreshClaudeEnterpriseDetails()
            }
        }
        .onChange(of: showsClaudeEnterpriseDetails) { _, showsDetails in
            if showsDetails, connected { viewModel.refreshClaudeEnterpriseDetails() }
        }
        .onAppear { viewModel.beginClaudeEnterpriseDetailsPresentation() }
        .onDisappear { viewModel.dismissClaudeEnterpriseReconnectPrompt() }
        .alert(
            "Reconnect Claude for Enterprise details?",
            isPresented: Binding(
                get: { viewModel.isClaudeEnterpriseReconnectPromptPresented },
                set: { presented in
                    if !presented { viewModel.dismissClaudeEnterpriseReconnectPrompt() }
                }
            )
        ) {
            Button("Reconnect") {
                Task { await viewModel.reconnectClaudeForEnterpriseDetails() }
            }
            Button("Cancel", role: .cancel) {
                viewModel.dismissClaudeEnterpriseReconnectPrompt()
            }
        } message: {
            Text("Your current Claude connection can still show allowance. Enterprise spend and skill activity need a Claude web session for the same organization. Reconnect opens Claude sign-in and changes the connection only after verification. Cancel keeps the current connection.")
        }
    }

    private var refreshHelp: String {
        let freshness = reading.map { analyticsFreshnessLabel($0.fetchedAt, at: .now, saved: error != nil || !connected) }
        return ["Refresh \(name) details", freshness].compactMap { $0 }.joined(separator: " · ")
    }

    private func refresh() {
        if isCodex {
            viewModel.refreshUsageHistory(force: true)
            Task { await viewModel.refreshCodex() }
        } else {
            viewModel.refreshClaudeEnterpriseDetails(force: true)
            Task { await viewModel.refreshClaude() }
        }
    }
}
