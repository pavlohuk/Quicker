import AppKit
import ApplicationServices

/// Tells which app is selected in the ⌘Tab switcher.
///
/// Once the switcher is on screen, the Dock's Accessibility tree has a list of the apps with the
/// selected one marked. A quick ⌘Tab releases ⌘ before the switcher appears, so there is no list
/// yet; the switcher would then pick by recency, which is tracked here from app activations.
final class SwitcherSelection: NSObject {
    private var dock: (app: NSRunningApplication, element: AXUIElement)?
    /// The tree is described in the log once, to diagnose a macOS that lays it out differently.
    private var described = false
    /// Regular apps, most recently activated first: the order of the ⌘Tab switcher.
    private var recent: [NSRunningApplication] = []

    override init() {
        super.init()
        if let front = NSWorkspace.shared.frontmostApplication { recent = [front] }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        recent.removeAll { $0.isTerminated || $0.processIdentifier == app.processIdentifier }
        recent.insert(app, at: 0)
    }

    /// The app the switcher would activate if ⌘ were released now, or nil. `steps` is how far
    /// the selection was moved with Tab and ⇧Tab, or nil when it was moved some other way.
    func selectedApp(steps: Int?) -> NSRunningApplication? {
        guard let dock = dockProcess(), let list = findList(in: dock.element, depth: 0) else {
            // The switcher has not appeared yet.
            recent.removeAll { $0.isTerminated }
            if let steps, steps > 0, steps < recent.count { return recent[steps] }
            log.info("⌘Tab selection: no switcher on screen and no recent app \(steps.map(String.init) ?? "-", privacy: .public) back")
            return nil
        }
        guard let item = selectedItem(of: list) else {
            describeOnce("no selected item in the switcher list", element: list)
            return nil
        }
        if let url = urlValue(item), let app = DockClickInterceptor.runningApp(at: url) { return app }
        // No location: match by name, but only when it is unambiguous.
        if let title = stringValue(item, kAXTitleAttribute) {
            // Helper processes often carry the app's name too, but only regular apps are listed.
            let matches = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.localizedName == title
            }
            if matches.count == 1 { return matches[0] }
        }
        describeOnce("no running app for the selected switcher item", element: item)
        return nil
    }

    // MARK: Private

    private func dockProcess() -> (app: NSRunningApplication, element: AXUIElement)? {
        if let dock, !dock.app.isTerminated { return dock }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        dock = (app, element)
        return dock
    }

    private func findList(in element: AXUIElement, depth: Int) -> AXUIElement? {
        for child in children(element) {
            if stringValue(child, kAXSubroleAttribute) == "AXProcessSwitcherList" { return child }
            // The Dock's own icon list is large; the switcher is never inside it.
            if stringValue(child, kAXSubroleAttribute) == nil, stringValue(child, kAXRoleAttribute) == kAXListRole as String,
               depth == 0, children(child).contains(where: { stringValue($0, kAXSubroleAttribute) == "AXApplicationDockItem" }) {
                continue
            }
            if depth < 2, let found = findList(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func selectedItem(of list: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(list, kAXSelectedChildrenAttribute as CFString, &value) == .success,
           let selected = value as? [AXUIElement], let first = selected.first {
            return first
        }
        return children(list).first { item in
            var selected: CFTypeRef?
            return AXUIElementCopyAttributeValue(item, kAXSelectedAttribute as CFString, &selected) == .success
                && (selected as? Bool) == true
        }
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func urlValue(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == CFURLGetTypeID() else { return nil }
        return (raw as! CFURL) as URL
    }

    private func describeOnce(_ problem: String, element: AXUIElement? = nil) {
        guard !described else { return }
        described = true
        var lines = [problem]
        if let dock = dockProcess() {
            for child in children(dock.element) {
                lines.append("dock child \(describe(child)), \(children(child).count) children")
            }
        }
        if let element {
            lines.append("element \(describe(element))")
            for child in children(element).prefix(3) { lines.append("  child \(describe(child))") }
        }
        log.error("⌘Tab selection: \(lines.joined(separator: "; "), privacy: .public)")
    }

    private func describe(_ element: AXUIElement) -> String {
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        let attributes = (names as? [String]) ?? []
        let role = stringValue(element, kAXRoleAttribute) ?? "?"
        let subrole = stringValue(element, kAXSubroleAttribute) ?? "-"
        let title = stringValue(element, kAXTitleAttribute) ?? ""
        return "\(role)/\(subrole) '\(title)' [\(attributes.joined(separator: ","))]"
    }
}
