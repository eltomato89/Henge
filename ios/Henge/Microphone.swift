// SPDX-License-Identifier: GPL-2.0-or-later
import AVFAudio
import Foundation

/// The Mac's microphone is this device's (Settings > Sound). Off by default: the virtual sound card
/// then has no input stream at all (HV_MIC, devices/virtio_snd.c).
enum Microphone {
    static let key = "henge.audio.mic"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// The app's audio session: playback only, or play-and-record while the microphone is on.
    /// The engine's input unit (host/audio_mac.c) needs the record category in place before it starts.
    static func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if isOn {
                // A2DP, not the hands-free profile: Bluetooth headphones keep their sound quality,
                // and the device's own microphone records.
                try session.setCategory(.playAndRecord, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            } else {
                try session.setCategory(.playback, options: [.mixWithOthers])
            }
        } catch {
            HengeLog.log("audio", "audio session category failed: \(error.localizedDescription)")
        }
        HengeLog.log("audio", "microphone \(isOn ? "on" : "off"); permission \(permissionName)")
    }

    /// Ask iOS for the microphone (it asks the user once; later calls answer at once).
    static func requestPermission(_ done: @escaping (Bool) -> Void = { _ in }) {
        AVAudioApplication.requestRecordPermission { granted in
            HengeLog.log("audio", "microphone permission \(granted ? "granted" : "refused")")
            DispatchQueue.main.async { done(granted) }
        }
    }

    private static var permissionName: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        default: return "not asked"
        }
    }
}
