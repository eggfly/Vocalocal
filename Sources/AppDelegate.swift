import AppKit
import AVFoundation
import ServiceManagement

/// 交互方式和 Typeless 一致：
///  - 按住 Fn 说话，松开后识别并输入
///  - 双击 Fn 进入免按住模式（HUD 圆点变橙色），再按一次 Fn 结束
///  - 录音中按 Esc，或 Fn 和其它键组合（fn+↑ 等），取消本次录音
///  - 有选中文字时，说出的内容作为改写指令（"翻译成英文""改得正式一点"）
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Phase { case idle, recording(handsFree: Bool), processing }

    private var config = Config.load()
    private let monitor = FnKeyMonitor()
    private let recorder = AudioRecorder()
    private let hud = HUDController()
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var settings: SettingsWindowController!
    private var levelTimer: Timer?
    private var retryTimer: Timer?

    private var phase: Phase = .idle
    private var fnDownAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var focus = FocusContext()
    private var screenTask: Task<ScreenContext, Never>?
    private var lastResult: String?

    private static let tapThreshold: TimeInterval = 0.3      // 短于此视为"点按"而不是"按住说话"
    private static let doubleTapWindow: TimeInterval = 0.5
    private static let minDuration: TimeInterval = 0.4       // 录音太短直接丢弃

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !FileManager.default.fileExists(atPath: Config.fileURL.path) { config.save() }
        settings = SettingsWindowController(config: config) { [weak self] newConfig in
            self?.config = newConfig
            newConfig.save()
            if newConfig.asrProvider == "apple" { AppleSpeech.requestAuthorization() }
            self?.hud.show(.message("设置已保存"), autoHideAfter: 1.2)
        }
        setupMenu()
        requestPermissions()
        wireMonitor()
        startMonitor()
        if CommandLine.arguments.contains("--test-record") { selfTestRecording() }
        if let i = CommandLine.arguments.firstIndex(of: "--test-file"), i + 1 < CommandLine.arguments.count,
           let wav = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 1])) {
            // 诊断：用录音文件走完整流程，不粘贴
            Task { @MainActor in
                await self.process(wav: wav, config: self.config, focus: FocusContext(), audioName: nil, insert: false)
                Log.info("test-file: done")
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--bench"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { @MainActor in await Bench.run(directory: dir) }
        }
    }

    /// 诊断：录 3 秒后走完整的识别流程（不粘贴），结果写到日志
    private func selfTestRecording() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            Log.info("self-test: recording 3s")
            startRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                stopLevelTimer()
                let duration = recorder.duration
                let wav = recorder.stop()
                phase = .idle
                hud.show(.hidden)
                let peak = wav.count > 44 ? wav.dropFirst(44).withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
                } : 0
                Log.info(String(format: "self-test: %.2fs, %d bytes, peak=%d", duration, wav.count, peak))
                try? wav.write(to: History.fileURL.deletingLastPathComponent().appendingPathComponent("last.wav"))
                let config = self.config
                Task {
                    do { Log.info("self-test ASR: \(try await Transcriber.transcribe(wav: wav, config: config))") }
                    catch { Log.info("self-test ASR error: \(error.localizedDescription)") }
                }
            }
        }
    }

    // MARK: - 权限

    private func requestPermissions() {
        // 辅助功能：事件监听、读取输入框、模拟 ⌘V 都需要
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        Log.info("launch: accessibility=\(trusted) microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) screen=\(CGPreflightScreenCaptureAccess()) asr=\(config.asrProvider) corrector=\(config.correctorEnabled)")
        // 屏幕录制：辅助功能读不到文字时（虚拟机、远程桌面、图片等）用 OCR 获取屏幕上下文
        if config.useFieldContext, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        AVCaptureDevice.requestAccess(for: .audio) { granted in Log.info("microphone granted=\(granted)") }
        if config.asrProvider == "apple" { AppleSpeech.requestAuthorization() }
    }

    private func startMonitor() {
        // 没有辅助功能权限时 tapCreate 依然可能成功，但收不到任何键盘事件，所以必须先确认权限
        if AXIsProcessTrusted(), monitor.start() {
            Log.info("event tap started (accessibility=\(AXIsProcessTrusted()))")
            retryTimer?.invalidate()
            retryTimer = nil
            updateStatus("就绪 — 按住 Fn 说话")
            return
        }
        updateStatus("⚠️ 需要“辅助功能”权限")
        if retryTimer == nil {
            Log.info("event tap not started: accessibility not granted, retrying every 2s")
            hud.show(.message("需要授予辅助功能权限"), autoHideAfter: 5)
        }
        // 用户在系统设置里授权后自动生效，不用重启
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.startMonitor()
        }
    }

    // MARK: - Fn 状态机

    private func wireMonitor() {
        monitor.onFnDown = { [weak self] in self?.fnDown() }
        monitor.onFnUp = { [weak self] in self?.fnUp() }
        monitor.onChordWhileFn = { [weak self] in
            guard let self, case .recording(handsFree: false) = self.phase else { return }
            self.cancelRecording()
        }
        monitor.onEscape = { [weak self] in
            guard let self, case .recording = self.phase else { return }
            self.cancelRecording()
        }
    }

    private func fnDown() {
        Log.info("fn down (phase=\(phase))")
        switch phase {
        case .idle:
            fnDownAt = Date()
            startRecording()
        case .recording(handsFree: true):
            finishRecording()
        case .recording(handsFree: false), .processing:
            break
        }
    }

    private func fnUp() {
        Log.info("fn up (phase=\(phase), held=\(String(format: "%.2f", Date().timeIntervalSince(fnDownAt)))s)")
        guard case .recording(handsFree: false) = phase else { return }
        let held = Date().timeIntervalSince(fnDownAt)
        if held >= Self.tapThreshold {
            finishRecording()
            return
        }
        // 点按
        if Date().timeIntervalSince(lastTapAt) < Self.doubleTapWindow {
            lastTapAt = .distantPast
            phase = .recording(handsFree: true)       // 双击：继续录音，进入免按住模式
            hud.show(.listening(handsFree: true))
        } else {
            lastTapAt = Date()
            cancelRecording(silently: true)            // 单击：可能是第一次点按，静默丢弃
        }
    }

    // MARK: - 录音

    private func startRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.show(.message("需要麦克风权限"), autoHideAfter: 2)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        }
        // 按下 Fn 的瞬间记录焦点：选中的文字、光标前内容、目标 App
        focus = FocusContext.capture()
        // 屏幕文字在后台读取（限时 0.4 秒），和录音同时进行，不增加延迟
        if config.useFieldContext, let pid = focus.pid {
            screenTask = Task.detached(priority: .userInitiated) { await ScreenContext.capture(pid: pid) }
        } else {
            screenTask = nil
        }
        // 说话期间把本地 LLM 加载好。开启纠错后 LLM 只用于“选中文字改写”，没有选中文字就不加载，省 5~6 GB
        if !config.correctorEnabled || !(focus.selectedText ?? "").isEmpty { Polisher.warmUp(config: config) }
        do {
            try recorder.start(noiseSuppression: config.noiseSuppression)
        } catch {
            hud.show(.message("录音失败：\(error.localizedDescription)"), autoHideAfter: 2.5)
            return
        }
        phase = .recording(handsFree: false)
        hud.show(.listening(handsFree: false))
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.hud.model.push(level: self.recorder.level)
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func cancelRecording(silently: Bool = false) {
        stopLevelTimer()
        recorder.stop()
        phase = .idle
        hud.show(silently ? .hidden : .message("已取消"), autoHideAfter: silently ? nil : 0.8)
    }

    private func finishRecording() {
        stopLevelTimer()
        let duration = recorder.duration
        let wav = recorder.stop()
        let peak = wav.count > 44 ? wav.dropFirst(44).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
        } : 0
        Log.info(String(format: "recorded %.2fs, %d bytes, peak=%d/32767", duration, wav.count, peak))
        guard duration >= Self.minDuration else {
            phase = .idle
            hud.show(.hidden)
            return
        }
        phase = .processing
        hud.show(.thinking)
        let config = self.config
        let focus = self.focus
        let audioName = config.saveRecordings ? History.saveRecording(wav) : nil
        let screenTask = self.screenTask
        Task { @MainActor in
            let screen = await screenTask?.value ?? ScreenContext()
            await self.process(wav: wav, config: config, focus: focus, audioName: audioName, screen: screen)
            self.phase = .idle
        }
    }

    // MARK: - 识别 → 润色 → 输入

    @MainActor
    private func process(wav: Data, config: Config, focus: FocusContext, audioName: String?,
                         screen: ScreenContext = ScreenContext(), insert: Bool = true) async {
        let started = Date()
        // 识别阶段的上下文只放光标前的一小段文字。
        // 不放 App 名之类的固定文字：录音几乎没有人声时，模型会把上下文原样“念”出来
        var asrContext = ""
        if config.useFieldContext, let before = focus.textBeforeCursor?.suffix(200), !before.isEmpty {
            asrContext = "输入框前文：\(before)"
        }
        // 热词 = 用户词汇表 + 屏幕上出现的术语（去重，用户词优先）
        var hotwords = config.vocabularyList
        var seenWords = Set(hotwords.map { $0.lowercased() })
        for term in screen.terms where seenWords.insert(term.lowercased()).inserted { hotwords.append(term) }
        Log.info("context: screen[\(screen.source)] \(screen.visibleText.count) chars, \(screen.terms.count) terms: \(screen.terms.prefix(15).joined(separator: ","))")
        let raw: String
        do {
            raw = try await Transcriber.transcribe(wav: wav, config: config, context: asrContext, hotwords: hotwords)
        } catch {
            hud.show(.message("识别失败：\(error.localizedDescription)"), autoHideAfter: 4)
            Log.info("ASR error: \(error)")
            return
        }
        guard !raw.isEmpty, !Self.isContextEcho(raw, context: asrContext, hotwords: hotwords) else {
            if !raw.isEmpty { Log.info("dropped context echo: \(raw)") }
            hud.show(.message("没有听清"), autoHideAfter: 1.2)
            return
        }

        var output = raw
        var note: String?
        let editingSelection = config.editSelection && !(focus.selectedText ?? "").isEmpty
        let llmReady = config.llmEnabled && !config.llmBaseURL.isEmpty
        if config.correctorEnabled, !editingSelection {
            // 纠错：听录音、看屏幕，只改听错的词
            do {
                let context = [focus.textBeforeCursor.map { String($0.suffix(500)) } ?? "",
                               String(screen.visibleText.suffix(2500))].filter { !$0.isEmpty }.joined(separator: "\n")
                let fixes = try await Corrector.correct(wav: wav, draft: raw, context: context, hotwords: hotwords, config: config)
                let result = Corrector.apply(fixes, to: raw)
                output = result.text.isEmpty ? raw : result.text
                if !fixes.isEmpty {
                    func show(_ f: [Corrector.Fix]) -> String { f.map { "\($0.from)→\($0.to)" }.joined(separator: ", ") }
                    note = "fixes: [\(show(result.applied))] rejected: [\(show(result.rejected))]"
                    Log.info("correct: \(note!)")
                }
            } catch {
                Log.info("corrector error: \(error.localizedDescription), using raw")
            }
        } else if llmReady {
            do {
                if config.editSelection, let selected = focus.selectedText, !selected.isEmpty {
                    output = try await Polisher.edit(selected: selected, instruction: raw, config: config)
                } else {
                    let context = config.useFieldContext ? focus.textBeforeCursor : nil
                    let polished = try await Polisher.polish(raw, appName: focus.appName, fieldContext: context,
                                                             vocabulary: hotwords, config: config)
                    if Polisher.isSafe(raw: raw, polished: polished) {
                        output = polished
                    } else {
                        note = "polish rejected: \(polished)"
                        Log.info("polish rejected (too different), using raw. raw=\(raw) polished=\(polished)")
                    }
                }
                if output.isEmpty { output = raw }
            } catch {
                // LLM 挂了也要能用：退回原始转写
                Log.info("LLM error: \(error)")
                output = raw
            }
        }

        lastResult = output
        if insert {   // 诊断运行不写历史
            History.append(raw: raw, final: output, app: focus.bundleID, seconds: Date().timeIntervalSince(started),
                           audio: audioName, note: note)
        }
        hud.show(.hidden)
        Log.info(String(format: "result (%.2fs): %@", Date().timeIntervalSince(started), output))
        if insert { await TextInserter.insert(output, config: config) }
    }

    /// 识别结果只是上下文或词汇表的原文 → 模型在没听到人声时“念”了提示词，丢弃
    static func isContextEcho(_ raw: String, context: String, hotwords: [String]) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let r = norm(raw)
        guard r.count >= 2 else { return false }
        if norm(context).contains(r) { return true }
        // 结果完全由热词拼成，例如 "Python Ollama MLX"
        var rest = r
        for w in hotwords.map(norm).filter({ $0.count >= 2 }).sorted(by: { $0.count > $1.count }) {
            rest = rest.replacingOccurrences(of: w, with: "")
        }
        return rest.isEmpty
    }

    // MARK: - 菜单

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Vocalocal")
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "启动中…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("粘贴上一次结果", #selector(pasteLast)))
        menu.addItem(item("打开历史记录", #selector(openHistory)))
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(openSettings), key: ","))
        menu.addItem(item("打开辅助功能设置", #selector(openAccessibility)))
        menu.addItem(item("打开麦克风设置", #selector(openMicrophone)))
        menu.addItem(item("打开屏幕录制设置", #selector(openScreenRecording)))
        let login = item("开机启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func updateStatus(_ text: String) {
        statusLine?.title = text
    }

    @objc private func pasteLast() {
        guard let lastResult else { return }
        let config = self.config
        // 等菜单关闭、焦点回到原 App 后再粘贴
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task { @MainActor in await TextInserter.insert(lastResult, config: config) }
        }
    }

    @objc private func openHistory() { NSWorkspace.shared.open(History.fileURL) }
    @objc private func openSettings() { settings.show(config: config) }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openScreenRecording() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            hud.show(.message("开机启动设置失败"), autoHideAfter: 2)
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

enum History {
    static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vocalocal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    /// 保存录音，返回文件名（记录在 history.jsonl 的 audio 字段，方便之后挑样本做评测）
    static func saveRecording(_ wav: Data) -> String? {
        let dir = fileURL.deletingLastPathComponent().appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = f.string(from: Date()) + ".wav"
        do {
            try wav.write(to: dir.appendingPathComponent(name))
            return name
        } catch {
            Log.info("save recording failed: \(error)")
            return nil
        }
    }

    static func append(raw: String, final: String, app: String?, seconds: TimeInterval, audio: String? = nil, note: String? = nil) {
        var entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "app": app ?? "",
            "raw": raw,
            "final": final,
            "latency": (seconds * 100).rounded() / 100,
        ]
        if let audio { entry["audio"] = audio }
        if let note { entry["note"] = note }
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.withoutEscapingSlashes]) else { return }
        line.append(0x0A)
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
