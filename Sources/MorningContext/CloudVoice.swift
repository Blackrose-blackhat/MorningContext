import Foundation
import Security

/// ElevenLabs text-to-speech: natural voices from your own ElevenLabs account (Voice Library, Voice Design,
/// or your own clone). The API key lives in the macOS Keychain; nothing is sent unless a key is set.
enum ElevenLabs {
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
    }

    /// Low-latency model, built for conversational agents.
    static let model = "eleven_flash_v2_5"
    /// A stock ElevenLabs voice, used until you pick one in Settings.
    static let defaultVoiceId = "21m00Tcm4TlvDq8ikWAM"

    static var isConfigured: Bool { !apiKey.isEmpty }

    /// Whether a key was saved, without touching the Keychain (each read of a rebuilt app can prompt for your
    /// password). For display only; speaking still reads the real key.
    static var probablyConfigured: Bool { cachedKey.map { !$0.isEmpty } ?? Settings.defaults.bool(forKey: savedFlag) }
    private static let savedFlag = "elevenLabsKeySaved"

    /// Read from the Keychain once per launch: every read of an item can trigger macOS's
    /// "wants to use your confidential information" prompt, so never read it per sentence.
    private static var cachedKey: String?

    static var apiKey: String {
        get {
            if let cachedKey { return cachedKey }
            let k = Keychain.read(account: keyAccount) ?? ""
            cachedKey = k
            Settings.defaults.set(!k.isEmpty, forKey: savedFlag)
            return k
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard v != cachedKey else { return }
            if v.isEmpty { Keychain.delete(account: keyAccount) } else { Keychain.write(v, account: keyAccount) }
            cachedKey = v
            Settings.defaults.set(!v.isEmpty, forKey: savedFlag)
        }
    }

    static var voiceId: String {
        let v = Settings.defaults.string(forKey: Settings.Key.elevenLabsVoiceId) ?? ""
        return v.isEmpty ? defaultVoiceId : v
    }

    private static let keyAccount = "elevenlabs-api-key"
    private static let base = URL(string: "https://api.elevenlabs.io/v1")!

    /// Raw 16-bit 24 kHz PCM for one sentence (plays through the echo-cancelled engine without decoding).
    @discardableResult
    static func synthesize(_ text: String, completion: @escaping (Result<Data, Error>) -> Void) -> URLSessionDataTask? {
        let key = apiKey
        guard !key.isEmpty else { completion(.failure(err("No ElevenLabs API key"))); return nil }
        var comps = URLComponents(url: base.appendingPathComponent("text-to-speech/\(voiceId)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.8],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let task = URLSession.shared.dataTask(with: req) { data, resp, error in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<Data, Error>
            if let error { result = .failure(error) }
            else if status == 200, let data, !data.isEmpty { result = .success(data) }
            else { result = .failure(err(apiError(status: status, data: data))) }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }

    /// The voices in your ElevenLabs account (premade + ones you added from the Voice Library or designed).
    static func listVoices(key: String? = nil, completion: @escaping (Result<[Voice], Error>) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent("voices"), timeoutInterval: 15)
        req.setValue(key ?? apiKey, forHTTPHeaderField: "xi-api-key")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<[Voice], Error>
            if let error { result = .failure(error) }
            else if status == 200, let data,
                    let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let arr = obj["voices"] as? [[String: Any]] {
                result = .success(arr.compactMap { v in
                    guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
                    let labels = (v["labels"] as? [String: Any] ?? [:]).values.compactMap { $0 as? String }
                    let category = v["category"] as? String ?? ""
                    return Voice(id: id, name: name, detail: ([category] + labels).filter { !$0.isEmpty }.joined(separator: " · "))
                }.sorted { $0.name < $1.name })
            } else { result = .failure(err(apiError(status: status, data: data))) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func apiError(status: Int, data: Data?) -> String {
        let detail = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["detail"] as? [String: Any])?["message"] as? String ?? $0["detail"] as? String }
        switch status {
        case 401: return "ElevenLabs rejected the API key" + (detail.map { ": \($0)" } ?? ".")
        case 404: return "ElevenLabs couldn't find that voice. Pick another in Settings."
        case 429: return "ElevenLabs quota or rate limit reached" + (detail.map { ": \($0)" } ?? ".")
        default:  return "ElevenLabs error \(status)" + (detail.map { ": \($0)" } ?? "")
        }
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "ElevenLabs", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

/// Minimal generic-password Keychain wrapper.
enum Keychain {
    private static let service = "io.github.blackrose-blackhat.morningcontext"

    static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
