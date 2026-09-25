import AVFoundation
import Foundation
import Observation
import Speech

/// Spracheingabe für Ideen und Chats: hört zu und schreibt live mit (auf dem Gerät, wenn möglich).
@MainActor
@Observable
final class SpeechRecorder {
    private(set) var isRecording = false
    private(set) var transcript = ""
    private(set) var level: Float = 0
    var error: String?

    @ObservationIgnored private var session: SpeechSession?

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start() async {
        guard !isRecording else { return }
        error = nil
        transcript = ""
        guard await Self.authorize() else {
            error = "Bitte erlaube Mikrofon und Spracherkennung in den Einstellungen."
            return
        }
        do {
            let session = SpeechSession()
            try session.start { [weak self] text, level, finished, message in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if let level { self.level = level }
                    if let message { self.error = message }
                    if finished { self.stop() }
                }
            }
            self.session = session
            isRecording = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        session?.stop()
        session = nil
        isRecording = false
        level = 0
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Die eigentliche Aufnahme – bewusst außerhalb des Main Actors, weil Audio- und
/// Erkennungs-Callbacks auf eigenen Threads kommen.
private final class SpeechSession: @unchecked Sendable {
    typealias Update = @Sendable (_ text: String?, _ level: Float?, _ finished: Bool, _ error: String?) -> Void

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(update: @escaping Update) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw NSError(domain: "Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Spracherkennung ist gerade nicht verfügbar."])
        }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            update(nil, Self.level(of: buffer), false, nil)
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let finished = result?.isFinal ?? false
            // Auch ein Abbruch durch `stop()` kommt als Fehler an – das ist kein Problem, also nicht anzeigen.
            update(text, nil, finished || error != nil, nil)
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += data[index] * data[index] }
        let rms = (sum / Float(count)).squareRoot()
        return min(1, rms * 12)
    }
}
