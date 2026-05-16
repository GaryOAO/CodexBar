import Darwin
import Foundation
import Logging

/// Listens on a Unix domain socket and emits one `HookEvent` per NDJSON line
/// any connected hook shim writes. Lightweight: no auth (POSIX file perms on
/// the socket are enough — only the user that owns ~/.codexbar/ can write),
/// no threading model beyond GCD I/O sources.
///
/// Lifecycle:
///   let receiver = HookEventReceiver()
///   try receiver.start()
///   for await event in receiver.events { ... }
///   receiver.stop()       // also unlinks the socket file
///
/// The socket is short and local; we use BSD sockets directly via Darwin
/// instead of Network.framework because NWListener's `.unix` endpoint has
/// historically been fragile on macOS and the BSD path is ~40 lines.
public final class HookEventReceiver: @unchecked Sendable {
    public static let defaultSocketRelativePath = ".codexbar/hook.sock"

    public let socketPath: String
    public let events: AsyncStream<HookEvent>

    private let log = CodexBarLog.logger("hooks.receiver")
    private let queue = DispatchQueue(label: "com.steipete.codexbar.hookreceiver", qos: .utility)
    private let continuation: AsyncStream<HookEvent>.Continuation

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [DispatchSourceRead] = []
    private var stopped = false

    public init(socketPath: String? = nil) {
        if let socketPath {
            self.socketPath = socketPath
        } else {
            let home = NSHomeDirectory()
            self.socketPath = (home as NSString).appendingPathComponent(Self.defaultSocketRelativePath)
        }

        var continuationOut: AsyncStream<HookEvent>.Continuation!
        self.events = AsyncStream { c in continuationOut = c }
        self.continuation = continuationOut
    }

    /// Bind + listen. Throws if the parent dir cannot be created or the bind
    /// fails for a reason other than "stale socket file from previous run".
    public func start() throws {
        try self.queue.sync {
            try self.bindAndListenLocked()
        }
    }

    public func stop() {
        self.queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.acceptSource?.cancel()
            self.acceptSource = nil
            for s in self.clientSources {
                s.cancel()
            }
            self.clientSources.removeAll()
            if self.listenFD >= 0 {
                Darwin.close(self.listenFD)
                self.listenFD = -1
            }
            unlink(self.socketPath)
            self.continuation.finish()
            self.log.info("hook socket stopped", metadata: ["path": self.socketPath])
        }
    }

    private func bindAndListenLocked() throws {
        let parent = (self.socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        // Remove any stale socket left behind by a previous CodexBar process.
        unlink(self.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HookReceiverError.posix("socket()", errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = self.socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            Darwin.close(fd)
            throw HookReceiverError.pathTooLong(self.socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dst, src.baseAddress!, src.count)
                }
            }
        }

        let bound = withUnsafePointer(to: &addr) { rawPtr in
            rawPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let saved = errno
            Darwin.close(fd)
            throw HookReceiverError.posix("bind()", saved)
        }

        // Lock the socket file to owner-only access. Even though it sits inside
        // a 0700 directory, an explicit chmod here keeps things tidy if the
        // user later loosens parent dir perms by hand.
        _ = chmod(self.socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            let saved = errno
            Darwin.close(fd)
            unlink(self.socketPath)
            throw HookReceiverError.posix("listen()", saved)
        }

        self.listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        self.acceptSource = src

        self.log.info("hook socket listening", metadata: ["path": self.socketPath])
    }

    private func accept() {
        var clientAddr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFD = Darwin.accept(self.listenFD, &clientAddr, &len)
        guard clientFD >= 0 else { return }
        self.serve(clientFD: clientFD)
    }

    private func serve(clientFD: Int32) {
        // Each accepted connection gets its own read source. Hook shims typically
        // write one NDJSON line then close, but we tolerate any number of lines
        // before EOF.
        let src = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: self.queue)
        var buffer = Data()

        src.setEventHandler { [weak self] in
            guard let self else { return }
            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = read(clientFD, &tmp, tmp.count)
            if n > 0 {
                buffer.append(tmp, count: n)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self.deliver(line: line)
                    }
                }
            } else if n == 0 {
                // EOF — flush any trailing data without a newline as one final line.
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                    self.deliver(line: line)
                    buffer.removeAll()
                }
                src.cancel()
            } else if errno != EAGAIN, errno != EINTR {
                self.log.debug("read() failed", metadata: ["errno": "\(errno)"])
                src.cancel()
            }
        }

        src.setCancelHandler {
            Darwin.close(clientFD)
        }

        self.clientSources.append(src)
        src.resume()
    }

    private func deliver(line: String) {
        guard let event = HookEvent.decode(jsonLine: line) else {
            self.log.debug("dropped unparseable hook payload", metadata: ["bytes": "\(line.count)"])
            return
        }
        self.log.info(
            "hook event",
            metadata: [
                "kind": event.kind.rawValue,
                "source": event.source.rawValue,
                "tool": event.toolName ?? "-",
            ])
        self.continuation.yield(event)
    }
}

public enum HookReceiverError: Error, CustomStringConvertible, Sendable {
    case posix(String, Int32)
    case pathTooLong(String)

    public var description: String {
        switch self {
        case let .posix(call, code):
            let msg = String(cString: strerror(code))
            return "\(call) failed: \(msg) (errno=\(code))"
        case let .pathTooLong(path):
            return "socket path too long for sockaddr_un: \(path)"
        }
    }
}
