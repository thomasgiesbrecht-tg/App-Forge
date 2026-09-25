import AppKit
import Foundation
import Observation

/// Live-Ansicht des iOS-Simulators über `xcrun simctl`.
@MainActor
@Observable
final class SimulatorService {
    struct Device: Identifiable, Hashable, Sendable {
        var udid: String
        var name: String
        var state: String
        var runtime: String

        var id: String { udid }
        var isBooted: Bool { state == "Booted" }
        var isPad: Bool { name.localizedCaseInsensitiveContains("iPad") }
    }

    private(set) var devices: [Device] = []
    var selectedUDID: String? {
        didSet { UserDefaults.standard.set(selectedUDID, forKey: "simulator.udid") }
    }
    private(set) var frame: NSImage?
    private(set) var isBusy = false
    private(set) var lastError: String?

    init() {
        selectedUDID = UserDefaults.standard.string(forKey: "simulator.udid")
    }

    var selectedDevice: Device? { devices.first { $0.udid == selectedUDID } }

    // MARK: Geräte

    func refreshDevices(for platform: TargetPlatform) async {
        guard let data = await Shell.run(["xcrun", "simctl", "list", "devices", "available", "-j"])?.output else {
            lastError = "simctl nicht erreichbar – ist Xcode installiert?"
            return
        }
        struct List: Decodable {
            struct Entry: Decodable { var udid: String; var name: String; var state: String }
            var devices: [String: [Entry]]
        }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return }
        devices = list.devices
            .filter { $0.key.contains("SimRuntime.iOS") }
            .flatMap { runtime, entries in
                let version = runtime.components(separatedBy: "iOS-").last?.replacingOccurrences(of: "-", with: ".") ?? ""
                return entries.map { Device(udid: $0.udid, name: $0.name, state: $0.state, runtime: "iOS \(version)") }
            }
            .sorted { ($0.isBooted ? 0 : 1, $1.runtime, $0.name) < ($1.isBooted ? 0 : 1, $0.runtime, $1.name) }

        let wantsPad = platform == .iPadOS
        if selectedDevice == nil {
            selectedUDID = (devices.first { $0.isBooted && $0.isPad == wantsPad }
                ?? devices.first { $0.isPad == wantsPad }
                ?? devices.first)?.udid
        }
        lastError = nil
    }

    func boot() async {
        guard let udid = selectedUDID else { return }
        isBusy = true
        _ = await Shell.run(["xcrun", "simctl", "boot", udid])
        _ = await Shell.run(["xcrun", "simctl", "bootstatus", udid, "-b"])
        isBusy = false
        await refreshState()
    }

    func shutdown() async {
        guard let udid = selectedUDID else { return }
        isBusy = true
        _ = await Shell.run(["xcrun", "simctl", "shutdown", udid])
        isBusy = false
        frame = nil
        await refreshState()
    }

    func setAppearance(dark: Bool) async {
        guard let udid = selectedUDID else { return }
        _ = await Shell.run(["xcrun", "simctl", "ui", udid, "appearance", dark ? "dark" : "light"])
    }

    func openSimulatorApp() {
        var args = ["-a", "Simulator"]
        if let udid = selectedUDID { args += ["--args", "-CurrentDeviceUDID", udid] }
        Task { _ = await Shell.run(["open"] + args) }
    }

    private func refreshState() async {
        let platform: TargetPlatform = (selectedDevice?.isPad ?? false) ? .iPadOS : .iOS
        await refreshDevices(for: platform)
    }

    // MARK: Live-Bild

    /// Holt ein neues Bild vom gebooteten Simulator. Wird von der Ansicht in einer Schleife aufgerufen.
    func captureFrame() async {
        guard let device = selectedDevice, device.isBooted else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "appforge-sim-\(device.udid).jpg")
        guard let result = await Shell.run(["xcrun", "simctl", "io", device.udid, "screenshot", "--type=jpeg", file.path]),
              result.status == 0,
              let image = NSImage(contentsOf: file)
        else { return }
        frame = image
    }

    /// Aktuelles Bild als PNG-Anhang für den Chat.
    func screenshotAttachment() async -> Attachment? {
        guard let device = selectedDevice, device.isBooted else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "appforge-shot-\(UUID().uuidString).png")
        guard let result = await Shell.run(["xcrun", "simctl", "io", device.udid, "screenshot", file.path]),
              result.status == 0, let data = try? Data(contentsOf: file)
        else { return nil }
        try? FileManager.default.removeItem(at: file)
        return AttachmentFactory.image(data: data, filename: "Simulator \(device.name).png")
    }
}

/// Kleine Hilfe zum Ausführen von Kommandozeilen-Werkzeugen ohne den Hauptthread zu blockieren.
enum Shell {
    struct Result: Sendable {
        var status: Int32
        var output: Data
    }

    static func run(_ arguments: [String]) async -> Result? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            // Ausgabe fortlaufend lesen, damit große Ausgaben die Pipe nicht blockieren.
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in buffer.append(handle.availableData) }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: Result(status: process.terminationStatus, output: buffer.data))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ data: Data) { lock.withLock { storage.append(data) } }
        var data: Data { lock.withLock { storage } }
    }
}
