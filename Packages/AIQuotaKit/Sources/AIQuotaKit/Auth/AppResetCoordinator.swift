import Foundation
import os

/// Orchestrates a full reset across service coordinators.
/// Auth reset must complete before product state is cleared.
public actor AppResetCoordinator {

    private let claude: ClaudeAuthCoordinator
    private let codex: CodexAuthCoordinator
    private let cursor: CursorAuthCoordinator
    private let logger = Logger(subsystem: "ai.quota", category: "reset")

    public struct ResetResult: Sendable {
        /// Any warnings from teardown (e.g. WebKit verification timeout).
        public let warnings: [String]
    }

    public init(
        claude: ClaudeAuthCoordinator,
        codex: CodexAuthCoordinator,
        cursor: CursorAuthCoordinator
    ) {
        self.claude = claude
        self.codex = codex
        self.cursor = cursor
    }

    /// Resets all service coordinators to signedOutByUser.
    /// Caller must stop and await the refresh loop before calling this.
    /// Returns after coordinators have reached a stable terminal state.
    public func reset() async -> ResetResult {
        logger.info("[AppReset] beginning cross-service reset")

        async let claudeReset: Void = claude.reset()
        async let codexReset: Void = codex.reset()
        async let cursorReset: Void = cursor.reset()
        _ = await (claudeReset, codexReset, cursorReset)

        logger.info("[AppReset] all coordinators reached terminal state")

        let claudeState = await claude.state
        let codexState  = await codex.state
        let cursorState = await cursor.state
        var warnings: [String] = []
        if claudeState != .signedOutByUser {
            warnings.append("Claude coordinator ended in unexpected state: \(claudeState)")
        }
        if codexState != .signedOutByUser {
            warnings.append("Codex coordinator ended in unexpected state: \(codexState)")
        }
        if cursorState != .signedOutByUser {
            warnings.append("Cursor coordinator ended in unexpected state: \(cursorState)")
        }
        if !warnings.isEmpty { logger.warning("[AppReset] \(warnings.joined(separator: "; "))") }

        return ResetResult(warnings: warnings)
    }
}
