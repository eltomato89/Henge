@main
struct HardwareShortcutTests {
    typealias E = HardwareShortcutMapper.KeyEvent
    static let control: UInt8 = 0xe0, rightControl: UInt8 = 0xe4
    static let shift: UInt8 = 0xe1, command: UInt8 = 0xe3
    static let tab: UInt8 = 0x2b, q: UInt8 = 0x14, a: UInt8 = 0x04

    static func key(_ usage: UInt8, _ down: Bool) -> E { E(usage: usage, down: down) }

    static func check(_ actual: [E], _ expected: [E], _ name: String) {
        guard actual == expected else { fatalError("\(name): got \(actual), expected \(expected)") }
    }

    static func main() {
        var keys = HardwareShortcutMapper()
        check(keys.event(control, down: true, enabled: false), [key(control, true)], "disabled control")
        check(keys.event(tab, down: true, enabled: false), [key(tab, true)], "disabled tab")
        check(keys.event(tab, down: false, enabled: false), [key(tab, false)], "disabled tab release")
        check(keys.event(control, down: false, enabled: false), [key(control, false)], "disabled control release")

        check(keys.event(control, down: true, enabled: true), [key(control, true)], "control")
        check(keys.event(tab, down: true, enabled: true), [key(control, false), key(command, true), key(tab, true)], "start switcher")
        check(keys.event(tab, down: false, enabled: true), [key(tab, false)], "keep switcher open")
        check(keys.event(tab, down: true, enabled: true), [key(tab, true)], "cycle")
        check(keys.event(tab, down: false, enabled: false), [key(tab, false)], "setting changed mid-chord")
        check(keys.event(control, down: false, enabled: false), [key(command, false)], "finish switcher")
        check(keys.releaseAll(), [], "switcher cleanup")

        check(keys.event(rightControl, down: true, enabled: true), [key(rightControl, true)], "right control")
        check(keys.event(shift, down: true, enabled: true), [key(shift, true)], "shift")
        check(keys.event(tab, down: true, enabled: true), [key(rightControl, false), key(command, true), key(tab, true)], "reverse switcher")
        check(keys.event(tab, down: false, enabled: true), [key(tab, false)], "reverse tab release")
        check(keys.event(rightControl, down: false, enabled: true), [key(command, false)], "reverse control release")
        check(keys.event(shift, down: false, enabled: true), [key(shift, false)], "reverse shift release")

        check(keys.event(control, down: true, enabled: true), [key(control, true)], "quit control")
        check(keys.event(q, down: true, enabled: true), [key(control, false), key(command, true), key(q, true)], "quit")
        check(keys.event(q, down: false, enabled: true), [key(q, false), key(command, false), key(control, true)], "quit release restores control")
        check(keys.event(a, down: true, enabled: true), [key(a, true)], "ordinary control shortcut")
        check(keys.event(a, down: false, enabled: true), [key(a, false)], "ordinary release")
        check(keys.event(control, down: false, enabled: true), [key(control, false)], "ordinary control release")

        check(keys.event(control, down: true, enabled: true), [key(control, true)], "cleanup control")
        check(keys.event(tab, down: true, enabled: true), [key(control, false), key(command, true), key(tab, true)], "cleanup switcher")
        check(keys.releaseAll(), [key(tab, false), key(command, false)], "focus loss releases guest keys")
        check(keys.event(tab, down: false, enabled: true), [], "late release ignored")
        check(keys.releaseAll(), [], "cleanup is idempotent")

        check(keys.event(control, down: true, enabled: true), [key(control, true)], "mixed control")
        check(keys.event(command, down: true, enabled: true), [key(command, true)], "physical command")
        check(keys.event(tab, down: true, enabled: true), [key(tab, true)], "existing command is not remapped")
        _ = keys.releaseAll()
        check(keys.event(control, down: true, enabled: true), [key(control, true)], "switch to other chord")
        _ = keys.event(tab, down: true, enabled: true)
        _ = keys.event(tab, down: false, enabled: true)
        check(keys.event(a, down: true, enabled: true), [key(command, false), key(control, true), key(a, true)], "other key restores control")
        _ = keys.releaseAll()

        _ = keys.event(control, down: true, enabled: true)
        _ = keys.event(rightControl, down: true, enabled: true)
        check(keys.event(tab, down: true, enabled: true), [key(control, false), key(rightControl, false), key(command, true), key(tab, true)], "both controls suppressed")
        check(keys.event(control, down: false, enabled: true), [], "one control still held")
        check(keys.event(rightControl, down: false, enabled: true), [key(command, false)], "last control ends switcher")
        check(keys.event(tab, down: false, enabled: true), [key(tab, false)], "tab released after control")
        _ = keys.event(control, down: true, enabled: true)
        _ = keys.event(shift, down: true, enabled: true)
        check(keys.event(q, down: true, enabled: true), [key(q, true)], "shift-control-q remains unchanged")
        _ = keys.releaseAll()

        _ = keys.event(control, down: true, enabled: true)
        _ = keys.event(tab, down: true, enabled: true)
        check(keys.event(command, down: true, enabled: true), [], "physical command shares synthetic press")
        check(keys.event(control, down: false, enabled: true), [], "physical command remains held")
        check(keys.event(command, down: false, enabled: true), [key(command, false)], "physical command releases normally")
        _ = keys.releaseAll()

        print("PASS: hardware shortcut mapping and release handling")
    }
}
