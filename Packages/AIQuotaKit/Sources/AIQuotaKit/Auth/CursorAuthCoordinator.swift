import Foundation
import MobileAccessCore
import OSLog

// MARK: - Request context

/// Value type the coordinator produces for authenticated requests.
public struct CursorRequestContext: Sendable {
    public let accessToken: String
    public let email: String?
    public let membershipType: String?
    public let source: CursorUsage.Source
}

// MARK: - CursorAuthCoordinator

/// Owns Cursor auth state. There is no interactive OAuth flow: "sign in" means
/// resolving a session credential from Cursor IDE local state (`state.vscdb`)
/// or a manually pasted token, then validating it against `usage-summary`.
/// Cursor's files are only ever read, never written.
public actor CursorAuthCoordinator {

    private static let signedOutKey = "cursor.signedOutByUser"

    public private(set) var state: AuthState = .unknown
    private var continuations: [UUID: AsyncStream<AuthState>.Continuation] = [:]
    private var credential: CursorCredential?

    private let logger = Logger(subsystem: "ai.quota", category: "cursor-coord")

    public typealias CredentialResolver = @Sendable () -> [CursorCredential]
    public typealias CredentialValidator = @Sendable (CursorCredential) async -> Bool
    private let credentialResolver: CredentialResolver
    private let credentialValidator: CredentialValidator

    public init(
        credentialResolver: CredentialResolver? = nil,
        credentialValidator: CredentialValidator? = nil
    ) {
        self.credentialResolver = credentialResolver ?? { CursorCredentialsStore.candidates() }
        self.credentialValidator = credentialValidator ?? { credential in
            await Self.validate(credential: credential)
        }
    }

    // MARK: - State stream

    public nonisolated var stateStream: AsyncStream<AuthState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(continuation: continuation, id: id) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(continuation: AsyncStream<AuthState>.Continuation, id: UUID) {
        continuations[id] = continuation
        continuation.yield(state)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func transition(to newState: AuthState) {
        state = newState
        logger.info("[CursorCoord] → \(String(describing: newState), privacy: .public)")
        for c in continuations.values { c.yield(newState) }
    }

    // MARK: - Bootstrap

    public func bootstrap() async {
        guard state == .unknown else { return }

        if UserDefaults.standard.bool(forKey: Self.signedOutKey) {
            transition(to: .signedOutByUser)
            return
        }

        transition(to: .restoringSession)
        if await resolveAndValidate() {
            transition(to: .authenticated)
        } else {
            transition(to: .unauthenticated)
        }
    }

    // MARK: - Sign in / out

    /// Rescans local Cursor state and validates what it finds.
    public func signIn() async throws {
        guard await resolveAndValidate() else {
            transition(to: .unauthenticated)
            throw NetworkError.notAuthenticated
        }
        UserDefaults.standard.removeObject(forKey: Self.signedOutKey)
        transition(to: .authenticated)
    }

    /// Validates and stores an access token the user pasted manually.
    public func signIn(manualToken token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NetworkError.notAuthenticated }
        let candidate = CursorCredential(accessToken: trimmed, source: .manual)
        guard await credentialValidator(candidate) else {
            throw NetworkError.notAuthenticated
        }
        CursorCredentialsStore.saveManualToken(trimmed)
        credential = candidate
        persistSharedAuthContext()
        UserDefaults.standard.removeObject(forKey: Self.signedOutKey)
        transition(to: .authenticated)
    }

    public func signOut() async throws {
        credential = nil
        CursorCredentialsStore.clearManualToken()
        SharedAuthContextStore.clearCursor()
        UserDefaults.standard.set(true, forKey: Self.signedOutKey)
        transition(to: .signedOutByUser)
    }

    public func reset() async {
        credential = nil
        CursorCredentialsStore.clearManualToken()
        SharedAuthContextStore.clearCursor()
        UserDefaults.standard.set(true, forKey: Self.signedOutKey)
        transition(to: .signedOutByUser)
    }

    // MARK: - Requests

    public func requestContext() throws -> CursorRequestContext {
        guard let credential else { throw NetworkError.notAuthenticated }
        return CursorRequestContext(
            accessToken: credential.accessToken,
            email: credential.email,
            membershipType: credential.membershipType,
            source: credential.source
        )
    }

    public func revalidateSessionAfterAuthFailure() async -> Bool {
        if await resolveAndValidate() {
            transition(to: .authenticated)
            return true
        }
        transition(to: .unauthenticated)
        return false
    }

    public func restoreWithoutPromptIfPossible(allowSignedOutByUser: Bool) async -> Bool {
        if !allowSignedOutByUser,
           UserDefaults.standard.bool(forKey: Self.signedOutKey) {
            return false
        }
        if await resolveAndValidate() {
            transition(to: .authenticated)
            return true
        }
        return false
    }

    public func hasUsableCredentials() async -> Bool {
        await resolveAndValidate()
    }

    // MARK: - Private

    private func resolveAndValidate() async -> Bool {
        for candidate in credentialResolver() where await credentialValidator(candidate) {
            credential = candidate
            persistSharedAuthContext()
            return true
        }
        credential = nil
        SharedAuthContextStore.clearCursor()
        return false
    }

    private func persistSharedAuthContext() {
        guard let credential else { return }
        SharedAuthContextStore.saveCursor(SharedCursorAuthContext(
            accessToken: credential.accessToken,
            email: credential.email,
            membershipType: credential.membershipType
        ))
    }

    /// A cheap probe: status 2xx means the credential is accepted.
    private static func validate(credential: CursorCredential) async -> Bool {
        do {
            let request = try CursorAPI.usageSummaryRequest(accessToken: credential.accessToken)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            let (_, response) = try await URLSession(configuration: config).data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
