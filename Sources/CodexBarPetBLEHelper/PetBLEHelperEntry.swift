import AppKit
import CodexBarCore
import Foundation

@main
struct PetBLEHelperEntry {
    static func main() {
        let app = NSApplication.shared
        let delegate = PetBLEHelperDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
private final class PetBLEHelperDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let client = PetBLEClient()
    private let defaults = PetBLEIPCBridge.sharedDefaults()
    private let containerURL = PetBLEIPCBridge.sharedContainerURL()
    private let center = DistributedNotificationCenter.default()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastRequestID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.record("helper launching")
        self.center.addObserver(
            self,
            selector: #selector(self.handleCommandNotification(_:)),
            name: PetBLEIPCBridge.commandNotificationName,
            object: nil)
        self.client.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.record("helper state=\(state)")
                self.publishSnapshot(requestID: nil)
            }
        }
        self.client.onSnapshotChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.publishSnapshot(requestID: nil)
            }
        }
        self.publishSnapshot(requestID: nil)
        self.handlePendingCommand()
        self.client.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.center.removeObserver(self)
        self.client.stop()
        self.record("helper terminating")
    }

    @objc private func handleCommandNotification(_ notification: Notification) {
        self.handlePendingCommand()
    }

    private func handlePendingCommand() {
        guard let data = self.read(
            filename: PetBLEIPCBridge.commandFilename,
            defaultsKey: PetBLEIPCBridge.commandDefaultsKey)
        else { return }
        do {
            let request = try self.decoder.decode(PetBLEIPCRequest.self, from: data)
            guard request.requestID != self.lastRequestID else { return }
            self.lastRequestID = request.requestID
            self.handle(request)
        } catch {
            self.publish(.error(requestID: nil, message: "decode command failed: \(error)"))
        }
    }

    private func handle(_ request: PetBLEIPCRequest) {
        switch request.command {
        case .start:
            self.record("helper command=start")
            self.client.start()
            self.publish(.ack(requestID: request.requestID))
            self.publishSnapshot(requestID: request.requestID)
        case .stop:
            self.record("helper command=stop")
            self.client.stop()
            self.publish(.ack(requestID: request.requestID))
            self.publishSnapshot(requestID: request.requestID)
        case .restartForForegroundAuthorization:
            self.record("helper command=restart")
            self.client.restartForForegroundAuthorization()
            self.publish(.ack(requestID: request.requestID))
            self.publishSnapshot(requestID: request.requestID)
        case let .pushStatus(status):
            self.ensureClientStarted(reason: "pushStatus")
            self.client.pushStatus(status)
            self.publish(.ack(requestID: request.requestID))
            self.publishSnapshot(requestID: request.requestID)
        case let .pushCodexStatus(status):
            self.ensureClientStarted(reason: "pushCodexStatus")
            self.client.pushCodexStatus(status)
            self.publish(.ack(requestID: request.requestID))
            self.publishSnapshot(requestID: request.requestID)
        case let .pushProviderStatuses(status, codexStatus):
            self.ensureClientStarted(reason: "pushProviderStatuses")
            self.client.pushStatus(status)
            self.client.pushCodexStatus(codexStatus)
            self.publish(.ack(requestID: request.requestID))
            self.publishSnapshot(requestID: request.requestID)
        case let .setTheme(theme):
            self.ensureClientStarted(reason: "setTheme")
            self.client.setTheme(theme)
            self.publish(.ack(requestID: request.requestID))
            self.publishSnapshot(requestID: request.requestID)
        case let .setDisplayConfig(config):
            self.ensureClientStarted(reason: "setDisplayConfig")
            self.client.setDisplayConfig(config)
            self.publish(.ack(requestID: request.requestID))
            self.publishSnapshot(requestID: request.requestID)
        case .snapshot:
            self.ensureClientStarted(reason: "snapshot")
            self.client.refreshSnapshotInputs()
            self.publishSnapshot(requestID: request.requestID)
        case .shutdown:
            self.record("helper command=shutdown")
            self.publish(.ack(requestID: request.requestID))
            NSApp.terminate(nil)
        }
    }

    private func ensureClientStarted(reason: String) {
        guard self.client.state == .off else { return }
        self.record("helper auto-start for \(reason)")
        self.client.start()
    }

    private func publishSnapshot(requestID: UUID?) {
        self.publish(.snapshot(requestID: requestID, self.client.snapshot(runtimeDetail: self.runtimeDetail())))
    }

    private func publish(_ event: PetBLEIPCEvent) {
        guard let data = try? self.encoder.encode(event) else { return }
        self.write(data, filename: PetBLEIPCBridge.eventFilename, defaultsKey: PetBLEIPCBridge.eventDefaultsKey)
        self.defaults.set(data, forKey: PetBLEIPCBridge.eventDefaultsKey)
        self.defaults.set(UUID().uuidString, forKey: PetBLEIPCBridge.eventIDDefaultsKey)
        if case let .snapshot(_, snapshot) = event,
           let snapshotData = try? self.encoder.encode(snapshot)
        {
            self.write(
                snapshotData,
                filename: PetBLEIPCBridge.snapshotFilename,
                defaultsKey: PetBLEIPCBridge.snapshotDefaultsKey)
            self.defaults.set(snapshotData, forKey: PetBLEIPCBridge.snapshotDefaultsKey)
        }
        self.defaults.synchronize()
        self.center.postNotificationName(
            PetBLEIPCBridge.eventNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
    }

    private func record(_ message: String) {
        self.defaults.set(message, forKey: "petBLEHelperRuntimeDetail")
        self.defaults.set(Date().timeIntervalSince1970, forKey: "petBLEHelperRuntimeUpdatedAt")
        self.defaults.synchronize()
    }

    private func runtimeDetail() -> String {
        self.defaults.string(forKey: "petBLEHelperRuntimeDetail") ?? "helper running"
    }

    private func url(for filename: String) -> URL? {
        self.containerURL?.appendingPathComponent(filename, isDirectory: false)
    }

    private func write(_ data: Data, filename: String, defaultsKey: String) {
        if let url = self.url(for: filename) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        self.defaults.set(data, forKey: defaultsKey)
    }

    private func read(filename: String, defaultsKey: String) -> Data? {
        if let url = self.url(for: filename),
           let data = try? Data(contentsOf: url)
        {
            return data
        }
        return self.defaults.data(forKey: defaultsKey)
    }
}
