// kilx — a macOS stand-in for X11's xkill.
//
// Usage:  ./kilx          (build with: swiftc -O main.swift -o kilx, or `make`)
// After arming, click any window, menu bar / status item, or Dock icon to
// terminate the app that owns it. Right-click or Esc cancels. The click
// itself is consumed and never reaches the target, just like xkill grabs the
// pointer. One click per run: the tool exits after the first mouse-down
// whether or not it killed anything, so a stray click can never take down a
// second app.
//
// Requires Accessibility permission for the app you launch it from
// (System Settings → Privacy & Security → Accessibility). Esc additionally
// needs Input Monitoring; if it is missing the tap simply isn't installed.

import Cocoa
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Tuning

private let menuBarHeight: CGFloat = 30   // menu bar strip height (pt)
private let dockZoneHeight: CGFloat = 170 // dock strip height (pt)
private let axWalkDepth = 12          // max parent hops to the owning app
private let dockResolveAttempts = 4   // dock geometry reads before giving up
private let dockReadRetryDelay = 0.12 // s between dock geometry reads
private let quitPollInterval = 0.2    // s between termination checks
private let gracefulQuitTimeout = 6.0 // s before force-killing

// MARK: - Small helpers

private func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

private let dockItemRole = "AXDockItem"

private func axAttr(_ element: AXUIElement, _ attr: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr, &value) == .success else { return nil }
    return value
}

private func axRole(_ element: AXUIElement) -> String? {
    axAttr(element, kAXRoleAttribute as CFString) as? String
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let posRef = axAttr(element, kAXPositionAttribute as CFString),
          let sizeRef = axAttr(element, kAXSizeAttribute as CFString) else { return nil }
    let pos = posRef as! AXValue
    let size = sizeRef as! AXValue
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard withUnsafeMutableBytes(of: &origin, { AXValueGetValue(pos, .cgPoint, $0.baseAddress!) }),
          withUnsafeMutableBytes(of: &extent, { AXValueGetValue(size, .cgSize, $0.baseAddress!) }) else { return nil }
    return CGRect(origin: origin, size: extent)
}

/// Walk up the accessibility tree to the owning application element,
/// reporting whether a window appeared in the chain.
private func resolveApp(from element: AXUIElement) -> (app: AXUIElement, sawWindow: Bool)? {
    var current: AXUIElement? = element
    var sawWindow = false
    for _ in 0..<axWalkDepth {
        guard let cur = current else { return nil }
        let role = axRole(cur)
        if role == kAXApplicationRole as String { return (cur, sawWindow) }
        if role == kAXWindowRole as String { sawWindow = true }
        guard let parentRef = axAttr(cur, kAXParentAttribute as CFString) else { return nil }
        current = (parentRef as! AXUIElement)
    }
    return nil
}

private var finderPID: pid_t {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0
}

// MARK: - Dock

private var dockPID: pid_t {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
}

/// Depth-first walk of the Dock's accessibility tree collecting AXDockItem elements.
private func dockItemElements() -> [AXUIElement] {
    let pid = dockPID
    guard pid != 0 else { return [] }
    var stack: [AXUIElement] = [AXUIElementCreateApplication(pid)]
    var found: [AXUIElement] = []
    var visited = 0
    while let current = stack.popLast(), visited < 1000 {
        visited += 1
        if axRole(current) == dockItemRole { found.append(current) }
        if let children = axAttr(current, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            stack.append(contentsOf: children)
        }
    }
    return found
}

private func dockItemTitle(_ item: AXUIElement) -> String? {
    axAttr(item, kAXTitleAttribute as CFString) as? String
        ?? axAttr(item, kAXDescriptionAttribute as CFString) as? String
}

/// Item whose frame contains the point, preferring the innermost (smallest)
/// frame.
private func dockItem(at point: CGPoint, among items: [AXUIElement]) -> AXUIElement? {
    let framed = items.compactMap { item -> (AXUIElement, CGRect)? in
        guard let f = axFrame(item) else { return nil }
        return (item, f)
    }
    return framed
        .filter { $0.1.contains(point) }
        .min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
}

