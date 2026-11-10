import Foundation

@main
struct HardwareShortcutTests {
    typealias E = HardwareShortcutMapper.KeyEvent
    typealias Shortcut = HardwareShortcutMapper.Shortcut
    static let control: UInt8 = 0xe0, rightControl: UInt8 = 0xe4
    static let shift: UInt8 = 0xe1, command: UInt8 = 0xe3
    static let tab: UInt8 = 0x2b, q: UInt8 = 0x14, a: UInt8 = 0x04, space: UInt8 = 0x2c
    static let allShortcuts: Set<Shortcut> = [.appSwitcher, .quit, .spotlight]
    static let noShortcuts: Set<Shortcut> = []

    static func key(_ usage: UInt8, _ down: Bool) -> E { E(usage: usage, down: down) }

    static func check(_ actual: [E], _ expected: [E], _ name: String) {
        guard actual == expected else { fatalError("\(name): got \(actual), expected \(expected)") }
    }

    static func main() {
        checkSettingsMigration()
        var keys = HardwareShortcutMapper()
        check(keys.event(control, down: true, enabled: noShortcuts.contains), [key(control, true)], "disabled control")
        check(keys.event(tab, down: true, enabled: noShortcuts.contains), [key(tab, true)], "disabled tab")
        check(keys.event(tab, down: false, enabled: noShortcuts.contains), [key(tab, false)], "disabled tab release")
        check(keys.event(control, down: false, enabled: noShortcuts.contains), [key(control, false)], "disabled control release")

        check(keys.event(control, down: true, enabled: allShortcuts.contains), [key(control, true)], "control")
        check(keys.event(tab, down: true, enabled: allShortcuts.contains), [key(control, false), key(command, true), key(tab, true)], "start switcher")
        check(keys.event(tab, down: false, enabled: allShortcuts.contains), [key(tab, false)], "keep switcher open")
        check(keys.event(tab, down: true, enabled: allShortcuts.contains), [key(tab, true)], "cycle")
        check(keys.event(tab, down: false, enabled: noShortcuts.contains), [key(tab, false)], "setting changed mid-chord")
        check(keys.event(control, down: false, enabled: noShortcuts.contains), [key(command, false)], "finish switcher")
        check(keys.releaseAll(), [], "switcher cleanup")

        check(keys.event(rightControl, down: true, enabled: allShortcuts.contains), [key(rightControl, true)], "right control")
        check(keys.event(shift, down: true, enabled: allShortcuts.contains), [key(shift, true)], "shift")
        check(keys.event(tab, down: true, enabled: allShortcuts.contains), [key(rightControl, false), key(command, true), key(tab, true)], "reverse switcher")
        check(keys.event(tab, down: false, enabled: allShortcuts.contains), [key(tab, false)], "reverse tab release")
        check(keys.event(rightControl, down: false, enabled: allShortcuts.contains), [key(command, false)], "reverse control release")
        check(keys.event(shift, down: false, enabled: allShortcuts.contains), [key(shift, false)], "reverse shift release")

        check(keys.event(control, down: true, enabled: allShortcuts.contains), [key(control, true)], "quit control")
        check(keys.event(q, down: true, enabled: allShortcuts.contains), [key(control, false), key(command, true), key(q, true)], "quit")
        check(keys.event(q, down: false, enabled: allShortcuts.contains), [key(q, false), key(command, false), key(control, true)], "quit release restores control")
        check(keys.event(a, down: true, enabled: allShortcuts.contains), [key(a, true)], "ordinary control shortcut")
        check(keys.event(a, down: false, enabled: allShortcuts.contains), [key(a, false)], "ordinary release")
        check(keys.event(control, down: false, enabled: allShortcuts.contains), [key(control, false)], "ordinary control release")

        check(keys.event(control, down: true, enabled: allShortcuts.contains), [key(control, true)], "cleanup control")
        check(keys.event(tab, down: true, enabled: allShortcuts.contains), [key(control, false), key(command, true), key(tab, true)], "cleanup switcher")
        check(keys.releaseAll(), [key(tab, false), key(command, false)], "focus loss releases guest keys")
        check(keys.event(tab, down: false, enabled: allShortcuts.contains), [], "late release ignored")
        check(keys.releaseAll(), [], "cleanup is idempotent")

        check(keys.event(control, down: true, enabled: allShortcuts.contains), [key(control, true)], "mixed control")
        check(keys.event(command, down: true, enabled: allShortcuts.contains), [key(command, true)], "physical command")
        check(keys.event(tab, down: true, enabled: allShortcuts.contains), [key(tab, true)], "existing command is not remapped")
        _ = keys.releaseAll()
        check(keys.event(control, down: true, enabled: allShortcuts.contains), [key(control, true)], "switch to other chord")
        _ = keys.event(tab, down: true, enabled: allShortcuts.contains)
        _ = keys.event(tab, down: false, enabled: allShortcuts.contains)
        check(keys.event(a, down: true, enabled: allShortcuts.contains), [key(command, false), key(control, true), key(a, true)], "other key restores control")
        _ = keys.releaseAll()

        _ = keys.event(control, down: true, enabled: allShortcuts.contains)
        _ = keys.event(rightControl, down: true, enabled: allShortcuts.contains)
        check(keys.event(tab, down: true, enabled: allShortcuts.contains), [key(control, false), key(rightControl, false), key(command, true), key(tab, true)], "both controls suppressed")
        check(keys.event(control, down: false, enabled: allShortcuts.contains), [], "one control still held")
        check(keys.event(rightControl, down: false, enabled: allShortcuts.contains), [key(command, false)], "last control ends switcher")
        check(keys.event(tab, down: false, enabled: allShortcuts.contains), [key(tab, false)], "tab released after control")
        _ = keys.event(control, down: true, enabled: allShortcuts.contains)
        _ = keys.event(shift, down: true, enabled: allShortcuts.contains)
        check(keys.event(q, down: true, enabled: allShortcuts.contains), [key(q, true)], "shift-control-q remains unchanged")
        _ = keys.releaseAll()

        _ = keys.event(control, down: true, enabled: allShortcuts.contains)
        _ = keys.event(tab, down: true, enabled: allShortcuts.contains)
        check(keys.event(command, down: true, enabled: allShortcuts.contains), [], "physical command shares synthetic press")
        check(keys.event(control, down: false, enabled: allShortcuts.contains), [], "physical command remains held")
        check(keys.event(command, down: false, enabled: allShortcuts.contains), [key(command, false)], "physical command releases normally")
        _ = keys.releaseAll()

        _ = keys.event(control, down: true, enabled: allShortcuts.contains)
        _ = keys.event(q, down: true, enabled: allShortcuts.contains)
        check(keys.event(a, down: true, enabled: allShortcuts.contains),
              [key(command, false), key(control, true), key(a, true)], "other key interrupts quit")
        check(keys.event(q, down: false, enabled: allShortcuts.contains), [key(q, false)], "interrupted quit releases Q")
        _ = keys.releaseAll()

        let spotlightOnly: Set<Shortcut> = [.spotlight]
        _ = keys.event(control, down: true, enabled: spotlightOnly.contains)
        check(keys.event(tab, down: true, enabled: spotlightOnly.contains), [key(tab, true)], "Tab is off when only Spotlight is enabled")
        _ = keys.event(tab, down: false, enabled: spotlightOnly.contains)
        check(keys.event(q, down: true, enabled: spotlightOnly.contains), [key(q, true)], "Q is off when only Spotlight is enabled")
        _ = keys.event(q, down: false, enabled: spotlightOnly.contains)
        check(keys.event(space, down: true, enabled: spotlightOnly.contains),
              [key(control, false), key(command, true), key(space, true)], "Spotlight")
        check(keys.event(space, down: false, enabled: noShortcuts.contains),
              [key(space, false), key(command, false), key(control, true)], "Spotlight restores Control after a settings change")
        check(keys.event(space, down: true, enabled: noShortcuts.contains), [key(space, true)], "Space is off when Spotlight is disabled")
        _ = keys.releaseAll()

        _ = keys.event(control, down: true, enabled: spotlightOnly.contains)
        _ = keys.event(shift, down: true, enabled: spotlightOnly.contains)
        check(keys.event(space, down: true, enabled: spotlightOnly.contains), [key(space, true)], "shift-control-space remains unchanged")
        _ = keys.releaseAll()

        print("PASS: hardware shortcut mapping and release handling")
    }

    static func checkSettingsMigration() {
        let suite = "Henge.HardwareShortcutTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("could not open test preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldKey = "henge.keyboard.controlMacShortcuts"

        HardwareShortcutMapper.migrateSettings(in: defaults)
        precondition(allShortcuts.allSatisfy { defaults.object(forKey: $0.defaultsKey) == nil })

        defaults.set(true, forKey: oldKey)
        HardwareShortcutMapper.migrateSettings(in: defaults)
        precondition(defaults.bool(forKey: Shortcut.appSwitcher.defaultsKey))
        precondition(defaults.bool(forKey: Shortcut.quit.defaultsKey))
        precondition(!defaults.bool(forKey: Shortcut.spotlight.defaultsKey))

        defaults.set(true, forKey: oldKey)
        defaults.set(false, forKey: Shortcut.quit.defaultsKey)
        HardwareShortcutMapper.migrateSettings(in: defaults)
        precondition(!defaults.bool(forKey: Shortcut.quit.defaultsKey))
        precondition(defaults.object(forKey: oldKey) == nil)
    }
}
