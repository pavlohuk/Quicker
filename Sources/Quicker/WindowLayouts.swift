import AppKit
import ApplicationServices
import CShims

/// Remembers where every window is and how big, separately for each set of connected displays
/// (the MacBook screen alone, an external monitor, both…), and puts the windows back when the
/// displays change.
///
/// While the displays stay the same, the windows of every desktop are noted every few seconds.
/// When a display is connected or disconnected, macOS squeezes and moves the windows to fit; once
/// the displays settle, each window gets the frame it last had with this set of displays.
///
/// A window is recognised by its id while its app keeps running. After the app was relaunched,
/// its windows take the frames remembered for that app on the same desktop.
///
/// Windows are not moved between desktops: macOS no longer lets another app do that. They keep
/// their desktops through a display change anyway; what the system loses is their frames.
final class WindowLayouts {
    private struct Record: Codable, Equatable {
        var bundle: String
        var display: String
        var desktop: Int
        var x, y, width, height: Double
        /// Valid while the app keeps running.
        var window: UInt32
        var pid: Int32

        var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    private struct Profile: Codable {
        var used: Date
        var windows: [Record]
    }

    private struct Target {
        let pid: pid_t
        let frame: CGRect
    }

    /// All state below belongs to this queue: listing windows and talking to apps over
    /// Accessibility must not hold up the main thread, which serves the event tap.
    private let queue = DispatchQueue(label: "com.pavlohuk.Quicker.layouts", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var enabled = false
    private var profiles: [String: Profile] = [:]
    private var loaded = false
    /// The set of displays the windows are being noted for.
    private var key: String?
    /// The windows as of the last look. Remembered only if the displays are still the same one
    /// look later, so a layout macOS has already started to rearrange is never taken for the user's.
    private var candidate: [Record]?
    /// The displays are changing, or the windows are being put back: nothing is noted.
    private var frozen = false
    /// The set of displays differed from `key` at some point since `frozen` was set.
    private var changed = false
    private var nextStep: DispatchWorkItem?
    /// Windows that could not be reached when the displays changed; tried again on their desktop.
    private var pending: [UInt32: Target] = [:]
    private var pendingUntil = Date.distantPast
    private var apps: [pid_t: NSRunningApplication] = [:]

    private static let interval: TimeInterval = 3
    /// Displays come and go in several steps, and macOS and the apps move windows after each.
    private static let settleDelay: TimeInterval = 2.5
    private static let maxProfiles = 12

    init() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, _, context in
            guard let context else { return }
            let layouts = Unmanaged<WindowLayouts>.fromOpaque(context).takeUnretainedValue()
            layouts.queue.async { layouts.displaysChanging() }
        }, me)
    }

    /// Brings the feature in line with the setting.
    func update() {
        let on = Settings.shared.rememberWindowLayouts
        queue.async { self.setEnabled(on) }
    }

    /// Windows of a desktop that is not shown cannot always be reached; they are when it is.
    func spaceDidChange() {
        queue.asyncAfter(deadline: .now() + 0.4) { self.retryPending() }
    }

    // MARK: Noting the windows

    private func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        nextStep?.cancel()
        nextStep = nil
        frozen = false
        changed = false
        candidate = nil
        pending = [:]
        timer?.cancel()
        timer = nil
        guard on else { return }
        load()
        key = Self.displaysKey()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        log.notice("layouts: remembering windows for \(self.key ?? "no display", privacy: .public)")
    }

    private func tick() {
        guard enabled, !frozen else { return }
        guard let current = Self.displaysKey() else { return }
        guard current == key else {
            // Changed without a word from the system.
            displaysChanging()
            return
        }
        if let candidate { commit(candidate) }
        candidate = records(of: snapshot())
    }

    private func commit(_ windows: [Record]) {
        guard let key else { return }
        // Apps with no window now (not running, hidden away) keep what was remembered for them.
        let present = Set(windows.map(\.bundle))
        let kept = (profiles[key]?.windows ?? []).filter { !present.contains($0.bundle) }.prefix(300)
        let updated = windows + kept
        guard updated != profiles[key]?.windows else { return }
        profiles[key] = Profile(used: Date(), windows: updated)
        save()
    }

    private func snapshot() -> [ISWindowInfo] {
        var buffer = [ISWindowInfo](repeating: ISWindowInfo(), count: 1024)
        let count = Int(is_windows_snapshot(&buffer, Int32(buffer.count)))
        let own = ProcessInfo.processInfo.processIdentifier
        return buffer.prefix(count).filter { info in
            guard info.pid != own, let app = app(info.pid), app.bundleIdentifier != nil else { return false }
            // The windows of a hidden app are all ordered out, and come back as they were.
            return info.ordered_in || app.isHidden
        }
    }

    private func records(of windows: [ISWindowInfo]) -> [Record] {
        windows.compactMap { info -> Record? in
            guard let bundle = app(info.pid)?.bundleIdentifier else { return nil }
            return Record(bundle: bundle, display: Self.display(of: info), desktop: Int(info.desktop),
                          x: info.x, y: info.y, width: info.width, height: info.height,
                          window: info.window, pid: info.pid)
        }
        // Not front to back: the order must not change with every click on a window.
        .sorted { $0.window < $1.window }
    }

    private func app(_ pid: pid_t) -> NSRunningApplication? {
        if let known = apps[pid], !known.isTerminated { return known }
        let app = NSRunningApplication(processIdentifier: pid)
        apps[pid] = app
        if apps.count > 500 { apps = apps.filter { !$0.value.isTerminated } }
        return app
    }

    private static func display(of info: ISWindowInfo) -> String {
        withUnsafeBytes(of: info.display) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Display changes

    /// A display is being added, removed or rearranged. Called for every step of the change.
    private func displaysChanging() {
        guard enabled else { return }
        if !frozen {
            frozen = true
            changed = false
            candidate = nil
        }
        if Self.displaysKey() != key { changed = true }
        schedule(after: Self.settleDelay) { [weak self] in self?.displaysSettled() }
    }

    private func displaysSettled() {
        // No display at all (asleep with the lid closed): wait for one.
        guard let current = Self.displaysKey() else { return }
        guard changed || current != key else {
            // Nothing that matters changed (a colour profile, the same displays again).
            frozen = false
            return
        }
        log.notice("layouts: displays changed to \(current, privacy: .public)")
        key = current
        restore()
        // Once more for the windows that macOS or their apps moved late, then start noting again.
        schedule(after: Self.settleDelay) { [weak self] in
            guard let self else { return }
            self.restore()
            self.frozen = false
            self.changed = false
            self.candidate = nil
        }
    }

    private func schedule(after delay: TimeInterval, _ step: @escaping () -> Void) {
        nextStep?.cancel()
        let work = DispatchWorkItem(block: step)
        nextStep = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// One part per display, so the same monitor at another resolution or on the other side of
    /// the MacBook is a layout of its own. Nil when no display is on.
    private static func displaysKey() -> String? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else { return nil }
        return ids.prefix(Int(count)).map { id -> String in
            let bounds = CGDisplayBounds(id)
            var name = "builtin"
            if CGDisplayIsBuiltin(id) == 0 {
                name = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "display\(id)"
            }
            return "\(name)@\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width))x\(Int(bounds.height))"
        }.sorted().joined(separator: "|")
    }

    // MARK: Putting the windows back

    private func restore() {
        pending = [:]
        guard let key, let remembered = profiles[key]?.windows, !remembered.isEmpty, AXIsProcessTrusted() else { return }
        profiles[key]?.used = Date()
        let windows = snapshot()
        var left = remembered
        var targets: [UInt32: Target] = [:]
        var strangers: [ISWindowInfo] = []

        func aim(_ info: ISWindowInfo, at index: Int) {
            let frame = left.remove(at: index).frame
            let now = CGRect(x: info.x, y: info.y, width: info.width, height: info.height)
            guard Self.differs(now, frame), Self.isOnScreen(frame) else { return }
            targets[info.window] = Target(pid: info.pid, frame: frame)
        }
        // The very same windows first.
        for info in windows {
            if let index = left.firstIndex(where: { $0.window == info.window && $0.pid == info.pid }) {
                aim(info, at: index)
            } else {
                strangers.append(info)
            }
        }
        // Then windows opened since (their app was relaunched, or the window is new): they take
        // what is remembered for a window of that app on that desktop that no longer exists.
        for info in strangers {
            guard let bundle = app(info.pid)?.bundleIdentifier else { continue }
            let display = Self.display(of: info)
            if let index = left.firstIndex(where: { $0.bundle == bundle && $0.desktop == Int(info.desktop) && $0.display == display }) {
                aim(info, at: index)
            }
        }
        guard !targets.isEmpty else { return }

        let wanted = targets.count
        apply(&targets, reachHidden: true)
        log.notice("layouts: put back \(wanted - targets.count) of \(wanted) windows")
        pending = targets
        pendingUntil = Date().addingTimeInterval(600)
    }

    private func retryPending() {
        guard enabled, !pending.isEmpty else { return }
        guard Date() < pendingUntil else {
            pending = [:]
            return
        }
        // Not the ones the user closed meanwhile.
        let alive = Set(snapshot().map(\.window))
        pending = pending.filter { alive.contains($0.key) }
        let wanted = pending.count
        apply(&pending, reachHidden: false)
        if pending.count < wanted { log.notice("layouts: put back \(wanted - self.pending.count) more windows") }
    }

    /// Gives each window its frame and takes it off `targets`. The windows that could not be
    /// reached stay.
    private func apply(_ targets: inout [UInt32: Target], reachHidden: Bool) {
        for (pid, ids) in Dictionary(grouping: targets.keys, by: { targets[$0]!.pid }) {
            var wanted = Set(ids)
            for (id, element) in elements(of: pid, windows: wanted, reachHidden: reachHidden) {
                guard let target = targets[id], Self.setFrame(element, target.frame) else { continue }
                targets[id] = nil
                wanted.remove(id)
            }
        }
    }

    /// Accessibility elements of the given windows of an app.
    private func elements(of pid: pid_t, windows wanted: Set<UInt32>, reachHidden: Bool) -> [UInt32: AXUIElement] {
        var found: [UInt32: AXUIElement] = [:]
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        // An app that does not answer is left alone.
        guard result == .success, let list = value as? [AXUIElement] else { return found }
        for element in list {
            let id = is_ax_window_id(Unmanaged.passUnretained(element).toOpaque())
            if wanted.contains(id) { found[id] = element }
        }
        guard reachHidden, found.count < wanted.count else { return found }

        // The list only has the windows of the desktop on screen. The others are reached by going
        // through the app's element numbers, which are small; a second at most.
        let deadline = Date().addingTimeInterval(1)
        for index in UInt64(0)..<1000 {
            if found.count == wanted.count || Date() > deadline { break }
            guard let raw = is_ax_element_create(pid, index) else { continue }
            let element = Unmanaged<AXUIElement>.fromOpaque(raw).takeRetainedValue()
            let id = is_ax_window_id(raw)
            guard wanted.contains(id), found[id] == nil else { continue }
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXWindowRole as String else { continue }
            found[id] = element
        }
        return found
    }

    private static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return false }
        // The size first, so the window fits where it goes; again after the move, because where it
        // was may not have had room for it.
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, extent)
        return moved == .success
    }

    private static func differs(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) > 1 || abs(a.minY - b.minY) > 1 || abs(a.width - b.width) > 1 || abs(a.height - b.height) > 1
    }

    /// Whether a good part of the frame's top edge, where the title bar is, lies on a display.
    private static func isOnScreen(_ frame: CGRect) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        let top = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 20)
        return ids.prefix(Int(count)).contains { CGDisplayBounds($0).intersection(top).width >= 60 }
    }

    // MARK: Storage

    private static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Quicker", isDirectory: true)
            .appendingPathComponent("WindowLayouts.json")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let file = Self.file, let data = try? Data(contentsOf: file) else { return }
        do {
            profiles = try JSONDecoder().decode([String: Profile].self, from: data)
        } catch {
            log.error("layouts: cannot read the remembered windows: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard let file = Self.file else { return }
        // Sets of displays not seen for the longest go first.
        while profiles.count > Self.maxProfiles, let oldest = profiles.min(by: { $0.value.used < $1.value.used }) {
            profiles[oldest.key] = nil
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(profiles).write(to: file, options: .atomic)
        } catch {
            log.error("layouts: cannot save the remembered windows: \(error.localizedDescription, privacy: .public)")
        }
    }
}
