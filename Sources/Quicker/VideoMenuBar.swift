import AppKit
import IOKit.pwr_mgt

/// Hides the menu bar on a full-screen Space while a video plays there, for people who keep the
/// menu bar visible in full-screen apps otherwise.
///
/// A video is recognised by the app that owns the full-screen Space keeping the display awake:
/// browsers (Arc's "Video Wake Lock"), IINA, QuickTime and TV all do that while playing. Pausing
/// drops that hold, so once a video has played the menu bar stays hidden until the Space changes;
/// leaving a browser's full-screen video closes its Space anyway.
///
/// The system option ("Automatically hide and show the menu bar: Never") is flipped to "hide in
/// full screen" for that time and put back afterwards, on quit, and on the next launch after a
/// crash.
final class VideoMenuBar {
    private static let visibleKey = "AppleMenuBarVisibleInFullscreen" as CFString
    private static let changedNotification = Notification.Name("AppleInterfaceFullScreenMenuBarVisibilityChangedNotification")
    /// Set while Quicker has the menu bar hidden, so a crash can be undone on the next launch.
    private static let hiddenFlag = "menuBarHiddenForVideo"

    private var hidden = false
    private var pollTimer: Timer?
    /// Owner of the full-screen Space being watched for a video.
    private var watchedPid: pid_t = 0

    init() {
        if UserDefaults.standard.bool(forKey: Self.hiddenFlag) {
            log.notice("restoring the full-screen menu bar left hidden by a previous run")
            Self.setVisibleInFullScreen(true)
            UserDefaults.standard.set(false, forKey: Self.hiddenFlag)
        }
    }

    /// Call on every Space change and settings change, with the Space the user is on now.
    func update(_ space: SpaceSnapshot?) {
        stopPolling()
        guard Settings.shared.hideMenuBarForVideo, let space,
              space.current >= 0, space.current < space.count,
              space.types[space.current] == 4, space.pids[space.current] > 0 else {
            show()
            return
        }
        let pid = space.pids[space.current]
        if hidden && pid == watchedPid { return }
        show()
        watchedPid = pid
        check()
        if !hidden {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        }
    }

    /// Puts the user's setting back; call before quitting.
    func restore() {
        stopPolling()
        show()
    }

    // MARK: Private

    private func check() {
        guard Self.keepsDisplayAwake(watchedPid) else { return }
        stopPolling()
        hide()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func hide() {
        // Respect a menu bar the user already hides in full screen; nothing to do then.
        guard !hidden, Self.visibleInFullScreen() else { return }
        let name = NSRunningApplication(processIdentifier: watchedPid)?.localizedName ?? "pid \(watchedPid)"
        log.info("hiding the menu bar for a full-screen video in \(name, privacy: .public)")
        hidden = true
        UserDefaults.standard.set(true, forKey: Self.hiddenFlag)
        Self.setVisibleInFullScreen(false)
    }

    private func show() {
        guard hidden else { return }
        log.info("showing the menu bar again")
        hidden = false
        Self.setVisibleInFullScreen(true)
        UserDefaults.standard.set(false, forKey: Self.hiddenFlag)
    }

    private static func visibleInFullScreen() -> Bool {
        let value = CFPreferencesCopyValue(visibleKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? Bool) ?? false
    }

    /// Same change as System Settings makes: the global preference, then the notification that
    /// makes the WindowServer and apps pick it up right away.
    private static func setVisibleInFullScreen(_ visible: Bool) {
        CFPreferencesSetValue(visibleKey, visible as CFBoolean, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        DistributedNotificationCenter.default().postNotificationName(changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// True when `pid` holds an assertion that keeps the display on, as video playback does.
    private static func keepsDisplayAwake(_ pid: pid_t) -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
              let mine = all[NSNumber(value: pid)] else { return false }
        let displayTypes: Set<String> = [kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionTypePreventUserIdleDisplaySleep]
        return mine.contains { ($0[kIOPMAssertionTypeKey] as? String).map(displayTypes.contains) ?? false }
    }
}
