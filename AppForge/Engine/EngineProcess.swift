import Foundation

/// Startet und beendet den lokalen `opencode serve`-Prozess.
final class EngineProcess: @unchecked Sendable {
    enum EngineError: LocalizedError {
        case binaryNotFound
        case startTimeout(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                "OpenCode wurde nicht gefunden. Installiere es mit „brew install anomalyco/tap/opencode“ oder trage den Pfad in den Einstellungen ein."
            case .startTimeout(let log):
                "OpenCode ist nicht rechtzeitig gestartet.\n\(log.suffix(800))"
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var outputLog = ""

    /// Startet den Server und wartet, bis er antwortet.
    func start(binaryOverride: String?) async throws -> OpenCodeClient {
        stop()
        Self.killOrphanedServer()
        let environment = await ShellEnvironment.load()
        guard let binary = Self.findBinary(override: binaryOverride, path: environment["PATH"] ?? "") else {
            throw EngineError.binaryNotFound
        }
        try EngineConfig.write()

        let port = try FreePort.find()
        let password = UUID().uuidString

        var env = environment
        env["OPENCODE_SERVER_PASSWORD"] = password
        env["OPENCODE_CONFIG"] = EngineConfig.configFile.path
        env["OPENCODE_CONFIG_DIR"] = EngineConfig.configDirectory.path

        let process = Process()
        process.executableURL = URL(filePath: binary)
        process.arguments = ["serve", "--hostname", "127.0.0.1", "--port", String(port)]
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let self, !text.isEmpty else { return }
            self.lock.withLock { self.outputLog = String((self.outputLog + text).suffix(20_000)) }
        }

        try process.run()
        lock.withLock { self.process = process; self.outputLog = "" }
        try? String(process.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)

        let client = OpenCodeClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, password: password)
        for _ in 0..<60 {
            if !process.isRunning { break }
            if (try? await client.health()) == true { return client }
            try await Task.sleep(for: .milliseconds(250))
        }
        let log = lock.withLock { outputLog }
        stop()
        throw EngineError.startTimeout(log)
    }

    func stop() {
        let running = lock.withLock { () -> Process? in
            defer { process = nil }
            return process
        }
        guard let running, running.isRunning else { return }
        running.terminate()
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    var log: String { lock.withLock { outputLog } }

    private static var pidFile: URL { EngineConfig.supportDirectory.appending(path: "engine.pid") }

    /// Wurde AppForge hart beendet (Absturz, Force Quit), läuft der alte Server weiter.
    /// Beim nächsten Start wird er anhand der PID-Datei beendet – aber nur, wenn es wirklich `opencode serve` ist.
    private static func killOrphanedServer() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return }
        try? FileManager.default.removeItem(at: pidFile)

        var buffer = [CChar](repeating: 0, count: 4096)
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return }
        let args = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0).map { String(decoding: $0.map(UInt8.init), as: UTF8.self) }
        guard args.contains(where: { $0.hasSuffix("opencode") }), args.contains("serve") else { return }
        kill(pid, SIGTERM)
    }

    static func findBinary(override: String?, path: String) -> String? {
        let fm = FileManager.default
        if let override, !override.isEmpty, fm.isExecutableFile(atPath: override) { return override }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = path.split(separator: ":").map { "\($0)/opencode" } + [
            "\(home)/.opencode/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(home)/.bun/bin/opencode",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}

/// GUI-Apps erben nicht den PATH der Shell. Für `xcrun`, `npx` & Co. holen wir ihn aus der Login-Shell.
enum ShellEnvironment {
    static func load() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let path = await loginShellPATH() {
            env["PATH"] = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.opencode/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        }
        return env
    }

    private static func loginShellPATH() async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: path.isEmpty ? nil : path)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}

enum FreePort {
    static func find() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
