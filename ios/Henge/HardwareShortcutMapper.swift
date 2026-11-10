import Foundation

/// Sends Command in place of Control for selected shortcuts on a physical keyboard.
struct HardwareShortcutMapper {
    enum Shortcut: UInt8 {
        case appSwitcher = 0x2b
        case quit = 0x14
        case spotlight = 0x2c

        var defaultsKey: String {
            switch self {
            case .appSwitcher: "henge.keyboard.controlTab"
            case .quit: "henge.keyboard.controlQ"
            case .spotlight: "henge.keyboard.controlSpace"
            }
        }
    }

    /// The old switch covered Tab and Q together. Keep that choice for both.
    static func migrateSettings(in defaults: UserDefaults = .standard) {
        let oldKey = "henge.keyboard.controlMacShortcuts"
        guard defaults.object(forKey: oldKey) != nil else { return }
        for shortcut in [Shortcut.appSwitcher, .quit] where defaults.object(forKey: shortcut.defaultsKey) == nil {
            defaults.set(defaults.bool(forKey: oldKey), forKey: shortcut.defaultsKey)
        }
        defaults.removeObject(forKey: oldKey)
    }

    struct KeyEvent: Equatable {
        let usage: UInt8
        let down: Bool
    }

    private static let leftControl: UInt8 = 0xe0
    private static let rightControl: UInt8 = 0xe4
    private static let leftCommand: UInt8 = 0xe3
    private static let rightCommand: UInt8 = 0xe7

    private var activeShortcut: Shortcut?
    private var physical: Set<UInt8> = []
    private var guest: Set<UInt8> = []

    var hasHeldKey: Bool { physical.contains { $0 < 0xe0 } }

    private var controlHeld: Bool {
        physical.contains(Self.leftControl) || physical.contains(Self.rightControl)
    }

    private mutating func send(_ usage: UInt8, _ down: Bool, into events: inout [KeyEvent]) {
        let changed = down ? guest.insert(usage).inserted : guest.remove(usage) != nil
        if changed { events.append(KeyEvent(usage: usage, down: down)) }
    }

    private mutating func endMapping(into events: inout [KeyEvent]) {
        activeShortcut = nil
        if !physical.contains(Self.leftCommand) { send(Self.leftCommand, false, into: &events) }
        for control in [Self.leftControl, Self.rightControl] where physical.contains(control) {
            send(control, true, into: &events)
        }
    }

    mutating func event(_ usage: UInt8, down: Bool, enabled: (Shortcut) -> Bool) -> [KeyEvent] {
        var events: [KeyEvent] = []
        let changed = down ? physical.insert(usage).inserted : physical.remove(usage) != nil
        guard changed else { return events }

        if usage == Self.leftControl || usage == Self.rightControl {
            if activeShortcut != nil {
                if !controlHeld { endMapping(into: &events) }
            } else {
                send(usage, down, into: &events)
            }
            return events
        }

        // Let the next key see Control again, even if the shortcut key is still down.
        if down, let activeShortcut, usage < 0xe0, usage != activeShortcut.rawValue {
            endMapping(into: &events)
        }

        let noCommandOrOption = physical.isDisjoint(with: [Self.leftCommand, Self.rightCommand, 0xe2, 0xe6])
        let noOtherKey = !physical.contains { $0 < 0xe0 && $0 != usage }
        let noShift = physical.isDisjoint(with: [0xe1, 0xe5])
        if down, activeShortcut == nil, controlHeld, noCommandOrOption, noOtherKey,
           let shortcut = Shortcut(rawValue: usage), shortcut == .appSwitcher || noShift, enabled(shortcut) {
            for control in [Self.leftControl, Self.rightControl] { send(control, false, into: &events) }
            activeShortcut = shortcut
            send(Self.leftCommand, true, into: &events)
        }

        // Releasing the physical Command doesn't lift the Command held by the shortcut.
        if usage != Self.leftCommand || down || activeShortcut == nil {
            send(usage, down, into: &events)
        }
        // Leave Command down between Tab presses so the app switcher stays open.
        if !down, let activeShortcut, activeShortcut != .appSwitcher, usage == activeShortcut.rawValue {
            endMapping(into: &events)
        }
        return events
    }

    mutating func releaseAll() -> [KeyEvent] {
        let releases = guest.sorted { a, b in
            let am = a >= 0xe0, bm = b >= 0xe0
            return am != bm ? !am : a < b
        }.map { KeyEvent(usage: $0, down: false) }
        physical.removeAll()
        guest.removeAll()
        activeShortcut = nil
        return releases
    }
}
