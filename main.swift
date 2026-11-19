// TopPrompter — a small teleprompter that floats at the very top-center of your
// external display (above the menu bar), right under the camera.
// Modes: Manual (steady scroll), Talk (scrolls only while you're speaking),
// Follow (listens to your words and keeps your place in the script).
import Cocoa
import Carbon.HIToolbox
import UniformTypeIdentifiers
import AVFoundation
import Speech

// Self-tests use a separate settings store so they never touch your script or settings.
let isTestRun = CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--trace") || CommandLine.arguments.contains("--voicetest") || CommandLine.arguments.contains("--mictest")
let defaults = isTestRun ? UserDefaults(suiteName: "local.toolkit.TopPrompter.tests")! : UserDefaults.standard

enum Mode: Int, CaseIterable {
    case manual = 0, talk, follow
    var title: String { ["Manual", "Talk", "Follow"][rawValue] }
}

let sampleScript = """
Welcome to TopPrompter.

Click Edit (or press E), paste your script, then press Esc.

Pick a mode at the bottom. Manual scrolls at a steady speed. Talk scrolls only while you're speaking and stops when you go quiet. Follow listens to your words and keeps your place, even if you speed up, slow down or skip a line.

Press Space to play or pause. Up and Down change the speed. Plus and minus change the text size. R goes back to the start.

While another app is in front: Control Option P plays and pauses, Control Option R restarts, and Control Option M switches modes.
"""

/// Where logs go. On the machine this app was built on (the TopPrompter project folder exists) they stay
/// next to the code; on anyone else's Mac they go to ~/Library/Logs/TopPrompter and no take audio is saved.
let devFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/TopPrompter/build.sh")
let isDevMachine = FileManager.default.fileExists(atPath: devFolder.path)
let logsDir: URL = isDevMachine
    ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/TopPrompter/logs")
    : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/TopPrompter")

/// Plain-text log of what the voice modes hear and decide: ~/Downloads/TopPrompter/logs/voice-log.txt
final class VoiceLog {
    private var handle: FileHandle?
    private let start = CACurrentMediaTime()
    init(name: String) {
        let dir = logsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let prev = dir.appendingPathComponent(name.replacingOccurrences(of: ".txt", with: "-previous.txt"))
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: url, to: prev)                 // keep the last launch's log
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        write("TopPrompter started \(Date())")
    }
    func write(_ s: String) {
        let line = String(format: "%7.2f  ", CACurrentMediaTime() - start) + s + "\n"
        handle?.write(Data(line.utf8))
    }
}

// MARK: - Views

final class PrompterWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Allow sitting on top of the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class RootView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Bottom control bar; dragging its background moves the window.
final class DragBar: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Bottom-right grip. Resizes symmetrically so the window stays centered under the camera,
/// with the top edge pinned.
final class ResizeGrip: NSView {
    static let minSize = NSSize(width: 760, height: 130)
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.45).setStroke()
        let p = NSBezierPath(); p.lineWidth = 1.5
        for i in stride(from: 5.0, through: 15.0, by: 5.0) {
            p.move(to: NSPoint(x: bounds.maxX - i, y: 3)); p.line(to: NSPoint(x: bounds.maxX - 3, y: i))
        }
        p.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let m = NSEvent.mouseLocation
        var f = startFrame
        f.size.width = max(Self.minSize.width, startFrame.width + (m.x - startMouse.x) * 2)
        f.origin.x = startFrame.midX - f.width / 2
        f.size.height = max(Self.minSize.height, startFrame.height - (m.y - startMouse.y))
        f.origin.y = startFrame.maxY - f.height
        w.setFrame(f, display: true)
    }
}

/// Small dot: grey = mic off, dim green = listening, bright green = hearing you.
final class LevelDot: NSView {
    enum State { case off, listening, hearing }
    var state: State = .off { didSet { if state != oldValue { update() } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func update() {
        let c: NSColor
        switch state {
        case .off: c = NSColor(white: 1, alpha: 0)
        case .listening: c = NSColor.systemGreen.withAlphaComponent(0.35)
        case .hearing: c = NSColor.systemGreen
        }
        layer?.backgroundColor = c.cgColor
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSMenuDelegate {
    var window: PrompterWindow!
    var scrollView: NSScrollView!
    var textView: NSTextView!
    var toolbar: DragBar!
    var playButton: NSButton!
    var editButton: NSButton!
    var modeControl: NSSegmentedControl!
    var speedLabel: NSTextField!
    var levelDot: LevelDot!
    let fadeMask = CAGradientLayer()
    var link: CADisplayLink?
    var hotKeys: [EventHotKeyRef?] = []
    let micMenu = NSMenu(title: "Microphone")

    let voice = VoiceEngine()
    let follower = Follower()
    let phone = PhoneServer()
    let vlog = VoiceLog(name: CommandLine.arguments.contains("--voicetest") ? "voicetest-log.txt"
                        : CommandLine.arguments.contains("--mictest") ? "mictest-log.txt" : "voice-log.txt")
    var levelStats = (n: 0, sum: Float(0), max: Float(-120), heard: 0, lastReport: CACurrentMediaTime())
    var phonePolls = 0
    var scriptVersion = 1

    var mode = Mode(rawValue: defaults.integer(forKey: "mode")) ?? .manual
    var playing = false
    var editing = false
    var hovering = false
    var pos: CGFloat = 0           // scroll offset we're driving
    var vel: CGFloat = 0           // current scroll velocity (eases in/out)
    var followTarget: CGFloat = 0
    var lastTick: CFTimeInterval = 0
    var speed = CGFloat(defaults.object(forKey: "speed") as? Double ?? 45)       // points per second
    var fontSize = CGFloat(defaults.object(forKey: "fontSize") as? Double ?? 30)
    var sensitivity = Float(defaults.object(forKey: "sensitivity") as? Double ?? 10)  // dB above room noise
    var dimmedUpTo = 0
    var userScrolled = false

    // voice-activity detection
    var noiseFloor: Float = -60
    var lastVoiceAt: CFTimeInterval = 0
    var speaking = false

    let barH: CGFloat = 42
    let sideInset: CGFloat = 28

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        var frame = topCenter(NSSize(width: 820, height: 210), on: preferredScreen())
        if let s = defaults.string(forKey: "frame.v2") {
            let saved = NSRectFromString(s)
            if saved.width >= ResizeGrip.minSize.width,
               NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: saved.midX, y: saved.maxY - 1)) }) {
                frame = saved
            }
        }