/// Is the click point inside the strip the Dock occupies on the primary
/// display? Purely geometric (the bottom ~170 pt of the primary display, in
/// the same top-left global coordinates as the click) so it stays reliable
/// even while the Dock's accessibility tree is transiently unreadable during
/// a reflow.
private func inDockZone(_ p: CGPoint) -> Bool {
    let b = CGDisplayBounds(CGMainDisplayID())
    return p.x >= b.minX && p.x <= b.maxX
        && p.y >= b.maxY - dockZoneHeight && p.y <= b.maxY
}

private var dockVisible: Bool {
    UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") != true
}

/// Is the point in the menu bar strip (top of the primary display)?
private func inMenuBarStrip(_ p: CGPoint) -> Bool {
    let b = CGDisplayBounds(CGMainDisplayID())
    return p.x >= b.minX && p.x <= b.maxX && p.y >= b.minY && p.y <= b.minY + menuBarHeight
}

/// Menu bar extras that are system components, not apps — clicking their
/// icons should never kill them.
private func isSystemMenuBarOwner(_ pid: pid_t) -> Bool {
    guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
    return ["com.apple.controlcenter", "com.apple.spotlight", "com.apple.systemuiserver"].contains(bundle)
}

/// Resolve the Dock item under the cursor from the earliest consistent read:
/// item frames and the system-wide hit test must agree within one read, and
/// that result is used immediately. Re-resolving against a later (settled)
/// layout would kill the app that now occupies the click point instead of the
/// icon that was there when the user clicked. Returns nil if the Dock's tree
/// stays unreadable or the two signals keep disagreeing.
private func resolveDockItem(at point: CGPoint) -> AXUIElement? {
    for _ in 0..<dockResolveAttempts {
        let items = dockItemElements()
        let frameHit = dockItem(at: point, among: items)

        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                   Float(point.x), Float(point.y), &hit)
        let hitItem = (err == .success && hit != nil && axRole(hit!) == dockItemRole) ? hit : nil

        if let frameHit, let hitItem {
            if CFEqual(frameHit, hitItem) { return frameHit } // consistent — trust it
        } else if let resolved = frameHit ?? hitItem {
            return resolved
        }
        Thread.sleep(forTimeInterval: dockReadRetryDelay) // transient read failure — retry with fresher geometry
    }
    return nil
}

/// Kill the app behind the Dock icon under the cursor, or exit cleanly if the
/// icon is not a running app or the Dock layout is unstable.
private func handleDockClick(at point: CGPoint) -> Never {
    guard let item = resolveDockItem(at: point) else {
        log("kilx: could not identify the dock app under the cursor (dock in flux?) — nothing killed.")
        exit(1)
    }
    if let app = appForDockItem(item) {
        killApp(pid: app.processIdentifier, name: app.localizedName ?? "app")
    }
    log("kilx: dock item \"\(dockItemTitle(item) ?? "?")\" is not a running app (folder/stack/trash?) — nothing killed.")
    exit(1)
}

/// Match a dock item's title to a running app, ignoring case and
/// punctuation: the dock title "ChatGPT (Classic)" must match the app's
/// localizedName "ChatGPT Classic".
private func normalizedName(_ s: String) -> String {
    s.lowercased().filter { $0.isLetter || $0.isNumber }
}

private func runningApp(named name: String) -> NSRunningApplication? {
    let wanted = normalizedName(name)
    guard !wanted.isEmpty else { return nil }
    return NSWorkspace.shared.runningApplications.first {
        normalizedName($0.localizedName ?? "") == wanted
    }
}

private func appForDockItem(_ item: AXUIElement) -> NSRunningApplication? {
    guard let title = dockItemTitle(item) else { return nil }
    return runningApp(named: title)
}

// MARK: - Fallback: top-most window under the cursor

