import AppKit
import Carbon
import CoreGraphics
import Darwin
import Foundation

private struct CapturedImage {
    let image: CGImage
    let appKitFrame: CGRect
    let title: String
}

private struct ScreenSelection {
    let rect: CGRect
    let startPoint: CGPoint
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID?
    let backingScaleFactor: CGFloat
}

private enum PinnedWindowPlacement {
    static let fallbackSmallSize = CGSize(width: 320, height: 220)
    static let minimumSize = CGSize(width: 160, height: 120)

    static func adjustedFrame(for frame: CGRect) -> CGRect {
        var adjustedFrame = frame
        if adjustedFrame.width < minimumSize.width || adjustedFrame.height < minimumSize.height {
            adjustedFrame.size = CGSize(
                width: max(adjustedFrame.width, fallbackSmallSize.width),
                height: max(adjustedFrame.height, fallbackSmallSize.height)
            )
        }
        return adjustedFrame
    }

    static func frameAnchoredAtSelectionStart(_ selection: ScreenSelection) -> CGRect {
        let rect = selection.rect.standardized
        var size = rect.size
        if size.width < minimumSize.width || size.height < minimumSize.height {
            size = CGSize(
                width: max(size.width, fallbackSmallSize.width),
                height: max(size.height, fallbackSmallSize.height)
            )
        }

        let startsOnRight = abs(selection.startPoint.x - rect.maxX) < abs(selection.startPoint.x - rect.minX)
        let startsOnTop = abs(selection.startPoint.y - rect.maxY) < abs(selection.startPoint.y - rect.minY)

        let origin = CGPoint(
            x: startsOnRight ? selection.startPoint.x - size.width : selection.startPoint.x,
            y: startsOnTop ? selection.startPoint.y - size.height : selection.startPoint.y
        )
        return clamp(CGRect(origin: origin, size: size), to: selection.screenFrame)
    }

    private static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        guard !bounds.isNull, !bounds.isEmpty else {
            return frame
        }

        var origin = frame.origin
        if frame.width <= bounds.width {
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - frame.width)
        } else {
            origin.x = bounds.minX
        }

        if frame.height <= bounds.height {
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - frame.height)
        } else {
            origin.y = bounds.minY
        }

        return CGRect(origin: origin, size: frame.size)
    }
}

private enum ShortcutAction: UInt32, CaseIterable {
    case pinFrontmostWindow = 1
    case pinScreenSelection = 2
}

private struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyEquivalent: String

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var displayString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        parts.append(keyEquivalent.uppercased())
        return parts.joined(separator: " + ")
    }

    static let defaultPinFrontmostWindow = KeyboardShortcut(
        keyCode: 35,
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey),
        keyEquivalent: "p"
    )

    static let defaultPinScreenSelection = KeyboardShortcut(
        keyCode: 1,
        carbonModifiers: UInt32(cmdKey | optionKey | controlKey),
        keyEquivalent: "s"
    )

    static func from(event: NSEvent) -> KeyboardShortcut? {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if modifierFlags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        let nonShiftModifierCount = [
            modifierFlags.contains(.command),
            modifierFlags.contains(.option),
            modifierFlags.contains(.control)
        ].filter { $0 }.count
        guard nonShiftModifierCount >= 2 else {
            return nil
        }

        guard
            let character = event.charactersIgnoringModifiers?.lowercased().first,
            character.isLetter || character.isNumber
        else {
            return nil
        }

        return KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbonModifiers,
            keyEquivalent: String(character)
        )
    }
}

private struct ShortcutSettings: Equatable {
    var pinFrontmostWindow: KeyboardShortcut
    var pinScreenSelection: KeyboardShortcut

    static let defaults = ShortcutSettings(
        pinFrontmostWindow: .defaultPinFrontmostWindow,
        pinScreenSelection: .defaultPinScreenSelection
    )
}

private enum ShortcutStore {
    private static let pinFrontmostWindowKey = "Shortcut.PinFrontmostWindow"
    private static let pinScreenSelectionKey = "Shortcut.PinScreenSelection"

    static func load() -> ShortcutSettings {
        ShortcutSettings(
            pinFrontmostWindow: loadShortcut(forKey: pinFrontmostWindowKey) ?? .defaultPinFrontmostWindow,
            pinScreenSelection: loadShortcut(forKey: pinScreenSelectionKey) ?? .defaultPinScreenSelection
        )
    }

