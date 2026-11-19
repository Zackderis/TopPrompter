import AVFoundation
import Speech
import CoreAudio
import AudioToolbox

/// Microphone capture: reports loudness (for Talk mode) and live transcripts (for Follow mode).
final class VoiceEngine {
    var onLevel: ((Float) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    var deviceID: AudioDeviceID?
    var contextualStrings: [String] = []

    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let lock = NSLock()
    private var generation = 0
    private var wantSpeech = false
    private var lastStart: CFTimeInterval = 0
    private var quickFailures = 0
    private(set) var running = false

    /// When set, an audio file stands in for the microphone (testing). Same path as the live mic.
    static var simulatedInput: URL?
    private var simTimer: Timer?

    private var takeFile: AVAudioFile?
    private var monoFormat: AVAudioFormat?

    /// Every mic buffer goes through here: mixed down to one channel (the recognizer only
    /// listens to the first channel, and some interfaces put the voice on the other side),
    /// saved to the take recording, measured, and handed to the recognizer.
    private func handleMicBuffer(_ buf: AVAudioPCMBuffer) {
        let mono = VoiceEngine.downmix(buf, &monoFormat)
        try? takeFile?.write(from: mono)
        lock.lock(); let req = request; lock.unlock()
        req?.append(mono)
        let db = VoiceEngine.rmsDB(mono)
        DispatchQueue.main.async { self.onLevel?(db) }
    }

    static func downmix(_ buf: AVAudioPCMBuffer, _ fmtCache: inout AVAudioFormat?) -> AVAudioPCMBuffer {
        let chs = Int(buf.format.channelCount)
        guard chs > 1, let src = buf.floatChannelData else { return buf }
        if fmtCache == nil || fmtCache!.sampleRate != buf.format.sampleRate {
            fmtCache = AVAudioFormat(standardFormatWithSampleRate: buf.format.sampleRate, channels: 1)
        }
        guard let f = fmtCache, let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: buf.frameLength),
              let dst = out.floatChannelData?[0] else { return buf }
        out.frameLength = buf.frameLength
        let n = Int(buf.frameLength)
        // Sum the channels (a voice on one side keeps full level; centred voice is averaged).
        var peak = [Float](repeating: 0, count: chs)
        for c in 0..<chs { for i in 0..<n { peak[c] = max(peak[c], abs(src[c][i])) } }
        let active = max(1, peak.filter { $0 > 0.0005 }.count)
        for i in 0..<n {
            var s: Float = 0
            for c in 0..<chs { s += src[c][i] }
            dst[i] = s / Float(active)
        }
        return out
    }

