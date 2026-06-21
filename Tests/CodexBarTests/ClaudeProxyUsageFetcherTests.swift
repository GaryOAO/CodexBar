import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeProxyUsageFetcherTests {
    private struct StubTransport: ProviderHTTPTransport {
        let json: String
        let status: Int
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: self.status,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(self.json.utf8), resp)
        }
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test
    func `maps proxy per-key usage into a cost snapshot`() async throws {
        let json = """
        {
          "id": "k1", "name": "macbook",
          "current_month_usage": {"requests": 30, "input_tokens": 1000, "output_tokens": 500,
            "cache_creation_input_tokens": 100, "cache_read_input_tokens": 400, "cost_usd": 1.25, "last_updated": 1},
          "daily_buckets": {
            "2026-06-19": {"requests": 10, "input_tokens": 300, "output_tokens": 100,
              "cache_creation_input_tokens": 0, "cache_read_input_tokens": 100, "cost_usd": 0.25},
            "2026-06-20": {"requests": 20, "input_tokens": 700, "output_tokens": 400,
              "cache_creation_input_tokens": 100, "cache_read_input_tokens": 300, "cost_usd": 1.00}
          }
        }
        """
        let snap = try await ClaudeProxyUsageFetcher.loadProxyTokenSnapshot(
            baseURL: "https://proxy.example",
            token: "PK",
            historyDays: 30,
            transport: StubTransport(json: json, status: 200),
            now: self.date("2026-06-20T12:00:00Z"))

        #expect(snap.daily.count == 2)
        #expect(snap.currencyCode == "USD")
        #expect(snap.historyLabel == "Proxy · all machines")
        // Cycle totals come straight from current_month_usage.
        #expect(snap.last30DaysCostUSD == 1.25)
        #expect(snap.last30DaysRequests == 30)
        #expect(snap.last30DaysTokens == 2000) // 1000 + 500 + 100 + 400
        // "Today" is the 2026-06-20 bucket.
        #expect(snap.sessionCostUSD == 1.00)
        #expect(snap.sessionRequests == 20)
        #expect(snap.sessionTokens == 1500) // 700 + 400 + 100 + 300

        let today = try #require(snap.daily.first { $0.date == "2026-06-20" })
        #expect(today.totalTokens == 1500)
        #expect(today.cacheReadTokens == 300)
        #expect(today.cacheCreationTokens == 100)
        // Buckets are sorted ascending by date.
        #expect(snap.daily.map(\.date) == ["2026-06-19", "2026-06-20"])
    }

    @Test
    func `sums buckets when cycle totals are absent`() async throws {
        let json = """
        {"daily_buckets": {
          "2026-06-19": {"input_tokens": 300, "output_tokens": 100, "cost_usd": 0.25, "requests": 2},
          "2026-06-20": {"input_tokens": 200, "output_tokens": 50, "cost_usd": 0.10, "requests": 1}
        }}
        """
        let snap = try await ClaudeProxyUsageFetcher.loadProxyTokenSnapshot(
            baseURL: "https://proxy.example/", // trailing slash should be tolerated
            token: "PK",
            transport: StubTransport(json: json, status: 200),
            now: self.date("2026-06-20T00:00:00Z"))

        #expect(snap.last30DaysRequests == 3)
        #expect(snap.last30DaysTokens == 650) // (300+100) + (200+50)
        let cost = try #require(snap.last30DaysCostUSD)
        #expect(abs(cost - 0.35) < 1e-9)
    }

    @Test
    func `throws on non-2xx status`() async throws {
        await #expect(throws: ClaudeProxyUsageFetcher.FetchError.self) {
            _ = try await ClaudeProxyUsageFetcher.loadProxyTokenSnapshot(
                baseURL: "https://proxy.example",
                token: "bad",
                transport: StubTransport(json: "{}", status: 401),
                now: self.date("2026-06-20T00:00:00Z"))
        }
    }
}
