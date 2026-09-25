import Foundation

/// Einstellungen für `/foto` und `/video`.
struct MediaSettings: Codable, Sendable {
    enum Region: String, Codable, CaseIterable, Identifiable, Sendable {
        case international, china

        var id: String { rawValue }
        var title: String { self == .international ? "International (Singapur)" : "China (Peking)" }
        var baseURL: URL {
            URL(string: self == .international ? "https://dashscope-intl.aliyuncs.com" : "https://dashscope.aliyuncs.com")!
        }
        /// Anbieter-ID in OpenCode, deren Schlüssel mitbenutzt wird.
        var providerID: String { self == .international ? "alibaba" : "alibaba-cn" }
    }

    var region: Region = .international
    /// Qwen-Image 2.0 erzeugt und bearbeitet Bilder mit freien Formaten.
    var imageModel = "qwen-image-2.0"
    var imageEditModel = "qwen-image-2.0"
    var textToVideoModel = "wan2.7-t2v"
    var imageToVideoModel = "wan2.7-i2v"
    var imageSize = "2048*2048"
    var videoRatio = "16:9"
    var videoResolution = "720P"
    var videoDuration = 5

    static var current: MediaSettings {
        guard let data = UserDefaults.standard.data(forKey: "media.settings.v2"),
              let settings = try? JSONDecoder().decode(MediaSettings.self, from: data) else { return MediaSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "media.settings.v2") }
    }

    static let imageSizes: [(String, String)] = [
        ("2048*2048", "Quadratisch 1:1"), ("2688*1536", "Quer 16:9"), ("1536*2688", "Hoch 9:16"),
        ("2368*1728", "Quer 4:3"), ("1728*2368", "Hoch 3:4"),
    ]
    static let videoRatios: [(String, String)] = [
        ("16:9", "Quer 16:9"), ("9:16", "Hoch 9:16"), ("1:1", "Quadratisch 1:1"), ("4:3", "Quer 4:3"), ("3:4", "Hoch 3:4"),
    ]

    /// Listenpreise Singapur (Stand September 2026), US-Dollar. `nil`, wenn das Modell unbekannt ist.
    func estimatedCost(_ kind: MediaKind) -> Double? {
        switch kind {
        case .image:
            let perImage: [String: Double] = [
                "qwen-image-3.0-pro": 0.075, "qwen-image-3.0": 0.03, "qwen-image-2.0-pro": 0.075, "qwen-image-2.0": 0.035,
                "qwen-image-max": 0.075, "qwen-image-plus": 0.03, "qwen-image": 0.035,
                "qwen-image-edit-max": 0.075, "qwen-image-edit-plus": 0.03, "qwen-image-edit": 0.045,
            ]
            return perImage[imageModel]
        case .video:
            let flash = textToVideoModel.contains("flash")
            let perSecond = videoResolution == "1080P" ? (flash ? 0.075 : 0.15) : (flash ? 0.05 : 0.10)
            return perSecond * Double(videoDuration)
        }
    }
}

