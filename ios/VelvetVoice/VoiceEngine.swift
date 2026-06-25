import Foundation
import AVFoundation
import Speech

/// Drives the hands-free loop: listen (SFSpeechRecognizer) -> think (OpenRouter)
/// -> speak (AVSpeechSynthesizer) -> listen again. Audio routes through the
/// built-in speaker or a connected Bluetooth headset/car automatically.
@MainActor
final class VoiceEngine: NSObject, ObservableObject {

    enum Status: String {
        case idle      = "Ready"
        case listening = "Listening…"
        case thinking  = "Thinking…"
        case speaking  = "Speaking…"
        case error     = "Error"
    }

    struct Turn: Identifiable {
        let id = UUID()
        let role: String      // "user" or "assistant"
        let text: String
    }

    @Published var status: Status = .idle
    @Published var isActive = false
    @Published var transcript: [Turn] = []
    @Published var liveText = ""
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private let synth = AVSpeechSynthesizer()
    private let client = OpenRouterClient()

    private var conversation: [ChatMessage] = []   // history sent to the API
    private var silenceTimer: Timer?
    private var latestText = ""

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Public control

    func startVoice() {
        requestPermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.fail("Microphone and Speech Recognition permission are required. Enable them in Settings ▸ VelvetVoice.")
                return
            }
            self.conversation = [ChatMessage(role: "system", content: Settings.persona)]
            self.transcript.removeAll()
            self.isActive = true
            self.configureSession()
            self.beginListening()
        }
    }

    func stopVoice() {
        isActive = false
        stopListening()
        synth.stopSpeaking(at: .immediate)
        deactivateSession()
        liveText = ""
        status = .idle
    }

    /// Send a typed message (works whether or not the voice loop is running).
    func sendTyped(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if conversation.isEmpty {
            conversation = [ChatMessage(role: "system", content: Settings.persona)]
        }
        configureSession()                 // ensure TTS output (and Bluetooth) is ready
        transcript.append(Turn(role: "user", text: t))
        status = .thinking
        Task { await self.handle(userText: t) }
    }

    // MARK: - Permissions

    private func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            AVAudioApplication.requestRecordPermission { micGranted in
                DispatchQueue.main.async {
                    done(speechStatus == .authorized && micGranted)
                }
            }
        }
    }

    // MARK: - Audio session (Bluetooth-aware)

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord + .allowBluetooth gives two-way audio over a Bluetooth
            // headset/car (HFP); .defaultToSpeaker keeps it loud on a bare phone.
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            fail("Audio session error: \(error.localizedDescription)")
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Listening

    private func beginListening() {
        guard isActive else { return }
        stopListening()

        guard let recognizer, recognizer.isAvailable else {
            fail("Speech recognition is not available right now.")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        latestText = ""

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [req] buffer, _ in
            req.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            fail("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        status = .listening

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.latestText = result.bestTranscription.formattedString
                    self.liveText = self.latestText
                    self.resetSilenceTimer()
                }
                if error != nil {
                    // Transient recognizer error: restart if we're still meant to listen.
                    if self.isActive && !self.synth.isSpeaking && self.status == .listening {
                        self.beginListening()
                    }
                }
            }
        }
    }

    private func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Treat ~1.2s of no new words as "the user finished talking".
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishUtterance() }
        }
    }

    private func finishUtterance() {
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !text.isEmpty else { return }
        stopListening()
        liveText = ""
        transcript.append(Turn(role: "user", text: text))
        status = .thinking
        Task { await self.handle(userText: text) }
    }

    // MARK: - Model call

    private func handle(userText: String) async {
        conversation.append(ChatMessage(role: "user", content: userText))
        do {
            let reply = try await client.send(messages: conversation,
                                              model: Settings.model,
                                              apiKey: Settings.apiKey)
            conversation.append(ChatMessage(role: "assistant", content: reply))
            trimHistory()
            transcript.append(Turn(role: "assistant", text: reply))
            speak(reply)
        } catch {
            // Roll back the optimistic user turn so history stays alternating.
            if conversation.last?.role == "user" { conversation.removeLast() }
            fail(error.localizedDescription)
            if isActive { beginListening() }   // keep the loop alive after a hiccup
        }
    }

    private func trimHistory() {
        guard conversation.count > 18 else { return }
        let system = conversation[0]
        var tail = Array(conversation.suffix(16))
        while let first = tail.first, first.role != "user" { tail.removeFirst() }
        conversation = [system] + tail
    }

    // MARK: - Speaking

    private func speak(_ text: String) {
        status = .speaking
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.1
        if let voice = bestVoice() { utterance.voice = voice }
        synth.speak(utterance)
    }

    private func bestVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        if let premium  = english.first(where: { $0.quality == .premium })  { return premium }
        if let enhanced = english.first(where: { $0.quality == .enhanced }) { return enhanced }
        return english.first(where: { $0.name.contains("Samantha") }) ?? english.first
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        errorMessage = message
        if status != .speaking { status = .error }
    }
}

// MARK: - Speech finished -> resume listening

extension VoiceEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isActive else {
                if self.status == .speaking { self.status = .idle }
                return
            }
            self.beginListening()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.isActive && self.status == .speaking { self.status = .idle }
        }
    }
}
