import Foundation

/// A Cursor subscription reading decoded from `GET https://cursor.com/api/usage-summary`.
///
/// Cursor reports a billing-cycle plan allowance (monthly), optional auto/API
/// model breakdowns, and on-demand overage. The dual-arc UI maps plan usage onto
/// the long window and leaves the short window empty unless a shorter meter appears.
public struct CursorUsage: Codable, Sendable, Equatable {
    /// Plan allowance used percent (`individualUsage.plan.totalPercentUsed`).
    public let planUsedPercent: Double?
    public let planUsedUSD: Double?
    public let planLimitUSD: Double?
    public let autoPercentUsed: Double?
    public let apiPercentUsed: Double?
    public let onDemandUsedUSD: Double?
    public let onDemandLimitUSD: Double?
    public let onDemandEnabled: Bool
    public let membershipType: String?
    public let email: String?
    public let billingCycleStart: Date?
    public let billingCycleEnd: Date?
    public let isUnlimited: Bool
    public let source: Source
    public let fetchedAt: Date

    public enum Source: String, Codable, Sendable, Equatable {
        /// Cursor IDE `state.vscdb` access token.
        case appState
        /// A session token the user pasted into Settings.
        case manual
        case unknown
    }

    public enum DisplayKind: String, Codable, Sendable, Equatable {
        case plan
        case onDemand
        case unknown

        public var displayLabel: String {
            switch self {
            case .plan: "Plan"
            case .onDemand: "On-demand"
            case .unknown: "Usage"
            }
        }
    }

    public struct Metric: Codable, Sendable, Equatable {
        public let kind: DisplayKind
        public let utilization: Double?
        public let resetAt: Date?

        public init(kind: DisplayKind, utilization: Double?, resetAt: Date?) {
            self.kind = kind
            self.utilization = utilization
            self.resetAt = resetAt
        }

        public var displayLabel: String { kind.displayLabel }
    }

    public var primaryMetric: Metric {
        if let planUsedPercent {
            return Metric(kind: .plan, utilization: planUsedPercent, resetAt: billingCycleEnd)
        }
        if onDemandEnabled, let used = onDemandUsedUSD, let limit = onDemandLimitUSD, limit > 0 {
            return Metric(kind: .onDemand, utilization: min(100, max(0, used / limit * 100)), resetAt: billingCycleEnd)
        }
        return Metric(kind: .unknown, utilization: nil, resetAt: billingCycleEnd)
    }

    public var usedPercent: Int { Int((primaryMetric.utilization ?? 0).rounded()) }
    public var limitReached: Bool { (primaryMetric.utilization ?? 0) >= 100 }
    public var percentFraction: Double { min(1, max(0, (primaryMetric.utilization ?? 0) / 100.0)) }
    public var remainingPercent: Int { max(0, 100 - usedPercent) }
    public var resetAt: Date? { primaryMetric.resetAt }
    public var resetAfterSeconds: Int? { primaryMetric.resetAt.map { max(0, Int($0.timeIntervalSinceNow)) } }
    public var planDisplayName: String {
        guard let membershipType, !membershipType.isEmpty else { return "Unknown" }
        return membershipType.prefix(1).uppercased() + membershipType.dropFirst()
    }
    public var hasPlanWindow: Bool { planUsedPercent != nil || isUnlimited }
    public var primaryMetricLabel: String { primaryMetric.displayLabel }

    public init(
        planUsedPercent: Double?,
        planUsedUSD: Double? = nil,
        planLimitUSD: Double? = nil,
        autoPercentUsed: Double? = nil,
        apiPercentUsed: Double? = nil,
        onDemandUsedUSD: Double? = nil,
        onDemandLimitUSD: Double? = nil,
        onDemandEnabled: Bool = false,
        membershipType: String? = nil,
        email: String? = nil,
        billingCycleStart: Date? = nil,
        billingCycleEnd: Date? = nil,
        isUnlimited: Bool = false,
        source: Source = .unknown,
        fetchedAt: Date
    ) {
        self.planUsedPercent = planUsedPercent
        self.planUsedUSD = planUsedUSD
        self.planLimitUSD = planLimitUSD
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.onDemandUsedUSD = onDemandUsedUSD
        self.onDemandLimitUSD = onDemandLimitUSD
        self.onDemandEnabled = onDemandEnabled
        self.membershipType = membershipType
        self.email = email
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.isUnlimited = isUnlimited
        self.source = source
        self.fetchedAt = fetchedAt
    }

    public static let placeholder = CursorUsage(
        planUsedPercent: 42,
        planUsedUSD: 8.4,
        planLimitUSD: 20,
        autoPercentUsed: 30,
        apiPercentUsed: 55,
        onDemandEnabled: false,
        membershipType: "pro",
        email: "you@example.com",
        billingCycleStart: Date.now.addingTimeInterval(-86_400 * 10),
        billingCycleEnd: Date.now.addingTimeInterval(86_400 * 20),
        source: .appState,
        fetchedAt: .now
    )
}
