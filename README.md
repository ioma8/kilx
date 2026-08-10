# mkill

A macOS stand-in for X11's `xkill`: run it, click a window (or Dock icon), and the app that owns it is terminated.

## Requirements

- macOS with a recent Xcode Command Line Tools (Swift 6+)
- **Accessibility** permission for the app you launch it from (System Settings → Privacy & Security → Accessibility)
- Esc-cancel additionally needs **Input Monitoring** (optional — skipped silently if missing)

## Install

```sh
make               # builds ./mkill
sudo make install  # installs to /usr/local/bin
```

## Usage

```sh
./mkill
```

Then click:

| you click | result |
|---|---|
| a window / menu bar | the owning app quits (graceful, force after 6 s) |
| a running app's Dock icon | that app quits |
| a non-running app's icon, folder, stack, Trash | nothing killed (exit 1) |
| the desktop | nothing killed (exit 1) |
| right-click or Esc | cancels (exit 0) |

The click itself is consumed and never reaches the target — exactly like `xkill` grabbing the pointer. One click per run: the tool exits after the first mouse-down, so a stray click can never take down a second app.

## How it works

- A global `CGEventTap` on mouse-downs; the click is consumed.
- Window clicks: accessibility hit test → owning app → PID → graceful `terminate()`, `forceTerminate()` after 6 s.
- Dock clicks: resolved from the Dock's own icon geometry (never the window underneath the Dock bar) and refused while the Dock layout is unstable.
- Fallback to the top-most window under the cursor for apps without accessibility support.

## License

[MIT](LICENSE)
