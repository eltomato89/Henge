// SPDX-License-Identifier: GPL-2.0-or-later
import AVFAudio
import Foundation

/// Keeps a running Mac running while Henge is in the background (Settings > Background).
///
/// The app has the audio background mode, but iOS only honours it while sound is playing, and the
/// Mac's sound card goes quiet whenever macOS has nothing to play: then iOS suspends Henge within
/// seconds and the Mac freezes. This plays silence for as long as a Mac session is open, so iOS
/// keeps the process going. It mixes with other apps' sound and is inaudible.
///
/// It does not protect against jetsam: under memory pressure iOS ends background apps first, and a
/// Mac makes Henge a large one. Less Mac memory and fewer other apps open make that less likely.
final class KeepAlive {
    static let shared = KeepAlive()
    static let key = "henge.background.keepAlive"

    /// On unless turned off.
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var wanted = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() {
        guard Self.isOn, !wanted else { return }
        wanted = true
        let center = NotificationCenter.default
        // A call or another app's audio session can stop ours; pick it up again afterwards.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            HengeLog.log("background", "audio interruption ended; keeping alive again")
            self?.play()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            HengeLog.log("background", "audio route changed; keeping alive again")
            self?.play()
        })
        play()
    }

    func stop() {
        guard wanted else { return }
        wanted = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        player.stop()
        engine.stop()
        HengeLog.log("background", "keep-alive off")
    }

    private func play() {
        guard wanted else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying {
                let format = player.outputFormat(forBus: 0)
                // One second of zeros, looped.
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
                buffer.frameLength = buffer.frameCapacity
                player.scheduleBuffer(buffer, at: nil, options: .loops)
                player.volume = 0
                player.play()
            }
            HengeLog.log("background", "keep-alive on: Henge keeps running in the background while a Mac runs")
        } catch {
            HengeLog.log("background", "keep-alive failed: \(error.localizedDescription)")
        }
    }
}
