import SwiftUI
import UIKit
import GameController

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads and
    /// squarer phones (iPhone Duo, about 1.46:1) would get bars above and below at 16:9. Phones wider
    /// than 16:9 come out at 1920×1080, as before.
    static var fittingScreen: (width: Int, height: Int) {
        let size = UIScreen.main.bounds.size
        let shape = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
    }

    /// Preserve the iPad's shape while reducing the virtual GPU's pixel work.
    static var performanceScreen: (width: Int, height: Int) {
        let fit = fittingScreen
        return (1600, Int((Double(fit.height) * 5 / 6 / 8).rounded()) * 8)
    }

    /// The panel itself, on its side: every physical pixel, and its real size in mm so that macOS
    /// sees a Retina density and draws at 2x (looks like half the pixels, sharp as the iPad's own UI).
    /// Every iPad with an M chip is 264 ppi.
    static var retinaScreen: (width: Int, height: Int) {
        let n = UIScreen.main.nativeBounds.size
        return (Int(max(n.width, n.height)) / 8 * 8, Int(min(n.width, n.height)) / 8 * 8)
    }
    static var retinaMM: (width: Int, height: Int) {
        let s = retinaScreen
        return (Int((Double(s.width) / 264 * 25.4).rounded()), Int((Double(s.height) / 264 * 25.4).rounded()))
    }

    /// How much memory to suggest for a new Mac: what leaves this device room for iOS.
    static var suggestedRAMGB: Int {
        let mb = ProcessInfo.processInfo.physicalMemory >> 20
        // m4 fork: an 8 GB iPad (7.4 GB usable) thrashes and kills the Mac at 6 GB: 16 GB devices only.
        // A 6 GB device (5.7 GB usable) could not build a 4 GB Mac, and installed a 3 GB one (#70); 4 GB devices, 2.
        return mb >= 14_000 ? 8 : mb >= 10_000 ? 6 : mb >= 7_000 ? 4 : mb >= 5_000 ? 3 : 2
    }

    /// The choices for a Mac's memory, in GB.
    static let memoryChoices = 1...16

    /// What a choice risks on this device, if anything. An install always gets at least 2 GB (Installer.install).
    static func memoryNote(_ gb: Int) -> String? {
        if gb < 4 { return "macOS has little room under 4 GB, so it can be very slow." }
        if gb > suggestedRAMGB { return "More than \(suggestedRAMGB) GB is a lot for this \(name): iOS may close Henge when macOS gets busy." }
        return nil
    }

    /// The virtual CPU offers Armv8.5 instructions (core/sysreg.c), and macOS uses them. They run as
    /// they are, so the chip needs them too: A14, M1 and later, which is iPhone13,x and iPad13,x up.
    static let chipTooOld: Bool = {
        let model = HengeLog.deviceModel
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
              let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return major < 13
    }()

    static let chipTooOldText = "macOS won't run on this \(name). Henge needs an A14 or M1 chip or newer."
}

/// A physical keyboard. iOS and the Mac's USB keyboard use the same HID codes for each key.
enum HardwareKeys {
    private static var mapper = HardwareShortcutMapper()
    private static var lastKey: CFTimeInterval = 0

    /// With the on-screen keyboard's view holding the keyboard, iOS may also offer a hardware key as
    /// text, and again as it repeats. The Mac has the key already, and repeats it itself.
    static var keyJustPressed: Bool {
        mapper.hasHeldKey || CACurrentMediaTime() - lastKey < 0.1
    }

    /// Sends the presses that are keys, and returns the rest.
    static func send(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var rest = Set<UIPress>()
        // A chord can arrive in one unordered Set. Press modifiers first and
        // release them last so the guest sees the intended shortcut.
        let ordered = presses.sorted { a, b in
            let aCode = a.key?.keyCode.rawValue ?? 0
            let bCode = b.key?.keyCode.rawValue ?? 0
            let aModifier = (0xe0...0xe7).contains(aCode)
            let bModifier = (0xe0...0xe7).contains(bCode)
            if aModifier != bModifier { return down ? aModifier : !aModifier }
            return aCode < bCode
        }
        let defaults = UserDefaults.standard
        for press in ordered {
            guard let raw = press.key?.keyCode.rawValue, raw >= 0x04, raw <= 0xe7 else {
                rest.insert(press)
                continue
            }
            let usage = UInt8(raw)
            let events = mapper.event(usage, down: down) { shortcut in
                // The keys above the on-screen keyboard can already be holding a modifier in the Mac.
                StickyKeys.shared.down.isEmpty && defaults.bool(forKey: shortcut.defaultsKey)
            }
            for event in events {
                henge_vm_key_hid(event.usage, event.down ? 1 : 0)
            }
            if usage < 0xe0 { lastKey = CACurrentMediaTime() }
            if !down && usage < 0xe0 { StickyKeys.shared.releaseAll() } // one key after a tap on ⌃, ⌥ or ⌘
        }
        return rest
    }