private func windowOwnerPID(at point: CGPoint) -> pid_t? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    var best: (pid: pid_t, layer: Int)?
    for w in windows {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let layer = w[kCGWindowLayer as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"] else { continue }
        if CGRect(x: x, y: y, width: wd, height: ht).contains(point),
           best == nil || abs(layer) < abs(best!.layer) {
            best = (pid, layer)
        }
    }
    return best?.pid
}

// MARK: - Kill

private func killApp(pid: pid_t, name: String) -> Never {
    log("kilx: killing \(name) (pid \(pid))")
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        log("kilx: \(name) is already gone.")
        exit(0)
    }
    app.terminate() // graceful quit; lets the app save its state
    let deadline = Date().addingTimeInterval(gracefulQuitTimeout)
    while Date() < deadline {
        if app.isTerminated {
            log("kilx: \(name) terminated.")
            exit(0)
        }
        Thread.sleep(forTimeInterval: quitPollInterval)
    }
    log("kilx: \(name) did not quit in time; forcing…")
    app.forceTerminate()
    exit(0)
}

// MARK: - Click handling

/// What a click resolved to: a Dock icon to resolve further, an app to kill,
/// a click to refuse (with a reason), or nothing clickable.
private enum ClickTarget {
    case dock(point: CGPoint)
    case app(pid: pid_t)
    case refuse(String)
    case nothing
}

/// Classify the click: accessibility hit test, then the Dock zone, menu bar
/// strip, and desktop guards. No side effects — the caller acts on the result.
private func resolveClickTarget(at eventPoint: CGPoint) -> ClickTarget {
    // CGEvent locations and accessibility coordinates share the global display
    // coordinate space (origin at the top-left of the main display).
    let systemWide = AXUIElementCreateSystemWide()
    var hit: AXUIElement?
    var hitIsItem = false
    var hitPID: pid_t = 0
    var sawWindow = false
    if AXUIElementCopyElementAtPosition(systemWide, Float(eventPoint.x), Float(eventPoint.y), &hit) == .success,
       let hit {
        hitIsItem = axRole(hit) == dockItemRole
        if let resolved = resolveApp(from: hit) {
            AXUIElementGetPid(resolved.app, &hitPID)
            sawWindow = resolved.sawWindow
        }
    }

    // Dock click: the hit test says Dock, or the point lies in the Dock's
    // geometric zone on the primary display. The zone is tree-independent, so
    // a click during a Dock reflow (when its accessibility tree may be
    // transiently unreadable) never falls through to the window path and kills
    // the app whose window runs underneath the Dock bar.
    if hitIsItem || hitPID == dockPID || (dockVisible && inDockZone(eventPoint)) {
        return .dock(point: eventPoint)
    }

    // Menu bar: when the hit test fails in the top strip (dead spots between
    // status items), never fall through to the window path — it would kill the
    // window underneath the menu bar.
    if hitPID == 0 && inMenuBarStrip(eventPoint) {
        return .refuse("kilx: clicked the menu bar — nothing killed.")
    }

    // Window / menu bar / desktop click.
    if hitPID != 0 {
        if isSystemMenuBarOwner(hitPID) {
            return .refuse("kilx: clicked a system menu bar item — nothing killed.")
        }
        if hitPID == finderPID && !sawWindow {
            return .refuse("kilx: clicked the desktop — nothing killed.")
        }
        return .app(pid: hitPID)
    }

    // Fallback: top-most window under the cursor, for apps that do not expose
    // accessibility.
    if let pid = windowOwnerPID(at: eventPoint) {
        return .app(pid: pid)
    }

    return .nothing
}

private func handleClick(at eventPoint: CGPoint, isRightClick: Bool) {
    if isRightClick {
        log("kilx: cancelled.")
        exit(0)
    }
    switch resolveClickTarget(at: eventPoint) {
    case .dock(let point):
        handleDockClick(at: point)
    case .app(let pid):
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        killApp(pid: pid, name: name)
    case .refuse(let message):
        log(message)
        exit(1)
    case .nothing:
        log("kilx: nothing found under the cursor — nothing killed.")
        exit(1)
    }
}

