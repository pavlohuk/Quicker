# Quicker

A macOS menu bar app that makes switching between Spaces **instant, without the slide animation**.

- **Trackpad swipe.** The system three- or four-finger swipe between desktops switches immediately.
- **Hotkeys.** ⌘1…⌘9 jumps straight to desktop N, and ⌘←/⌘→ moves to the neighbouring Space.
- **Following apps.** ⌘Tab or a Dock click on an app whose windows are on another Space jumps there instantly.
- **Indicator.** After every switch, a small overlay at the top of the screen names the Space you landed on.

No SIP changes and no Dock patching are needed. The app is available in English and Ukrainian and follows the system language.

Developed and tested on macOS 27.0 on Apple Silicon. The minimum supported version is macOS 13, but versions before 27 are untested.

## Quick start

### 1. Build and install

You need Xcode or the Xcode Command Line Tools with Swift 5.9 or later.

```bash
git clone https://github.com/pavlohuk/Quicker.git
cd Quicker
Scripts/install.sh
```

The script builds a release binary and packs it into `Quicker.app`. It signs the app ad hoc, copies it to `/Applications`, and launches it. An icon appears in the menu bar.

To build without installing, run `Scripts/build-app.sh`. The app is written to `build/Quicker.app`.

### 2. Configure macOS

1. **Keep the system swipe on.** Open System Settings → Trackpad → More Gestures. Set "Swipe between full-screen applications" to three or four fingers. Quicker intercepts exactly this gesture, so it must stay enabled.
2. **Grant Accessibility.** macOS asks on first launch. You can also go to System Settings → Privacy & Security → Accessibility and turn on Quicker. The app notices the permission within a couple of seconds, so no restart is needed.
3. **Optional: turn off the animated app switch.** Go to System Settings → Desktop & Dock → Mission Control. Turn off "When switching to an application, switch to a Space with open windows for the application". This is required for the instant ⌘Tab behaviour described below.
4. **Optional: start at login.** Enable "Launch at Login" in the app's menu. The app must be in `/Applications` for this to work.

Now swipe with three fingers. Spaces switch instantly, and an overlay shows where you are.

If the Accessibility toggle looks on but nothing happens, reset the entry and grant it again. This can happen after replacing the app with a build signed differently. Then click "Grant Permission…" in the app's menu.

```bash
tccutil reset Accessibility com.pavlohuk.Quicker
```

## How it works

1. macOS recognises the swipe itself and sends "Dock swipe" gesture events to the Dock.
2. Quicker installs a session event tap that swallows those events.
3. Instead, it posts a synthetic Dock swipe with a near-zero progress and a huge fling velocity. The Dock performs the switch but finishes it at once, so there is nothing to animate.

Because the Dock does the switching, windows of the previous Space are hidden properly. Full-screen apps behave like any other Space, and other apps get the normal Space-change notification.

Switching Spaces directly through SkyLight's `SLSManagedDisplaySetCurrentSpace` was tried first and rejected. It changes the current Space without animation, but it leaves every window of the previous Space on screen.

The synthetic swipe technique comes from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) by jurplel, under the MIT license. That includes the event fields and the raw IOHID payload that macOS 27 requires. The license text is in `THIRD_PARTY_LICENSE-InstantSpaceSwitcher.txt` and in the header of `Sources/CShims/dockswipe.c`.

## Features

### Hotkeys

- **⌘1 … ⌘9** jumps straight to desktop N. Only regular desktops are counted, matching the "Desktop 1, Desktop 2…" labels in Mission Control, so full-screen apps are skipped. If there is no desktop N, the keystroke goes to the frontmost app as usual.
- **⌘← / ⌘→** moves to the neighbouring Space. Full-screen apps are included, in the same order as the swipe.

A jump across several Spaces is a burst of instant swipes, so it has no animation either. Holding an arrow key does not repeat the switch.

These shortcuts are captured globally, so apps no longer receive them. ⌘1…9 stops switching browser tabs and Finder views, and ⌘←/→ stops moving the cursor to the start or end of a line. To avoid this, pick another modifier in the menu: ⌘, ⌃, ⌥ or ⌃⌥. Digits and arrows can also be turned off separately.

### Following the activated app (⌘Tab, Dock)

Sometimes an app becomes active while none of its windows is on the current Space. This happens with ⌘Tab, a Dock click, or opening a link. Quicker then jumps instantly to the Space holding that app's most recently used window, and makes sure the app you picked gets focus there rather than another app on the same Space. Full-screen apps are supported. If the app already has a visible window on the current Space, nothing happens. Closed, hidden and minimized windows do not count, because macOS keeps them attached to the Space where they were last shown.

