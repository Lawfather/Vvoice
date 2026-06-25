import Foundation

struct ChatMessage: Codable {
    let role: String
    let content: String
}

/// Minimal OpenRouter chat client. Mirrors the web app's request format and its
/// 429 retry behaviour (free/cheap pools get briefly throttled upstream).
struct OpenRouterClient {

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    func send(messages: [ChatMessage],
              model: String,
              apiKey: String,
              temperature: Double = 1.0,
              maxTokens: Int = 500) async throws -> String {

        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw APIError(message: "Enter and save your OpenRouter API key first.")
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false
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
                throw APIError(message: "No response from the server.")
            }

            // Honor transient rate limits with a short, capped backoff.
            if http.statusCode == 429 && attempt < maxRetries {
                attempt += 1
                let wait = min(retryAfter(data: data, response: http) ?? Double(attempt) * 2, 20)
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }

            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 429 {
                    throw APIError(message: "Model is rate-limited right now. Wait a moment, or pick another model in Settings.")
                }
                throw APIError(message: parseError(data) ?? "API error \(http.statusCode).")
            }

            guard let content = parseContent(data) else {
                throw APIError(message: "Couldn't read the model's reply.")
            }
            return content
        }
    }

    // MARK: - JSON helpers

    private func parseContent(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
