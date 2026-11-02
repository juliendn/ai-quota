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
