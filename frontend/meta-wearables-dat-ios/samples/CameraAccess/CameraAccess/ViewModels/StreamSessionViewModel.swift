import AVFoundation
import MWDATCamera
import MWDATCore
import Speech
import SwiftUI

@MainActor
final class GlassesManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentFrame: UIImage?
    @Published private(set) var isStreaming = false
    @Published private(set) var isConnected = false
    @Published private(set) var statusMessage = "Waiting for glasses..."

    // MARK: - SDK

    private let wearables: WearablesInterface
    private let deviceSelector: AutoDeviceSelector
    private var deviceSession: DeviceSession?
    private var streamSession: StreamSession?

    private var stateListenerToken: AnyListenerToken?
    private var frameListenerToken: AnyListenerToken?
    private var errorListenerToken: AnyListenerToken?
    private var photoListenerToken: AnyListenerToken?
    private var deviceMonitorTask: Task<Void, Never>?

    // MARK: - Retry State

    private var streamStartAttempt = 0
    private let maxStreamAttempts = 6
    private let retryDelays = [3.0, 6.0, 10.0, 15.0, 20.0, 30.0]

    // MARK: - Speech

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false
    private var speechActive = false
    private var lastTriggerDate: Date = .distantPast

    private let wakePhrase = "computa how much is this worth"
    private let wakePhraseAlternates = [
        "computer how much is this worth",
        "compute how much is this worth",
        "computa how much is it worth",
        "computer how much is it worth",
    ]

    // MARK: - Init

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
        startDeviceMonitoring()
    }

    deinit {
        deviceMonitorTask?.cancel()
    }

    // MARK: - Public API

    func startStreaming() {
        streamStartAttempt = 0
        Task { await startStream() }
    }

    func stopStreaming() {
        Task { await teardownStream() }
    }

    func capturePhoto() {
        guard isStreaming else { return }
        let ok = streamSession?.capturePhoto(format: .jpeg) ?? false
        if !ok { print("[PIR] GlassesManager: capturePhoto call failed") }
    }

    // MARK: - Device Monitoring

    private func startDeviceMonitoring() {
        deviceMonitorTask = Task { [weak self] in
            guard let self else { return }
            for await device in deviceSelector.activeDeviceStream() {
                if device != nil {
                    print("[PIR] GlassesManager: device appeared, waiting 2s before streaming")
                    statusMessage = "Glasses connected…"
                    isConnected = true
                    streamStartAttempt = 0
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await startStream()
                } else {
                    print("[PIR] GlassesManager: device lost")
                    isConnected = false
                    statusMessage = "Waiting for glasses..."
                    await teardownStream()
                }
            }
        }
    }

    // MARK: - Stream Lifecycle

    private func startStream() async {
        guard !isStreaming else { return }
        statusMessage = "Connecting…"

        // Create device session if needed
        if deviceSession == nil || deviceSession?.state == .stopped {
            deviceSession = nil
            do {
                let session = try wearables.createSession(deviceSelector: deviceSelector)
                deviceSession = session
                try session.start()
                for await state in session.stateStream() {
                    if state == .started { break }
                    if state == .stopped {
                        statusMessage = "Device session failed"
                        return
                    }
                }
            } catch {
                print("[PIR] GlassesManager: device session error — \(error)")
                statusMessage = "Connection error"
                return
            }
        }

        guard let deviceSession, deviceSession.state == .started else { return }

        // Camera permission
        do {
            var status = try await wearables.checkPermissionStatus(.camera)
            if status != .granted {
                status = try await wearables.requestPermission(.camera)
            }
            guard status == .granted else {
                statusMessage = "Camera permission denied"
                return
            }
        } catch {
            print("[PIR] GlassesManager: permission error — \(error)")
            statusMessage = "Permission error"
            return
        }

        // Create and start stream
        let config = StreamSessionConfig(videoCodec: .raw, resolution: .medium, frameRate: 30)
        guard let stream = try? deviceSession.addStream(config: config) else {
            statusMessage = "Failed to create stream"
            return
        }
        streamSession = stream
        attachListeners(to: stream)
        await stream.start()
    }

    private func teardownStream() async {
        stopSpeechRecognition()
        clearListeners()
        let stream = streamSession
        streamSession = nil
        if let stream { await stream.stop() }
        currentFrame = nil
        isStreaming = false
    }

    // MARK: - Stream Listeners

    private func attachListeners(to stream: StreamSession) {
        stateListenerToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in self?.handleStreamState(state) }
        }
        frameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor [weak self] in self?.currentFrame = frame.makeUIImage() }
        }
        errorListenerToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in print("[PIR] GlassesManager: stream error — \(error)") }
        }
        photoListenerToken = stream.photoDataPublisher.listen { [weak self] data in
            Task { @MainActor [weak self] in self?.handlePhoto(data) }
        }
    }

    private func clearListeners() {
        stateListenerToken = nil
        frameListenerToken = nil
        errorListenerToken = nil
        photoListenerToken = nil
    }

    private func handleStreamState(_ state: StreamSessionState) {
        print("[PIR] GlassesManager: stream state → \(state)")
        switch state {
        case .streaming:
            streamStartAttempt = 0
            isStreaming = true
            statusMessage = "Streaming"
            startSpeechRecognition()
        case .stopped:
            let wasStreaming = isStreaming
            isStreaming = false
            currentFrame = nil
            stopSpeechRecognition()
            if wasStreaming || !isConnected || streamStartAttempt >= maxStreamAttempts {
                statusMessage = isConnected ? "Stopped — tap Start to retry" : "Waiting for glasses..."
            } else {
                scheduleRetry()
            }
        case .waitingForDevice, .starting:
            statusMessage = "Starting…"
        case .stopping:
            statusMessage = "Stopping…"
        case .paused:
            statusMessage = "Paused"
        @unknown default:
            break
        }
    }

    private func scheduleRetry() {
        streamStartAttempt += 1
        let delay = retryDelays[min(streamStartAttempt - 1, retryDelays.count - 1)]
        statusMessage = "Glasses not ready — retrying in \(Int(delay))s… (\(streamStartAttempt)/\(maxStreamAttempts))"
        print("[PIR] GlassesManager: error 11 — scheduling retry \(streamStartAttempt) in \(Int(delay))s")

        let oldStream = streamSession
        clearListeners()
        streamSession = nil

        Task { [weak self] in
            guard let self else { return }
            if let s = oldStream { await s.stop() }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.isConnected, !self.isStreaming else { return }
            await self.startStream()
        }
    }

    // MARK: - Photo & Backend

    private func handlePhoto(_ data: PhotoData) {
        print("[PIR] GlassesManager: photo captured (\(data.data.count) bytes)")
        Task { await postToBackend(jpegData: data.data) }
    }

    private func postToBackend(jpegData: Data) async {
        guard let url = URL(string: "http://localhost:8000/scan") else { return }
        let base64 = jpegData.base64EncodedString()
        let body: [String: Any?] = ["image_base64": base64, "user_id": Optional<String>.none]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            print("[PIR] /scan response: \(raw)")
        } catch {
            print("[PIR] GlassesManager: POST /scan failed — \(error)")
        }
    }

    // MARK: - Speech Recognition

    private func startSpeechRecognition() {
        guard !speechActive else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                print("[PIR] GlassesManager: speech auth denied (\(status.rawValue))")
                return
            }
            self?.beginSpeechSession()
        }
    }

    private func stopSpeechRecognition() {
        speechActive = false
        endSpeechSession()
    }

    private func beginSpeechSession() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }
        endSpeechSession()
        speechActive = true

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PIR] GlassesManager: audio session error — \(error)")
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        recognitionRequest = req

        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let text = result?.bestTranscription.formattedString {
                self.checkForWakePhrase(text)
            }
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard self?.speechActive == true else { return }
                    self?.beginSpeechSession()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }
        tapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("[PIR] GlassesManager: speech recognition active")
        } catch {
            print("[PIR] GlassesManager: audio engine failed — \(error)")
            endSpeechSession()
        }
    }

    private func checkForWakePhrase(_ transcript: String) {
        let lower = transcript.lowercased()
        let matched = lower.contains(wakePhrase) || wakePhraseAlternates.contains { lower.contains($0) }
        guard matched else { return }

        let now = Date()
        guard now.timeIntervalSince(lastTriggerDate) > 5 else { return }
        lastTriggerDate = now

        print("[PIR] GlassesManager: wake phrase detected in \"\(transcript)\"")
        Task { @MainActor [weak self] in self?.capturePhoto() }
    }

    private func endSpeechSession() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }
}
