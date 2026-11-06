import SwiftUI
import Speech
import AVFoundation
import FlickKit

/// Talk to Claude Code running on the Mac. Tap the mic, say it, tap again (or just stop talking).
struct AskView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var router: Router
    @StateObject private var ear = Listener()
    @State private var typed = ""
    @State private var lastPrompt = ""
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.faint).frame(width: 36, height: 5).padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !lastPrompt.isEmpty {
                            Text(lastPrompt)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.text)
                        } else if ear.listening {
                            Text(ear.transcript.isEmpty ? "Listening" : ear.transcript)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(ear.transcript.isEmpty ? Theme.dim : Theme.text)
                        }
                        ForEach(link.askLines.filter { $0.kind == .tool }.suffix(6)) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).padding(.top, 3)
                                Text(line.text).lineLimit(2)
                            }
                            .font(.system(size: 13).monospaced())
                            .foregroundStyle(Theme.dim)
                        }
                        if let answer = link.askAnswer {
                            Text(answer)
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.text)
                                .accessibilityIdentifier("ask.answer")
                                .id("answer")
                        } else if link.asking {
                            ProgressView().tint(Theme.dim).padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                }
                .onChange(of: link.askAnswer) { _, _ in withAnimation { proxy.scrollTo("answer") } }
            }

            Spacer(minLength: 0)

            if link.helperConnected {
                HStack(spacing: 10) {
                    TextField("Ask your Mac", text: $typed)
                        .focused($typing)
                        .submitLabel(.send)
                        .onSubmit { send(typed); typed = "" }
                        .font(.system(size: 16))
                        .padding(.horizontal, 18)
                        .frame(height: 52)
                        .glass(Capsule())
                        .accessibilityIdentifier("ask.field")
                    Button(action: micTapped) {
                        Image(systemName: link.asking ? "stop.fill" : (ear.listening ? "waveform" : "mic.fill"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(ear.listening || link.asking ? Theme.accent : Theme.text)
                            .frame(width: 52, height: 52)
                            .glass(Circle(), tint: ear.listening || link.asking ? Theme.accent.opacity(0.35) : nil, interactive: true)
                            .symbolEffect(.variableColor.iterative, isActive: ear.listening)
                    }
                    .accessibilityIdentifier("ask.mic")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background {
            ZStack {
                Color.black
                Rings(intensity: ear.listening ? 1.1 : (link.asking ? 0.7 : 0.18), speed: ear.listening ? 2.4 : 1)
                    .frame(height: 360)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: 120)
                    .animation(.easeInOut(duration: 0.4), value: ear.listening)
            }
            .ignoresSafeArea()
        }
        .overlay { if !link.helperConnected { needsMac } }
        .presentationDetents([.medium, .large])
        .presentationBackground(.black)
        .onAppear {
            link.onAnswer = { Speaker.shared.say($0) }
            if router.listenOnOpen { router.listenOnOpen = false; if link.helperConnected { startListening() } }
        }
        .onDisappear { ear.stop(); Speaker.shared.stop() }
        .onChange(of: ear.finished) { _, text in
            if let text, !text.isEmpty { send(text) }
        }
    }

    /// Claude runs on the Mac, so over plain Bluetooth there is nobody to ask.
    private var needsMac: some View {
        VStack(spacing: 18) {
            Image(systemName: "macbook")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.text)
                .frame(width: 76, height: 76)
                .glass(Circle())
            VStack(spacing: 6) {
                Text("Flick for Mac").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                Text("Claude runs on your Mac").font(.system(size: 15)).foregroundStyle(Theme.dim)
            }
            Button {
                Haptics.tap()
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { router.showMacPairing = true }
            } label: {
                Text("Pair").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 30).frame(height: 46)
                    .glass(Capsule(), tint: Theme.accent.opacity(0.35), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.pair")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.needsMac")
    }

    private func micTapped() {
        Haptics.tap()
        if link.asking { link.cancelAsk(); return }
        if ear.listening { ear.stop() } else { startListening() }
    }

    private func startListening() {
        Speaker.shared.stop()
        lastPrompt = ""
        typing = false
        ear.start()
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, link.helperConnected else { return }
        lastPrompt = t
        link.ask(t)
    }
}

/// On-device speech recognition; ends by itself after a short pause.
final class Listener: ObservableObject {
    @Published var transcript = ""
    @Published var listening = false
    @Published var finished: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: DispatchWorkItem?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    func start() {
        finished = nil
        transcript = ""
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard status == .authorized, granted else { return }
                    self.begin()
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { return }
        listening = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.armSilence()
                    if result.isFinal { self.stop() }
                }
                if error != nil, self.listening { self.stop() }
            }
        }
        armSilence(after: 6)
    }

    private func armSilence(after seconds: Double = 1.4) {
        silence?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        silence = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func stop() {
        guard listening else { return }
        listening = false
        silence?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        finished = transcript
    }
}

final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()

    func say(_ text: String) {
        guard Settings.speakAnswers else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.52
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}
