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
    // SIZE_TEST_MARKER_PARTIAL_DO_NOT_SHIP
}