// MARK: - Event taps

private let mouseTapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .leftMouseDown:
        handleClick(at: event.location, isRightClick: false)
    case .rightMouseDown:
        handleClick(at: event.location, isRightClick: true)
    default:
        break
    }
    return nil // consume the click, xkill-style: the target never sees it
}

private let keyTapCallback: CGEventTapCallBack = { _, _, event, _ in
    if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
        log("kilx: cancelled.")
        exit(0)
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Armed feedback

/// A skull image, drawn from the skull emoji.
private func skullImage() -> NSImage {
    let size = NSSize(width: 28, height: 28)
    let image = NSImage(size: size)
    image.lockFocus()
    let str = NSAttributedString(string: "💀", attributes: [.font: NSFont.systemFont(ofSize: 24)])
    let textSize = str.size()
    str.draw(at: NSPoint(x: (size.width - textSize.width) / 2,
                         y: (size.height - textSize.height) / 2))
    image.unlockFocus()
    return image
}

/// A skull that follows the mouse while armed. The real cursor cannot be
/// changed from a background process (cursor rects were removed from macOS),
/// so a small click-through overlay tracks the pointer instead.
private func showArmedFeedback() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // no Dock icon
    guard !NSScreen.screens.isEmpty else { return }

    let skullSize: CGFloat = 36
    let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: skullSize, height: skullSize))
    imageView.image = skullImage()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: skullSize, height: skullSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = imageView
    window.level = .screenSaver
    window.ignoresMouseEvents = true // clicks pass through to the event tap
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.orderFrontRegardless()

    // CGEvent locations and AppKit screen coordinates are both top-left/bottom-
    // left of the primary display, so the y flip is just the primary's height.
    let primaryHeight = NSScreen.screens[0].frame.height
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
        let loc = CGEvent(source: nil)?.location ?? .zero
        window.setFrameOrigin(NSPoint(x: loc.x - skullSize / 2,
                                      y: primaryHeight - loc.y - skullSize / 2))
    }
}

// MARK: - Main

if CommandLine.arguments.contains(where: { $0 == "-h" || $0 == "--help" }) {
    print("""
    kilx — a macOS stand-in for X11's xkill.

    Usage: kilx
      After arming, click a window, menu bar / status item, or Dock icon to
      terminate the app that owns it. Right-click or Esc cancels. One click
      per run.

    Requires Accessibility permission for the launching app
    (System Settings → Privacy & Security → Accessibility).
    """)
    exit(0)
}

let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
)
guard trusted else {
    log("kilx: Accessibility permission required. Grant it to the app you launch this from")
    log("       (System Settings → Privacy & Security → Accessibility), then run again.")
    exit(1)
}

// Refuse to run a second armed instance: a stale one left waiting for a click
// would silently consume the next mouse-down instead of the fresh instance.
let lockPath = "/tmp/kilx.pid"
if let existing = try? String(contentsOfFile: lockPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines),
   let pid = pid_t(existing), pid != getpid(), Darwin.kill(pid, 0) == 0 {
    log("kilx: another instance is already armed (pid \(pid)) — use it or kill it, then run again.")
    exit(1)
}
try? String(getpid()).write(toFile: lockPath, atomically: true, encoding: .utf8)
atexit { try? FileManager.default.removeItem(atPath: lockPath) }

log("kilx: armed — click a window, menu bar item, or Dock icon to kill its app; right-click or Esc to cancel.")

let mouseMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
              | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: mouseMask,
                                  callback: mouseTapCallback,
                                  userInfo: nil) else {
    log("kilx: failed to create the event tap.")
    exit(1)
}
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// Optional: Esc cancels. Needs Input Monitoring permission; degrade silently.
if let keyTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                  callback: keyTapCallback,
                                  userInfo: nil) {
    let keySource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyTap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), keySource, CFRunLoopMode.commonModes)
    CGEvent.tapEnable(tap: keyTap, enable: true)
}

showArmedFeedback()
CFRunLoopRun()
