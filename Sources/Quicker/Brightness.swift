import AppKit
import QuartzCore
import CShims

/// Brightness of the display under the cursor: Apple displays (built-in, Studio Display) through
/// the private DisplayServices framework, other external displays over DDC/CI.
final class BrightnessController {
    struct Display {
        let id: CGDirectDisplayID
        let name: String
        let screen: NSScreen
    }

    /// Called on the main thread whenever a display's brightness is known or changed.
    var onChange: ((CGDirectDisplayID, Double) -> Void)?

    private let services = DisplayServices()
    private let queue = DispatchQueue(label: "com.pavlohuk.Quicker.ddc", qos: .userInitiated)

    /// External display reached over DDC. Main thread only, except `service`, which is immutable.
    private final class DDCDisplay {
        let service: UnsafeRawPointer
        var maximum: UInt16 = 100
        /// Last known brightness, 0…1; nil until the first read answers.
        var value: Double?
        var reading = false
        /// Steps pressed before the first read answered.
        var pendingSteps: [(direction: Int, step: Double)] = []
        var writing = false
        var written: UInt16?

        init(service: UnsafeRawPointer) { self.service = service }
        deinit { is_ddc_release(service) }
    }

    private var ddc: [CGDirectDisplayID: DDCDisplay] = [:]
    /// Displays that have no DDC service, so they are not looked up again until displays change.
    private var noDDC: Set<CGDirectDisplayID> = []
    private var lookups: Set<CGDirectDisplayID> = []

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displaysChanged), name: NSWorkspace.didWakeNotification, object: nil)
        displaysChanged()
    }

    /// The display under the mouse cursor.
    func displayUnderMouse() -> Display? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return Display(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName, screen: screen)
    }

    /// Whether Quicker can change this display's brightness (DDC: once its service was found).
    func canControl(_ id: CGDirectDisplayID) -> Bool {
        services.canControl(id) || ddc[id] != nil
    }

    /// Current brightness, 0…1, if known.
    func value(of id: CGDirectDisplayID) -> Double? {
        if services.canControl(id) { return services.get(id) }
        return ddc[id]?.value
    }

    /// Moves to the next mark of a grid of `step` (macOS: 1/16) in `direction` (+1 / −1).
    func step(_ id: CGDirectDisplayID, direction: Int, step: Double) {
        if let animation = animations[id] {
            // Quick presses go on from where the running animation is heading.
            set(id, Self.stepped(animation.to, direction: direction, step: step), animated: true)
            return
        }
        if services.canControl(id) {
            set(id, Self.stepped(services.get(id) ?? 0.5, direction: direction, step: step), animated: true)
            return
        }
        guard let display = ddc[id] else { return }
        if let value = display.value {
            set(id, Self.stepped(value, direction: direction, step: step), animated: true)
        } else {
            display.pendingSteps.append((direction, step))
            read(id, display)
        }
    }

    /// `animated`: glide there over `glide` seconds, as the system does on the brightness keys.
    func set(_ id: CGDirectDisplayID, _ value: Double, animated: Bool) {
        let value = min(1, max(0, value))
        guard animated, let from = self.value(of: id), abs(from - value) > 0.001 else {
            animations[id] = nil
            apply(id, value)
            return
        }
        animations[id] = (from, value, CACurrentMediaTime())
        if animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.animationTick() }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }
        animationTick()
    }

    private var animations: [CGDirectDisplayID: (from: Double, to: Double, start: CFTimeInterval)] = [:]
    private var animationTimer: Timer?
    private let glide: CFTimeInterval = 0.2

    private func animationTick() {
        let now = CACurrentMediaTime()
        for (id, animation) in animations {
            let t = min(1, (now - animation.start) / glide)
            let eased = 1 - pow(1 - t, 3)
            apply(id, animation.from + (animation.to - animation.from) * eased)
            if t >= 1 { animations[id] = nil }
        }
        if animations.isEmpty {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func apply(_ id: CGDirectDisplayID, _ value: Double) {
        if services.canControl(id) {
            services.set(id, value)
            onChange?(id, value)
            return
        }
        guard let display = ddc[id] else { return }
        display.value = value
        onChange?(id, value)
        write(display)
    }

    static func stepped(_ value: Double, direction: Int, step: Double) -> Double {
        // From a value between marks, the first press lands on the neighbouring mark.
        let marks = value / step
        let next = direction > 0 ? (marks + 0.001).rounded(.down) + 1 : (marks - 0.001).rounded(.up) - 1
        return min(1, max(0, next * step))
    }

    // MARK: DDC

    @objc private func displaysChanged() {
        ddc.removeAll()
        noDDC.removeAll()
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return }
        let externals = ids.prefix(Int(count)).filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay && !services.canControl($0)
        }
        for id in externals { lookUp(id, soleFallback: externals.count == 1) }
    }

    private func lookUp(_ id: CGDirectDisplayID, soleFallback: Bool) {
        guard !lookups.contains(id) else { return }
        lookups.insert(id)
        let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id), serial = CGDisplaySerialNumber(id)
        queue.async { [weak self] in
            let service = is_ddc_service(vendor, model, serial, soleFallback)
            DispatchQueue.main.async {
                guard let self else { is_ddc_release(service); return }
                self.lookups.remove(id)
                guard let service else {
                    self.noDDC.insert(id)
                    log.notice("brightness: no DDC service for display \(id)")
                    return
                }
                let display = DDCDisplay(service: service)
                self.ddc[id] = display
                self.read(id, display)
            }
        }
    }

    private func read(_ id: CGDirectDisplayID, _ display: DDCDisplay) {
        guard !display.reading else { return }
        display.reading = true
        let service = display.service
        queue.async { [weak self] in
            var current: UInt16 = 0, maximum: UInt16 = 0
            let ok = is_ddc_read(service, 0x10, &current, &maximum)
            DispatchQueue.main.async {
                guard let self else { return }
                display.reading = false
                if ok {
                    display.maximum = maximum
                    display.value = Double(min(current, maximum)) / Double(maximum)
                    display.written = current
                    log.notice("brightness: display \(id) over DDC at \(current)/\(maximum)")
                } else if display.value == nil {
                    // The display does not answer reads; start from the middle.
                    log.notice("brightness: DDC read failed for display \(id)")
                    display.value = 0.5
                }
                let steps = display.pendingSteps
                display.pendingSteps.removeAll()
                if steps.isEmpty {
                    if let value = display.value { self.onChange?(id, value) }
                } else {
                    for s in steps { self.step(id, direction: s.direction, step: s.step) }
                }
            }
        }
    }

    /// Writes the latest value, one write at a time, skipping the values passed meanwhile.
    private func write(_ display: DDCDisplay) {
        guard !display.writing, let value = display.value else { return }
        let target = UInt16((value * Double(display.maximum)).rounded())
        guard target != display.written else { return }
        display.writing = true
        let service = display.service
        queue.async { [weak self] in
            let ok = is_ddc_write(service, 0x10, target)
            DispatchQueue.main.async {
                display.writing = false
                if ok { display.written = target } else { log.error("brightness: DDC write failed") }
                if ok { self?.write(display) }
            }
        }
    }
}

/// Private DisplayServices calls, loaded at run time.
private final class DisplayServices {
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Int32

    private var canFn: CanFn?
    private var getFn: GetFn?
    private var setFn: SetFn?
    private var changedFn: ChangedFn?

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else { return }
        func load<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        canFn = load("DisplayServicesCanChangeBrightness", as: CanFn.self)
        getFn = load("DisplayServicesGetBrightness", as: GetFn.self)
        setFn = load("DisplayServicesSetBrightness", as: SetFn.self)
        changedFn = load("DisplayServicesBrightnessChanged", as: ChangedFn.self)
    }

    func canControl(_ id: CGDirectDisplayID) -> Bool {
        guard let canFn, getFn != nil, setFn != nil else { return false }
        return canFn(id)
    }

    func get(_ id: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard let getFn, getFn(id, &value) == 0 else { return nil }
        return Double(value)
    }

    func set(_ id: CGDirectDisplayID, _ value: Double) {
        _ = setFn?(id, Float(value))
        // Lets Control Center and the system's brightness setting follow.
        _ = changedFn?(id, value)
    }
}