    /// iPadOS can keep a key's release when it takes over, as it does for ⌘-Tab: the Mac must not
    /// go on thinking the key is down.
    static func releaseAll() {
        for event in mapper.releaseAll() { henge_vm_key_hid(event.usage, 0) }
    }
}

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        wanted = on
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { _ in wanted }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    /// iPadOS only locks the pointer to an app that fills the screen: in a window (Stage Manager, or iPadOS 26's windows)
    /// the request is ignored and the system pointer stays separate from the Mac's (#18). An iPhone never locks it, and
    /// its apps are always full screen, so the hint is for iPad only.
    static var refused: Bool {
        guard Device.isPad, wanted, GCMouse.current != nil else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        return !scenes.isEmpty && !scenes.contains { $0.pointerLockState?.isLocked == true }
    }
}

/// A Magic Keyboard's trackpad or a mouse, while a Mac is running. GameController gives the raw motion,
/// which macOS then accelerates as it would for its own mouse.
final class HardwareMouse {
    static let shared = HardwareMouse()
    static let speedKey = "henge.mouse.speed"
    static let reverseKey = "henge.mouse.reverse"
    static let scrollSpeedKey = "henge.mouse.scrollSpeed"

    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    private var buttons = PhysicalMouseButtons(swapsRightAndMiddle: false)
    private var buttonsLogged = 0
    private var movesLogged = 0
    private var restX: Float = 0, restY: Float = 0
    private var speed: Float = 1
    private var reverse = false
    private var scrollsLogged = 0 // the first few, to see what a device's raw values look like
    private var lastScrollFirst: Float = 0, lastScrollSecond: Float = 0
    private let scrollFingers = ScrollFingers()