/// Client für Alibaba Model Studio (DashScope): Qwen-Image und Wan-Video.
/// Der API-Schlüssel wird aus der OpenCode-Verbindung „Alibaba“ oder aus DASHSCOPE_API_KEY gelesen.
struct DashScopeClient: Sendable {
    enum Failure: LocalizedError {
        case missingKey(String)
        case api(String)
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .missingKey(let provider):
                "Kein Alibaba-Schlüssel gefunden. Verbinde in den Einstellungen → Modelle den Anbieter „\(provider == "alibaba" ? "Alibaba" : "Alibaba (China)")“ oder setze DASHSCOPE_API_KEY."
            case .api(let message): "Alibaba meldet: \(message)"
            case .unexpected(let message): message
            }
        }
    }

    let settings: MediaSettings
    let key: String

    init(settings: MediaSettings) throws {
        self.settings = settings
        guard let key = Self.apiKey(provider: settings.region.providerID) else {
            throw Failure.missingKey(settings.region.providerID)
        }
        self.key = key
    }

    /// Schlüssel aus `~/.local/share/opencode/auth.json` (dort speichert OpenCode verbundene Anbieter) oder aus der Umgebung.
    static func apiKey(provider: String) -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/opencode/auth.json")
        if let data = try? Data(contentsOf: file),
           let json = try? JSONDecoder().decode([String: JSONValue].self, from: data),
           let key = json[provider]?["key"]?.stringValue, !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"]
    }

    // MARK: Bild

    /// Erzeugt ein Bild (oder bearbeitet `input`) und gibt die – zeitlich begrenzte – Ergebnis-URL zurück.
    func image(prompt: String, input: String?) async throws -> URL {
        var content: [[String: String]] = []
        if let input { content.append(["image": input]) }
        content.append(["text": prompt])
        // Beim Bearbeiten übernimmt das Ergebnis das Seitenverhältnis des Eingabebilds.
        var parameters: [String: Any] = ["watermark": false, "prompt_extend": true, "n": 1]
        if input == nil { parameters["size"] = settings.imageSize }
        let body: [String: Any] = [
            "model": input == nil ? settings.imageModel : settings.imageEditModel,
            "input": ["messages": [["role": "user", "content": content]]],
            "parameters": parameters,
        ]
        let json = try await post("/api/v1/services/aigc/multimodal-generation/generation", body: body, async: false)
        guard case .array(let choices) = json["output"]?["choices"],
              case .array(let items) = choices.first?["message"]?["content"],
              let urlString = items.compactMap({ $0["image"]?.stringValue }).first,
              let url = URL(string: urlString)
        else { throw Failure.unexpected("Die Antwort enthielt kein Bild.") }
        return url
    }

    // MARK: Video

    /// Erzeugt ein Video (aus Text oder aus dem Bild `input`). Dauert meist 1–5 Minuten.
    func video(prompt: String, input: String?, progress: @Sendable @escaping (String) -> Void) async throws -> URL {
        let model = input == nil ? settings.textToVideoModel : settings.imageToVideoModel
        // Ab Wan 2.7: Seitenverhältnis als `ratio`, Startbild im `media`-Feld. Ältere Modelle: `size` bzw. `img_url`.
        let modern = !model.hasPrefix("wan2.6") && !model.hasPrefix("wan2.5") && !model.hasPrefix("wan2.2") && !model.hasPrefix("wan2.1")
        var inputBody: [String: Any] = ["prompt": prompt]
        var parameters: [String: Any] = [
            "duration": settings.videoDuration, "prompt_extend": true, "watermark": false, "resolution": settings.videoResolution,
        ]
        if let input {
            if modern { inputBody["media"] = [["type": "first_frame", "url": input]] } else { inputBody["img_url"] = input }
        } else if modern {
            parameters["ratio"] = settings.videoRatio
        } else {
            parameters.removeValue(forKey: "resolution")
            parameters["size"] = Self.legacySize(ratio: settings.videoRatio, resolution: settings.videoResolution)
        }
        let body: [String: Any] = ["model": model, "input": inputBody, "parameters": parameters]
        let created = try await post("/api/v1/services/aigc/video-generation/video-synthesis", body: body, async: true)
        guard let taskID = created["output"]?["task_id"]?.stringValue else {
            throw Failure.unexpected("Alibaba hat keine Auftragsnummer zurückgegeben.")
        }

        // Status abfragen, bis das Video fertig ist (max. 15 Minuten).
        let started = Date()
        while Date().timeIntervalSince(started) < 15 * 60 {
            try await Task.sleep(for: .seconds(10))
            let task = try await get("/api/v1/tasks/\(taskID)")
            let status = task["output"]?["task_status"]?.stringValue ?? "UNKNOWN"
            switch status {
            case "SUCCEEDED":
                guard let urlString = task["output"]?["video_url"]?.stringValue, let url = URL(string: urlString) else {
                    throw Failure.unexpected("Das Video ist fertig, aber es fehlt die Adresse.")
                }
                return url
            case "FAILED", "CANCELED", "UNKNOWN":
                throw Failure.api(task["output"]?["message"]?.stringValue ?? "Videoerzeugung fehlgeschlagen (\(status)).")
            case "PENDING":
                progress("in der Warteschlange")
            default:
                progress("Video wird erzeugt")
            }
        }
        throw Failure.unexpected("Die Videoerzeugung hat länger als 15 Minuten gedauert.")
    }

    private static func legacySize(ratio: String, resolution: String) -> String {
        let hd = resolution == "1080P"
        switch ratio {
        case "9:16": return hd ? "1080*1920" : "720*1280"
        case "1:1": return hd ? "1440*1440" : "960*960"
        case "4:3": return hd ? "1632*1248" : "1088*832"
        case "3:4": return hd ? "1248*1632" : "832*1088"
        default: return hd ? "1920*1080" : "1280*720"
        }
    }

    // MARK: Transport

    private func post(_ path: String, body: [String: Any], async: Bool) async throws -> JSONValue {
        var request = URLRequest(url: settings.region.baseURL.appending(path: path), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if async { request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func get(_ path: String) async throws -> JSONValue {
        var request = URLRequest(url: settings.region.baseURL.appending(path: path), timeoutInterval: 60)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = json["message"]?.stringValue ?? json["code"]?.stringValue ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure.api("\(message) (HTTP \(http.statusCode))")
        }
        if let code = json["code"]?.stringValue, !code.isEmpty, json["output"] == nil {
            throw Failure.api(json["message"]?.stringValue ?? code)
        }
        return json
    }
}
