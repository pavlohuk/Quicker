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
        let host = NSHostingController(rootView: SettingsView().environmentObject(model))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        // An empty toolbar lets the sidebar reach the top of the window, as in System Settings.
        window.toolbar = NSToolbar()
        window.setContentSize(NSSize(width: 720, height: 480))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, hotkeys, apps, indicator, brightness, video, dock, mouse

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return L("settings.tab.general")
        case .hotkeys: return L("settings.tab.hotkeys")
        case .apps: return L("settings.tab.apps")
        case .indicator: return L("settings.tab.indicator")
        case .brightness: return L("settings.tab.brightness")
        case .video: return L("settings.tab.video")
        case .dock: return L("menu.dock")
        case .mouse: return L("settings.tab.mouse")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .hotkeys: return "keyboard"
        case .apps: return "macwindow.on.rectangle"
        case .indicator: return "rectangle.inset.filled"
        case .brightness: return "sun.max"
        case .video: return "play.rectangle"
        case .dock: return "dock.rectangle"
        case .mouse: return "computermouse"
        }
    }

    /// Icon tile colour, as in System Settings.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .hotkeys: return .indigo
        case .apps: return .blue
        case .indicator: return .teal
        case .brightness: return .orange
        case .video: return .red
        case .dock: return .purple
        case .mouse: return .green
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
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .padding(.vertical, 1)
            }
            .navigationSplitViewColumnWidth(200)
            .modifier(NoSidebarToggle())
        } detail: {
            let section = selection ?? .general
            Group {
                switch section {
                case .general: GeneralPane()
                case .hotkeys: HotkeysPane()
                case .apps: AppsPane()
                case .indicator: IndicatorPane()
                case .brightness: BrightnessPane()
                case .video: VideoPane()
                case .dock: DockPane()
                case .mouse: MousePane()
                }
            }
            .navigationTitle(section.title)
        }
        .frame(minWidth: 720, minHeight: 480)
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

private struct GeneralPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                Toggle(L("menu.enabled"), isOn: model.binding(\.enabled))
                Toggle(L("menu.invertSwipe"), isOn: model.binding(\.invertDirection))
                Toggle(L("menu.longSwipe"), isOn: model.binding(\.longSwipeSkipsMore))
            }
            Section {
                Toggle(L("menu.launchAtLogin"), isOn: model.launchAtLogin)
            }
        }
    }
}

private struct HotkeysPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        let m = model.settings.hotkeyModifier.symbol
        Pane {
            Section {
                Toggle(L("menu.hotkeys.digits", m), isOn: model.binding(\.hotkeyDigits))
                Toggle(L("menu.hotkeys.arrows", m), isOn: model.binding(\.hotkeyArrows))
                Picker(L("settings.modifier"), selection: model.binding(\.hotkeyModifier)) {
                    ForEach(HotkeyModifier.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

private struct AppsPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
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
        }
    }
}

private struct IndicatorPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                Toggle(L("menu.indicator.show"), isOn: model.binding(\.indicatorEnabled))
                Picker(L("settings.position"), selection: model.binding(\.indicatorCorner)) {
                    ForEach(IndicatorCorner.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!model.settings.indicatorEnabled)
            }
        }
    }
}

private struct BrightnessPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                Toggle(L("menu.brightness.keys"), isOn: model.binding(\.brightnessKeys))
            }
        }
    }
}

private struct VideoPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                Toggle(L("menu.video.hideMenuBar"), isOn: model.binding(\.hideMenuBarForVideo))
            }
        }
    }
}

private struct DockPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                Toggle(L("menu.dock.external"), isOn: model.binding(\.dockShownOnExternalDisplay))
            }
        }
    }
}

private struct MousePane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Pane {
            Section {
                Toggle(L("menu.scroll.smooth"), isOn: model.binding(\.smoothScroll))
                Picker(L("settings.smoothness"), selection: model.binding(\.scrollSmoothness)) {
                    ForEach(ScrollSmoothness.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!model.settings.smoothScroll)
            }
            Section {
                Toggle(L("settings.scrollBounce"), isOn: model.binding(\.scrollBounce))
                    .disabled(!model.settings.smoothScroll)
            } footer: {
                Text(L("settings.scrollBounce.hint"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
