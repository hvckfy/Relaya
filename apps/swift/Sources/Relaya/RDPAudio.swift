import AVFoundation
import RelayaCore

/// Звук удалённой машины: PCM из ядра (16 бит little-endian) → AVAudioEngine. Формат берётся из первого пакета;
/// смена формата пересоздаёт плеер не чаще раза в секунду (сервер, меняющий формат на каждом пакете, не дёргает звук).
@MainActor
final class RDPAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: RDPEngine.AudioFormat?
    private var output: AVAudioFormat?
    private var lastReset = Date.distantPast
    /// Громкость пользователя (0…1) × громкость сервера.
    var volume: Float = 1 { didSet { apply() } }
    private var serverVolume: Float = 1

    init() {
        engine.attach(player)
    }

    func setServerVolume(_ v: Double) {
        serverVolume = Float(v)
        apply()
    }

    private func apply() { player.volume = volume * serverVolume }

    func play(_ f: RDPEngine.AudioFormat, _ pcm: Data) {
        guard f.bitsPerSample == 16, f.channels > 0, f.sampleRate > 0 else { return }
        if f != format {
            guard Date().timeIntervalSince(lastReset) > 1 else { return }
            lastReset = Date()
            reconfigure(f)
        }
        guard let output else { return }
        let frames = pcm.count / (2 * f.channels)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for ch in 0..<f.channels {
                guard let dst = buffer.floatChannelData?[ch] else { continue }
                for i in 0..<frames { dst[i] = Float(Int16(littleEndian: src[i * f.channels + ch])) / 32768 }
            }
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    private func reconfigure(_ f: RDPEngine.AudioFormat) {
        player.stop()
        engine.stop()
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(f.sampleRate),
                                      channels: AVAudioChannelCount(f.channels), interleaved: false) else { return }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: out)
        do {
            try engine.start()
            format = f
            output = out
            apply()
        } catch {
            format = nil
            output = nil
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        format = nil
        output = nil
    }
}
