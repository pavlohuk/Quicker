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
/// time. By default the output is plain continuous (pixel) scrolling without phases, which every
/// app handles. With `scrollBounce` on it carries trackpad phases instead, so apps bounce at
/// the edges: a touch while the wheel turns, then momentum for what is left. The touch has to
/// last: after a touch of a single frame apps take the gesture for empty and ignore its
/// momentum, so nothing scrolls. It is also capped, because browsers keep stretching the page
/// past its edge for as long as a touch goes on, and a free-spinning wheel turns for seconds.
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
    private var lastInput: CFTimeInterval = 0
    private var touchStart: CFTimeInterval = 0
    /// A touch ends once the wheel has been still this long...
    private static let touchPause: CFTimeInterval = 0.18
    /// ...or has lasted this long; the wheel then feeds the momentum.
    private static let touchLimit: CFTimeInterval = 0.35
    /// The latest wheel event: each frame is a copy of it with new distances, so it keeps what
    /// the system filled in (location, window, target app). Some apps, such as WhatsApp, scroll
    /// an inactive window only with those.
    private var template: CGEvent?
    /// The app the wheel event was meant for; frames go straight to it.
    private var targetPID: pid_t = 0
    private var optionsAgent: [pid_t: Bool] = [:]

    // MARK: Event tap

    func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue) | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            let scroller = Unmanaged<SmoothScroller>.fromOpaque(info!).takeUnretainedValue()
            return scroller.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
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
        let speed = Settings.shared.scrollSpeed
        add(dy: dy * speed, dx: dx * speed, from: event)
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

    private func add(dy: Double, dx: Double, from event: CGEvent) {
        let reversed = dy * direction.y < 0 || dx * direction.x < 0
        // Turning the wheel back drops what is left in the old direction.
        if dy != 0 { remaining.y = remaining.y * dy < 0 ? dy : remaining.y + dy; direction.y = dy < 0 ? -1 : 1 }
        if dx != 0 { remaining.x = remaining.x * dx < 0 ? dx : remaining.x + dx; direction.x = dx < 0 ? -1 : 1 }
        template = event.copy()
        // Only a running app is a target; otherwise the frames go the usual way.
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if pid != targetPID {
            let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
            targetPID = app != nil && pid != ProcessInfo.processInfo.processIdentifier ? pid : 0
            log.info("smooth scroll target: \(app?.localizedName ?? "none", privacy: .public) (pid \(pid))")
        }
        let now = CACurrentMediaTime()
        let separate = now - lastInput > Self.touchPause
        lastInput = now
        switch phase {
        case .idle:
            phase = .touching
            sentFirst = false
            lastFrame = now
            touchStart = now
            startLink()
        case .gliding where reversed || separate:
            // A new touch, as a trackpad reports it; a steady stream of ticks feeds the glide.
            if sentFirst { post(y: 0, x: 0, scrollPhase: 0, momentumPhase: 3) }
            phase = .touching
            sentFirst = false
            touchStart = now
        case .gliding, .touching:
            break
        }
    }

    private func frame() {
        guard phase != .idle else { return }
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrame, 0), 0.05)
        lastFrame = now

        // The touch ends when the wheel pauses or at its limit; the rest is momentum.
        if phase == .touching, sentFirst,
           now - lastInput > Self.touchPause || now - touchStart > Self.touchLimit {
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
        template = nil
        remaining = (0, 0)
        carry = (0, 0)
        stopLink()
    }

    private func post(y: Int32, x: Int32, scrollPhase: Int64, momentumPhase: Int64) {
        let bounce = Settings.shared.scrollBounce
        // Without phases a marker-only frame carries nothing.
        if !bounce && y == 0 && x == 0 { return }
        guard let event = template?.copy() else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Only the pixel distance changes; the wheel's own line counts stay, as apps expect them.
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(y))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(x))
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: bounce ? scrollPhase : 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: bounce ? momentumPhase : 0)
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        if targetPID > 0 {
            event.postToPid(targetPID)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
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