    static func save(_ settings: ShortcutSettings) {
        saveShortcut(settings.pinFrontmostWindow, forKey: pinFrontmostWindowKey)
        saveShortcut(settings.pinScreenSelection, forKey: pinScreenSelectionKey)
    }

    private static func loadShortcut(forKey key: String) -> KeyboardShortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }

    private static func saveShortcut(_ shortcut: KeyboardShortcut, forKey key: String) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private final class HotKeyManager {
    private let signature = OSType(
        UInt32(Character("P").asciiValue!) << 24 |
        UInt32(Character("T").asciiValue!) << 16 |
        UInt32(Character("o").asciiValue!) << 8 |
        UInt32(Character("p").asciiValue!)
    )

    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var callbacks: [ShortcutAction: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else {
                    return status
                }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.handleHotKey(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(settings: ShortcutSettings, callbacks: [ShortcutAction: () -> Void]) -> Bool {
        unregisterAll()
        self.callbacks = callbacks

        return register(.pinFrontmostWindow, shortcut: settings.pinFrontmostWindow) &&
            register(.pinScreenSelection, shortcut: settings.pinScreenSelection)
    }

    private func register(_ action: ShortcutAction, shortcut: KeyboardShortcut) -> Bool {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            return false
        }

        hotKeyRefs[action] = hotKeyRef
        return true
    }

    private func unregisterAll() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
    }

    private func handleHotKey(id: UInt32) {
        guard let action = ShortcutAction(rawValue: id) else {
            return
        }
        callbacks[action]?()
    }
}

private enum ScreenGeometry {
    private static var mainScreenMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func appKitRect(fromCGWindowBounds rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainScreenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func cgRect(fromAppKitRect rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainScreenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        if let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return displayID
        }

        if let displayNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(displayNumber.uint32Value)
        }

        return nil
    }
}

private enum WindowCapture {
    static func captureFrontWindow(for processID: pid_t) -> CapturedImage? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates = windowInfo.compactMap { info -> (id: CGWindowID, bounds: CGRect, owner: String)? in
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == processID,
                let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width >= 80,
                bounds.height >= 60
            else {
                return nil
            }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { return nil }

            let owner = info[kCGWindowOwnerName as String] as? String ?? "Window"
            return (windowID, bounds, owner)
        }

        guard let target = candidates.first else {
            return nil
        }

        let options: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, target.id, options) else {
            return nil
        }

        return CapturedImage(
            image: image,
            appKitFrame: ScreenGeometry.appKitRect(fromCGWindowBounds: target.bounds),
            title: "Pinned: \(target.owner)"
        )
    }

    static func captureScreenSelection(_ selection: ScreenSelection) -> CapturedImage? {
        let normalizedRect = selection.rect.standardized
        guard normalizedRect.width >= 8, normalizedRect.height >= 8 else {
            return nil
        }

        guard let image = captureDisplayImage(for: selection, normalizedRect: normalizedRect) else {
            return nil
        }

        return CapturedImage(
            image: image,
            appKitFrame: PinnedWindowPlacement.frameAnchoredAtSelectionStart(selection),
            title: "Pinned Screenshot"
        )
    }

    private static func captureDisplayImage(for selection: ScreenSelection, normalizedRect: CGRect) -> CGImage? {
        if let displayID = selection.displayID {
            let localRect = CGRect(
                x: normalizedRect.minX - selection.screenFrame.minX,
                y: selection.screenFrame.maxY - normalizedRect.maxY,
                width: normalizedRect.width,
                height: normalizedRect.height
            )
            let pixelRect = localRect
                .applying(CGAffineTransform(scaleX: selection.backingScaleFactor, y: selection.backingScaleFactor))
                .integral

            if let image = CGDisplayCreateImage(displayID, rect: pixelRect) {
                return image
            }
        }

        let cgRect = ScreenGeometry.cgRect(fromAppKitRect: normalizedRect)
        let options: CGWindowImageOption = [.bestResolution]
        return CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, options)
    }
}

private final class PinnedPanelController: NSWindowController, NSWindowDelegate {
    var onClose: ((PinnedPanelController) -> Void)?

