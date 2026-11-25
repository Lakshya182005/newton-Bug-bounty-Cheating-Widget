import Cocoa
import CoreAudio
import CoreGraphics
import Darwin

// MARK: - Constants & IPC

private enum DefaultsKey {
    static let text = "widget.text"
    static let opacity = "widget.opacity"
    static let frame = "widget.frame"
}

private enum IPC {
    static let relaunchNotification = Notification.Name("com.local.PinnedTextWidget.relaunchRequest")
    static let darwinScreencaptureInvoke = "com.apple.screencapture.invoke" as CFString
    static let darwinScreencaptureInteractive = "com.apple.screencapture.interactive" as CFString
    static let watcherLockPath = "/tmp/PinnedTextWidget.watcher.lock"
    static let uiLockPath = "/tmp/PinnedTextWidget.ui.lock"
    static let screenshotProcessNames: Set<String> = ["screencapture", "screencaptureui", "Screenshot", "Grab"]
    static let screenshotBundleIDs: Set<String> = [
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher",
        "com.apple.Grab"
    ]
    // Keycodes for 3, 4, 5, 6 on US ANSI keyboard
    static let screenshotKeyCodes: Set<Int64> = [20, 21, 23, 22]
    static let f10KeyCode: Int64 = 109
    static let nxKeyTypeMute = 7
    static let nxSysDefinedRaw: UInt32 = 14
}

// MARK: - File Lock Helper

private func tryAcquireExclusiveLock(at path: String) -> Int32? {
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return nil }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        return fd
    }
    close(fd)
    return nil
}

private func isLockFree(at path: String) -> Bool {
    guard let fd = tryAcquireExclusiveLock(at: path) else { return false }
    flock(fd, LOCK_UN)
    close(fd)
    return true
}

// MARK: - Process Inspection Helper

private func isScreenshotProcessRunning() -> Bool {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return false }
    var pids = [pid_t](repeating: 0, count: Int(count) + 32)
    let actualBytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard actualBytes > 0 else { return false }
    let actualCount = Int(actualBytes) / MemoryLayout<pid_t>.size
    var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))

    for i in 0..<actualCount {
        let pid = pids[i]
        guard pid > 0 else { continue }
        let len = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if len > 0 {
            let name = String(cString: nameBuffer)
            if IPC.screenshotProcessNames.contains(name) {
                return true
            }
        }
    }
    return false
}

// MARK: - Top-Most Non-Closable Panel

final class PinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        // Closing is intentionally disabled.
    }

    override func cancelOperation(_ sender: Any?) {
        // Prevent Escape from closing or hiding the panel.
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            if ["w", "q", "h", "m"].contains(chars) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performClose(_:)) || item.action == #selector(NSApplication.terminate(_:)) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }
}

// MARK: - Editable TextView with Standard Shortcuts (No Close/Quit)

final class WidgetTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "w", "q", "h", "m":
                return true
            case "a":
                selectAll(nil)
                return true
            case "c":
                copy(nil)
                return true
            case "v":
                paste(nil)
                return true
            case "x":
                cut(nil)
                return true
            case "z":
                if flags.contains(.shift) {
                    undoManager?.redo()
                } else {
                    undoManager?.undo()
                }
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Draggable Header View

final class DraggableHeaderView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Resize Grip Indicator

final class ResizeGripView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.32).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.2
        for offset in stride(from: 4.0, through: 10.0, by: 3.0) {
            path.move(to: NSPoint(x: bounds.maxX - offset, y: 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: offset))
        }
        path.stroke()
    }
}

// MARK: - Listen-Only Event Tap Helper

final class ListenOnlyEventMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onKeyDown: (Int64, CGEventFlags) -> Void
    private let onSystemDefined: (NSEvent) -> Void

    init(
        onKeyDown: @escaping (Int64, CGEventFlags) -> Void,
        onSystemDefined: @escaping (NSEvent) -> Void
    ) {
        self.onKeyDown = onKeyDown
        self.onSystemDefined = onSystemDefined
    }

    @discardableResult
    func start() -> Bool {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << IPC.nxSysDefinedRaw))
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ListenOnlyEventMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                if type == .keyDown {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags
                    monitor.onKeyDown(keyCode, flags)
                } else if type.rawValue == IPC.nxSysDefinedRaw {
                    if let nsEvent = NSEvent(cgEvent: event) {
                        monitor.onSystemDefined(nsEvent)
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
    }
}

// MARK: - CoreAudio Mute Observer (Zero-Permission Backup for F10 Mute)

