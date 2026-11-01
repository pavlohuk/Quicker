import CShims
import Foundation

enum SpaceStep {
    case next
    case previous
}

/// Spaces of one display, in Dock order.
struct SpaceSnapshot {
    let display: String
    /// Index of the current (or, right after our own switch, the target) space.
    let current: Int
    /// Per space: 0 = desktop, 4 = full-screen app, other = system space.
    let types: [Int32]
    /// Per space: owning app of a full-screen space, 0 otherwise.
    let pids: [Int32]

    var count: Int { types.count }

    func with(current: Int) -> SpaceSnapshot {
        SpaceSnapshot(display: display, current: current, types: types, pids: pids)
    }
}

/// Asks the Dock to switch spaces instantly (synthetic swipes with a huge fling velocity).
///
/// The Dock itself performs the switch, so windows of the previous space are hidden properly and
/// full-screen app spaces work like any other space.
final class SpaceSwitcher {
    /// Time between asking the WindowServer to put an app's window in front and switching to its
    /// Space. Measured on macOS 27 with Arc and Calendar windows buried under other apps: with no
    /// wait the window was sometimes still underneath when the Space appeared; with 15 ms it
    /// occasionally was; with 30 ms it was on top within about a frame of landing every time, and
    /// waiting longer did not help further.
    static let prefocusLead: TimeInterval = 0.03

    /// Called with the space the user ends up on as soon as a switch is requested, before the Dock
    /// has finished. `switched` is false when nothing had to move (edge reached, already there).
    var onShowSpace: ((_ snapshot: SpaceSnapshot, _ switched: Bool) -> Void)?

    /// While our own swipes are still landing, SkyLight reports an intermediate space. Trusting it
    /// during a burst would let us overshoot past the last space, which on macOS 27 can wedge the
    /// Dock (black screen). Keep our own prediction authoritative for this long.
    private let predictionTTL: TimeInterval = 1.0
    private var predicted: (display: String, index: Int, at: Date, landed: Bool)?

    /// True right after our own switch, while the Dock may still report intermediate spaces.
    var isPredicting: Bool {
        guard let p = predicted else { return false }
        return Date().timeIntervalSince(p.at) < predictionTTL
    }

    /// True from our own switch until the Dock reports its target. While it is landing, macOS
    /// activates the topmost app of every Space it passes.
    var isLanding: Bool {
        guard let p = predicted, !p.landed else { return false }
        return isPredicting
    }

    /// Every active-space change. The prediction itself stays for its whole TTL: when the target
    /// is passed on the way somewhere else, more of our swipes are still queued, and trusting
    /// SkyLight then could overshoot.
    func spaceDidChange(_ landed: SpaceSnapshot) {
        guard var p = predicted, p.display == landed.display, p.index == landed.current else { return }
        p.landed = true
        predicted = p
    }

    /// One space to the right or left.
    @discardableResult
    func perform(_ step: SpaceStep) -> Bool {
        guard let state = snapshot() else { return false }
        let target = state.current + (step == .next ? 1 : -1)
        guard target >= 0, target < state.count else {
            log.debug("already on the \(step == .next ? "last" : "first", privacy: .public) space")
            onShowSpace?(state, false)
            return false
        }
        return move(state, to: target, reason: step == .next ? "next" : "previous")
    }

    /// True when there is a space at position `number` (1-based, Dock order).
    func hasSpace(at number: Int) -> Bool {
        guard let state = snapshot() else { return false }
        return number >= 1 && number <= state.count
    }

    /// Jumps straight to the space at position `number` (1-based, Dock order, full-screen apps
    /// included, as in the Spaces bar of Mission Control). Returns false when there is none.
    @discardableResult
    func jump(toPosition number: Int) -> Bool {
        guard let state = snapshot() else { return false }
        guard number >= 1, number <= state.count else {
            log.debug("no space \(number), only \(state.count)")
            return false
        }
        let target = number - 1
        if target == state.current {
            onShowSpace?(state, false)
            return true
        }
        return move(state, to: target, reason: "space \(number)")
    }

    /// Jumps straight to the space at `index` (0-based, Dock order, full-screen spaces included).
    /// With a `delay`, the target is reserved right away (so `snapshot()` already reports it) and
    /// the swipes are posted after the delay.
    @discardableResult
    func jump(toSpaceIndex index: Int, reason: String, after delay: TimeInterval = 0) -> Bool {
        guard let state = snapshot(), index >= 0, index < state.count else { return false }
        if index == state.current { return true }
        return move(state, to: index, reason: reason, after: delay)
    }

    /// Spaces of the display under the cursor. Right after our own switch, `current` is the
    /// predicted target rather than the intermediate space SkyLight may still report, unless
    /// `usePrediction` is false.
    func snapshot(usePrediction: Bool = true) -> SpaceSnapshot? {
        var info = ISSpaceInfo()
        guard is_spaces_info(&info), info.count > 0 else {
            log.error("could not read spaces of the current display")
            return nil
        }
        let display = withUnsafeBytes(of: info.display) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let count = Int(info.count)
        let types = withUnsafeBytes(of: info.types) { Array($0.bindMemory(to: Int32.self).prefix(count)) }
        let pids = withUnsafeBytes(of: info.pids) { Array($0.bindMemory(to: Int32.self).prefix(count)) }
        var current = Int(info.index)
        if usePrediction, let p = predicted, p.display == display, isPredicting, p.index < count {
            current = p.index
        }
        return SpaceSnapshot(display: display, current: current, types: types, pids: pids)
    }

    // MARK: Private

    private func move(_ state: SpaceSnapshot, to target: Int, reason: String, after delay: TimeInterval = 0) -> Bool {
        let direction: Int32 = target > state.current ? 1 : -1
        let steps = abs(target - state.current)
        let post = {
            for _ in 0..<steps {
                guard is_ds_post_switch(direction) else {
                    log.error("could not post the synthetic swipe")
                    return false
                }
            }
            return true
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { _ = post() }
        } else if !post() {
            return false
        }
        predicted = (state.display, target, Date(), false)
        log.notice("switch \(reason, privacy: .public): space \(state.current + 1) -> \(target + 1) of \(state.count)")
        onShowSpace?(state.with(current: target), true)
        return true
    }
}
