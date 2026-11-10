import AppKit
import SwiftUI

/// The settings window: sections in a sidebar on the left, like System Settings.
final class SettingsWindowController {
    private let model = SettingsModel()
    private var window: NSWindow?

    /// Called after any setting changes in the window.
    var onChange: (() -> Void)? {
        get { model.onChange }
        set { model.onChange = newValue }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Settings changed elsewhere (the menu); redraws the window if it is open.
    func refresh() { model.refresh() }

    private func makeWindow() -> NSWindow {
        weak var window: NSWindow?
        let host = NSHostingController(rootView: SettingsView(setTitle: { window?.title = $0 }).environmentObject(model))
        // Only a minimum size from SwiftUI, so the window can be resized freely above it.
        if #available(macOS 13.0, *) { host.sizingOptions = [.minSize] }
        let created = NSWindow(contentViewController: host)
        window = created
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        created.titlebarAppearsTransparent = true
        created.toolbarStyle = .unified
        // An empty toolbar lets the sidebar reach the top of the window, as in System Settings.
        created.toolbar = NSToolbar()
        created.setContentSize(NSSize(width: 720, height: 480))
        created.isReleasedWhenClosed = false
        created.center()
        return created
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, spaces, displays, mouse

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return L("settings.tab.general")
        case .spaces: return L("settings.tab.spaces")
        case .displays: return L("settings.tab.displays")
        case .mouse: return L("settings.tab.mouse")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .spaces: return "rectangle.split.3x1.fill"
        case .displays: return "sun.max.fill"
        case .mouse: return "computermouse.fill"
        }
    }

    /// Icon tile colour, after System Settings.
    var tint: Color {
        switch self {
        case .general, .mouse: return Color(white: 0.55)
        case .spaces, .displays: return .blue
        }
    }

}

/// Settings keep their sidebar; the toolbar button that hides it is removed where possible.
private struct NoSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

private struct SettingsView: View {
    /// Shows the section's name as the window title.
    let setTitle: (String) -> Void
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    // A white, filled glyph on a coloured tile, as in System Settings.
                    Image(systemName: section.symbol)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .navigationSplitViewColumnWidth(210)
            .modifier(NoSidebarToggle())
        } detail: {
            let section = selection ?? .general
            Group {
                switch section {
                case .general: GeneralPane()
                case .spaces: SpacesPane()
                case .displays: DisplaysPane()
                case .mouse: MousePane()
                }
            }
            .onAppear { setTitle(section.title) }
            .onChange(of: section) { setTitle($0.title) }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420, idealHeight: 480)
    }
}

/// Bridges `Settings` to SwiftUI: every write goes through `Settings` and tells the app.
final class SettingsModel: ObservableObject {
    let settings = Settings.shared
    var onChange: (() -> Void)?

    func refresh() { objectWillChange.send() }

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in
                self.objectWillChange.send()
                self.settings[keyPath: keyPath] = value
                self.onChange?()
            })
    }

    var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LoginItem.isEnabled },
            set: { value in
                self.objectWillChange.send()
                do {
                    try LoginItem.set(value)
                } catch {
                    log.error("login item change failed: \(error.localizedDescription, privacy: .public)")
                    let alert = NSAlert()
                    alert.messageText = L("alert.loginItem.title")
                    alert.informativeText = L("alert.loginItem.message", error.localizedDescription)
                    alert.runModal()
                }
            })
    }
}

// MARK: Panes

private struct Pane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

/// What Quicker needs from the system, and app-wide options.
private struct GeneralPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        let granted = AXIsProcessTrusted()
        let fingers = SystemGestureCheck.systemSwipeFingers()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        Pane {
            Section {
                StatusRow(title: L("settings.accessibility"), ok: granted,
                          value: L(granted ? "settings.accessibility.granted" : "settings.accessibility.missing"),
                          action: granted ? nil : (L("status.grantAccessibility"), {
                              let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                              _ = AXIsProcessTrustedWithOptions(options)
                              SystemGestureCheck.openAccessibilitySettings()
                          }))
                StatusRow(title: L("settings.swipe"), ok: fingers != nil,
                          value: fingers.map { L("settings.swipe.fingers", $0) } ?? L("settings.swipe.off"),
                          action: fingers != nil ? nil : (L("status.openTrackpad"), { SystemGestureCheck.openTrackpadSettings() }))
            } header: {
                Text(L("settings.status"))
            } footer: {
                Text(L("settings.status.hint")).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("menu.launchAtLogin"), isOn: model.launchAtLogin)
                LabeledContent(L("settings.version"), value: version)
            }
        }
    }
}

