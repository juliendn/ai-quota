import XCTest
@testable import MobileAccessCore

final class CursorAPITests: XCTestCase {
    func testSessionCookieUsesEncodedSubjectAndToken() throws {
        // {"sub":"github|123","iat":1} base64url payload
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncodedString()
        let payload = Data(#"{"sub":"github|123","iat":1}"#.utf8).base64URLEncodedString()
        let token = "\(header).\(payload).sig"

        let cookie = try CursorAPI.sessionCookie(accessToken: token)
        XCTAssertEqual(cookie, "WorkosCursorSessionToken=github%7C123%3A%3A\(token)")
        XCTAssertEqual(try CursorAPI.jwtSubject(token), "github|123")
    }

    func testDecodeUsageSummaryMapsPlanAndOnDemand() throws {
        let json = """
        {
          "billingCycleStart": "2026-10-01T00:00:00.000Z",
          "billingCycleEnd": "2026-11-01T00:00:00.000Z",
          "membershipType": "pro",
          "isUnlimited": false,
          "individualUsage": {
            "plan": {
              "used": 840,
              "limit": 2000,
              "remaining": 1160,
              "autoPercentUsed": 30.5,
              "apiPercentUsed": 55.0,
              "totalPercentUsed": 42.0,
              "breakdown": { "included": 2000, "bonus": 0, "total": 2000 }
            },
            "onDemand": {
              "enabled": true,
              "used": 150,
              "limit": 500,
              "remaining": 350
            }
          }
        }
        """.data(using: .utf8)!

        let usage = try CursorAPI.decodeUsageSummary(
            json,
            now: Date(timeIntervalSince1970: 1_762_000_000),
            source: .appState,
            email: "you@example.com"
        )

        XCTAssertEqual(usage.planUsedPercent, 42)
        XCTAssertEqual(usage.planLimitUSD, 20)
        XCTAssertEqual(usage.planUsedUSD, 8.4, accuracy: 0.001)
        XCTAssertEqual(usage.autoPercentUsed, 30.5)
        XCTAssertEqual(usage.apiPercentUsed, 55)
        XCTAssertTrue(usage.onDemandEnabled)
        XCTAssertEqual(usage.onDemandUsedUSD, 1.5)
        XCTAssertEqual(usage.onDemandLimitUSD, 5)
        XCTAssertEqual(usage.membershipType, "pro")
        XCTAssertEqual(usage.email, "you@example.com")
        XCTAssertEqual(usage.source, .appState)
        XCTAssertEqual(usage.usedPercent, 42)

        let reading = CursorAPI.makeReading(from: usage)
        XCTAssertNil(reading.shortTerm)
        XCTAssertEqual(reading.weekly?.usedPercent, 42)
        XCTAssertEqual(reading.metadata?.plan, "pro")
        XCTAssertEqual(reading.providerIdentity, "you@example.com")
    }

    func testDecodeRejectsEmptyPayload() {
        let json = Data(#"{"individualUsage":{}}"#.utf8)
        XCTAssertThrowsError(
            try CursorAPI.decodeUsageSummary(json, now: .now, source: .manual)
        )
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
