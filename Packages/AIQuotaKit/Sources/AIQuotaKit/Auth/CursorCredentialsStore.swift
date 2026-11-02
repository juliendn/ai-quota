import Foundation
import MobileAccessCore
import SQLite3

/// A Cursor session credential resolved from local Cursor IDE state.
/// Read-only: AIQuota never writes to Cursor's files.
public struct CursorCredential: Sendable, Equatable {
    public let accessToken: String
    public let email: String?
    public let membershipType: String?
    public let source: CursorUsage.Source

    public init(
        accessToken: String,
        email: String? = nil,
        membershipType: String? = nil,
        source: CursorUsage.Source
    ) {
        self.accessToken = accessToken
        self.email = email
        self.membershipType = membershipType
        self.source = source
    }
}

/// Discovers the access token Cursor already keeps on this machine.
///
/// Source order (first working wins):
/// 1. Cursor IDE `state.vscdb` → `cursorAuth/accessToken`
/// 2. A session token the user pasted in Settings (Keychain)
public enum CursorCredentialsStore {
    private static let manualTokenKeychainKey = "cursor.manualAccessToken"
    private static let tokenKey = "cursorAuth/accessToken"
    private static let emailKey = "cursorAuth/cachedEmail"
    private static let membershipKey = "cursorAuth/stripeMembershipType"

    // MARK: - Resolution

    public static func candidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CursorCredential] {
        [
            appStateCredential(home: home),
            manualCredential(),
        ].compactMap { $0 }
    }

    public static func hasDiscoverableCredential(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        appStateCredential(home: home) != nil
    }

    // MARK: - Cursor IDE state.vscdb

    public static func appStateCredential(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CursorCredential? {
        let dbPath = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
        guard let values = readLocalState(dbPath: dbPath.path),
              let token = values.token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return CursorCredential(
            accessToken: token,
            email: values.email,
            membershipType: values.membership,
            source: .appState
        )
    }

    /// Opens the VS Code-style state db read-only and never writes.
    static func readLocalState(dbPath: String) -> (token: String?, email: String?, membership: String?)? {
        var db: OpaquePointer?
        // Immutable + read-only so Cursor's WAL writers are undisturbed.
        let uri = "file:\(dbPath)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        func value(for key: String) -> String? {
            var statement: OpaquePointer?
            // Keys are constants owned by this store — safe to interpolate.
            let sql = "SELECT value FROM ItemTable WHERE key = '\(key)'"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let cString = sqlite3_column_text(statement, 0)
            else { return nil }
            let text = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        let token = value(for: tokenKey)
        guard token != nil else { return nil }
        return (token, value(for: emailKey), value(for: membershipKey))
    }

    // MARK: - Manual token

    public static func saveManualToken(_ token: String) {
        KeychainStore.save(token, forKey: manualTokenKeychainKey)
    }

    public static func manualCredential() -> CursorCredential? {
        guard let token = KeychainStore.load(forKey: manualTokenKeychainKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else { return nil }
        return CursorCredential(accessToken: token, source: .manual)
    }

    public static func clearManualToken() {
        KeychainStore.delete(forKey: manualTokenKeychainKey)
    }
}
