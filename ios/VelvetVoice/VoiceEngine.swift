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
    private let tts = OpenRouterTTS()
    private var audioPlayer: AVAudioPlayer?

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
            if Settings.pushToTalk {
                self.status = .idle          // ready — user holds the talk button
            } else {
                self.beginListening()
            }
        }
    }

    func stopVoice() {
        isActive = false
        stopListening()
        synth.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        deactivateSession()
        liveText = ""
        status = .idle
    }

    // MARK: - Push-to-talk

    /// Called when the user presses-and-holds the talk button. Interrupts any
    /// in-progress reply so you can barge in.
    func pttPress() {
        guard isActive else { return }
        audioPlayer?.stop(); audioPlayer = nil
        synth.stopSpeaking(at: .immediate)
        beginListening()
    }

    /// Called when the user releases the talk button — sends whatever was heard.
    func pttRelease() {
        guard isActive else { return }
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening()
        liveText = ""
        guard !text.isEmpty else { status = .idle; return }
        transcript.append(Turn(role: "user", text: text))
        status = .thinking
        Task { await self.handle(userText: text) }
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

    /// In auto mode, treat `Settings.silenceSeconds` of no new words as "done talking".
    /// In push-to-talk mode the button controls turn-end, so skip the timer entirely.
    private func resetSilenceTimer() {
        guard !Settings.pushToTalk else { return }
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: Settings.silenceSeconds, repeats: false) { [weak self] _ in
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
        if Settings.voiceProvider == "apple" {
            appleSpeak(text)
        } else {
            Task { await self.cloudSpeak(text) }
        }
    }

    /// OpenRouter TTS (Orpheus/etc.). Falls back to the on-device voice on any failure
    /// so a network blip still gets spoken aloud.
    private func cloudSpeak(_ text: String) async {
        do {
            let data = try await tts.synthesize(text: text,
                                                model: Settings.ttsModel,
                                                voice: Settings.ttsVoice,
                                                apiKey: Settings.apiKey)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            audioPlayer = player
            status = .speaking
            player.play()
        } catch {
            errorMessage = "Cloud voice unavailable (\(error.localizedDescription)). Using the phone's built-in voice."
            appleSpeak(text)
        }
    }

    private func appleSpeak(_ text: String) {
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

    /// Shared "finished talking" handler for BOTH the cloud audio player and the
    /// on-device synthesizer: resume the loop, or wait for the next push-to-talk press.
    private func onSpeechFinished() {
        audioPlayer = nil
        guard isActive else {
            if status == .speaking { status = .idle }
            return
        }
        if Settings.pushToTalk {
            status = .idle           // ready for the next hold-to-talk
        } else {
            beginListening()
        }
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        errorMessage = message
        if status != .speaking { status = .error }
    }
}

// MARK: - Speech finished -> resume listening

extension VoiceEngine: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    // On-device synthesizer finished.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onSpeechFinished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !self.isActive && self.status == .speaking { self.status = .idle }
        }
    }

    // Cloud TTS audio finished.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onSpeechFinished() }
    }
}
