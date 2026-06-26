import Foundation

/// Calls OpenRouter's dedicated TTS endpoint (/api/v1/audio/speech) and returns the
/// raw audio bytes (mp3). Mirrors OpenRouterClient's headers and 429 retry behaviour.
struct OpenRouterTTS {

    struct TTSError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/speech")!

    /// Returns mp3 audio data for `text` spoken by `voice` on `model`.
    func synthesize(text: String,
                    model: String,
                    voice: String,
                    apiKey: String) async throws -> Data {

        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TTSError(message: "Missing OpenRouter API key.")
        }

        let payload: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "mp3"
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        let maxRetries = 3
        var attempt = 0

        while true {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("https://lawfather.github.io/Vvoice/", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("VelvetVoice iOS", forHTTPHeaderField: "X-Title")
            req.httpBody = body

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw TTSError(message: "No response from TTS server.")
            }

            if http.statusCode == 429 && attempt < maxRetries {
                attempt += 1
                let wait = min(retryAfter(data: data, response: http) ?? Double(attempt) * 2, 20)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }

            guard (200..<300).contains(http.statusCode) else {
                throw TTSError(message: parseError(data) ?? "TTS error \(http.statusCode).")
            }

            // Success: body is raw audio. Guard against an unexpected JSON error body.
            if let ct = http.value(forHTTPHeaderField: "Content-Type"),
               ct.localizedCaseInsensitiveContains("json") {
                throw TTSError(message: parseError(data) ?? "TTS returned no audio.")
            }
            guard !data.isEmpty else { throw TTSError(message: "TTS returned empty audio.") }
            return data
        }
    }

    private func parseError(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let msg = err["message"] as? String
        else { return nil }
        return msg
    }

    private func retryAfter(data: Data, response: HTTPURLResponse) -> Double? {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let v = Double(header) {
            return v
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let meta = err["metadata"] as? [String: Any],
           let ra = meta["retry_after_seconds"] as? Double {
            return ra
        }
        return nil
    }
}
