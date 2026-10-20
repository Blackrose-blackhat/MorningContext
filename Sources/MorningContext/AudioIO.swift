import Foundation
import AVFoundation

/// One audio engine for the conversation: the mic and the voice share it, with Apple's voice processing
/// (echo cancellation) on, so the mic can stay open while Morning Context talks without hearing itself.
/// That's what makes "just start talking to interrupt" work.
final class AudioIO {
    static let shared = AudioIO()

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// What the voice is played at (ElevenLabs PCM is 24 kHz mono; the Mac voice is converted to it).
    let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    private(set) var running = false
    private(set) var echoCancelling = false
    private var attached = false
    private let lock = NSLock()
    private var inputHandler: ((AVAudioPCMBuffer) -> Void)?
    /// Loudness of what's being played (0…1), on the main queue — drives the orb and bars while it talks.
    var onOutputLevel: ((Float) -> Void)?

    /// What listeners receive: always mono. With echo cancellation the mic arrives as several channels (your
    /// echo-cancelled voice on channel 0, plus references), which the speech recognizer silently can't use.
    var inputFormat: AVAudioFormat {
        let f = engine.inputNode.outputFormat(forBus: 0)
        return AVAudioFormat(standardFormatWithSampleRate: f.sampleRate, channels: 1) ?? f
    }

    /// Channel 0 as its own mono buffer (no copy when it's already mono float).
    static func mono(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard b.format.channelCount > 1 || b.format.commonFormat != .pcmFormatFloat32,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: b.format.sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: b.frameLength),
              let src = b.floatChannelData?[0], let dst = out.floatChannelData?[0] else { return b }
        out.frameLength = b.frameLength
        memcpy(dst, src, Int(b.frameLength) * MemoryLayout<Float>.size)
        return out
    }

    /// Called on the audio thread with every mic buffer (already echo-cancelled when that's available).
    func setInputHandler(_ h: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); inputHandler = h; lock.unlock()
    }

    func start() throws {
        guard !running else { return }
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            // Some device combos (e.g. external display speakers + Mac mic) can't run voice processing.
            AppLog().info("echo cancellation unavailable (\(error.localizedDescription)); running without it")
            teardown()
            try startEngine(voiceProcessing: false)
        }
    }

    private func startEngine(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        let output = engine.outputNode
        if input.isVoiceProcessingEnabled != voiceProcessing { try input.setVoiceProcessingEnabled(voiceProcessing) }
        if output.isVoiceProcessingEnabled != voiceProcessing { try output.setVoiceProcessingEnabled(voiceProcessing) }
        echoCancelling = voiceProcessing
        if voiceProcessing, #available(macOS 14.0, *) {
            // Don't squash your music or other apps while we talk.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        if !attached {
            engine.attach(player)
            attached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw NSError(domain: "MorningContext", code: 3, userInfo: [NSLocalizedDescriptionKey: "No microphone found."]) }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); let h = self.inputHandler; self.lock.unlock()
            h?(AudioIO.mono(buffer))
        }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
            DispatchQueue.main.async { self?.onOutputLevel?(level) }
        }
        engine.prepare()
        try engine.start()
        player.play()
        running = true
        AppLog().info("audio engine on (echo cancellation: \(echoCancelling), mic \(Int(fmt.sampleRate)) Hz × \(fmt.channelCount))")
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

    func stop() {
        guard running else { return }
        setInputHandler(nil)
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    /// Plays one sentence; `done` runs on the main queue when it has finished (or was stopped).
    func play(_ buffer: AVAudioPCMBuffer, done: @escaping () -> Void) {
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Cuts the voice off immediately (barge-in).
    func stopPlayback() {
        player.stop()
        if running { player.play() }
    }

    // MARK: Buffers

    /// ElevenLabs `pcm_24000`: 16-bit little-endian mono → a playable float buffer.
    func buffer(pcm16 data: Data) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        return buf
    }

    /// Joins the Mac voice's rendered chunks, then resamples them to `playFormat` in a single pass.
    /// (Converting chunk by chunk drops samples at every boundary, which you hear as stutter.)
    func convert(_ chunks: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        let parts = chunks.filter { $0.frameLength > 0 }
        guard let fmt = parts.first?.format else { return nil }
        let total = parts.reduce(0) { $0 + Int($1.frameLength) }
        guard let joined = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total)) else { return nil }
        let bytesPerFrame = Int(fmt.streamDescription.pointee.mBytesPerFrame)
        let dst = UnsafeMutableAudioBufferListPointer(joined.mutableAudioBufferList)
        for part in parts where part.format == fmt {
            let src = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
            let offset = Int(joined.frameLength) * bytesPerFrame
            let bytes = Int(part.frameLength) * bytesPerFrame
            for (s, d) in zip(src, dst) where s.mData != nil && d.mData != nil {
                memcpy(d.mData! + offset, s.mData!, bytes)
            }
            joined.frameLength += part.frameLength
        }
        if fmt == playFormat { return joined }
        guard let conv = AVAudioConverter(from: fmt, to: playFormat) else { return nil }
        let cap = AVAudioFrameCount(Double(joined.frameLength) * playFormat.sampleRate / fmt.sampleRate + 4096)
        guard let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: cap) else { return nil }
        var given = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }   // end of stream flushes the resampler's tail
            given = true; status.pointee = .haveData; return joined
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// WAV wrapper so ElevenLabs PCM also plays outside a conversation (Settings → Test voice).
    static func wav(pcm16 data: Data, sampleRate: Int = 24_000) -> Data {
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + data.count)); h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        h.append("data".data(using: .ascii)!); u32(UInt32(data.count))
        return h + data
    }
}
