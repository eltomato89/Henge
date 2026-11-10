import Foundation

/// Translates selected physical keyboard shortcuts without changing the other Control combinations.
struct HardwareShortcutMapper {
    static let enabledKey = "henge.keyboard.controlMacShortcuts"

    struct KeyEvent: Equatable {
        let usage: UInt8
        let down: Bool
    }

    private static let leftControl: UInt8 = 0xe0
    private static let rightControl: UInt8 = 0xe4
    private static let leftCommand: UInt8 = 0xe3
    private static let rightCommand: UInt8 = 0xe7
    private static let tab: UInt8 = 0x2b
    private static let q: UInt8 = 0x14

    private enum Mapping { case switcher, quit }
    private var mapping: Mapping?
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
        guard mapping != nil else { return }
        mapping = nil
        if !physical.contains(Self.leftCommand) { send(Self.leftCommand, false, into: &events) }
        for control in [Self.leftControl, Self.rightControl] where physical.contains(control) {
            send(control, true, into: &events)
        }
    }

    /// `enabled` is sampled when a shortcut starts, so changing the setting mid-chord is safe.
    mutating func event(_ usage: UInt8, down: Bool, enabled: Bool) -> [KeyEvent] {
        var events: [KeyEvent] = []
        let changed = down ? physical.insert(usage).inserted : physical.remove(usage) != nil
        guard changed else { return events }

        if usage == Self.leftControl || usage == Self.rightControl {
            if mapping != nil {
                if !controlHeld { endMapping(into: &events) }
            } else {
                send(usage, down, into: &events)
            }
            return events
        }

        if down, mapping == .switcher, usage < 0xe0, usage != Self.tab {
            endMapping(into: &events)
        }

        let noCommandOrOption = physical.isDisjoint(with: [Self.leftCommand, Self.rightCommand, 0xe2, 0xe6])
        let noOtherKey = !physical.contains { $0 < 0xe0 && $0 != usage }
        let noShift = physical.isDisjoint(with: [0xe1, 0xe5])
        if down, mapping == nil, enabled, controlHeld, noCommandOrOption, noOtherKey,
           usage == Self.tab || (usage == Self.q && noShift) {
            for control in [Self.leftControl, Self.rightControl] { send(control, false, into: &events) }
            mapping = usage == Self.tab ? .switcher : .quit
            send(Self.leftCommand, true, into: &events)
        }

        // A physical left Command can share the synthetic Command while the switcher is open.
        if usage != Self.leftCommand || down || mapping == nil {
            send(usage, down, into: &events)
        }
        if !down, usage == Self.q, mapping == .quit { endMapping(into: &events) }
        return events
    }

    /// End every guest press, including a synthetic Command, when focus or the session is lost.
    mutating func releaseAll() -> [KeyEvent] {
        let releases = guest.sorted { a, b in
            let am = a >= 0xe0, bm = b >= 0xe0
            return am != bm ? !am : a < b
        }.map { KeyEvent(usage: $0, down: false) }
        physical.removeAll()
        guest.removeAll()
        mapping = nil
        return releases
    }
}