    /// Records what the mic hears to a file (this Mac only) so a take can be replayed for testing.
    var takeURL: URL?
    private func openTakeFile(sampleRate: Double) {
        guard let url = takeURL else { return }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        takeFile = try? AVAudioFile(forWriting: url, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func startSimulated(_ url: URL, speech: Bool) throws {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let chunk = AVAudioFrameCount(1024)
        running = true
        onLog?(String(format: "MIC (simulated from %@) started: %.0f Hz, %d channel(s)", url.lastPathComponent, fmt.sampleRate, fmt.channelCount))
        let interval = Double(chunk) / fmt.sampleRate
        let q = DispatchQueue(label: "sim-mic")
        q.async { [weak self] in
            var next = CACurrentMediaTime()
            while let self, self.running {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk),
                      (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else { break }
                self.handleMicBuffer(buf)
                next += interval
                let wait = next - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            DispatchQueue.main.async { self?.onLog?("MIC (simulated) finished") }
        }
        if speech { startRecognition() }
    }

    func start(speech: Bool) throws {
        stop()
        wantSpeech = speech
        quickFailures = 0
        if let sim = VoiceEngine.simulatedInput { try startSimulated(sim, speech: speech); return }
        let e = AVAudioEngine()
        let input = e.inputNode
        if var dev = deviceID, let au = input.audioUnit {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let fmt = input.outputFormat(forBus: 0)
        openTakeFile(sampleRate: fmt.sampleRate)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else {
            throw NSError(domain: "TopPrompter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The selected microphone isn't giving any audio."])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.handleMicBuffer(buf)
        }
        e.prepare()
        try e.start()
        engine = e
        running = true
        onLog?(String(format: "MIC started: %.0f Hz, %d channel(s)", fmt.sampleRate, fmt.channelCount))
        if speech { startRecognition() }
    }

    func stop() {
        if takeFile != nil { takeFile = nil; if let u = takeURL { onLog?("TAKE audio saved: \(u.path)") } }
        running = false
        generation += 1
        task?.cancel(); task = nil
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    static func rmsDB(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData, b.frameLength > 0 else { return -120 }
        let n = Int(b.frameLength)
        let p = ch[0]
        var sum: Float = 0
        for i in 0..<n { sum += p[i] * p[i] }
        return 10 * log10(max(sum / Float(n), 1e-12))
    }

    private func startRecognition() {
        guard running, wantSpeech else { return }
        let r = recognizer ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
        guard let r, r.isAvailable else { onError?("Speech recognition isn't available right now."); return }
        recognizer = r
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }   // private + no time limit
        onLog?("SPEECH session started (on-device: \(req.requiresOnDeviceRecognition), language \(r.locale.identifier))")
        req.taskHint = .dictation
        req.contextualStrings = contextualStrings
        lock.lock(); request = req; lock.unlock()
        generation += 1
        let gen = generation
        lastStart = CACurrentMediaTime()
        task = r.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.running, gen == self.generation else { return }
                if let result { self.onTranscript?(result.bestTranscription.formattedString) }
                if let error { self.onLog?("SPEECH session ended: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)") }
                else if result?.isFinal ?? false { self.onLog?("SPEECH session finished (final result)") }
                if error != nil || (result?.isFinal ?? false) { self.restartRecognition(failed: error != nil) }
            }
        }
    }

    /// Start a fresh recognition session so earlier words can't pull the place back (used on Restart).
    private var lastReset: CFTimeInterval = 0
    private var restartPending = false
    func resetTranscript() {
        guard running, wantSpeech else { return }
        let now = CACurrentMediaTime()
        guard now - lastReset > 1.0 else { return }      // never more than once a second
        lastReset = now
        onLog?("SPEECH reset (fresh listening after a jump)")
        restartRecognition(failed: false)
    }

    /// Recognition sessions end on long silences; quietly start a fresh one.
    private func restartRecognition(failed: Bool) {
        if failed && CACurrentMediaTime() - lastStart < 1.5 {
            quickFailures += 1
            if quickFailures >= 5 {
                onError?("Speech recognition keeps failing. Check System Settings → Privacy & Security → Speech Recognition, and that Dictation/Siri language is installed.")
                return
            }
        } else { quickFailures = 0 }
        generation += 1
        task?.cancel(); task = nil
        lock.lock(); request?.endAudio(); request = nil; lock.unlock()
        guard !restartPending else { return }          // one restart at a time
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.restartPending = false
            self?.startRecognition()
        }
    }

    // MARK: permissions

    static func requestPermissions(speech: Bool, completion: @escaping (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            guard ok else {
                DispatchQueue.main.async { completion("TopPrompter needs microphone access. Turn it on in System Settings → Privacy & Security → Microphone.") }
                return
            }
            guard speech else { DispatchQueue.main.async { completion(nil) }; return }
            SFSpeechRecognizer.requestAuthorization { st in
                DispatchQueue.main.async {
                    completion(st == .authorized ? nil
                               : "Follow mode needs Speech Recognition. Turn it on in System Settings → Privacy & Security → Speech Recognition.")
                }
            }
        }
    }

    // MARK: input devices

    static func defaultInputName() -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return "unknown" }
        return inputDevices().first { $0.id == id }?.name ?? "device \(id)"
    }

    struct InputDevice { let id: AudioDeviceID; let name: String; let uid: String }

    static func inputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                               mScope: kAudioDevicePropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr, s > 0 else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(s), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, raw) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            guard list.reduce(0, { $0 + Int($1.mNumberChannels) }) > 0 else { return nil }
            return InputDevice(id: id, name: stringProp(id, kAudioObjectPropertyName) ?? "Microphone \(id)",
                               uid: stringProp(id, kAudioDevicePropertyDeviceUID) ?? "\(id)")
        }
    }

    private static func stringProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var s = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &s, $0) }
        guard st == noErr, let v = value else { return nil }
        return v as String
    }
}
