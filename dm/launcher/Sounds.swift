// The interface's sounds: a soft bell as the choice moves, two rising notes to choose, one falling to go back. Made here once (a few hundred bytes of PCM each),
// played at Settings › Sound & music › Interface volume; off with Interface sounds.
import AppKit

enum UISound {
    case move, select, back
    private static let sounds: [UISound: NSSound] = [.move: make([(1320, 0, 0.07)]), .select: make([(880, 0, 0.06), (1320, 0.07, 0.1)]), .back: make([(990, 0, 0.06), (740, 0.06, 0.09)])]
    static var on: Bool { UserDefaults.standard.object(forKey: "sounds.on") as? Bool ?? true }
    static var volume: Float { UserDefaults.standard.object(forKey: "sounds.volume") as? Float ?? 0.4 }

    func play() {
        guard UISound.on, let s = UISound.sounds[self] else { return }
        s.stop(); s.volume = UISound.volume; s.play()
    }

    /// Bells: (frequency, start, decay) each, two partials, a 2 ms attack
    private static func make(_ notes: [(Double, Double, Double)]) -> NSSound {
        let rate = 44100.0, length = (notes.map { $0.1 + $0.2 * 6 }.max() ?? 0.3)
        let n = Int(rate * length)
        var pcm = [Int16](repeating: 0, count: n)
        for (f, t0, d) in notes {
            for i in Int(t0 * rate)..<n {
                let t = Double(i) / rate - t0
                let e = exp(-t / d) * min(1, t / 0.002)
                let v = (sin(2 * .pi * f * t) + 0.4 * sin(2 * .pi * f * 2.01 * t)) * e * 0.35
                pcm[i] = Int16(max(-32767, min(32767, Double(pcm[i]) + v * 32767)))
            }
        }
        var wav = Data("RIFF".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; wav.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; wav.append(Data(bytes: &x, count: 2)) }
        u32(36 + n * 2); wav.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(Int(rate)); u32(Int(rate) * 2); u16(2); u16(16)
        wav.append(Data("data".utf8)); u32(n * 2)
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
        return NSSound(data: wav) ?? NSSound()
    }
}