    func start() {
        let defaults = UserDefaults.standard
        speed = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        reverse = defaults.bool(forKey: Self.reverseKey)
        releaseButtons()
        let swapButtons = defaults.bool(forKey: PhysicalMouseButtons.swapKey)
        buttons = PhysicalMouseButtons(swapsRightAndMiddle: swapButtons)
        buttonsLogged = 0
        movesLogged = 0
        HengeLog.log("input", "physical mouse: swap right/middle \(swapButtons ? "on" : "off")")
        lastScrollFirst = 0
        lastScrollSecond = 0
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let mouse = note.object as? GCMouse else { return }
            self.releaseButtons()
            self.mice.removeAll { $0 === mouse }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { note in
            // The scene comes in the user info: the notification's object isn't it.
            let scene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene
            let locked = scene?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
        })
        PointerLock.set(true)
    }

    func stop() {
        PointerLock.set(false)
        releaseButtons()
        scrollFingers.end()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.scroll.valueChangedHandler = nil
        }
        mice.removeAll()
    }

    func releaseButtons() {
        for button in buttons.releaseAll() { henge_vm_mouse_button(button, 0) }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil)")
        input.mouseMovedHandler = { [weak self] _, dx, dy in self?.moved(dx, dy) }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(0, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(1, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(2, pressed) }
        input.scroll.valueChangedHandler = { [weak self] _, first, second in self?.scrolled(first, second) }
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    private func moved(_ dx: Float, _ dy: Float) {
        if movesLogged < 12, dx != 0 || dy != 0 {
            movesLogged += 1
            HengeLog.log("input", "mouse moved: \(dx), \(dy) (pointer lock \(UIApplication.shared.connectedScenes.contains { ($0 as? UIWindowScene)?.pointerLockState?.isLocked == true } ? "on" : "off"))")
        }
        restX += dx * speed
        restY -= dy * speed
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        henge_vm_mouse_move(Int32(x), Int32(y))
    }

    private func button(_ physicalButton: Int32, _ pressed: Bool) {
        guard let guestButton = buttons.event(physicalButton, pressed: pressed) else { return }
        if buttonsLogged < 32 {
            buttonsLogged += 1
            HengeLog.log("input", "physical mouse button: raw=\(physicalButton) guest=\(guestButton) \(pressed ? "down" : "up")")
        }
        henge_vm_mouse_button(guestButton, pressed ? 1 : 0)
        if !pressed { StickyKeys.shared.releaseAll() }
    }

    /// GameController puts vertical motion on the first axis and horizontal on the second, as the fingers' travel
    /// since the last sample (about every 8 ms on a Magic Keyboard), and ends a gesture with both at 0.
    ///
    /// The Mac doesn't get these as wheel clicks: a wheel steps in lines that macOS accelerates, so a small swipe ran
    /// to the end of a page in jumps. They become two fingers moving on the Magic Trackpad 2 the Mac already has
    /// (the touchscreen's, Trackpad.swift), so macOS scrolls them as a trackpad: smoothly, with its own momentum
    /// when the fingers lift.
    private func scrolled(_ first: Float, _ second: Float) {
        // GameController reports both axis states when either one changes. On a
        // Magic Keyboard it calls us twice per movement, with one stale axis in
        // each call; taking both values each time would double the motion.
        let verticalChanged = first != lastScrollFirst
        let horizontalChanged = second != lastScrollSecond
        lastScrollFirst = first
        lastScrollSecond = second
        if scrollsLogged < 24 {
            scrollsLogged += 1
            HengeLog.log("input", "scroll raw: \(first), \(second)")
        }
        guard first.isFinite, second.isFinite else { return }
        if first == 0 && second == 0 {
            scrollFingers.end()
            return
        }
        let defaults = UserDefaults.standard
        let configured = defaults.object(forKey: Self.scrollSpeedKey) == nil
            ? 0.3 : defaults.double(forKey: Self.scrollSpeedKey)
        let scale = Float(configured.isFinite ? min(max(configured, 0.1), 1.5) : 0.3)
        // GameController's values are the content's way; fingers on the Mac's pad move the other way.
        let way: Float = reverse ? 1 : -1
        // Sensor units per GameController unit: about 40 at the default speed (0.3).
        let gain = way * ScrollFingers.unitsPerPoint * scale / 0.3
        scrollFingers.move(dx: horizontalChanged ? second * gain : 0, dy: verticalChanged ? first * gain : 0)
    }
}

/// Two fingers on the Mac's emulated Magic Trackpad 2, driven by a hardware trackpad's scroll. Finger ids 14 and 15
/// stay clear of the touchscreen's 1...5. The two calls GameController makes per sample are merged into one frame,
/// so the guest sees evenly spaced samples and works out the fingers' speed (and the momentum after) correctly.
///
/// The emulated pad is only so big, and a long swipe runs off it. Lifting the fingers there at speed would start
/// macOS's momentum, and putting them down again at once reads as a second flick during it, which macOS answers by
/// scrolling faster and faster. So the fingers start at the edge they move away from, and at the far edge they
/// first hold still for a moment (the motion meanwhile is kept), lift with no speed left, start again from the
/// other edge, and the kept motion is paid out over the next samples.
final class ScrollFingers {
    static let unitsPerPoint: Float = 40
    /// Two pairs, used in turn: a pair lifted at an edge isn't put down again under the same ids a moment later.
    private static let pairs: [(Int32, Int32)] = [(14, 15), (12, 13)]
    private var pair = 0
    private var ids: (Int32, Int32) { Self.pairs[pair] }
    private var eventsLogged = 0
    private static let sensorW: Float = 8134, sensorH: Float = 5206
    /// Where the fingers may go: clear of the pad's edges, and well clear of the bottom, where a real
    /// Magic Trackpad expects a resting thumb and macOS treats touches differently.
    private static let minX: Float = sensorW * 0.12, maxX: Float = sensorW * 0.88
    private static let minY: Float = sensorH * 0.15, maxY: Float = sensorH * 0.70
    private static let spread: Float = 1100 // the fingers' distance apart, about two centimetres
    /// No sample for this long: the fingers lifted without the closing (0, 0).
    private static let idleLift: TimeInterval = 0.12
    private static let mergeDelay: TimeInterval = 0.003
    /// How long the fingers rest at an edge before lifting, so macOS sees them stopped.
    private static let rest: TimeInterval = 0.05

