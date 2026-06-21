import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexBarTests {
    @Test
    func `icon renderer produces template image`() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 50,
            weeklyRemaining: 75,
            creditsRemaining: 500,
            stale: false,
            style: .codex)
        #expect(image.isTemplate)
        #expect(image.size.width > 0)
    }

    @Test
    func `icon renderer renders at pixel aligned size`() {
        let image = IconRenderer.makeIcon(
            primaryRemaining: 50,
            weeklyRemaining: 75,
            creditsRemaining: 500,
            stale: false,
            style: .claude)
        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(bitmapReps.contains { rep in
            rep.pixelsWide == 36 && rep.pixelsHigh == 36
        })
    }

    @Test
    func `icon renderer caches static icons`() {
        let first = IconRenderer.makeIcon(
            primaryRemaining: 42,
            weeklyRemaining: 17,
            creditsRemaining: 250,
            stale: false,
            style: .codex)
        let second = IconRenderer.makeIcon(
            primaryRemaining: 42,
            weeklyRemaining: 17,
            creditsRemaining: 250,
            stale: false,
            style: .codex)
        #expect(first === second)
    }

    @Test
    func `copying rate windows preserves surviving payloads`() {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "test@example.com",
            accountOrganization: "Example",
            loginMethod: "OAuth")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: RateWindow(usedPercent: 30, windowMinutes: 60, resetsAt: nil, resetDescription: nil),
            subscriptionExpiresAt: updatedAt.addingTimeInterval(100),
            subscriptionRenewsAt: updatedAt.addingTimeInterval(200),
            updatedAt: updatedAt,
            identity: identity)

        let copied = snapshot.with(
            primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))

        #expect(copied.primary?.usedPercent == 40)
        #expect(copied.secondary?.usedPercent == 50)
        #expect(copied.tertiary?.usedPercent == 30)
        #expect(copied.subscriptionExpiresAt == updatedAt.addingTimeInterval(100))
        #expect(copied.subscriptionRenewsAt == updatedAt.addingTimeInterval(200))
        #expect(copied.identity?.accountOrganization == "Example")
    }

    @Test
    func `copying identity preserves surviving payloads`() {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            subscriptionExpiresAt: updatedAt.addingTimeInterval(100),
            subscriptionRenewsAt: updatedAt.addingTimeInterval(200),
            updatedAt: updatedAt)
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: "test@example.com",
            accountOrganization: "Example",
            loginMethod: "API")

        let copied = snapshot.withIdentity(identity)

        #expect(copied.subscriptionExpiresAt == updatedAt.addingTimeInterval(100))
        #expect(copied.subscriptionRenewsAt == updatedAt.addingTimeInterval(200))
        #expect(copied.identity?.accountOrganization == "Example")
    }

    @Test
    @MainActor
    func `status icon accessibility uses percentage scale`() {
        #expect(
            StatusIconView.accessibilityPercentRemaining(50) ==
                String(format: L("%d percent remaining"), 50))
    }

    @Test
    func `codex icon promotes weekly only window into primary display lane`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .codex)
        #expect(remaining.primary == 75)
        #expect(remaining.secondary == nil)
    }

    @Test
    func `codex icon uses semantic projection lanes when durations drift`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 25, windowMinutes: 11040, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date())

        let remaining = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, style: .codex)
        #expect(remaining.primary == 75)
        #expect(remaining.secondary == nil)
    }

    @Test
    func `status overlays cut halos through the quota bar and keep glyphs visible`() throws {
        let plain = IconRenderer.makeIcon(
            primaryRemaining: 100,
            weeklyRemaining: 100,
            creditsRemaining: nil,
            stale: false,
            style: .combined,
            statusIndicator: .none)
        let plainRep = try #require(plain.representations.compactMap { $0 as? NSBitmapImageRep }.first {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })

        func alpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
            (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
        }

        for indicator in [ProviderStatusIndicator.minor, .major] {
            let marked = IconRenderer.makeIcon(
                primaryRemaining: 100,
                weeklyRemaining: 100,
                creditsRemaining: nil,
                stale: false,
                style: .combined,
                statusIndicator: indicator)
            let markedRep = try #require(marked.representations.compactMap { $0 as? NSBitmapImageRep }.first {
                $0.pixelsWide == 36 && $0.pixelsHigh == 36
            })

            var cutoutPixels = 0
            var glyphPixels = 0
            for y in 0..<markedRep.pixelsHigh {
                for x in 0..<markedRep.pixelsWide {
                    let plainAlpha = alpha(plainRep, x: x, y: y)
                    let markedAlpha = alpha(markedRep, x: x, y: y)
                    if plainAlpha > 0.5, markedAlpha < 0.05 {
                        cutoutPixels += 1
                    }
                    if plainAlpha < 0.05, markedAlpha > 0.5 {
                        glyphPixels += 1
                    }
                }
            }

            #expect(cutoutPixels >= 8, "Expected halo cutout pixels for \(indicator)")
            #expect(glyphPixels >= 4, "Expected visible glyph pixels for \(indicator)")
        }
    }

    @Test
    func `icon renderer codex eyes punch through when unknown`() {
        // Regression: when remaining is nil, CoreGraphics inherits the previous fill alpha which caused
        // destinationOut “eyes” to become semi-transparent instead of fully punched through.
        let image = IconRenderer.makeIcon(
            primaryRemaining: nil,
            weeklyRemaining: 1,
            creditsRemaining: nil,
            stale: false,
            style: .codex)

        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        let rep = bitmapReps.first(where: { $0.pixelsWide == 36 && $0.pixelsHigh == 36 })
        #expect(rep != nil)
        guard let rep else { return }

        func alphaAt(px x: Int, _ y: Int) -> CGFloat {
            (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
        }

        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let isTransparent: (Int, Int) -> Bool = { x, y in
            alphaAt(px: x, y) < 0.05
        }

        // Flood-fill from the border through transparent pixels to label the "outside".
        var visited = Array(repeating: Array(repeating: false, count: w), count: h)
        var queue: [(Int, Int)] = []
        queue.reserveCapacity(w * 2 + h * 2)

        func enqueueIfOutside(_ x: Int, _ y: Int) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            guard !visited[y][x], isTransparent(x, y) else { return }
            visited[y][x] = true
            queue.append((x, y))
        }

        for x in 0..<w {
            enqueueIfOutside(x, 0)
            enqueueIfOutside(x, h - 1)
        }
        for y in 0..<h {
            enqueueIfOutside(0, y)
            enqueueIfOutside(w - 1, y)
        }

        while let (x, y) = queue.first {
            queue.removeFirst()
            enqueueIfOutside(x + 1, y)
            enqueueIfOutside(x - 1, y)
            enqueueIfOutside(x, y + 1)
            enqueueIfOutside(x, y - 1)
        }

        // Any remaining transparent pixels not reachable from the border are internal holes (i.e. the eyes).
        var internalHoles = 0
        for y in 0..<h {
            for x in 0..<w where isTransparent(x, y) && !visited[y][x] {
                internalHoles += 1
            }
        }

        #expect(internalHoles >= 16) // at least one 4×4 eye block, but typically two eyes => 32
    }

    @Test
    func `account info parses snake case auth token`() throws {
        let tmp = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let token = Self.fakeJWT(email: "user@example.com", plan: "pro")
        let auth = ["tokens": ["id_token": token, "access_token": "access", "refresh_token": "refresh"]]
        let data = try JSONSerialization.data(withJSONObject: auth)
        let authURL = tmp.appendingPathComponent("auth.json")
        try data.write(to: authURL)

        let fetcher = UsageFetcher(environment: ["CODEX_HOME": tmp.path])
        let account = fetcher.loadAccountInfo()
        #expect(account.email == "user@example.com")
        #expect(account.plan == "pro")
    }

    @Test
    func `account info parses legacy camel case auth token`() throws {
        let tmp = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let token = Self.fakeJWT(email: "user@example.com", plan: "pro")
        let auth = ["tokens": ["idToken": token, "accessToken": "access", "refreshToken": "refresh"]]
        let data = try JSONSerialization.data(withJSONObject: auth)
        let authURL = tmp.appendingPathComponent("auth.json")
        try data.write(to: authURL)

        let fetcher = UsageFetcher(environment: ["CODEX_HOME": tmp.path])
        let account = fetcher.loadAccountInfo()
        #expect(account.email == "user@example.com")
        #expect(account.plan == "pro")
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()
        func b64(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        return "\(b64(header)).\(b64(payload))."
    }
}