    init(captured: CapturedImage) {
        let image = NSImage(cgImage: captured.image, size: NSSize(width: captured.image.width, height: captured.image.height))
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor

        let frame = PinnedWindowPlacement.adjustedFrame(for: captured.appKitFrame)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = captured.title
        panel.contentView = imageView
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 160, height: 120)

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    var onComplete: ((CGRect, CGPoint) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: CGPoint?
    private var selectionRect: CGRect = .zero {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let overlay = NSBezierPath(rect: bounds)
        if !selectionRect.isEmpty {
            overlay.append(NSBezierPath(rect: selectionRect))
            overlay.windingRule = .evenOdd
        }

        NSColor.black.withAlphaComponent(0.32).setFill()
        overlay.fill()

        guard !selectionRect.isEmpty else { return }

        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: selectionRect).fill()

        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 2
        NSColor.systemYellow.setStroke()
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        dragStart = point
        selectionRect = CGRect(origin: point, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = clampedPoint(convert(event.locationInWindow, from: nil))
        selectionRect = CGRect(
            x: min(dragStart.x, current.x),
            y: min(dragStart.y, current.y),
            width: abs(current.x - dragStart.x),
            height: abs(current.y - dragStart.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }

        if selectionRect.width >= 8, selectionRect.height >= 8, let dragStart {
            onComplete?(selectionRect, dragStart)
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func clampedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

private final class SelectionCoordinator {
    private var windows: [SelectionWindow] = []

    func begin(onComplete: @escaping (ScreenSelection) -> Void) {
        closeSelectionWindows()

        for screen in NSScreen.screens {
            makeSelectionWindow(for: screen, onComplete: onComplete)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        windows.dropFirst().forEach { $0.orderFrontRegardless() }
    }

    private func makeSelectionWindow(for screen: NSScreen, onComplete: @escaping (ScreenSelection) -> Void) {
        let frame = screen.frame
        let selectionWindow = SelectionWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        selectionWindow.isOpaque = false
        selectionWindow.backgroundColor = .clear
        selectionWindow.level = .screenSaver
        selectionWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let selectionView = SelectionView(frame: CGRect(origin: .zero, size: frame.size))
        selectionView.onComplete = { [weak self, weak selectionWindow] localRect, localStartPoint in
            guard let selectionWindow else { return }
            let globalRect = localRect.offsetBy(dx: selectionWindow.frame.minX, dy: selectionWindow.frame.minY)
            let globalStartPoint = CGPoint(
                x: localStartPoint.x + selectionWindow.frame.minX,
                y: localStartPoint.y + selectionWindow.frame.minY
            )
            self?.closeSelectionWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                onComplete(ScreenSelection(
                    rect: globalRect,
                    startPoint: globalStartPoint,
                    screenFrame: selectionWindow.frame,
                    displayID: screen.displayID,
                    backingScaleFactor: screen.backingScaleFactor
                ))
            }
        }
        selectionView.onCancel = { [weak self] in
            self?.closeSelectionWindows()
        }

        selectionWindow.contentView = selectionView
        windows.append(selectionWindow)
    }

    private func closeSelectionWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class ShortcutRecorderButton: NSButton {
    var shortcut: KeyboardShortcut {
        didSet { updateTitle() }
    }

    private var isRecording = false

    init(shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Press shortcut..."
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            updateTitle()
            return
        }

        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        guard let newShortcut = KeyboardShortcut.from(event: event) else {
            NSSound.beep()
            return
        }

        shortcut = newShortcut
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    private func updateTitle() {
        title = shortcut.displayString
        toolTip = "Click and press a shortcut with at least two of Command, Option, or Control."
    }
}

private final class ShortcutSettingsWindowController: NSWindowController {
    private let pinWindowRecorder: ShortcutRecorderButton
    private let pinSelectionRecorder: ShortcutRecorderButton
    private let onSave: (ShortcutSettings) -> Void

    init(settings: ShortcutSettings, onSave: @escaping (ShortcutSettings) -> Void) {
        self.pinWindowRecorder = ShortcutRecorderButton(shortcut: settings.pinFrontmostWindow)
        self.pinSelectionRecorder = ShortcutRecorderButton(shortcut: settings.pinScreenSelection)
        self.onSave = onSave

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 190))
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Customize Shortcuts"
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        buildContent(in: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent(in contentView: NSView) {
        let titleLabel = NSTextField(labelWithString: "Click a shortcut, then press the new key combination.")
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .secondaryLabelColor

        let pinWindowLabel = NSTextField(labelWithString: "Pin frontmost window")
        let pinSelectionLabel = NSTextField(labelWithString: "Pin screen selection")

        pinWindowRecorder.translatesAutoresizingMaskIntoConstraints = false
        pinSelectionRecorder.translatesAutoresizingMaskIntoConstraints = false
        pinWindowRecorder.widthAnchor.constraint(equalToConstant: 190).isActive = true
        pinSelectionRecorder.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let grid = NSGridView(views: [
            [pinWindowLabel, pinWindowRecorder],
            [pinSelectionLabel, pinSelectionRecorder]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowSpacing = 12
        grid.columnSpacing = 14

        let restoreButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restoreButton.bezelStyle = .rounded

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [restoreButton, NSView(), cancelButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fill

        let stack = NSStackView(views: [titleLabel, grid, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            buttonStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }

    @objc private func restoreDefaults() {
        pinWindowRecorder.shortcut = .defaultPinFrontmostWindow
        pinSelectionRecorder.shortcut = .defaultPinScreenSelection
    }

    @objc private func cancel() {
        close()
    }

    @objc private func save() {
        let settings = ShortcutSettings(
            pinFrontmostWindow: pinWindowRecorder.shortcut,
            pinScreenSelection: pinSelectionRecorder.shortcut
        )

        guard settings.pinFrontmostWindow != settings.pinScreenSelection else {
            NSSound.beep()
            return
        }

        onSave(settings)
        close()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let selectionCoordinator = SelectionCoordinator()
    private let hotKeyManager = HotKeyManager()
    private var pinnedPanels: [PinnedPanelController] = []
    private var lastTargetApplication: NSRunningApplication?
    private var shortcutSettings = ShortcutStore.load()
    private var pinFrontmostWindowItem: NSMenuItem?
    private var pinScreenSelectionItem: NSMenuItem?
    private var shortcutSettingsWindowController: ShortcutSettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        registerHotKeys()
        updateTargetApplication(NSWorkspace.shared.frontmostApplication)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "PinTop")
            button.image?.isTemplate = true
            button.toolTip = "PinTop"
        }

        let menu = NSMenu()
        let pinFrontmostWindowItem = makeMenuItem(
            title: "Pin Frontmost Window Snapshot",
            action: #selector(pinFrontmostWindowSnapshot),
            shortcut: shortcutSettings.pinFrontmostWindow
        )
        let pinScreenSelectionItem = makeMenuItem(
            title: "Pin Screen Selection",
            action: #selector(pinScreenSelection),
            shortcut: shortcutSettings.pinScreenSelection
        )
        self.pinFrontmostWindowItem = pinFrontmostWindowItem
        self.pinScreenSelectionItem = pinScreenSelectionItem
        menu.addItem(pinFrontmostWindowItem)
        menu.addItem(pinScreenSelectionItem)
        menu.addItem(NSMenuItem(title: "Customize Shortcuts...", action: #selector(customizeShortcuts), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Register Screen Recording Permission", action: #selector(registerScreenRecordingPermission), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Screen Recording Settings", action: #selector(openScreenRecordingSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal PinTop App", action: #selector(revealPinTopApp), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Close All Pinned Snapshots", action: #selector(closeAllPinnedSnapshots), keyEquivalent: "w"))
        menu.addItem(NSMenuItem(title: "Quit PinTop", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func makeMenuItem(
        title: String,
        action: Selector,
        shortcut: KeyboardShortcut
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut.keyEquivalent)
        item.keyEquivalentModifierMask = shortcut.cocoaModifiers
        return item
    }

    private func updateMenuShortcuts() {
        pinFrontmostWindowItem?.keyEquivalent = shortcutSettings.pinFrontmostWindow.keyEquivalent
        pinFrontmostWindowItem?.keyEquivalentModifierMask = shortcutSettings.pinFrontmostWindow.cocoaModifiers
        pinScreenSelectionItem?.keyEquivalent = shortcutSettings.pinScreenSelection.keyEquivalent
        pinScreenSelectionItem?.keyEquivalentModifierMask = shortcutSettings.pinScreenSelection.cocoaModifiers
    }

    private func registerHotKeys() {
        let didRegister = hotKeyManager.register(settings: shortcutSettings, callbacks: [
            .pinFrontmostWindow: { [weak self] in self?.pinFrontmostWindowSnapshot() },
            .pinScreenSelection: { [weak self] in self?.pinScreenSelection() }
        ])

        if !didRegister {
            showAlert(
                title: "Shortcut conflict",
                message: "PinTop could not register one of the selected global shortcuts. Choose another combination in Customize Shortcuts."
            )
        }
    }

    @objc private func customizeShortcuts() {
        shortcutSettingsWindowController = ShortcutSettingsWindowController(settings: shortcutSettings) { [weak self] settings in
            guard let self else { return }
            shortcutSettings = settings
            ShortcutStore.save(settings)
            updateMenuShortcuts()
            registerHotKeys()
        }
        shortcutSettingsWindowController?.showWindow(nil)
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        updateTargetApplication(app)
    }

    private func updateTargetApplication(_ application: NSRunningApplication?) {
        guard
            let application,
            application.processIdentifier != getpid(),
            application.activationPolicy == .regular
        else {
            return
        }
        lastTargetApplication = application
    }

    @objc private func pinFrontmostWindowSnapshot() {
        guard hasScreenCaptureAccess() else {
            showScreenCapturePermissionRequired()
            return
        }

        guard let application = lastTargetApplication else {
            showAlert(
                title: "No target window",
                message: "Activate the window you want to pin, then choose Pin Frontmost Window Snapshot from the menu bar."
            )
            return
        }

        guard let captured = WindowCapture.captureFrontWindow(for: application.processIdentifier) else {
            showAlert(
                title: "Could not capture window",
                message: "PinTop could not find a visible normal window for \(application.localizedName ?? "the selected app"). Screen Recording permission may need a relaunch after being granted."
            )
            return
        }

        showPinnedPanel(for: captured)
    }

    @objc private func pinScreenSelection() {
        guard hasScreenCaptureAccess() else {
            showScreenCapturePermissionRequired()
            return
        }

        selectionCoordinator.begin { [weak self] selection in
            guard let self else { return }
            guard let captured = WindowCapture.captureScreenSelection(selection) else {
                self.showAlert(
                    title: "Could not capture selection",
                    message: "PinTop could not capture that area. Try a larger selection or relaunch the app after granting Screen Recording permission."
                )
                return
            }
            self.showPinnedPanel(for: captured)
        }
    }

    @objc private func registerScreenRecordingPermission() {
        if CGPreflightScreenCaptureAccess() {
            showAlert(title: "Permission already granted", message: "PinTop already has Screen Recording permission.")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            _ = CGRequestScreenCaptureAccess()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !CGPreflightScreenCaptureAccess() {
                    self?.openScreenRecordingSettingsWithoutPreflight()
                }
            }
        }
    }

    @objc private func openScreenRecordingSettings() {
        if CGPreflightScreenCaptureAccess() {
            showAlert(title: "Permission already granted", message: "PinTop already has Screen Recording permission.")
            return
        }

        openScreenRecordingSettingsWithoutPreflight()
    }

    private func openScreenRecordingSettingsWithoutPreflight() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealPinTopApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func closeAllPinnedSnapshots() {
        let panels = pinnedPanels
        pinnedPanels.removeAll()
        panels.forEach { $0.close() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showPinnedPanel(for captured: CapturedImage) {
        let panelController = PinnedPanelController(captured: captured)
        panelController.onClose = { [weak self] controller in
            self?.pinnedPanels.removeAll { $0 === controller }
        }
        pinnedPanels.append(panelController)
        panelController.showWindow(nil)
    }

    private func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func showScreenCapturePermissionRequired() {
        showAlert(
            title: "Screen Recording permission needed",
            message: "Turn on Screen Recording for PinTop in System Settings, then quit and relaunch PinTop. If PinTop is already listed, make sure its switch is enabled."
        )
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private let application = NSApplication.shared
private let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