    private var down = false
    private var x: Float = 0, y: Float = 0
    private var pendingX: Float = 0, pendingY: Float = 0
    private var flushScheduled = false
    private var idle: DispatchWorkItem?
    /// Resting at an edge until this time; motion meanwhile goes to the backlog.
    private var restingUntil: CFTimeInterval?
    private var backlogX: Float = 0, backlogY: Float = 0

    private static func now() -> UInt32 { UInt32(truncatingIfNeeded: Int(CACurrentMediaTime() * 1000)) }

    func move(dx: Float, dy: Float) {
        pendingX += dx
        pendingY += dy
        if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mergeDelay) { [weak self] in self?.flush() }
        }
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.end() }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleLift, execute: work)
    }

    /// The gesture is over: lift both fingers, and macOS carries the scroll on as it would on a Mac.
    func end() {
        idle?.cancel()
        idle = nil
        // Whatever was held back at an edge is dropped: replaying it now would be a jump.
        restingUntil = nil
        backlogX = 0
        backlogY = 0
        flush()
        lift()
    }

    private func flush() {
        flushScheduled = false
        var dx = pendingX, dy = pendingY
        pendingX = 0
        pendingY = 0
        guard dx != 0 || dy != 0 || restingUntil != nil else { return }
        let ts = Self.now()

        if let until = restingUntil {
            backlogX += dx
            backlogY += dy
            if CACurrentMediaTime() < until {
                frame(ts) // still: the guest's idea of the fingers' speed falls to nothing
                return
            }
            restingUntil = nil
            lift()
            place(towardX: backlogX, towardY: backlogY)
            dx = 0
            dy = 0
        }
        // Pay out what was held back, a share each sample, on top of the new motion.
        if backlogX != 0 || backlogY != 0 {
            let shareX = backlogX * 0.35, shareY = backlogY * 0.35
            dx += shareX
            dy += shareY
            backlogX -= shareX
            backlogY -= shareY
            if abs(backlogX) < 1 && abs(backlogY) < 1 { backlogX = 0; backlogY = 0 }
        }
        guard dx != 0 || dy != 0 else { return }
        if !down { place(towardX: dx, towardY: dy) }
        let nx = x + dx, ny = y + dy
        if nx - Self.spread / 2 < Self.minX || nx + Self.spread / 2 > Self.maxX || ny < Self.minY || ny > Self.maxY {
            // The edge: rest here, keeping this sample's motion for after.
            restingUntil = CACurrentMediaTime() + Self.rest
            log("edge at \(Int(x)),\(Int(y)): resting")
            backlogX += dx
            backlogY += dy
            frame(ts)
            return
        }
        x = nx
        y = ny
        frame(ts)
    }

    private func frame(_ ts: UInt32) {
        henge_vm_touch(ids.0, 1, Int32(x - Self.spread / 2), Int32(y), ts)
        henge_vm_touch(ids.1, 1, Int32(x + Self.spread / 2), Int32(y), ts)
        henge_vm_touch_frame(ts)
    }

    /// Fingers down at the edge the motion leads away from, so a swipe has the whole pad to travel.
    private func place(towardX: Float, towardY: Float) {
        let lowX = Self.minX + Self.spread / 2, highX = Self.maxX - Self.spread / 2
        let lowY = Self.minY, highY = Self.maxY
        if abs(towardY) >= abs(towardX) {
            y = towardY > 0 ? lowY : highY
            x = Self.sensorW / 2
        } else {
            x = towardX > 0 ? lowX : highX
            y = Self.sensorH / 2
        }
        let ts = Self.now()
        log("down \(ids.0)/\(ids.1) at \(Int(x)),\(Int(y))")
        henge_vm_touch(ids.0, 0, Int32(x - Self.spread / 2), Int32(y), ts)
        henge_vm_touch(ids.1, 0, Int32(x + Self.spread / 2), Int32(y), ts)
        down = true
    }

    private func lift() {
        guard down else { return }
        let ts = Self.now()
        henge_vm_touch(ids.0, 2, 0, 0, ts)
        henge_vm_touch(ids.1, 2, 0, 0, ts)
        log("up \(ids.0)/\(ids.1) at \(Int(x)),\(Int(y))")
        down = false
        pair = (pair + 1) % Self.pairs.count
    }

    private func log(_ text: String) {
        guard eventsLogged < 40 else { return }
        eventsLogged += 1
        HengeLog.log("input", "scroll fingers: \(text)")
    }
}