/// A requirement with a green or orange mark, and a button to fix it when it is not met.
private struct StatusRow: View {
    let title: String
    let ok: Bool
    let value: String
    let action: (String, () -> Void)?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if let action {
                    Button(action.0, action: action.1)
                }
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(value).foregroundStyle(.secondary)
            }
        }
    }
}

/// Everything about switching between Spaces: swipe, hotkeys, following apps, the indicator.
private struct SpacesPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        let m = model.settings.hotkeyModifier.symbol
        let enabled = model.settings.enabled
        Pane {
            Section {
                Toggle(L("menu.enabled"), isOn: model.binding(\.enabled))
            }
            Section(L("settings.section.swipe")) {
                Toggle(L("menu.invertSwipe"), isOn: model.binding(\.invertDirection))
                Toggle(L("menu.longSwipe"), isOn: model.binding(\.longSwipeSkipsMore))
            }
            .disabled(!enabled)
            Section(L("settings.tab.hotkeys")) {
                Toggle(L("menu.hotkeys.digits", m), isOn: model.binding(\.hotkeyDigits))
                Toggle(L("menu.hotkeys.arrows", m), isOn: model.binding(\.hotkeyArrows))
                Picker(L("settings.modifier"), selection: model.binding(\.hotkeyModifier)) {
                    ForEach(HotkeyModifier.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            .disabled(!enabled)
            Section {
                Toggle(L("menu.followApp.toggle"), isOn: model.binding(\.followActivatedApp))
            } header: {
                Text(L("menu.followApp"))
            } footer: {
                if model.settings.followActivatedApp && SystemGestureCheck.systemSwitchOnActivateEnabled() {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("menu.followApp.systemOn"))
                        Text(L("menu.followApp.hint1") + " " + L("menu.followApp.hint2"))
                            .foregroundStyle(.secondary)
                        Button(L("menu.followApp.openSettings")) { SystemGestureCheck.openDesktopAndDockSettings() }
                    }
                }
            }
            .disabled(!enabled)
            Section(L("settings.tab.indicator")) {
                Toggle(L("menu.indicator.show"), isOn: model.binding(\.indicatorEnabled))
                Picker(L("settings.position"), selection: model.binding(\.indicatorCorner)) {
                    ForEach(IndicatorCorner.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!model.settings.indicatorEnabled)
            }
        }
    }
}

private struct DisplaysPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                Toggle(L("menu.brightness.keys"), isOn: model.binding(\.brightnessKeys))
            } header: {
                Text(L("menu.brightness"))
            } footer: {
                Text(L("settings.footer.brightness")).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("menu.video.hideMenuBar"), isOn: model.binding(\.hideMenuBarForVideo))
            } header: {
                Text(L("menu.video"))
            } footer: {
                Text(L("settings.footer.video")).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("menu.dock.external"), isOn: model.binding(\.dockShownOnExternalDisplay))
            } header: {
                Text(L("menu.dock"))
            } footer: {
                Text(L("settings.footer.dock")).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MousePane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        let smooth = model.settings.smoothScroll
        Pane {
            Section {
                Toggle(L("menu.scroll.smooth"), isOn: model.binding(\.smoothScroll))
                Picker(L("settings.smoothness"), selection: model.binding(\.scrollSmoothness)) {
                    ForEach(ScrollSmoothness.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!smooth)
            } header: {
                Text(L("menu.scroll"))
            } footer: {
                Text(L("settings.footer.smooth")).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("settings.scrollBounce"), isOn: model.binding(\.scrollBounce))
                    .disabled(!smooth)
            } footer: {
                Text(L("settings.scrollBounce.hint")).foregroundStyle(.secondary)
            }
        }
    }
}
