import AVFoundation

/// 用 AVAudioEngine 采集麦克风，实时转成 16 kHz 单声道 Int16 PCM（语音识别的标准输入），
/// 结束时输出 WAV。Typeless 自己是编码成 Opus 再上传以节省流量；
/// 我们直接传 WAV：1 分钟约 1.9 MB，所有 OpenAI 兼容接口都支持。
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var _level: Float = 0
    private(set) var isRecording = false

    /// 0...1 的音量，用于 HUD 波形
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / Self.sampleRate
    }

    /// noiseSuppression：启用系统 Voice Processing I/O（回声消除 + 降噪 + 自动增益，和 FaceTime 同一套），
    /// 在嘈杂环境、外放音乐时识别率提升明显
    func start(noiseSuppression: Bool) throws {
        guard !isRecording else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        _level = 0
        lock.unlock()

        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != noiseSuppression {
            do {
                try input.setVoiceProcessingEnabled(noiseSuppression)
            } catch {
                Log.info("voice processing unavailable: \(error)")
            }
        }
        if noiseSuppression, #available(macOS 14.0, *) {
            // 默认会把其它 App 的声音压得很低，录音时音乐突然变小很突兀
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
        }

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Vocalocal", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风"])
        }
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                      channels: 1, interleaved: true)!
        // 开启 Voice Processing 后输入是多声道（实测 9 ch），处理后的人声只在第 0 声道；
        // 直接让 AVAudioConverter 混音会得到全静音，所以先手动取第 0 声道再重采样
        monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate,
                                   channels: 1, interleaved: false)
        converter = AVAudioConverter(from: monoFormat!, to: outFormat)
        Log.info("recording: input=\(inFormat) voiceProcessing=\(input.isVoiceProcessingEnabled)")

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer, outFormat: outFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// 停止录音并返回 WAV 数据
    @discardableResult
    func stop() -> Data {
        guard isRecording else { return Data() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        let pcm = samples
        _level = 0
        lock.unlock()
        return Self.wav(from: pcm)
    }

    private func process(_ buffer: AVAudioPCMBuffer, outFormat: AVAudioFormat) {
        guard let converter, let monoFormat,
              let src = buffer.floatChannelData?[0],
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData?[0] else { return }
        mono.frameLength = buffer.frameLength
        dst.update(from: src, count: Int(buffer.frameLength))

        // 计算音量（RMS → 粗略映射到 0...1）
        var rms: Float = 0
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            rms = sqrtf(sum / Float(buffer.frameLength))
        }
        let db = 20 * log10f(max(rms, 1e-6))
        let level = max(0, min(1, (db + 50) / 40))

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let data = out.int16ChannelData?[0] else { return }

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        _level = _level * 0.5 + level * 0.5
        lock.unlock()
    }

    static func wav(from pcm: [Int16]) -> Data {
        let byteCount = pcm.count * 2
        var d = Data(capacity: 44 + byteCount)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + byteCount))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(byteCount))
        pcm.withUnsafeBufferPointer { buf in
            buf.withMemoryRebound(to: UInt8.self) { d.append($0) }
        }
        return d
    }
}