        window = PrompterWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver                        // above the menu bar and other windows
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Ask screen recorders to leave it out (`defaults write local.toolkit.TopPrompter allowCapture -bool YES` to undo).
        window.sharingType = defaults.bool(forKey: "allowCapture") ? .readOnly : .none
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self

        let root = RootView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0, alpha: 0.95).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        root.onHover = { [weak self] h in self?.hovering = h; self?.updateToolbarVisibility() }
        window.contentView = root

        buildTextArea(in: root, frame: frame)
        buildToolbar(in: root, frame: frame)

        levelDot = LevelDot(frame: NSRect(x: 10, y: frame.height - 16, width: 8, height: 8))
        levelDot.autoresizingMask = [.minYMargin]
        root.addSubview(levelDot)

        follower.load(textView.string)
        applyStyle()
        updateInsets()
        textView.setFrameOrigin(.zero)
        restart()
        updateSpeedLabel()
        updatePlayButton()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e) ?? e }
        if !isTestRun { registerHotKeys() }

        voice.onLevel = { [weak self] db in self?.handleLevel(db) }
        voice.onTranscript = { [weak self] t in self?.handleTranscript(t) }
        voice.onError = { [weak self] msg in self?.vlog.write("ERROR \(msg)"); self?.setPlaying(false); self?.alert(msg) }
        voice.onLog = { [weak self] msg in self?.vlog.write(msg) }
        if !isTestRun && isDevMachine {
            voice.takeURL = logsDir.appendingPathComponent("last-take.wav")
        }

        phone.stateProvider = { [weak self] in
            self?.phonePolls += 1
            guard let self else { return PhoneServer.State(c: 0, playing: false, mode: 0, hearing: false, dim: 0, word: nil) }
            return PhoneServer.State(c: Double(self.readingChar()), playing: self.playing, mode: self.mode.rawValue,
                                     hearing: self.playing && self.mode != .manual && self.speaking,
                                     dim: self.mode == .follow ? max(0, self.dimmedUpTo) : 0,
                                     word: self.currentWordRange())
        }
        phone.scriptProvider = { [weak self] in (self?.scriptVersion ?? 0, self?.textView.string ?? "") }
        phone.onCommand = { [weak self] c in
            switch c {
            case "toggle": self?.togglePlay()
            case "restart": self?.restart()
            case "faster": self?.faster()
            case "slower": self?.slower()
            case "debug":
                if let s = self {
                    let tv = s.textView!, cv = s.scrollView.contentView
                    s.vlog.write("DEBUG textView.frame=\(NSStringFromRect(tv.frame)) bounds=\(NSStringFromRect(tv.bounds)) clip.bounds=\(NSStringFromRect(cv.bounds)) docRect=\(NSStringFromRect(cv.documentRect)) visible=\(NSStringFromRect(tv.visibleRect)) inset=\(tv.textContainerInset.height) startPos=\(s.startPos) maxScroll=\(s.maxScroll) font=\(s.fontSize) usedRect=\(NSStringFromRect(tv.layoutManager!.usedRect(for: tv.textContainer!)))")
                }
            default: break
            }
        }
        phone.onError = { [weak self] msg in self?.alert(msg) }
        if (defaults.bool(forKey: "phoneEnabled") && !isTestRun) || CommandLine.arguments.contains("--voicetest") { phone.start() }

        if isTestRun {
            // Test runs stay invisible and click-through so they can't catch your clicks or keys.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if CommandLine.arguments.contains("--voicetest") { runVoiceTest(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--mictest"), i + 1 < CommandLine.arguments.count {
            // Full live path (Follow mode, Play, mic tap, recognizer, scrolling) with a file as the mic.
            VoiceEngine.simulatedInput = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let script = UserDefaults.standard.string(forKey: "script") ?? ""
            textView.string = script; follower.load(script); applyStyle(); updateInsets()
            setMode(.follow); restart(); setPlaying(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["MT_SECONDS"] ?? "40") ?? 40)) {
                self.vlog.write(String(format: "MICTEST DONE: cursor %d of %d, top char %.0f, next \"%@\"", self.follower.cursor, self.follower.words.count, self.readingChar(), self.nextWords()))
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--trace") { runSelfTest(); return }
        if textView.string.isEmpty { setEditing(true) }
    }

    /// Runs a recorded audio file through the real speech recognizer + Follow logic, using your saved
    /// script (read-only). Usage: open -n TopPrompter.app --args --voicetest /path/to/audio
    func runVoiceTest() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--voicetest"), i + 1 < args.count else { NSApp.terminate(nil); return }
        let audio = URL(fileURLWithPath: args[i + 1])
        let script = UserDefaults.standard.string(forKey: "script") ?? ""
        textView.string = script
        follower.load(script)
        applyStyle(); updateInsets()
        mode = .follow; modeControl.selectedSegment = 2
        playing = true; startLink(); restart()
        vlog.write("VOICETEST audio \(audio.lastPathComponent), script words \(follower.words.count), first words \"\(nextWords(8))\"")
        let skipped = Follower.tokenize(script).count - follower.words.count
        vlog.write("VOICETEST skipping \(skipped) words of notes/directions")
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                self.vlog.write("VOICETEST speech permission: \(st.rawValue) (3 = allowed)")
                guard st == .authorized, let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
                    self.vlog.write("VOICETEST DONE (no permission)"); NSApp.terminate(nil); return
                }
                let req = SFSpeechAudioBufferRecognitionRequest()
                req.shouldReportPartialResults = true
                self.feedRealtime(audio, into: req)
                if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
                req.taskHint = .dictation
                req.contextualStrings = self.unusualWords()
                self.vlog.write("VOICETEST on-device: \(req.requiresOnDeviceRecognition)")
                self.voiceTestTask = r.recognitionTask(with: req) { result, error in
                    DispatchQueue.main.async {
                        if let result { self.handleTranscript(result.bestTranscription.formattedString) }
                        if error != nil || (result?.isFinal ?? false) {
                            if let error { self.vlog.write("VOICETEST error \(error.localizedDescription)") }
                            let pct = self.follower.words.isEmpty ? 0 : self.follower.cursor * 100 / self.follower.words.count
                            self.vlog.write("VOICETEST DONE: reached word \(self.follower.cursor) of \(self.follower.words.count) (\(pct)%), next: \"\(self.nextWords(8))\"")
                            if let result { self.vlog.write("VOICETEST final transcript: \(result.bestTranscription.formattedString)") }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
    }
    var voiceTestTask: SFSpeechRecognitionTask?
    var voiceTestTimer: Timer?

    /// Sends the audio file to the recognizer at normal speaking speed, like a live mic.
    func feedRealtime(_ url: URL, into req: SFSpeechAudioBufferRecognitionRequest) {
        guard let file = try? AVAudioFile(forReading: url) else { vlog.write("VOICETEST can't read audio"); req.endAudio(); return }
        let fmt = file.processingFormat
        let chunk = AVAudioFrameCount(fmt.sampleRate / 10)            // 100 ms
        let speed = Double(ProcessInfo.processInfo.environment["VT_SPEED"] ?? "1") ?? 1
        voiceTestTimer = Timer.scheduledTimer(withTimeInterval: 0.1 / speed, repeats: true) { t in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk),
                  (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else {
                t.invalidate(); req.endAudio(); return
            }
            req.append(buf)
        }
    }

    /// Exercises each mode without a mic: run TopPrompter.app/Contents/MacOS/TopPrompter --selftest
    func runSelfTest() {
        func log(_ s: String) { print(s); fflush(stdout) }
        func y() -> CGFloat { scrollView.contentView.bounds.origin.y }
        if CommandLine.arguments.contains("--trace") {
            func yy() -> CGFloat { scrollView.contentView.bounds.origin.y }
            let marks: [(Double, String, () -> Void)] = [
                (0.2, "nudge 800", { self.nudge(800) }), (0.4, "restart", { self.restart() }),
                (0.45, "", {}), (0.6, "", {}), (1.0, "", {}),
                (1.2, "replaceScript(long)", { self.replaceScript((1...80).map { "Line \($0) of a long test script with plenty of words" }.joined(separator: "\n")) }),
                (1.25, "", {}), (1.5, "", {}), (2.0, "restart", { self.restart() }), (2.1, "", {}), (2.5, "", {}),
            ]
            for (t, label, f) in marks {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    f(); log(String(format: "t=%.2f %@ y=%.1f startPos=%.1f frameH=%.1f inset=%.1f", t, label, yy(), self.startPos, self.textView.frame.height, self.textView.textContainerInset.height))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { NSApp.terminate(nil) }
            return
        }
        let savedScript = defaults.string(forKey: "script")
        replaceScript((1...60).map { "Line \($0) of the test script has a few words like apollo outbound and leads" }.joined(separator: "\n"))
        var t = 0.0
        func at(_ d: Double, _ f: @escaping () -> Void) { t += d; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

        var y0: CGFloat = 0
        at(0.3) { self.setMode(.manual); y0 = y(); log(String(format: "dbg start y=%.1f startPos=%.1f maxScroll=%.1f frameH=%.1f clipH=%.1f", y0, self.startPos, self.maxScroll, self.textView.frame.height, self.scrollView.contentView.bounds.height)); self.setPlaying(true) }
        for _ in 0..<8 { at(0.25) { log(String(format: "dbg y=%.1f pos=%.1f vel=%.1f", y(), self.pos, self.vel)) } }
        t -= 2.0
        at(2.0) { let d = y() - y0; log(String(format: "manual: moved %.0fpt in 2s at speed %.0f → %@", d, self.speed, d > self.speed * 1.4 ? "OK" : "FAIL")); self.setPlaying(false) }

        // Talk mode: fake the mic levels instead of the real microphone.
        at(0.3) { self.restart(); self.mode = .talk; self.modeControl.selectedSegment = 1; self.playing = true; self.startLink(); y0 = y() }
        var talkTimer: Timer?
        at(0.0) { talkTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in self.handleLevel(-65) } }   // silence
        at(1.5) { let d = y() - y0; log(String(format: "talk/silent: moved %.1fpt → %@", d, d < 2 ? "OK" : "FAIL")); y0 = y()
                  talkTimer?.invalidate(); talkTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in self.handleLevel(-25) } }  // talking
        at(1.5) { let d = y() - y0; log(String(format: "talk/speaking: moved %.0fpt → %@", d, d > 30 ? "OK" : "FAIL"))
                  talkTimer?.invalidate(); talkTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in self.handleLevel(-65) } }
        at(1.2) { y0 = y() }
        at(1.0) { let d = y() - y0; log(String(format: "talk/stopped talking: moved %.1fpt after stopping → %@", d, d < 2 ? "OK" : "FAIL"))
                  talkTimer?.invalidate(); self.link?.isPaused = true; self.playing = false }

        // Follow mode: feed fake transcripts.
        at(0.3) { self.restart(); self.mode = .follow; self.modeControl.selectedSegment = 2; self.playing = true; self.startLink(); y0 = y() }
        var spoken = ""
        let words = "line 1 of the test script has a few words like apollo outbound and leads line 2 of the test script has a few words like apollo outbound and leads line 3 of the test script".split(separator: " ")
        for w in words { at(0.05) { spoken += (spoken.isEmpty ? "" : " ") + w; self.handleTranscript(spoken) } }
        at(1.5) { let d = y() - y0; log(String(format: "follow: cursor=%d, scrolled %.0fpt (≈2 lines at %.0fpt font) → %@", self.follower.cursor, d, self.fontSize, (self.follower.cursor == 36 && d > self.fontSize) ? "OK" : "FAIL")); y0 = y() }
        at(1.5) { let d = y() - y0; log(String(format: "follow/silent: moved %.1fpt → %@", d, abs(d) < 2 ? "OK" : "FAIL")) }
        // Restart while following and while speech keeps arriving.
        at(0.1) { self.restart(); log(String(format: "follow/restart: char=%.1f y=%.1f startPos=%.1f cursor=%d", self.readingChar(), y(), self.startPos, self.follower.cursor)) }
        at(0.0) { spoken = "" }
        for w in "line 1 of the test".split(separator: " ") { at(0.08) { spoken += (spoken.isEmpty ? "" : " ") + w; self.handleTranscript(spoken) } }
        at(1.5) { log(String(format: "follow/after restart, reading from the top: char=%.1f cursor=%d → %@", self.readingChar(), self.follower.cursor, (self.follower.cursor == 5 && self.readingChar() < 5) ? "OK" : "FAIL")) }
        // Restart in manual after scrolling a while.
        at(0.1) { self.playing = false; self.link?.isPaused = true; self.mode = .manual; self.modeControl.selectedSegment = 0; self.clearDim(); self.nudge(400) }
        at(0.3) { log(String(format: "manual/before restart: char=%.1f", self.readingChar())); self.setPlaying(true) }
        at(1.0) { self.restart()
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                      log(String(format: "manual/restart while playing: char=%.1f y=%.1f startPos=%.1f → %@", self.readingChar(), y(), self.startPos, (y() - self.startPos) < 8 ? "OK" : "FAIL")) } }
        at(0.1) { self.setPlaying(false); self.nudge(400); self.restart() }
        at(0.3) { log(String(format: "manual/restart while paused: char=%.1f → %@", self.readingChar(), self.readingChar() < 1 ? "OK" : "FAIL")) }
        at(0.2) { self.playing = false; self.link?.isPaused = true
                  if let s = savedScript { defaults.set(s, forKey: "script") } else { defaults.removeObject(forKey: "script") }
                  NSApp.terminate(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { voice.stop() }

    func buildTextArea(in root: NSView, frame: NSRect) {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: barH, width: frame.width, height: frame.height - barH))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.12, 0.94, 1]
        scrollView.layer?.mask = fadeMask

        // TextKit 1 so we can look up line positions and tint already-read words cheaply.
        let size = scrollView.contentSize
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.frame = NSRect(origin: .zero, size: size)
        tv.minSize = NSSize(width: 0, height: size.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.insertionPointColor = .white
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isEditable = false
        tv.isSelectable = false
        tv.delegate = self
        tv.string = defaults.string(forKey: "script") ?? sampleScript
        textView = tv
        scrollView.documentView = tv
        root.addSubview(scrollView)
        // Keep the text pinned to the top of the scroll area. When the text gets shorter (smaller font,
        // shorter script) AppKit can slide it up, so "the top" would show the middle of the script.
        tv.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: .main) { [weak self] _ in
            guard let self, self.textView.frame.origin != .zero else { return }
            let shift = self.textView.frame.origin.y
            self.vlog.write(String(format: "TEXT AREA had slid %.0fpt — pinned back to the top", shift))
            self.textView.setFrameOrigin(.zero)
            self.scrollTo(max(self.startPos, self.scrollView.contentView.bounds.origin.y - shift))
            self.pos = self.scrollView.contentView.bounds.origin.y
            self.followTarget = self.pos
        }
        // Never rest above the first line (AppKit can move the view there when the text is replaced).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            guard let self, !self.editing else { return }
            let y = self.scrollView.contentView.bounds.origin.y
            if y < self.startPos - 1 {
                if isTestRun { print("BOUNDS moved above start to \(y); stack:\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n")) }
                self.vlog.write(String(format: "VIEW was moved above the script start (%.0f) — corrected", y))
                DispatchQueue.main.async { self.scrollTo(max(self.pos, self.startPos)) }
            }
        }
        // A real trackpad/mouse scroll (not our own scrolling) means "take me here".
        NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
            self?.userScrolled = true
        }
    }

    func buildToolbar(in root: NSView, frame: NSRect) {
        toolbar = DragBar(frame: NSRect(x: 0, y: 0, width: frame.width, height: barH))
        toolbar.autoresizingMask = [.width]
        let line = NSView(frame: NSRect(x: 0, y: barH - 1, width: frame.width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        line.autoresizingMask = [.width]
        toolbar.addSubview(line)

        playButton = button("play.fill", "Play", "Play / pause (Space)", #selector(togglePlay))
        editButton = button("pencil", "Edit", "Edit the script (E). Esc when done.", #selector(toggleEdit))
        modeControl = NSSegmentedControl(labels: Mode.allCases.map(\.title), trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged))
        modeControl.controlSize = .small
        modeControl.font = .systemFont(ofSize: 11, weight: .medium)
        modeControl.selectedSegment = mode.rawValue
        modeControl.setToolTip("Steady scroll at the set speed", forSegment: 0)
        modeControl.setToolTip("Scrolls only while you're talking", forSegment: 1)
        modeControl.setToolTip("Follows your words and keeps your place", forSegment: 2)
        speedLabel = NSTextField(labelWithString: "")
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        speedLabel.textColor = NSColor(white: 1, alpha: 0.6)
        speedLabel.alignment = .center
        speedLabel.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let stack = NSStackView(views: [
            button("backward.end.fill", "Restart", "Back to the start (R)", #selector(restart)),
            playButton,
            gap(),
            modeControl,
            gap(),
            button("tortoise.fill", "Slower", "Slower (↓)", #selector(slower)),
            speedLabel,
            button("hare.fill", "Faster", "Faster (↑)", #selector(faster)),
            gap(),
            button("textformat.size.smaller", "Smaller", "Smaller text (−)", #selector(smaller)),
            button("textformat.size.larger", "Bigger", "Bigger text (+)", #selector(bigger)),
            gap(),
            editButton,
            button("mic.fill", "Mic", "Choose microphone", #selector(showMicMenu(_:))),
            button("iphone", "iPhone", "Show the script on your iPhone", #selector(showPhone)),
            button("arrow.up.to.line", "Top", "Snap to top center (⌘T)", #selector(snapTop)),
            button("display.2", "Screen", "Move to the other display (⌘D)", #selector(nextDisplay)),
            button("xmark", "Quit", "Quit (⌘Q)", #selector(quit)),
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: -1),
        ])
        let grip = ResizeGrip(frame: NSRect(x: frame.width - 20, y: 1, width: 18, height: 18))
        grip.autoresizingMask = [.minXMargin]
        toolbar.addSubview(grip)
        root.addSubview(toolbar)
    }

    // MARK: UI helpers

    func button(_ symbol: String, _ title: String, _ tip: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: title)!
        let b = NSButton(title: title, image: img, target: self, action: action)
        b.imagePosition = .imageAbove
        b.isBordered = false
        b.font = .systemFont(ofSize: 9, weight: .medium)
        b.contentTintColor = .white
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        b.toolTip = tip
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        return b
    }

    func gap() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 4).isActive = true
        return v
    }

    func applyStyle() {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineHeightMultiple = 1.12
        ps.paragraphSpacing = fontSize * 0.4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: ps,
        ]
        textView.defaultParagraphStyle = ps
        textView.typingAttributes = attrs
        if let ts = textView.textStorage {
            ts.beginEditing()
            ts.setAttributes(attrs, range: NSRange(location: 0, length: ts.length))
            ts.endEditing()
        }
        dimmedUpTo = -1
        updateDim()
    }

    /// Top/bottom padding equal to the visible height, so the first line can sit at the top
    /// edge (right under the camera) and the last line can scroll all the way up.
    func updateInsets() {
        let h = scrollView.contentSize.height
        let old = textView.textContainerInset.height
        textView.textContainerInset = NSSize(width: sideInset, height: h)
        textView.minSize = NSSize(width: 0, height: h)
        if old > 0 && old != h { pos += h - old; followTarget += h - old; scrollTo(pos) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fadeMask.frame = scrollView.bounds
        CATransaction.commit()
    }

    var startPos: CGFloat { textView.textContainerInset.height - 6 }

    /// Where Restart goes: the first line with a spoken word at the top (notes like "Z01" skipped).
    var firstSpokenPos: CGFloat {
        guard let first = follower.words.first else { return startPos }
        return max(startPos, lineTop(forChar: first.range.location) - 6)
    }
    var maxScroll: CGFloat { max(0, textView.frame.height - scrollView.contentView.bounds.height) }

    func scrollTo(_ y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func updateSpeedLabel() { speedLabel.stringValue = String(format: "%.0f", speed) }

    func updatePlayButton() {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        playButton.title = playing ? "Pause" : (mode == .manual ? "Play" : "Listen")
    }

    func updateToolbarVisibility() {
        let show = !playing || hovering
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            toolbar.animator().alphaValue = show ? 1 : 0
        }
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "TopPrompter"
        a.informativeText = text
        window.level = .normal
        a.runModal()
        window.level = .screenSaver
    }

    // MARK: playback

    func setPlaying(_ p: Bool) {
        if p == playing { return }
        playing = p
        if p {
            setEditing(false)
            pos = scrollView.contentView.bounds.origin.y
            if pos >= maxScroll - 1 { restart() }      // at the end → start over
            vel = 0
            followTarget = pos
            if mode == .follow { syncCursorToView() }
            startLink()
            startVoiceIfNeeded()
        } else {
            link?.isPaused = true
            voice.stop()
            speaking = false
            levelDot.state = .off
        }
        updatePlayButton()
        updateToolbarVisibility()
        vlog.write(p ? "PLAY (\(mode.title))" : "PAUSE")
    }

    func startLink() {
        if link == nil {
            let l = scrollView.displayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        lastTick = 0
        link?.isPaused = false
    }

    /// Runs once per display refresh while playing.
    @objc func step(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = lastTick == 0 ? 0 : CGFloat(min(0.1, now - lastTick))
        lastTick = now
        guard dt > 0 else { return }

        let current = scrollView.contentView.bounds.origin.y
        if userScrolled {                                 // you scrolled by hand → go from there
            userScrolled = false
            pos = current
            followTarget = current
            if mode == .follow { syncCursorToView(); voice.resetTranscript() }
        } else if abs(current - pos) > 3 {
            pos = current                                 // view was clamped/moved by layout: just follow it
        }

        switch mode {
        case .follow:
            pos += (followTarget - pos) * min(1, dt * 2.5)   // gentle glide to the next line
        case .manual, .talk:
            let target: CGFloat = (mode == .manual || speaking) ? speed : 0
            vel += (target - vel) * min(1, dt * (target > vel ? 6 : 10))   // smooth start, quicker stop
            pos += vel * dt
        }

        if pos >= maxScroll {
            pos = maxScroll
            scrollTo(pos)
            if mode != .follow { setPlaying(false) }
            return
        }
        scrollTo(pos)
    }

    func setEditing(_ e: Bool) {
        editing = e
        textView.isEditable = e
        textView.isSelectable = e
        editButton.contentTintColor = e ? .systemYellow : .white
        editButton.title = e ? "Done" : "Edit"
        if e {
            setPlaying(false)
            clearDim()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            window.makeFirstResponder(window.contentView)
            follower.load(textView.string)
            syncCursorToView()
        }
    }

    // MARK: voice

    func startVoiceIfNeeded() {
        guard playing, mode != .manual else { return }
        let speech = mode == .follow
        levelDot.state = .listening
        VoiceEngine.requestPermissions(speech: speech) { [weak self] err in
            guard let self, self.playing, self.mode != .manual else { return }
            if let err { self.setPlaying(false); self.alert(err); return }
            self.voice.deviceID = self.selectedDevice()?.id
            self.voice.contextualStrings = self.unusualWords()
            self.vlog.write("LISTEN start: mode \(self.mode.title), mic \(self.selectedDevice()?.name ?? "System Default (\(VoiceEngine.defaultInputName()))"), script words \(self.follower.words.count), cursor \(self.follower.cursor) \"\(self.nextWords())\"")
            do { try self.voice.start(speech: speech) } catch {
                self.vlog.write("ERROR mic start: \(error.localizedDescription)")
                self.setPlaying(false)
                self.alert("Couldn't start the microphone: \(error.localizedDescription)")
            }
        }
    }

    func handleLevel(_ db: Float) {
        guard playing else { return }
        // Track the room's background noise: drop fast, rise slowly.
        if db < noiseFloor { noiseFloor = db } else { noiseFloor = min(noiseFloor + 0.01, -20) }
        let threshold = max(noiseFloor + sensitivity, -58)
        let now = CACurrentMediaTime()
        if db > threshold { lastVoiceAt = now }
        speaking = now - lastVoiceAt < 0.6            // short grace period between words
        levelDot.state = speaking ? .hearing : .listening
        levelStats.n += 1; levelStats.sum += db; levelStats.max = max(levelStats.max, db)
        if db > threshold { levelStats.heard += 1 }
        if now - levelStats.lastReport >= 1 {
            vlog.write(String(format: "MIC avg %.0f dB, peak %.0f dB, room %.0f dB, voice threshold %.0f dB, voice in %d%% of the last second, phone polls %d, top char %.0f",
                              levelStats.sum / Float(max(1, levelStats.n)), levelStats.max, noiseFloor, threshold,
                              levelStats.heard * 100 / max(1, levelStats.n), phonePolls, readingChar()))
            levelStats = (0, 0, -120, 0, now); phonePolls = 0
        }
    }

    func handleTranscript(_ t: String) {
        guard playing, mode == .follow else { return }
        speaking = true
        lastVoiceAt = CACurrentMediaTime()
        let before = follower.cursor
        let moved = follower.feed(t)
        if moved { moveToCursor() }
        let tail = t.split(separator: " ").suffix(8).joined(separator: " ")
        vlog.write("HEARD \"…\(tail)\"  → \(follower.lastNote)" + (moved ? "  [cursor \(before)→\(follower.cursor): \"\(nextWords())\"]" : ""))
    }

    /// The next few script words from the cursor, for the log.
    func nextWords(_ n: Int = 5) -> String {
        let ns = textView.string as NSString
        let ws = follower.words
        guard follower.cursor < ws.count else { return "(end)" }
        return ws[follower.cursor..<min(ws.count, follower.cursor + n)].map { ns.substring(with: $0.range) }.joined(separator: " ")
    }

    /// Scroll so the line you're on sits at the top, and grey out what you've already said.
    func moveToCursor() {
        let words = follower.words
        guard !words.isEmpty else { return }
        // Scroll by the last word you actually said (not the next one), and keep the line
        // before it visible above, so the line you're reading sits second from the top.
        let said = max(0, min(follower.cursor - 1, words.count - 1))
        followTarget = min(maxScroll, max(startPos, previousLineTop(forChar: words[said].range.location) - 6))
        updateDim()
    }

    /// Top of the line just above the one holding this character (or that line itself if it's the first).
    func previousLineTop(forChar ci: Int) -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
        lm.ensureLayout(for: tc)
        let len = textView.textStorage?.length ?? 0
        guard len > 0 else { return 0 }
        var lineRange = NSRange()
        let gi = lm.glyphIndexForCharacter(at: min(ci, len - 1))
        let r = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: &lineRange)
        if lineRange.location == 0 { return r.minY + textView.textContainerOrigin.y }
        var prevRange = NSRange()
        var prev = lm.lineFragmentRect(forGlyphAt: lineRange.location - 1, effectiveRange: &prevRange)
        // Skip blank lines between paragraphs so there's real text above.
        while prevRange.location > 0,
              (textView.string as NSString).substring(with: lm.characterRange(forGlyphRange: prevRange, actualGlyphRange: nil))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prev = lm.lineFragmentRect(forGlyphAt: prevRange.location - 1, effectiveRange: &prevRange)
        }
        return prev.minY + textView.textContainerOrigin.y
    }

    func lineTop(forChar ci: Int) -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
        lm.ensureLayout(for: tc)
        let len = textView.textStorage?.length ?? 0
        guard len > 0 else { return 0 }
        let gi = lm.glyphIndexForCharacter(at: min(ci, len - 1))
        return lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil).minY + textView.textContainerOrigin.y
    }

    /// Point the follower at the first word on the top line currently visible.
    func syncCursorToView() {
        guard mode == .follow, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        var y = scrollView.contentView.bounds.origin.y - textView.textContainerOrigin.y + 10
        guard (textView.textStorage?.length ?? 0) > 0 else { follower.cursor = 0; return }
        // At the start position you're on the first spoken word.
        if scrollView.contentView.bounds.origin.y <= firstSpokenPos + 2 { follower.cursor = 0; updateDim(); return }
        // Past the start, the top row is the line you just read; the reading line is the second row.
        if scrollView.contentView.bounds.origin.y > startPos + 2 {
            let topLine = lm.lineFragmentRect(forGlyphAt: lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: tc), effectiveRange: nil)
            y = topLine.maxY + 2
        }
        let gi = lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: tc)
        let ci = lm.characterIndexForGlyph(at: gi)
        follower.cursor = follower.words.firstIndex { $0.range.location >= ci } ?? follower.words.count
        updateDim()
    }

    func updateDim() {
        guard let lm = textView.layoutManager else { return }
        let len = textView.textStorage?.length ?? 0
        let words = follower.words
        let upTo: Int
        if mode != .follow || editing || follower.cursor == 0 || words.isEmpty {
            upTo = 0
        } else {
            let w = words[min(follower.cursor, words.count) - 1]
            upTo = min(len, w.range.location + w.range.length)
        }
        let word = currentWordRange()
        guard upTo != dimmedUpTo || word != highlighted else { return }
        dimmedUpTo = upTo
        highlighted = word
        let all = NSRange(location: 0, length: len)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        if upTo > 0 {
            lm.addTemporaryAttribute(.foregroundColor, value: NSColor(white: 1, alpha: 0.35),
                                     forCharacterRange: NSRange(location: 0, length: upTo))
        }
        if let w = word {   // the word it just heard you say
            lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow, forCharacterRange: w)
            lm.addTemporaryAttribute(.foregroundColor, value: NSColor.black, forCharacterRange: w)
        }
    }

    var highlighted: NSRange?

    /// Range of the last script word you said (Follow mode only).
    func currentWordRange() -> NSRange? {
        guard mode == .follow, !editing, follower.cursor > 0, !follower.words.isEmpty else { return nil }
        return follower.words[min(follower.cursor, follower.words.count) - 1].range
    }

    func clearDim() {
        guard let lm = textView.layoutManager else { return }
        let all = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        dimmedUpTo = 0
        highlighted = nil
    }

    /// Names and long words from the script help the recognizer (e.g. "Apollo", "OBSBOT").
    func unusualWords() -> [String] {
        var seen = Set<String>(), out: [String] = []
        let ns = textView.string as NSString
        for w in follower.words {
            let raw = ns.substring(with: w.range)
            guard raw.count >= 7 || raw.first?.isUppercase == true, w.norm.count > 2, !seen.contains(w.norm) else { continue }
            seen.insert(w.norm); out.append(raw)
            if out.count >= 100 { break }
        }
        return out
    }

    // MARK: actions

    @objc func togglePlay() { setPlaying(!playing) }
    @objc func toggleEdit() { setEditing(!editing) }

    @objc func restart() {
        vlog.write("RESTART")
        voice.resetTranscript()             // forget words heard before the restart
        textView.layoutManager.map { lm in textView.textContainer.map { lm.ensureLayout(for: $0) } }
        follower.load(textView.string)
        pos = startPos                      // very top of the script (Z01 etc. visible)
        followTarget = pos
        vel = 0
        follower.cursor = 0
        scrollTo(pos)
        updateDim()
    }

    @objc func modeChanged() { setMode(Mode(rawValue: modeControl.selectedSegment) ?? .manual) }

    func setMode(_ m: Mode) {
        mode = m
        modeControl.selectedSegment = m.rawValue
        defaults.set(m.rawValue, forKey: "mode")
        voice.stop()
        levelDot.state = playing && m != .manual ? .listening : .off
        speaking = false
        vel = 0
        followTarget = scrollView.contentView.bounds.origin.y
        if m == .follow { syncCursorToView() } else { clearDim() }
        startVoiceIfNeeded()
        updatePlayButton()
        rebuildVoiceMenuChecks()
    }

    @objc func cycleMode() { setMode(Mode(rawValue: (mode.rawValue + 1) % Mode.allCases.count)!) }
    @objc func menuMode(_ s: NSMenuItem) { setMode(Mode(rawValue: s.tag) ?? .manual) }

    @objc func faster() { speed = min(400, speed + 5); saveSpeed() }
    @objc func slower() { speed = max(5, speed - 5); saveSpeed() }
    func saveSpeed() { defaults.set(Double(speed), forKey: "speed"); updateSpeedLabel() }

    @objc func bigger() { setFont(fontSize + 2) }
    @objc func smaller() { setFont(fontSize - 2) }
    func setFont(_ s: CGFloat) {
        let ci = topVisibleChar()
        fontSize = min(96, max(14, s))
        defaults.set(Double(fontSize), forKey: "fontSize")
        applyStyle()
        pos = lineTop(forChar: ci) - 6           // keep your place when text reflows
        followTarget = pos
        scrollTo(pos)
    }

    func topVisibleChar() -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              (textView.textStorage?.length ?? 0) > 0 else { return 0 }
        let y = scrollView.contentView.bounds.origin.y - textView.textContainerOrigin.y + 10
        return lm.characterIndexForGlyph(at: lm.glyphIndex(for: NSPoint(x: 0, y: max(0, y)), in: tc))
    }

    func nudge(_ d: CGFloat) {
        voice.resetTranscript()
        pos = min(maxScroll, max(0, scrollView.contentView.bounds.origin.y + d))
        followTarget = pos
        scrollTo(pos)
        syncCursorToView()
    }

    @objc func snapTop() {
        let s = window.screen ?? preferredScreen()
        window.setFrame(topCenter(window.frame.size, on: s), display: true, animate: true)
    }

    @objc func nextDisplay() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { snapTop(); return }
        let i = screens.firstIndex(where: { $0 == window.screen }) ?? 0
        let next = screens[(i + 1) % screens.count]
        window.setFrame(topCenter(window.frame.size, on: next), display: true, animate: true)
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: iPhone display

    /// Continuous reading position (character index + fraction through its line) at the top of the view,
    /// so the phone can put the same spot at its own top edge whatever its line wrapping.
    func readingChar() -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
        let len = textView.textStorage?.length ?? 0
        guard len > 0 else { return 0 }
        let y = scrollView.contentView.bounds.origin.y + 6 - textView.textContainerOrigin.y
        if y <= 0 { return 0 }
        let gi = lm.glyphIndex(for: NSPoint(x: 0, y: y), in: tc)
        var glyphRange = NSRange()
        let rect = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: &glyphRange)
        let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if y >= rect.maxY { return CGFloat(len) }        // past the last line
        let f = rect.height > 0 ? min(1, max(0, (y - rect.minY) / rect.height)) : 0
        return CGFloat(chars.location) + f * CGFloat(chars.length)
    }

    @objc func showPhone() {
        phone.start()
        defaults.set(true, forKey: "phoneEnabled")
        guard let url = PhoneServer.url() else {
            alert("This Mac isn't on a network right now. Connect it to the same Wi-Fi or router as your iPhone, then click iPhone again.")
            return
        }
        let a = NSAlert()
        a.messageText = "Show the script on your iPhone"
        a.informativeText = """
        1. Make sure your iPhone is on the same Wi-Fi as this Mac.
        2. Point the iPhone camera at this code and tap the link (or type \(url) into Safari).
        3. In Safari tap Share → Add to Home Screen. Open it from there and it runs full screen.

        Your Mac stays in charge: Play, Talk and Follow all run here, using the Mac's microphone. The phone just shows the script and follows along.
        Keep this app open while you use the phone. Set your iPhone's Auto-Lock to Never if the screen dims.
        """
        if let img = PhoneServer.qrImage(url) {
            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
            iv.image = img
            a.accessoryView = iv
        }
        a.addButton(withTitle: "Done")
        a.addButton(withTitle: "Copy Link")
        a.addButton(withTitle: "Turn Off iPhone Link")
        window.level = .normal
        switch a.runModal() {
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        case .alertThirdButtonReturn:
            phone.stop()
            defaults.set(false, forKey: "phoneEnabled")
        default: break
        }
        window.level = .screenSaver
    }

    @objc func pasteScript() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { NSSound.beep(); return }
        replaceScript(s)
    }

    @objc func openFile() {
        let p = NSOpenPanel()
        var types: [UTType] = [.plainText, .rtf, .text]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        p.allowedContentTypes = types
        window.level = .normal
        defer { window.level = .screenSaver }
        guard p.runModal() == .OK, let url = p.url,
              let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return }
        replaceScript(a.string)
    }

    func replaceScript(_ s: String) {
        setPlaying(false)
        textView.string = s
        scriptVersion += 1
        follower.load(s)
        applyStyle()
        defaults.set(s, forKey: "script")
        restart()
    }

    // MARK: microphone menu

    func selectedDevice() -> VoiceEngine.InputDevice? {
        guard let uid = defaults.string(forKey: "micUID") else { return nil }
        return VoiceEngine.inputDevices().first { $0.uid == uid }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === micMenu else { return }
        menu.removeAllItems()
        let current = defaults.string(forKey: "micUID")
        let def = NSMenuItem(title: "System Default", action: #selector(pickMic(_:)), keyEquivalent: "")
        def.target = self
        def.state = current == nil ? .on : .off
        menu.addItem(def)
        menu.addItem(.separator())
        for d in VoiceEngine.inputDevices() {
            let it = NSMenuItem(title: d.name, action: #selector(pickMic(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.uid
            it.state = d.uid == current ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let head = NSMenuItem(title: "Talk mode sensitivity", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for (name, v) in [("Low (noisy room)", Float(16)), ("Medium", 10), ("High (quiet voice)", 6)] {
            let it = NSMenuItem(title: "   " + name, action: #selector(pickSensitivity(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v
            it.state = abs(sensitivity - v) < 0.1 ? .on : .off
            menu.addItem(it)
        }
    }

    @objc func showMicMenu(_ sender: NSButton) {
        menuNeedsUpdate(micMenu)
        window.level = .normal       // menus at screenSaver level would hide behind the window
        micMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        window.level = .screenSaver
    }

    @objc func pickMic(_ item: NSMenuItem) {
        if let uid = item.representedObject as? String { defaults.set(uid, forKey: "micUID") }
        else { defaults.removeObject(forKey: "micUID") }
        if playing && mode != .manual { voice.stop(); startVoiceIfNeeded() }
    }

    @objc func pickSensitivity(_ item: NSMenuItem) {
        sensitivity = item.representedObject as? Float ?? 10
        defaults.set(Double(sensitivity), forKey: "sensitivity")
    }

    // MARK: keys

    func handleKey(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        if e.modifierFlags.contains(.command) { return e }            // menu shortcuts
        if editing {
            if Int(e.keyCode) == kVK_Escape { setEditing(false); return nil }
            return e
        }
        switch Int(e.keyCode) {
        case kVK_Space: togglePlay()
        case kVK_UpArrow: faster()
        case kVK_DownArrow: slower()
        case kVK_LeftArrow: nudge(-fontSize * 1.5)
        case kVK_RightArrow: nudge(fontSize * 1.5)
        case kVK_ANSI_R: restart()
        case kVK_ANSI_M: cycleMode()
        case kVK_ANSI_E, kVK_Return: setEditing(true)
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: bigger()
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: smaller()
        case kVK_Escape: setPlaying(false)
        default: return e
        }
        return nil
    }

    /// Control-Option shortcuts that work while another app is in front.
    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { appDelegate.hotKey(id) }
            return noErr
        }, 1, &spec, nil, nil)
        let mods = UInt32(controlKey | optionKey)
        let keys = [(1, kVK_ANSI_P), (2, kVK_ANSI_R), (3, kVK_UpArrow), (4, kVK_DownArrow), (5, kVK_ANSI_M)]
        for (id, key) in keys {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x5450_4D54), id: UInt32(id)),
                                GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }

    func hotKey(_ id: UInt32) {
        switch id {
        case 1: togglePlay()
        case 2: restart()
        case 3: faster()
        case 4: slower()
        case 5: cycleMode()
        default: break
        }
    }

    // MARK: window / text delegates

    func windowDidResize(_ notification: Notification) {
        updateInsets()
        if mode == .follow { moveToCursor(); pos = followTarget; scrollTo(pos) }
        saveFrame()
    }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func saveFrame() { defaults.set(NSStringFromRect(window.frame), forKey: "frame.v2") }
    func textDidChange(_ notification: Notification) {
        scriptVersion += 1
        defaults.set(textView.string, forKey: "script")
        follower.load(textView.string)
    }

    // MARK: screens

    func preferredScreen() -> NSScreen {
        let external = NSScreen.screens.first { s in
            let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayIsBuiltin(n) == 0
        }
        return external ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func topCenter(_ size: NSSize, on s: NSScreen) -> NSRect {
        NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: menu bar

    var modeItems: [NSMenuItem] = []

    func rebuildVoiceMenuChecks() { for it in modeItems { it.state = it.tag == mode.rawValue ? .on : .off } }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit TopPrompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "Script")
        file.addItem(withTitle: "Open Text File…", action: #selector(openFile), keyEquivalent: "o").target = self
        let paste = file.addItem(withTitle: "Replace Script with Clipboard", action: #selector(pasteScript), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = [.command, .shift]; paste.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Snap to Top Center", action: #selector(snapTop), keyEquivalent: "t").target = self
        file.addItem(withTitle: "Move to Next Display", action: #selector(nextDisplay), keyEquivalent: "d").target = self
        file.addItem(withTitle: "Show on iPhone…", action: #selector(showPhone), keyEquivalent: "i").target = self
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let voiceItem = NSMenuItem(); main.addItem(voiceItem)
        let vm = NSMenu(title: "Mode")
        for m in Mode.allCases {
            let it = NSMenuItem(title: m.title, action: #selector(menuMode(_:)), keyEquivalent: "\(m.rawValue + 1)")
            it.target = self; it.tag = m.rawValue
            vm.addItem(it); modeItems.append(it)
        }
        vm.addItem(.separator())
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenu.delegate = self
        micItem.submenu = micMenu
        vm.addItem(micItem)
        voiceItem.submenu = vm
        rebuildVoiceMenuChecks()

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
