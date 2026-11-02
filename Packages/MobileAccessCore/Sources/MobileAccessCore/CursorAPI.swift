import Foundation

public enum CursorAccessError: Error, LocalizedError, Sendable {
    case invalidResponse
    case noWindows
    case invalidToken

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Unexpected response from Cursor."
        case .noWindows: "Cursor reported no quota windows."
        case .invalidToken: "Cursor access token is invalid."
        }
    }
}

/// Wire surface for Cursor's undocumented `usage-summary` endpoint.
/// Auth uses a session cookie of the form
/// `WorkosCursorSessionToken=<jwt.sub>%3A%3A<accessToken>` (verified empirically;
/// Bearer and raw cookies return 401).
public enum CursorAPI {
    public static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    public static let authMeURL = URL(string: "https://cursor.com/api/auth/me")!

    /// Builds the authenticated request Cursor's own clients use.
    public static func usageSummaryRequest(accessToken: String) throws -> URLRequest {
        let cookie = try sessionCookie(accessToken: accessToken)
        var request = URLRequest(url: usageSummaryURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        return request
    }

    public static func authMeRequest(accessToken: String) throws -> URLRequest {
        let cookie = try sessionCookie(accessToken: accessToken)
        var request = URLRequest(url: authMeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        return request
    }

    /// `WorkosCursorSessionToken=<url-encoded sub>::<token>` with `::` as `%3A%3A`.
    public static func sessionCookie(accessToken: String) throws -> String {
        let sub = try jwtSubject(accessToken)
        // Match Go's url.QueryEscape: encode reserved characters including `|`.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedSub = sub.addingPercentEncoding(withAllowedCharacters: allowed) ?? sub
        return "WorkosCursorSessionToken=\(encodedSub)%3A%3A\(accessToken)"
    }

    /// Decodes the JWT payload `sub` claim without verifying the signature.
    public static func jwtSubject(_ token: String) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw CursorAccessError.invalidToken }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = claims["sub"] as? String,
              !sub.isEmpty
        else { throw CursorAccessError.invalidToken }
        return sub
    }

    public static func decodeUsageSummary(
        _ data: Data,
        now: Date,
        source: CursorUsage.Source,
        email: String? = nil
    ) throws -> CursorUsage {
        let raw = try JSONDecoder().decode(UsageSummaryResponse.self, from: data)
        let plan = raw.individualUsage?.plan
        let onDemand = raw.individualUsage?.onDemand

        let cycleStart = isoDate(raw.billingCycleStart)
        let cycleEnd = isoDate(raw.billingCycleEnd)

        let planPercent = plan?.totalPercentUsed.flatMap { (0...100).contains($0) ? $0 : nil }
        let planLimitUSD = centsToUSD(plan?.breakdown?.total) ?? centsToUSD(plan?.limit)
        let planUsedUSD: Double?
        if let limit = planLimitUSD, let percent = planPercent {
            planUsedUSD = limit * percent / 100
        } else {
            planUsedUSD = centsToUSD(plan?.used)
        }

        let hasPlan = planPercent != nil || planUsedUSD != nil || planLimitUSD != nil || raw.isUnlimited == true
        let hasOnDemand = onDemand?.enabled == true
            && (onDemand?.used != nil || onDemand?.limit != nil)
        guard hasPlan || hasOnDemand else { throw CursorAccessError.noWindows }

        return CursorUsage(
            planUsedPercent: planPercent,
            planUsedUSD: planUsedUSD,
            planLimitUSD: planLimitUSD,
            autoPercentUsed: plan?.autoPercentUsed,
            apiPercentUsed: plan?.apiPercentUsed,
            onDemandUsedUSD: centsToUSD(onDemand?.used),
            onDemandLimitUSD: centsToUSD(onDemand?.limit),
            onDemandEnabled: onDemand?.enabled ?? false,
            membershipType: raw.membershipType,
            email: email,
            billingCycleStart: cycleStart,
            billingCycleEnd: cycleEnd,
            isUnlimited: raw.isUnlimited ?? false,
            source: source,
            fetchedAt: now
        )
    }

    /// Maps Cursor onto the shared dual-window reading:
    /// plan → long (weekly/monthly) slot; short-term stays empty.
    public static func makeReading(from usage: CursorUsage) -> QuotaReading {
        var weekly: QuotaWindow?
        if let used = usage.planUsedPercent {
            let duration: Int
            if let start = usage.billingCycleStart, let end = usage.billingCycleEnd {
                duration = max(86400, Int(end.timeIntervalSince(start)))
            } else {
                duration = 30 * 86400
            }
            weekly = QuotaWindow(usedPercent: used, durationSeconds: duration, resetsAt: usage.billingCycleEnd)
        }

        let budget = MonthlyBudget(
            used: usage.planUsedUSD,
            limit: usage.planLimitUSD,
            unit: "USD",
            resetsAt: usage.billingCycleEnd
        )

        let metadata = AccountMetadata(
            plan: usage.membershipType,
            balanceUSD: usage.onDemandEnabled ? usage.onDemandLimitUSD.flatMap { limit in
                usage.onDemandUsedUSD.map { max(0, limit - $0) }
            } : nil,
            usageSpent: usage.planUsedUSD ?? usage.onDemandUsedUSD,
            usageCurrency: "USD"
        )

        return QuotaReading(
            fetchedAt: usage.fetchedAt,
            shortTerm: nil,
            weekly: weekly,
            metadata: metadata,
            monthlyBudget: weekly == nil ? budget : nil,
            providerIdentity: usage.email
        )
    }

    private static func centsToUSD(_ cents: Double?) -> Double? {
        guard let cents, cents.isFinite else { return nil }
        return cents / 100
    }

    private static func isoDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Wire types

private struct UsageSummaryResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let isUnlimited: Bool?
    let individualUsage: IndividualUsage?

    struct IndividualUsage: Decodable {
        let plan: Plan?
        let onDemand: OnDemand?
    }

    struct Plan: Decodable {
        let used: Double?
        let limit: Double?
        let remaining: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
        let breakdown: Breakdown?
    }

    struct Breakdown: Decodable {
        let included: Double?
        let bonus: Double?
        let total: Double?
    }

    struct OnDemand: Decodable {
        let enabled: Bool?
        let used: Double?
        let limit: Double?
        let remaining: Double?
    }
}
