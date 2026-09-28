import AVFoundation
import Foundation
import Observation
import Speech

/// All microphone access starts in begin(), called only by the user's microphone button.
/// Recognition callback payloads are copied into Sendable values before returning to the main actor.
@MainActor @Observable
final class DictationController {
    enum Phase: Equatable {
        case idle, authorizing, recording, finishing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var notice: String?
    var isActive: Bool { phase == .authorizing || phase == .recording || phase == .finishing }
    var isRecording: Bool { phase == .recording }
    var isError: Bool { if case .failed = phase { return true }; return false }
    var statusText: String? {
        switch phase {
        case .idle: return notice
        case .authorizing: return "正在等待麦克风与语音识别授权…"
        case .recording: return "正在听写 · 点击麦克风结束"
        case .finishing: return "录音已停止，正在完成识别…"
        case .failed(let message): return message
        }
    }

    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?
    @ObservationIgnored private var recordingLimit: Task<Void, Never>?
    @ObservationIgnored private var finishDeadline: Task<Void, Never>?
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var audioInput: AVAudioInputNode?
    @ObservationIgnored private var audioSink: DictationAudioSink?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var tapInstalled = false

    func begin(localeIdentifier: String = "") {
        guard !isActive else { return }
        releaseResources()
        generation = UUID()
        let token = generation
        transcript = ""
        notice = nil
        phase = .authorizing
        authorizationTask = Task { [weak self] in
            let microphone = await Self.microphonePermission()
            guard let self, self.generation == token, !Task.isCancelled else { return }
            guard microphone == .allowed else {
                self.fail(microphone == .restricted
                    ? "设备限制了麦克风访问，无法开始听写。"
                    : "麦克风未获授权。请在系统设置 → 隐私与安全性 → 麦克风中允许 Claudex Shell。")
                return
            }
            let speech = await Self.speechPermission()
            guard self.generation == token, !Task.isCancelled else { return }
            guard speech == .allowed else {
                self.fail(speech == .restricted
                    ? "设备限制了语音识别，无法开始听写。"
                    : "语音识别未获授权。请在系统设置 → 隐私与安全性 → 语音识别中允许 Claudex Shell。")
                return
            }
            self.startRecording(localeIdentifier: localeIdentifier, token: token)
        }
    }

    /// Stops capture immediately. Buffered speech can finish for up to three seconds.
    func finish() {
        guard phase == .recording else { cancel(); return }
        phase = .finishing
        stopCapture()
        recognitionTask?.finish()
        let token = generation
        finishDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.generation == token, self.phase == .finishing else { return }
            if self.transcript.isEmpty { self.fail("未识别到语音，请重试并检查麦克风输入。") }
            else { self.complete(message: "听写已结束，已保留识别文字。") }
        }
    }

    /// Cancels permission/startup, audio capture, and recognition without discarding inserted text.
    func cancel(message: String? = nil) {
        generation = UUID()
        releaseResources()
        phase = .idle
        transcript = ""
        notice = message
    }

    func clearNotice() {
        if !isActive { phase = .idle; notice = nil }
    }

    private func startRecording(localeIdentifier: String, token: UUID) {
        guard let recognizer = localeIdentifier.isEmpty ? SFSpeechRecognizer() : SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            fail("系统不支持所选听写语言。可在麦克风菜单中选择中文或 English。")
            return
        }
        guard recognizer.isAvailable else {
            fail("系统语音识别暂不可用。请检查网络或稍后重试。")
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("没有可用的麦克风输入。请在系统设置 → 声音中选择输入设备。")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        // Apple documents that this flag can be honored only when the recognizer supports it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let sink = DictationAudioSink(request: request)
        self.recognizer = recognizer
        audioEngine = engine
        audioInput = input
        audioSink = sink
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let recognizedText = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isActive else { return }
                if let recognizedText, !recognizedText.isEmpty { self.transcript = recognizedText }
                if final {
                    if self.transcript.isEmpty { self.fail("未识别到语音，请重试。") }
                    else { self.complete() }
                } else if let failure {
                    if self.phase == .finishing, !self.transcript.isEmpty { self.complete(message: "听写已结束，已保留识别文字。") }
                    else { self.fail("听写未完成：\(failure)") }
                }
            }
        }
        // The audio callback only feeds its synchronized sink, never main-actor UI state.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in sink.append(buffer) }
        tapInstalled = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.phase == .recording else { return }
                self.fail("麦克风设备发生变化，听写已停止。请选择输入设备后重试。")
            }
        }
        do {
            engine.prepare()
            try engine.start()
            phase = .recording
            recordingLimit = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(55)) } catch { return }
                guard let self, self.generation == token, self.phase == .recording else { return }
                self.finish()
            }
        } catch {
            fail("麦克风无法启动：\(error.localizedDescription)")
        }
    }

    private func stopCapture() {
        recordingLimit?.cancel(); recordingLimit = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        audioEngine?.stop()
        if tapInstalled { audioInput?.removeTap(onBus: 0); tapInstalled = false }
        audioSink?.finish()
        audioSink = nil
        audioInput = nil
        audioEngine = nil
    }

    private func releaseResources() {
        authorizationTask?.cancel(); authorizationTask = nil
        finishDeadline?.cancel(); finishDeadline = nil
        stopCapture()
        recognitionTask?.cancel(); recognitionTask = nil
        recognizer = nil
    }

    private func fail(_ message: String) {
        generation = UUID()
        releaseResources()
        phase = .failed(message)
        notice = nil
    }

    private func complete(message: String? = nil) {
        generation = UUID()
        releaseResources()
        phase = .idle
        notice = message
    }

    private enum Permission: Sendable { case allowed, denied, restricted }
    private static func microphonePermission() async -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .restricted: return .restricted
        case .denied: return .denied
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable allowed in continuation.resume(returning: allowed ? .allowed : .denied) }
            }
        @unknown default: return .denied
        }
    }
    private nonisolated static func speechPermissionValue(_ status: SFSpeechRecognizerAuthorizationStatus) -> Permission {
        switch status {
        case .authorized: return .allowed
        case .restricted: return .restricted
        default: return .denied
        }
    }
    private static func speechPermission() async -> Permission {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status != .notDetermined { return speechPermissionValue(status) }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: speechPermissionValue(status))
            }
        }
    }
}

/// The request is shared only with AVAudioEngine's tap. Its lifetime and append/endAudio
/// calls are protected by one lock; no buffer or Speech object crosses into UI tasks.
private final class DictationAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        request?.endAudio()
        request = nil
    }
}
