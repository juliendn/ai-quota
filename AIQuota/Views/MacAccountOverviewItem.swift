import SwiftUI
import AIQuotaKit

private struct MacReconnectButtonAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// A Mac-sized version of the accepted iOS overview hierarchy: dial, one
/// account identity, plan, usage and reset context. The whole surface opens
/// details; account management lives in Settings and the context menu.
struct MacAccountCard: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let account: ConnectedAccount
    let session: AdditionalAccountSession?
    let tokenHistory: CodexTokenHistory?
    let availableWidth: CGFloat
    let showsAccountLabel: Bool
    let open: () -> Void
    let reconnect: () -> Void
    let highlighted: Bool

    private var codexUsage: CodexUsage? {
        MacAccountOverviewUsage.codex(account: account, isolated: session?.codexUsage,
                                      primary: viewModel.codexUsage)
    }
    private var claudeUsage: ClaudeUsage? {
        MacAccountOverviewUsage.claude(account: account, isolated: session?.claudeUsage,
                                       primary: viewModel.claudeUsage)
    }
    private var cursorUsage: CursorUsage? {
        MacAccountOverviewUsage.cursor(account: account, isolated: nil,
                                       primary: viewModel.cursorUsage)
    }
    private var hasReading: Bool { codexUsage != nil || claudeUsage != nil || cursorUsage != nil }
    private var awaitingConnection: Bool { loading && !connected && !hasReading }
    private var showsProgress: Bool {
        guard loading else { return false }
        let signingIn = account.connectionKind == .isolated
            ? session?.state == .signingIn
            : ({
                switch account.provider {
                case .codex: viewModel.codexState
                case .claude: viewModel.claudeState
                case .cursor: viewModel.cursorState
                }
            }()) == .signingIn
        return !hasReading || signingIn
    }
    private var loading: Bool {
        if account.connectionKind == .isolated {
            guard let session else { return false }
            return session.isLoading || session.state == .unknown ||
                session.state == .restoringSession || session.state == .signingIn
        }
        switch account.provider {
        case .codex: return viewModel.isCodexLoading || viewModel.isCodexRecovering
        case .claude: return viewModel.isClaudeLoading || viewModel.isClaudeRecovering
        case .cursor: return viewModel.isCursorLoading || viewModel.isCursorRecovering
        }
    }
    private var connected: Bool {
        if account.connectionKind == .isolated { return session?.isAuthenticated == true }
        switch account.provider {
        case .codex: return viewModel.isCodexAuthenticated
        case .claude: return viewModel.isClaudeAuthenticated
        case .cursor: return viewModel.isCursorAuthenticated
        }
    }
    private var issue: String? {
        if account.connectionKind == .isolated { return session?.issue }
        switch account.provider {
        case .codex: return viewModel.codexError?.localizedDescription
        case .claude: return viewModel.claudeError?.localizedDescription
        case .cursor: return viewModel.cursorError?.localizedDescription
        }
    }
    private var serviceName: String { account.provider.displayName }
    private var icon: String {
        switch account.provider {
        case .codex: "logo-openai"
        case .claude: "logo-claude"
        case .cursor: "logo-cursor"
        }
    }
    private var plan: String? {
        switch account.provider {
        case .codex: return codexUsage?.displayPlan
        case .claude: return claudeUsage?.planLabel.displayName
        case .cursor: return cursorUsage?.planDisplayName
        }
    }
    private var accountLabel: String? {
        let label = account.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        if !showsAccountLabel && label.caseInsensitiveCompare("Personal") == .orderedSame { return nil }
        if label.caseInsensitiveCompare(serviceName) == .orderedSame { return nil }
        if let plan, plan.caseInsensitiveCompare("Unknown") != .orderedSame {
            var defaultLabels = ["\(serviceName) \(plan)"]
            // Codex reports business for workspaces previously named Enterprise.
            if account.provider == .codex, ["business", "enterprise"].contains(plan.lowercased()) {
                defaultLabels += ["Codex Business", "Codex Enterprise"]
            }
            if defaultLabels.contains(where: { label.caseInsensitiveCompare($0) == .orderedSame }) { return nil }
        }
        let parts = label.split(whereSeparator: \.isWhitespace)
        if parts.count == 2,
           ["account", "service"].contains(parts[0].lowercased()),
           parts[1].allSatisfy(\.isNumber) { return nil }
        return label
    }
    private var budget: (used: Double, limit: Double, unit: String, currency: String?, reset: Date?)? {
        if account.provider == .codex, codexUsage?.reportedWindowShape == nil,
           let value = codexUsage?.displayableMonthlyBudget,
           let used = value.used, let limit = value.limit {
            let unit = value.unit ?? "monthly allowance"
            let currency = unit.count == 3 && unit.lowercased() != "credit" ? unit.uppercased() : nil
            return (used, limit, unit, currency, value.resetAt)
        }
        if account.provider == .claude, claudeUsage?.primaryMetric.kind == .spendLimit,
           let value = claudeUsage?.spendLimit,
           value.used.isFinite, value.limit.isFinite, value.limit > 0 {
            return (value.used, value.limit, "monthly spend", value.currencyCode, nil)
        }
        if account.provider == .cursor,
           let used = cursorUsage?.planUsedUSD, let limit = cursorUsage?.planLimitUSD,
           limit > 0 {
            return (used, limit, "monthly spend", "USD", cursorUsage?.billingCycleEnd)
        }
        return nil
    }
    private var primaryPercent: Int? {
        if let budget { return Int((budget.used / budget.limit * 100).rounded()) }
        if let usage = codexUsage {
            switch usage.reportedWindowShape {
            case .dual: return usage.hourlyUsedPercent
            case .weeklyOnly: return usage.weeklyUsedPercent
            case nil: return nil
            }
        }
        if let cursorUsage { return cursorUsage.usedPercent }
        return claudeUsage?.usedPercent
    }
    private var secondaryPercent: Int? {
        if codexUsage?.reportedWindowShape == .dual { return codexUsage?.weeklyUsedPercent }
        if let usage = claudeUsage, usage.primaryMetric.kind != .sevenDay,
           let weekly = usage.sevenDayUtilization { return Int(weekly.rounded()) }
        return nil
    }
    private var primaryLabel: String {
        if budget != nil { return CalendarMonthLabel.compact(containing: readingAt) }
        if account.provider == .codex { return codexUsage?.reportedWindowShape == .dual ? "5h" : "7d" }
        if account.provider == .cursor { return cursorUsage?.primaryMetricLabel ?? "Plan" }
        return claudeUsage?.primaryMetricLabel ?? "5h"
    }

    private var readingAt: Date {
        codexUsage?.fetchedAt ?? claudeUsage?.fetchedAt ?? cursorUsage?.fetchedAt ?? .now
    }

    private var showsTokenHistory: Bool {
        guard connected || loading, account.provider == .codex, let tokenHistory,
              tokenHistory.isAttributed(toWorkspaceID: account.workspaceID) else { return false }
        return CodexTokenHistoryView.hasVisibleData(tokenHistory)
    }

    var body: some View {
        Button(action: connected || hasReading ? open : reconnect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 20) {
                    MacAccountDial(icon: icon, primaryPercent: connected || loading ? primaryPercent : nil,
                                   primaryLabel: primaryLabel, secondaryPercent: connected || loading ? secondaryPercent : nil,
                                   loading: loading, connected: connected || (loading && hasReading),
                                   hasIssue: !loading && issue != nil,
                                   showsSecondaryPlaceholder: secondaryPercent != nil || !hasReading)
                        .help(budget == nil ? primaryLabel : "\(CalendarMonthLabel.spoken(containing: readingAt)). Reset uses the provider's date.")
                    details
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                if showsTokenHistory, let tokenHistory {
                    CodexTokenHistoryView(history: tokenHistory,
                                          availableWidth: availableWidth + 2 * MacAccountDial.strokeOutset)
                        .padding(.horizontal, -MacAccountDial.strokeOutset)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 21)
            .padding(.bottom, showsTokenHistory ? 8 : 21)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .overlay {
                if showsProgress {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(Color.overviewPrimary)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(MacAccountRowButtonStyle(highlighted: highlighted))
        .focusEffectDisabled()
        .disabled(awaitingConnection)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(loading ? "Busy, updating allowance" : "")
        .accessibilityAddTraits(loading ? .updatesFrequently : [])
        .accessibilityHint(connected || hasReading ? "Open account details" : "Reconnect account")
        // Overlay the secondary control as a sibling of the full-row Button.
        // This keeps its action independent and avoids nesting native buttons.
        .overlayPreferenceValue(MacReconnectButtonAnchor.self) { anchor in
            if let anchor {
                GeometryReader { geometry in
                    let bounds = geometry[anchor]
                    reconnectButton
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                }
            }
        }
    }

    private var reconnectButton: some View {
        Button("Reconnect", action: reconnect)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(Color.overviewAccent)
            .disabled(loading)
            .accessibilityLabel("Reconnect \(serviceName)" + (accountLabel.map { " · \($0)" } ?? ""))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(serviceName)
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.25)
                        .foregroundStyle(Color.overviewPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    statusIndicator
                }
                if let plan {
                    Text("\(plan) plan" + (accountLabel.map { " · \($0)" } ?? ""))