final class CoreAudioMuteObserver {
    private var currentDeviceID: AudioDeviceID = 0
    private var lastKnownMute: UInt32?
    private var deviceChangeBlock: AudioObjectPropertyListenerBlock?
    private var muteChangeBlock: AudioObjectPropertyListenerBlock?
    private let onMuteToggled: () -> Void

    init(onMuteToggled: @escaping () -> Void) {
        self.onMuteToggled = onMuteToggled
    }

    func start() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.attachToDefaultOutputDevice()
            }
        }
        deviceChangeBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        attachToDefaultOutputDevice()
    }

    private func attachToDefaultOutputDevice() {
        detachFromCurrentDevice()

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return }

        currentDeviceID = deviceID
        lastKnownMute = readMuteState(deviceID: deviceID)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let newMute = self.readMuteState(deviceID: self.currentDeviceID)
            if let newMute, newMute != self.lastKnownMute {
                self.lastKnownMute = newMute
                DispatchQueue.main.async {
                    self.onMuteToggled()
                }
            }
        }
        muteChangeBlock = block
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, DispatchQueue.main, block)
    }

    private func detachFromCurrentDevice() {
        guard currentDeviceID != 0, let muteChangeBlock else { return }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(currentDeviceID, &muteAddr, DispatchQueue.main, muteChangeBlock)
        self.muteChangeBlock = nil
        currentDeviceID = 0
        lastKnownMute = nil
    }

    private func readMuteState(deviceID: AudioDeviceID) -> UInt32? {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted)
        return err == noErr ? muted : nil
    }
}

// MARK: - Background Watcher Mode (Listens for Mute F10 to Relaunch)

final class WatcherRunner {
    private let lockFD: Int32
    private var tapMonitor: ListenOnlyEventMonitor?
    private var coreAudioObserver: CoreAudioMuteObserver?
    private var lastTriggerTime: TimeInterval = 0
    private var relaunchInFlight = false

    init(lockFD: Int32) {
        self.lockFD = lockFD
    }

    func run() -> Never {
        tapMonitor = ListenOnlyEventMonitor(
            onKeyDown: { [weak self] keyCode, flags in
                let disallowed: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
                if keyCode == IPC.f10KeyCode && flags.intersection(disallowed).isEmpty {
                    DispatchQueue.main.async {
                        self?.handleMutePressed()
                    }
                }
            },
            onSystemDefined: { [weak self] event in
                guard event.subtype.rawValue == 8 else { return }
                let data1 = event.data1
                let keyCode = (data1 & 0xFFFF0000) >> 16
                let keyFlags = data1 & 0x0000FFFF
                let keyState = (keyFlags & 0xFF00) >> 8
                if keyCode == IPC.nxKeyTypeMute && keyState == 0x0A {
                    DispatchQueue.main.async {
                        self?.handleMutePressed()
                    }
                }
            }
        )
        _ = tapMonitor?.start()

        // CoreAudio mute listener acts as a zero-TCC-permission detector for F10 Mute.
        coreAudioObserver = CoreAudioMuteObserver { [weak self] in
            self?.handleMutePressed()
        }
        coreAudioObserver?.start()

        CFRunLoopRun()
        exit(0)
    }

    private func handleMutePressed() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerTime > 0.45 else { return }
        lastTriggerTime = now
        guard !relaunchInFlight else { return }
        relaunchInFlight = true

        // Ask any running UI instance to exit so it cleanly relaunches.
        DistributedNotificationCenter.default().postNotificationName(
            IPC.relaunchNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        waitForUIToExitAndLaunch(attemptsRemaining: 40)
    }

    private func waitForUIToExitAndLaunch(attemptsRemaining: Int) {
        if isLockFree(at: IPC.uiLockPath) || attemptsRemaining <= 0 {
            launchWidgetApp()
            relaunchInFlight = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.waitForUIToExitAndLaunch(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func launchWidgetApp() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
    }
}

// MARK: - App Delegate (UI Widget Mode)

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var panel: PinnedPanel!
    private var textView: WidgetTextView!
    private var opacitySlider: NSSlider!
    private var opacityLabel: NSTextField!
    private var enforceTimer: Timer?
    private var screenshotPollTimer: Timer?
    private var tapMonitor: ListenOnlyEventMonitor?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var allowForceClose = false
    private var isHiddenForScreenshot = false
    private var hideUntilUptime: TimeInterval = 0
    private var wasScreenshotProcessActive = false
    private var uiLockFD: Int32?

    private static var highestWindowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        uiLockFD = tryAcquireExclusiveLock(at: IPC.uiLockPath)
        ensureWatcherRunning()

        NSApp.setActivationPolicy(.accessory)
        setupMinimalEditMenu()
        setupPanel()
        observeSystemEvents()
        startScreenshotMonitors()
        startHierarchyEnforcement()
        enforceTopHierarchy()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return allowForceClose ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
        if let fd = uiLockFD {
            flock(fd, LOCK_UN)
            close(fd)
            uiLockFD = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return false
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    func textDidChange(_ notification: Notification) {
        UserDefaults.standard.set(textView.string, forKey: DefaultsKey.text)
    }

    // MARK: - Watcher Lifecycle

    private func ensureWatcherRunning() {
        guard let execPath = Bundle.main.executablePath else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: execPath)
        task.arguments = ["--watcher"]
        try? task.run()
    }

    // MARK: - Setup

    private func setupMinimalEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupPanel() {
        let initialFrame = loadInitialFrame()
        let savedOpacity = loadInitialOpacity()

        panel = PinnedPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.level = Self.highestWindowLevel
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        // Exclude from WindowServer captures so 0ms screenshots never catch the widget.
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 220, height: 140)
        panel.alphaValue = savedOpacity

        let container = NSView(frame: NSRect(origin: .zero, size: initialFrame.size))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.88).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        container.layer?.masksToBounds = true

