import Foundation

/// A local Unix socket that the Claude Code hook script and the `notch` command talk to.
/// Each connection sends one JSON object on one line, with the token from `bridge.token`
/// (a file only you can read; it changes every launch). The handler may answer with one
/// line, later, on the same connection: a permission request waits that way.
///
/// Message shape: {"type": "hook" | "cli", "token": "...", ...anything else}.
@MainActor
final class BridgeServer {
    typealias Handler = (_ message: [String: Any], _ connection: BridgeConnection) -> Void

    static var socketURL: URL { Config.directory.appendingPathComponent("bridge.sock") }
    static var tokenURL: URL { Config.directory.appendingPathComponent("bridge.token") }

    private var handlers: [String: Handler] = [:]
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "local.dynamicnotch.bridge")
    private var token = ""

    /// Registers the handler for one message type ("hook", "cli").
    func on(_ type: String, _ handler: @escaping Handler) { handlers[type] = handler }

    func start() {
        do {
            token = try Self.writeToken()
            listenFD = try Self.listen(at: Self.socketURL)
        } catch {
            Log.app.error("bridge failed to start: \(String(describing: error), privacy: .public)")
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        let fd = listenFD
        let expected = token
        let q = queue
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            BridgeConnection.read(client, queue: q) { line, connection in
                guard let data = line.data(using: .utf8),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let sent = json["token"] as? String, Self.equal(sent, expected),
                      let type = json["type"] as? String else {
                    connection.close()
                    return
                }
                var message = json
                message["token"] = nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let handler = self?.handlers[type] else { connection.close(); return }
                        handler(message, connection)
                    }
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        acceptSource = source
        Log.app.info("bridge listening at \(Self.socketURL.path, privacy: .public)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketURL.path)
    }

    /// Constant-time comparison, so the token can't be guessed byte by byte.
    nonisolated static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private static func writeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BridgeError.random
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let path = tokenURL.path
        unlink(path)
        guard FileManager.default.createFile(atPath: path, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw BridgeError.token
        }
        return token
    }

    private static func listen(at url: URL) throws -> Int32 {
        let path = url.path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socket(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)   // never inherited by processes the app starts
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); throw BridgeError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0 else { let e = errno; Darwin.close(fd); throw BridgeError.bind(e) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { let e = errno; Darwin.close(fd); throw BridgeError.listen(e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    enum BridgeError: Error { case random, token, socket(Int32), pathTooLong, bind(Int32), listen(Int32) }
}

/// One client connection. Reads a single line, then lets the handler reply once.
/// `onClose` fires if the client goes away first (Claude Code cancelled the hook).
final class BridgeConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false
    private var gotLine = false
    private var onLine: ((String, BridgeConnection) -> Void)?

    /// Called on the main thread when the client disconnects before the reply or close has
    /// gone out. Main-only: set it from the line's handler. The disconnect reaches the main
    /// queue after that handler (the bridge queue sends both, in order), so it can't be missed.
    @MainActor var onClose: (@MainActor () -> Void)?

    private init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    static func read(_ fd: Int32, queue: DispatchQueue, onLine: @escaping (String, BridgeConnection) -> Void) {
        let c = BridgeConnection(fd: fd, queue: queue)
        c.onLine = onLine
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { c.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        c.source = source
        source.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) { peerClosed() }
            return
        }
        guard !gotLine else { return }             // ignore anything after the first line
        buffer.append(contentsOf: chunk[0..<n])
        if buffer.count > 4_000_000 { finish(); return }   // a hook payload is never this big
        if let nl = buffer.firstIndex(of: 0x0A) {
            gotLine = true
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeAll()
            onLine?(line, self)
            onLine = nil
        }
    }

    private func peerClosed() {
        // A client that closes before sending a newline still gets its line handled.
        if !gotLine, !buffer.isEmpty, let onLine {
            gotLine = true
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            self.onLine = nil
            onLine(line, self)
        }
        let wasOpen = !closed
        finish()
        if wasOpen, gotLine {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.onClose?()
                    self.onClose = nil
                }
            }
        }
    }

    /// Sends one JSON line and closes. Safe to call from any thread, once.
    func reply(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { close(); return }
        queue.async { [self] in
            guard !closed else { return }
            var bytes = [UInt8](data)
            bytes.append(0x0A)
            var sent = 0
            while sent < bytes.count {
                let n = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n > 0 { sent += n } else if errno == EAGAIN || errno == EINTR { usleep(1000) } else { break }
            }
            finish()
        }
    }

    /// Closes without a reply.
    func close() {
        queue.async { [self] in finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
    }
}
