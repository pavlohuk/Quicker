import AppKit

/// Keeps the Dock shown while an external display is connected, when it is set to hide
/// automatically, and lets it hide again once only the built-in display is left.
///
/// Only an auto-hide that Quicker turned off is turned back on, so a Dock set to stay shown is
/// never touched.
final class DockAutoHide {
    private let defaults = UserDefaults.standard
    /// Set while Quicker keeps the Dock shown; survives a restart of Quicker.
    private let restoreKey = "dockAutoHideTurnedOff"
    private var pending: DispatchWorkItem?

    private typealias GetFn = @convention(c) () -> Bool
    private typealias SetFn = @convention(c) (Bool) -> Void
    private let getFn: GetFn?
    private let setFn: SetFn?

    init() {
        // Private CoreDock calls: they change the setting live, without restarting the Dock.
        let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        getFn = dlsym(handle, "CoreDockGetAutoHideEnabled").map { unsafeBitCast($0, to: GetFn.self) }
        setFn = dlsym(handle, "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: SetFn.self) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Brings the Dock in line with the connected displays and the setting.
    func update() {
        guard let getFn, let setFn else { return }
        let turnedOff = defaults.bool(forKey: restoreKey)
        if Settings.shared.dockShownOnExternalDisplay && Self.externalDisplayConnected() {
            guard getFn() else { return }
            setFn(false)
            defaults.set(true, forKey: restoreKey)
            log.notice("dock: external display connected, auto-hide off")
        } else if turnedOff {
            setFn(true)
            defaults.removeObject(forKey: restoreKey)
            log.notice("dock: auto-hide back on")
        }
    }

    @objc private func displaysChanged() {
        // Displays come and go in several steps; act once they settle.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.update() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private static func externalDisplayConnected() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}