        let header = DraggableHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor

        let titleLabel = NSTextField(labelWithString: "Pinned Note")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.72)

        opacityLabel = NSTextField(labelWithString: "\(Int(round(savedOpacity * 100)))%")
        opacityLabel.translatesAutoresizingMaskIntoConstraints = false
        opacityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        opacityLabel.alignment = .right

        opacitySlider = NSSlider(
            value: Double(savedOpacity),
            minValue: 0.15,
            maxValue: 1.0,
            target: self,
            action: #selector(opacityChanged(_:))
        )
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.controlSize = .mini
        opacitySlider.isContinuous = true
        opacitySlider.toolTip = "Transparency"

        header.addSubview(titleLabel)
        header.addSubview(opacitySlider)
        header.addSubview(opacityLabel)

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = NSColor.white.withAlphaComponent(0.12)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        textView = WidgetTextView()
        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.95)
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = UserDefaults.standard.string(forKey: DefaultsKey.text)
            ?? "Pinned widget — always on top.\nEdit this text freely, drag the top bar to move, or adjust opacity above."

        scrollView.documentView = textView

        let resizeGrip = ResizeGripView()
        resizeGrip.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(divider)
        container.addSubview(scrollView)
        container.addSubview(resizeGrip)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            opacityLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            opacityLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            opacityLabel.widthAnchor.constraint(equalToConstant: 36),

            opacitySlider.trailingAnchor.constraint(equalTo: opacityLabel.leadingAnchor, constant: -6),
            opacitySlider.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            opacitySlider.widthAnchor.constraint(equalToConstant: 78),
            opacitySlider.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            resizeGrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resizeGrip.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            resizeGrip.widthAnchor.constraint(equalToConstant: 14),
            resizeGrip.heightAnchor.constraint(equalToConstant: 14)
        ])

        panel.contentView = container
        panel.orderFrontRegardless()
    }

    // MARK: - Screenshot Detection & Temporary Hide (No Closing)

    private func startScreenshotMonitors() {
        // 1. Listen-only CGEventTap for immediate Cmd+Shift+3/4/5/6 shortcut detection
        tapMonitor = ListenOnlyEventMonitor(
            onKeyDown: { [weak self] keyCode, flags in
                if flags.contains([.maskCommand, .maskShift]) && IPC.screenshotKeyCodes.contains(keyCode) {
                    DispatchQueue.main.async {
                        self?.hideTemporarilyForScreenshot(graceSeconds: 1.4)
                    }
                }
            },
            onSystemDefined: { _ in }
        )

        if tapMonitor?.start() != true {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains([.command, .shift]) && IPC.screenshotKeyCodes.contains(Int64(event.keyCode)) {
                    self?.hideTemporarilyForScreenshot(graceSeconds: 1.4)
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains([.command, .shift]) && IPC.screenshotKeyCodes.contains(Int64(event.keyCode)) {
                self?.hideTemporarilyForScreenshot(graceSeconds: 1.4)
                return event
            }
            return event
        }

        // 2. Darwin notifications posted by Apple screencapture tools
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.hideTemporarilyForScreenshot(graceSeconds: 1.2)
            }
        }
        CFNotificationCenterAddObserver(
            darwinCenter,
            observer,
            callback,
            IPC.darwinScreencaptureInvoke,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            darwinCenter,
            observer,
            callback,
            IPC.darwinScreencaptureInteractive,
            nil,
            .deliverImmediately
        )

        // 3. Process poll for CLI `screencapture`, `screencaptureui`, `Screenshot`, or `Grab`
        screenshotPollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateScreenshotVisibilityState()
        }
        if let screenshotPollTimer {
            RunLoop.main.add(screenshotPollTimer, forMode: .common)
        }
    }

    private func hideTemporarilyForScreenshot(graceSeconds: TimeInterval) {
        let targetUntil = ProcessInfo.processInfo.systemUptime + graceSeconds
        if targetUntil > hideUntilUptime {
            hideUntilUptime = targetUntil
        }
        if !isHiddenForScreenshot {
            isHiddenForScreenshot = true
            panel?.orderOut(nil)
        }
    }

    private func updateScreenshotVisibilityState() {
        guard !allowForceClose else { return }
        let procActive = isScreenshotProcessRunning()
        if procActive {
            wasScreenshotProcessActive = true
            hideTemporarilyForScreenshot(graceSeconds: 0.35)
            return
        }

        if wasScreenshotProcessActive {
            wasScreenshotProcessActive = false
            hideUntilUptime = max(hideUntilUptime, ProcessInfo.processInfo.systemUptime + 0.35)
        }

        if isHiddenForScreenshot && ProcessInfo.processInfo.systemUptime >= hideUntilUptime {
            isHiddenForScreenshot = false
            enforceTopHierarchy()
        }
    }

    private func terminateForRelaunch() {
        guard !allowForceClose else { return }
        allowForceClose = true
        UserDefaults.standard.set(textView.string, forKey: DefaultsKey.text)
        saveFrame()
        panel?.orderOut(nil)
        if let fd = uiLockFD {
            flock(fd, LOCK_UN)
            close(fd)
            uiLockFD = nil
        }
        NSApp.terminate(nil)
    }

    // MARK: - Actions & Hierarchy Enforcement

    @objc private func opacityChanged(_ sender: NSSlider) {
        let value = CGFloat(min(max(sender.doubleValue, 0.15), 1.0))
        panel.alphaValue = value
        opacityLabel.stringValue = "\(Int(round(value * 100)))%"
        UserDefaults.standard.set(Double(value), forKey: DefaultsKey.opacity)
    }

    private func observeSystemEvents() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            self,
            selector: #selector(handleEnvironmentChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(handleEnvironmentChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(handleSystemPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(handleAppLaunch(_:)),
            name: NSWorkspace.willLaunchApplicationNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(handleAppLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnvironmentChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleRelaunchRequest),
            name: IPC.relaunchNotification,
            object: nil
        )
    }

    @objc private func handleAppLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        if let bundleID = app.bundleIdentifier, IPC.screenshotBundleIDs.contains(bundleID) {
            hideTemporarilyForScreenshot(graceSeconds: 1.0)
        } else if let name = app.localizedName, IPC.screenshotProcessNames.contains(name) {
            hideTemporarilyForScreenshot(graceSeconds: 1.0)
        }
    }

    @objc private func handleRelaunchRequest() {
        terminateForRelaunch()
    }

    private func startHierarchyEnforcement() {
        enforceTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.enforceTopHierarchy()
        }
        if let enforceTimer {
            RunLoop.main.add(enforceTimer, forMode: .common)
        }
    }

    @objc private func handleEnvironmentChange() {
        enforceTopHierarchy()
    }

    @objc private func handleSystemPowerOff() {
        allowForceClose = true
    }

    private func enforceTopHierarchy() {
        guard !allowForceClose, !isHiddenForScreenshot, let panel else { return }
        let targetLevel = Self.highestWindowLevel
        if panel.level != targetLevel {
            panel.level = targetLevel
        }
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.orderFrontRegardless()
    }

    // MARK: - Persistence Helpers

    private func loadInitialOpacity() -> CGFloat {
        if UserDefaults.standard.object(forKey: DefaultsKey.opacity) != nil {
            let stored = UserDefaults.standard.double(forKey: DefaultsKey.opacity)
            return CGFloat(min(max(stored, 0.15), 1.0))
        }
        return 0.9
    }

    private func loadInitialFrame() -> NSRect {
        if let stored = UserDefaults.standard.string(forKey: DefaultsKey.frame) {
            let rect = NSRectFromString(stored)
            if rect.width >= 220 && rect.height >= 140 {
                return rect
            }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width: CGFloat = 320
        let height: CGFloat = 210
        return NSRect(
            x: visible.maxX - width - 24,
            y: visible.maxY - height - 24,
            width: width,
            height: height
        )
    }

    private func saveFrame() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: DefaultsKey.frame)
    }
}

// MARK: - Entry Point

if CommandLine.arguments.contains("--watcher") {
    guard let watcherLockFD = tryAcquireExclusiveLock(at: IPC.watcherLockPath) else {
        exit(0)
    }
    let watcher = WatcherRunner(lockFD: watcherLockFD)
    watcher.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