Dock clicks are handled before the Dock acts on them. When you click the icon of a running app whose windows are all on another Space, Quicker holds the click back, jumps to that Space instantly and then passes the click on to the Dock. The Dock then just activates the app, so there is no delay and no slide.

In both cases Quicker first asks the WindowServer to bring the app's most recent window to the front, waits 30 ms and only then switches. Without that, the Space would first appear with another app's window on top, and the app you picked would rise about 0.1 s later. Some apps, such as Arc and Things, bring their window forward on activation by themselves, which makes macOS slide to their Space even with the system option off. Quicker switches instantly before that slide can happen. Clicks with ⌘, ⌃, ⌥ or ⇧ held, clicks on apps that are not running, and clicks on apps with a visible window on the current Space reach the Dock unchanged. Each Dock icon is matched to the running app by its location on disk, so copies of one app with the same bundle identifier, such as Telegram and a second Telegram, are told apart.

This needs the system option from step 3 of the setup to be off. While it is on, the Dock performs its own animated switch. Quicker then stays out of the way so the two switches do not collide, and its menu shows a warning.

### Space indicator

After every Space change, an overlay appears for about a second at the top centre of the screen, just below the menu bar. It shows the Space name: "Desktop N" for desktops, or the app name for a full-screen Space. Below the name is a row of marks for all Spaces in Dock order. A dot is a desktop, a short pill is a full-screen app, and the current Space is highlighted.

- It reacts to every kind of switch, including swipes, hotkeys, Mission Control, Dock clicks and the system Ctrl+←/→.
- It appears once the Dock has landed on the final Space, so a multi-Space jump never shows the Spaces in between.
- It never takes focus or intercepts clicks, and it is visible over full-screen apps.
- Its position can be the top centre or any corner, and it can be turned off in the menu.

## Menu

- **Status.** Shows whether Accessibility is granted and which finger count the system swipe uses.
- **Enabled.** The master switch. When it is off, swipes reach the system unchanged with the normal animation, and the hotkeys and app following do nothing.
- **Invert Swipe Direction.** Affects the trackpad only.
- **Hotkeys.** Toggles for digits and arrows, and the modifier choice.
- **Go to App (⌘Tab, Dock).** Toggles following the activated app.
- **Space Indicator.** On/off and the position on screen.
- **Launch at Login.** Uses `SMAppService`.

Settings are stored in the `com.pavlohuk.Quicker` defaults domain.

## Language

The menu, the indicator and the alerts are localized in English and Ukrainian. macOS picks the language from your preferred languages in System Settings → General → Language & Region. Any other language falls back to English. To use a different language for Quicker only, add it under Applications in the same settings pane.

The translations are in `Resources/en.lproj/Localizable.strings` and `Resources/uk.lproj/Localizable.strings`. Both files must contain the same keys.

## Troubleshooting

Stream the app's log:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.pavlohuk.Quicker"' --level info
```

In zsh, `log` is a shell builtin, so use the full path `/usr/bin/log`. Every swipe or hotkey should print a line such as `switch next: space 1 -> 2 of 3` or `switch desktop 3: space 1 -> 5 of 5`. Every indicator prints whether it was actually visible on screen.

Switch Spaces from a terminal without a gesture:

```bash
kill -USR1 $(pgrep -x Quicker)   # next Space
kill -USR2 $(pgrep -x Quicker)   # previous Space
```

Common problems:

- **The swipe does nothing.** The system swipe between full-screen applications is probably off. The menu shows a warning in that case.
- **The swipe still animates.** Accessibility is probably not granted, so the app cannot install its event tap. Check the first lines of the menu.
- **Double switches or two overlays.** Another tool that intercepts the same gesture is running, for example InstantSpaceSwitcher. Quit it and remove it from Login Items.

## Limitations

- Undocumented event fields and private APIs are used, so a macOS update may break the app.
- At the first or last Space, a swipe past the edge is ignored, with no rubber-band bounce. The app deliberately never posts a switch beyond the last Space, because on macOS 27 that can wedge the Dock.
- The build is signed ad hoc, but the designated requirement is pinned to the bundle identifier `com.pavlohuk.Quicker` rather than to the build's hash. That is why the Accessibility permission survives rebuilds. The trade-off is that any app signed the same way with the same identifier would inherit the permission, so do not reuse that identifier for anything else.

## License

Quicker is released under the [MIT License](LICENSE). The synthetic swipe code adapted from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) keeps its own MIT notice in `THIRD_PARTY_LICENSE-InstantSpaceSwitcher.txt` and in the header of `Sources/CShims/dockswipe.c`.
