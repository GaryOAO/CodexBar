import Foundation

/// Fetches per-key token usage + cost from a self-hosted claude-oauth-proxy
/// (`GET {baseURL}/api/key/usage`, authenticated with the proxy API key) and maps
/// it into a `CostUsageTokenSnapshot`. The proxy aggregates usage centrally across
/// every machine that shares the same `PROXY_API_KEY`, so this drives CodexBar's
/// Claude cost view with a cross-machine total instead of the per-machine local
/// `~/.claude` log scan.
public enum ClaudeProxyUsageFetcher {
    public enum FetchError: LocalizedError, Sendable {
        case badStatus(Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case let .badStatus(code): "Proxy usage endpoint returned HTTP \(code)."
            case .invalidResponse: "Proxy usage endpoint returned an unreadable response."
            }
        }
    }

    /// Wire shape of `GET /api/key/usage`. Only the daily buckets are needed; the
    /// 30-day totals are summed from them. Extra keys (id/name/cycle/…) are ignored.
    private struct Response: Decodable {
        let daily_buckets: [String: Day]?

        struct Day: Decodable {
            let requests: Int?
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let cost_usd: Double?
        }
    }

    public static func loadProxyTokenSnapshot(
        baseURL: String,
        token: String,
        historyDays: Int = 30,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> CostUsageTokenSnapshot
    {
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmedBase + "/api/key/usage") else {
            throw FetchError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let result = try await transport.response(for: request)
        guard (200..<300).contains(result.statusCode) else {
            throw FetchError.badStatus(result.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: result.data) else {
            throw FetchError.invalidResponse
        }
        return Self.makeSnapshot(from: decoded, historyDays: historyDays, now: now)
    }

    private static func makeSnapshot(
        from response: Response,
        historyDays: Int,
        now: Date) -> CostUsageTokenSnapshot
    {
        let clampedDays = max(1, min(365, historyDays))
        let buckets = response.daily_buckets ?? [:]
        let daily: [CostUsageDailyReport.Entry] = buckets.keys.sorted().map { day in
            let d = buckets[day]
            let total = (d?.input_tokens ?? 0) + (d?.output_tokens ?? 0)
                + (d?.cache_creation_input_tokens ?? 0) + (d?.cache_read_input_tokens ?? 0)
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: d?.input_tokens,
                outputTokens: d?.output_tokens,
                cacheReadTokens: d?.cache_read_input_tokens,
                cacheCreationTokens: d?.cache_creation_input_tokens,
                totalTokens: total,
                requestCount: d?.requests,
                costUSD: d?.cost_usd,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }

        // "Last 30 days" totals come from the daily buckets (the rolling history
        // window), not the proxy's plan-cycle counter — the cycle is a shorter
        // 7-day plan window and would understate the 30-day cost/token view.
        let last30Tokens = daily.reduce(0) { $0 + ($1.totalTokens ?? 0) }
        let last30Cost = daily.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
        let last30Requests = daily.reduce(0) { $0 + ($1.requestCount ?? 0) }

        // "Today" = the bucket for the current UTC day.
        let todayKey = Self.utcDayKey(now)
        let today = daily.first { $0.date == todayKey }

        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: today?.costUSD,
            sessionRequests: today?.requestCount,
            last30DaysTokens: last30Tokens,
            last30DaysCostUSD: last30Cost,
            last30DaysRequests: last30Requests,
            currencyCode: "USD",
            historyDays: clampedDays,
            historyLabel: "Proxy · all machines",
            daily: daily,
            updatedAt: now)
    }

    private static func utcDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
