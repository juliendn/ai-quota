import Foundation
import MobileAccessCore
import OSLog

/// Fetches Cursor quota via `usage-summary` using the credential the
/// coordinator resolved from local Cursor IDE state.
public actor CursorClient {
    private let logger = Logger(subsystem: "app.aiquota", category: "CursorClient")
    private let coordinator: CursorAuthCoordinator
    private let session: URLSession

    public init(coordinator: CursorAuthCoordinator) {
        self.coordinator = coordinator
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    public func fetchUsage(now: Date = .now) async throws -> CursorUsage {
        let context = try await coordinator.requestContext()
        var request = try CursorAPI.usageSummaryRequest(accessToken: context.accessToken)
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            recordAttempt(source: context.source, httpStatus: nil, category: .network)
            throw NetworkError.networkUnavailable
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            recordAttempt(source: context.source, httpStatus: http.statusCode, category: .authFailed)
            throw NetworkError.notAuthenticated
        case 429:
            recordAttempt(source: context.source, httpStatus: 429, category: .rateLimited)
            throw NetworkError.rateLimited
        default:
            recordAttempt(source: context.source, httpStatus: http.statusCode, category: .serverError)
            throw NetworkError.httpError(statusCode: http.statusCode)
        }

        do {
            var usage = try CursorAPI.decodeUsageSummary(
                data,
                now: now,
                source: context.source,
                email: context.email
            )
            // Prefer local membership when the summary omits it.
            if usage.membershipType == nil, let membership = context.membershipType {
                usage = CursorUsage(
                    planUsedPercent: usage.planUsedPercent,
                    planUsedUSD: usage.planUsedUSD,
                    planLimitUSD: usage.planLimitUSD,
                    autoPercentUsed: usage.autoPercentUsed,
                    apiPercentUsed: usage.apiPercentUsed,
                    onDemandUsedUSD: usage.onDemandUsedUSD,
                    onDemandLimitUSD: usage.onDemandLimitUSD,
                    onDemandEnabled: usage.onDemandEnabled,
                    membershipType: membership,
                    email: usage.email ?? context.email,
                    billingCycleStart: usage.billingCycleStart,
                    billingCycleEnd: usage.billingCycleEnd,
                    isUnlimited: usage.isUnlimited,
                    source: usage.source,
                    fetchedAt: usage.fetchedAt
                )
            }
            recordAttempt(source: context.source, httpStatus: http.statusCode, category: .success)
            return usage
        } catch {
            recordAttempt(source: context.source, httpStatus: http.statusCode, category: .invalidResponse)
            throw NetworkError.decodingError(underlying: error)
        }
    }

    private func recordAttempt(
        source: CursorUsage.Source,
        httpStatus: Int?,
        category: CursorSourceAttempt.ErrorCategory
    ) {
        SharedDefaults.appendCursorSourceAttempt(
            CursorSourceAttempt(source: source, httpStatus: httpStatus, errorCategory: category)
        )
    }
}
