import AppKit
import CoreVideo

/// How long a smoothed scroll takes to settle.
enum ScrollSmoothness: String, CaseIterable {
    case low
    case medium
    case high

    /// Time constant of the easing: the remaining distance shrinks by e every `tau` seconds.
    var tau: Double {
        switch self {
        case .low: return 0.05
        case .medium: return 0.09
        case .high: return 0.16
        }
    }

    var title: String { L("menu.scroll.smoothness.\(rawValue)") }
}

/// Smooth scrolling for mouse wheels, close to a trackpad.
///
/// Wheel events are swallowed and their distance added to a target. On every display frame the
/// page moves a share of what is left, so it glides to a stop instead of jumping a notch at a
/// time. The output carries trackpad phases: a touch of one frame, then momentum for the rest,
/// so apps bounce briefly at the edges. A longer touch made browsers keep stretching the page
/// past its edge for as long as the wheel turned.
///
/// A wheel's own inertia (the free-spinning wheel of an MX Master) arrives as a steady stream of
/// ticks, which keeps moving the target; once the wheel stops, the scroll eases out. No extra
/// momentum is added on top, so the page never runs on after the wheel.
///
/// Logi Options+ takes over the wheel and posts its own continuous (pixel) events, which look
/// like a trackpad's except for their missing phases; those are smoothed too.
final class SmoothScroller {
    /// Stored in the source user data of the events Quicker posts ("QSMS").
    private static let marker: Int64 = 0x5153_4D53

    private var tap: CFMachPort?
    private var link: CVDisplayLink?

    private enum Phase { case idle, touching, gliding }
    private var phase = Phase.idle
    private var sentFirst = false
    private var remaining = (y: 0.0, x: 0.0)
    private var carry = (y: 0.0, x: 0.0)
    /// Direction of the current glide on each axis (-1, 0, 1).
    private var direction = (y: 0.0, x: 0.0)
    private var lastFrame: CFTimeInterval = 0
    private var flags: CGEventFlags = []
    private var optionsAgent: [pid_t: Bool] = [:]

    // MARK: Event tap

    func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue) | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            let scroller = Unmanaged<SmoothScroller>.fromOpaque(info!).takeUnretainedValue()
            return scroller.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("smooth scroll: could not create the event tap")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.notice("smooth scroll active")
    }

    /// Returns true to swallow the event. Runs inside the event tap: keep it cheap.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown:
            // A click stops a glide, as on a trackpad.
            if phase != .idle { finish() }
            return false
        case .scrollWheel:
            break
        default:
            return false
        }
        guard Settings.shared.smoothScroll,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return false }
        // A trackpad or Magic Mouse: phases set. Let it through and stop any glide of ours.
        if event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
            || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 {
            if phase != .idle { finish() }
            return false
        }
        // Continuous events without phases come from Logi Options+ or remote desktops; only the
        // former is a wheel.
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
           !isOptionsAgent(pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))) {
            return false
        }
        var dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        var dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        if dy == 0 && dx == 0 {
            dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10
            dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 10
        }
        guard dy != 0 || dx != 0 else { return false }
        add(dy: dy, dx: dx, flags: event.flags)
        return true
    }

    private func isOptionsAgent(_ pid: pid_t) -> Bool {
        if let known = optionsAgent[pid] { return known }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        let match = path.contains("logioptionsplus_agent") || path.contains("LogiMgrDaemon")
        optionsAgent[pid] = match
        return match
    }

    // MARK: Glide

    private func add(dy: Double, dx: Double, flags: CGEventFlags) {
        let reversed = dy * direction.y < 0 || dx * direction.x < 0
        // Turning the wheel back drops what is left in the old direction.
        if dy != 0 { remaining.y = remaining.y * dy < 0 ? dy : remaining.y + dy; direction.y = dy < 0 ? -1 : 1 }
        if dx != 0 { remaining.x = remaining.x * dx < 0 ? dx : remaining.x + dx; direction.x = dx < 0 ? -1 : 1 }
        self.flags = flags
        switch phase {
        case .idle:
            phase = .touching
            sentFirst = false
            lastFrame = CACurrentMediaTime()
            startLink()
        case .gliding where reversed:
            // A new touch, as a trackpad reports it; same-direction ticks just feed the glide.
            if sentFirst { post(y: 0, x: 0, scrollPhase: 0, momentumPhase: 3) }
            phase = .touching
            sentFirst = false
        case .gliding, .touching:
            break
        }
    }

    private func frame() {
        guard phase != .idle else { return }
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrame, 0), 0.05)
        lastFrame = now

        // The touch lasts one frame; everything after it is momentum.
        if phase == .touching, sentFirst {
            post(y: 0, x: 0, scrollPhase: 4, momentumPhase: 0)
            phase = .gliding
            sentFirst = false
        }

        let share = 1 - exp(-dt / Settings.shared.scrollSmoothness.tau)
        let y = step(&remaining.y, &carry.y, share)
        let x = step(&remaining.x, &carry.x, share)
        if y != 0 || x != 0 {
            if phase == .touching {
                post(y: y, x: x, scrollPhase: sentFirst ? 2 : 1, momentumPhase: 0)
            } else {
                post(y: y, x: x, scrollPhase: 0, momentumPhase: sentFirst ? 2 : 1)
            }
            sentFirst = true
        }

        if remaining.y == 0, remaining.x == 0 {
            // Less than a pixel in all: nothing was posted, so there is no touch to end.
            if phase == .touching, !sentFirst { phase = .idle }
            if phase != .touching { finish() }
        }
    }

    /// Moves a share of what is left on one axis; returns whole pixels and keeps the fraction.
    private func step(_ remaining: inout Double, _ carry: inout Double, _ share: Double) -> Int32 {
        guard remaining != 0 else { return 0 }
        var move = remaining * share
        if abs(remaining) < 1 || abs(move) < 0.25 { move = remaining }
        remaining -= move
        let total = carry + move
        let whole = total.rounded(.towardZero)
        carry = total - whole
        return Int32(whole)
    }

    private func finish() {
        switch phase {
        case .touching: post(y: 0, x: 0, scrollPhase: 4, momentumPhase: 0)
        case .gliding:
            // Momentum that never started (all distance went out in the touch) needs no end.
            if sentFirst { post(y: 0, x: 0, scrollPhase: 0, momentumPhase: 3) }
        case .idle: break
        }
        phase = .idle
        direction = (0, 0)
        remaining = (0, 0)
        carry = (0, 0)
        stopLink()
    }

    private func post(y: Int32, x: Int32, scrollPhase: Int64, momentumPhase: Int64) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
        else { return }
        event.flags = flags
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: Display link

    private func startLink() {
        if link == nil {
            var created: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&created)
            guard let created else { return }
            CVDisplayLinkSetOutputCallback(created, { _, _, _, _, _, info in
                let scroller = Unmanaged<SmoothScroller>.fromOpaque(info!).takeUnretainedValue()
                DispatchQueue.main.async { scroller.frame() }
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())
            link = created
        }
        if let link, !CVDisplayLinkIsRunning(link) { CVDisplayLinkStart(link) }
    }

    private func stopLink() {
        if let link, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
    }
}
