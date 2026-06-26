import SwiftUI

struct ContentView: View {
    @StateObject private var engine = VoiceEngine()

    @State private var apiKey   = Settings.apiKey
    @State private var modelID  = Settings.model
    @State private var persona  = Settings.persona
    @State private var typed    = ""
    @State private var showSettings = true

    // Voice + turn-taking
    @State private var useCloudVoice = (Settings.voiceProvider != "apple")
    @State private var ttsID    = Settings.ttsModel
    @State private var silence  = Settings.silenceSeconds
    @State private var pushToTalk = Settings.pushToTalk

    private let accent = Color(red: 0.75, green: 0.15, blue: 0.83)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusPill
                    settingsCard
                    controls
                    transcriptCard
                    typeRow
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("VelvetVoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(Color.black.ignoresSafeArea())
        }
        .tint(accent)
        .alert("Notice",
               isPresented: Binding(get: { engine.errorMessage != nil },
                                    set: { if !$0 { engine.errorMessage = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(engine.errorMessage ?? "")
        }
    }

    // MARK: status

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(engine.status.rawValue)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(Model.named(modelID).name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.white.opacity(0.06), in: Capsule())
    }

    private var statusColor: Color {
        switch engine.status {
        case .listening: return .green
        case .thinking:  return .yellow
        case .speaking:  return accent
        case .error:     return .red
        case .idle:      return .gray
        }
    }

    // MARK: settings

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation { showSettings.toggle() }
            } label: {
                HStack {
                    Label("Configuration", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Image(systemName: showSettings ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.primary)

            if showSettings {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OPENROUTER API KEY").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        SecureField("sk-or-...", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.footnote, design: .monospaced))
                        Button("Save") {
                            Settings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            hideKeyboard()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Text("Key is stored only on this device.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("MODEL (uncensored, tested working)").font(.caption2).foregroundStyle(.secondary)
                    Picker("Model", selection: $modelID) {
                        ForEach(Model.all) { m in Text(m.name).tag(m.id) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: modelID) { _, newValue in Settings.model = newValue }
                    Text(Model.named(modelID).note)
                        .font(.caption2).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("PERSONA / SYSTEM PROMPT").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset default") {
                            persona = Settings.defaultPersona
                            Settings.persona = persona
                        }
                        .font(.caption2)
                    }
                    TextEditor(text: $persona)
                        .frame(minHeight: 90)
                        .font(.footnote)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: persona) { _, newValue in Settings.persona = newValue }
                }

                // VOICE
                VStack(alignment: .leading, spacing: 6) {
                    Text("VOICE").font(.caption2).foregroundStyle(.secondary)
                    Picker("Voice source", selection: $useCloudVoice) {
                        Text("Cloud (better)").tag(true)
                        Text("Apple (free)").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: useCloudVoice) { _, v in
                        Settings.voiceProvider = v ? "openrouter" : "apple"
                    }
                    if useCloudVoice {
                        Picker("TTS voice", selection: $ttsID) {
                            ForEach(TTSOption.all) { o in Text(o.name).tag(o.id) }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: ttsID) { _, id in
                            let o = TTSOption.named(id)
                            Settings.ttsModel = o.id
                            Settings.ttsVoice = o.voice
                        }
                        Text(TTSOption.named(ttsID).note)
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Uses the phone's built-in voice — free, offline, instant.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                // TURN-TAKING
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $pushToTalk) {
                        Text("PUSH-TO-TALK").font(.caption2).foregroundStyle(.secondary)
                    }
                    .onChange(of: pushToTalk) { _, v in Settings.pushToTalk = v }
                    Text(pushToTalk
                         ? "Hold the button to talk; it replies when you let go."
                         : "Auto mode: it replies after you pause.")
                        .font(.caption2).foregroundStyle(.secondary)

                    if !pushToTalk {
                        HStack {
                            Text("PATIENCE").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1fs", silence))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Slider(value: $silence, in: 0.8...4.0, step: 0.1)
                            .onChange(of: silence) { _, v in Settings.silenceSeconds = v }
                        Text("How long it waits after you stop talking before replying.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    // MARK: talk controls

    @ViewBuilder
    private var controls: some View {
        if engine.isActive && pushToTalk {
            VStack(spacing: 10) {
                holdToTalkButton
                stopButton
            }
        } else {
            startStopButton
        }
    }

    private var startStopButton: some View {
        Button {
            if engine.isActive { engine.stopVoice() } else { engine.startVoice() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: engine.isActive ? "stop.fill" : "mic.fill")
                Text(engine.isActive ? "STOP VOICE CHAT" : "START VOICE CHAT")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                LinearGradient(colors: engine.isActive
                               ? [.green, .teal]
                               : [accent, .pink],
                               startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 22))
            .foregroundStyle(.white)
        }
    }

    private var stopButton: some View {
        Button { engine.stopVoice() } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                Text("STOP").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(.white)
        }
    }

    private var holdToTalkButton: some View {
        let listening = engine.status == .listening
        return Text(listening ? "● LISTENING — release to send" : "HOLD TO TALK")
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(
                LinearGradient(colors: listening ? [.green, .teal] : [accent, .pink],
                               startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 22))
            .foregroundStyle(.white)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if engine.status != .listening { engine.pttPress() }
                    }
                    .onEnded { _ in engine.pttRelease() }
            )
    }

    // MARK: transcript

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if engine.transcript.isEmpty && engine.liveText.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.largeTitle).foregroundStyle(accent.opacity(0.6))
                    Text("Press Start and just talk — it listens, replies, and speaks back.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(engine.transcript) { turn in
                    bubble(turn)
                }
                if !engine.liveText.isEmpty {
                    bubble(VoiceEngine.Turn(role: "user", text: engine.liveText), live: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)))
    }

    private func bubble(_ turn: VoiceEngine.Turn, live: Bool = false) -> some View {
        let isUser = turn.role == "user"
        return HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(isUser ? "YOU" : "VELVET")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(turn.text)
                    .font(.callout)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                (isUser ? Color.blue.opacity(live ? 0.35 : 0.65)
                        : accent.opacity(0.55)),
                in: RoundedRectangle(cornerRadius: 16))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    // MARK: typed fallback

    private var typeRow: some View {
        HStack {
            TextField("Or type a message…", text: $typed)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(.white.opacity(0.06), in: Capsule())
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .padding(12)
                    .background(accent, in: Circle())
                    .foregroundStyle(.white)
            }
        }
    }

    private func send() {
        let text = typed
        typed = ""
        engine.sendTyped(text)
        hideKeyboard()
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

#Preview {
    ContentView().preferredColorScheme(.dark)
}
