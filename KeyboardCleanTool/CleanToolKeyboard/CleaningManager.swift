import Cocoa
import SwiftUI
import Combine
import IOKit.graphics
import IOKit.hid

class CleaningManager: ObservableObject {
    static weak var shared: CleaningManager?

    @Published var isCleaning = false
    @Published var isExiting = false
    @Published var exitProgress: Double = 0

    fileprivate var eventTap: CFMachPort?
    private var overlayWindows: [NSWindow] = []
    private var runLoopSource: CFRunLoopSource?
    private var exitStartTime: Date?
    private var exitTimer: Timer?
    private var savedBrightness: Float = 1.0
    private var hidTrackpadManager: IOHIDManager?
    private var hidKeyboardManager: IOHIDManager?

    init() {
        CleaningManager.shared = self
    }

    // MARK: - Public

    func startCleaning() {
        guard !isCleaning else { return }

        if !checkAccessibilityPermission() {
            requestAccessibilityPermission()
            return
        }

        isCleaning = true
        isExiting = false
        exitProgress = 0

        savedBrightness = getBrightness()
        setBrightness(0.0)

        showOverlay()
        seizeInputDevices()
        setupEventTap()
    }

    func stopCleaning() {
        exitTimer?.invalidate()
        exitTimer = nil
        exitStartTime = nil

        removeEventTap()
        releaseInputDevices()
        hideOverlay()

        setBrightness(savedBrightness)

        isCleaning = false
        isExiting = false
        exitProgress = 0

        // Bring main window to front
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Brightness Control (CoreDisplay private API)

    // CoreDisplay private functions for brightness control
    // These work on modern macOS where IODisplaySetFloatParameter is deprecated/broken
    @objc private class CoreDisplayBridge: NSObject {
        static let displayServicesHandle: UnsafeMutableRawPointer? = {
            dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW)
        }()

        typealias GetBrightnessFunc = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        typealias SetBrightnessFunc = @convention(c) (UInt32, Float) -> Int32

        static var getBrightnessFunc: GetBrightnessFunc? = {
            guard let handle = displayServicesHandle else { return nil }
            guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
            return unsafeBitCast(sym, to: GetBrightnessFunc.self)
        }()

        static var setBrightnessFunc: SetBrightnessFunc? = {
            guard let handle = displayServicesHandle else { return nil }
            guard let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
            return unsafeBitCast(sym, to: SetBrightnessFunc.self)
        }()
    }

    private func getMainDisplayID() -> UInt32 {
        return CGMainDisplayID()
    }

    private func getBrightness() -> Float {
        var brightness: Float = 1.0
        let displayID = getMainDisplayID()
        if let getFunc = CoreDisplayBridge.getBrightnessFunc {
            let result = getFunc(displayID, &brightness)
            if result == 0 {
                return brightness
            }
        }
        // Fallback: IOKit
        var iterator: io_iterator_t = 0
        let res = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator)
        guard res == kIOReturnSuccess else { return brightness }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var val: Float = 0
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &val) == kIOReturnSuccess {
                brightness = val
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return brightness
    }

    private func setBrightness(_ value: Float) {
        let displayID = getMainDisplayID()
        if let setFunc = CoreDisplayBridge.setBrightnessFunc {
            let result = setFunc(displayID, value)
            if result == 0 {
                return
            }
        }
        // Fallback: IOKit
        var iterator: io_iterator_t = 0
        let res = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator)
        guard res == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, value)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    // MARK: - Accessibility Permission

    private func checkAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        let alert = NSAlert()
        alert.messageText = "Permission Required"
        alert.informativeText = "To block the keyboard and trackpad, you need to grant Accessibility permission in System Settings.\n\nAfter granting permission, press the button again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Overlay Windows

    private func showOverlay() {
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            window.isOpaque = true
            window.backgroundColor = .black
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true
            window.ignoresMouseEvents = false
            window.hasShadow = false

            let overlayView = CleaningOverlayView(manager: self)
            window.contentView = NSHostingView(rootView: overlayView)

            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }

        NSCursor.hide()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideOverlay() {
        NSCursor.unhide()
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    // MARK: - HID Device Seize (Trackpad + Keyboard)

    private func seizeInputDevices() {
        // --- Seize Trackpad ---
        let trackpadMgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let touchPadMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer,
            kIOHIDDeviceUsageKey: kHIDUsage_Dig_TouchPad
        ]
        let pointerMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer
        ]
        let mouseMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
        ]

        IOHIDManagerSetDeviceMatchingMultiple(trackpadMgr, [touchPadMatch, pointerMatch, mouseMatch] as CFArray)
        IOHIDManagerScheduleWithRunLoop(trackpadMgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let trackpadResult = IOHIDManagerOpen(trackpadMgr, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if trackpadResult == kIOReturnSuccess {
            hidTrackpadManager = trackpadMgr
            print("✅ Trackpad seized")
        } else {
            print("⚠️ Failed to seize trackpad (code: \(trackpadResult))")
        }

        // --- Seize Keyboard (blocks media/function keys at driver level) ---
        let keyboardMgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let keyboardMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ]
        let keypadMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad
        ]
        let consumerMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_Consumer,
            kIOHIDDeviceUsageKey: 1  // Consumer Control (media keys)
        ]

        IOHIDManagerSetDeviceMatchingMultiple(keyboardMgr, [keyboardMatch, keypadMatch, consumerMatch] as CFArray)
        IOHIDManagerScheduleWithRunLoop(keyboardMgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // Register input callback to detect Command keys for exit while keyboard is seized
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(keyboardMgr, hidKeyboardCallback, context)

        let kbResult = IOHIDManagerOpen(keyboardMgr, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if kbResult == kIOReturnSuccess {
            hidKeyboardManager = keyboardMgr
            print("✅ Keyboard seized — media/fn keys blocked")
        } else {
            print("⚠️ Failed to seize keyboard (code: \(kbResult))")
        }
    }

    private func releaseInputDevices() {
        if let manager = hidTrackpadManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            hidTrackpadManager = nil
        }
        if let manager = hidKeyboardManager {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            hidKeyboardManager = nil
        }
        print("✅ Input devices released")
    }

    // Track Command key state from HID callback
    fileprivate var leftCmdDown = false
    fileprivate var rightCmdDown = false

    fileprivate func handleHIDKeyboard(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) != 0

        // Keyboard usage page: Left GUI (Command) = 0xE3, Right GUI (Command) = 0xE7
        if usagePage == kHIDPage_KeyboardOrKeypad {
            if usage == 0xE3 { // Left Command
                leftCmdDown = pressed
            } else if usage == 0xE7 { // Right Command
                rightCmdDown = pressed
            }

            let bothPressed = leftCmdDown && rightCmdDown
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isCleaning else { return }
                if bothPressed && !self.isExiting {
                    self.startExitSequence()
                } else if !bothPressed && self.isExiting {
                    self.cancelExitSequence()
                }
            }
        }
    }

    // MARK: - Event Tap

    private func setupEventTap() {
        // Intercept all event types including media keys (NX_SYSDEFINED = 14) and gestures
        var eventMask: CGEventMask = 0
        eventMask |= (1 << CGEventType.keyDown.rawValue)
        eventMask |= (1 << CGEventType.keyUp.rawValue)
        eventMask |= (1 << CGEventType.flagsChanged.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDown.rawValue)
        eventMask |= (1 << CGEventType.leftMouseUp.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDown.rawValue)
        eventMask |= (1 << CGEventType.rightMouseUp.rawValue)
        eventMask |= (1 << CGEventType.mouseMoved.rawValue)
        eventMask |= (1 << CGEventType.leftMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.rightMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.scrollWheel.rawValue)
        eventMask |= (1 << CGEventType.tabletPointer.rawValue)
        eventMask |= (1 << CGEventType.tabletProximity.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDown.rawValue)
        eventMask |= (1 << CGEventType.otherMouseUp.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDragged.rawValue)
        eventMask |= (1 << 14)  // NX_SYSDEFINED — media keys (brightness, volume, etc.)
        eventMask |= (1 << 18)  // rotate
        eventMask |= (1 << 29)  // gesture
        eventMask |= (1 << 30)  // magnify
        eventMask |= (1 << 31)  // swipe
        eventMask |= (1 << 32)  // smartMagnify
        eventMask |= (1 << 34)  // pressure
        eventMask |= (1 << 37)  // directTouch

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: context
        ) else {
            print("❌ Failed to create event tap. Check Accessibility permissions.")
            stopCleaning()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Exit Sequence

    fileprivate func startExitSequence() {
        isExiting = true
        exitProgress = 0
        exitStartTime = Date()

        exitTimer?.invalidate()
        exitTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.exitStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.exitProgress = min(elapsed / 3.0, 1.0)

            if elapsed >= 3.0 {
                self.stopCleaning()
            }
        }
    }

    fileprivate func cancelExitSequence() {
        isExiting = false
        exitProgress = 0
        exitStartTime = nil
        exitTimer?.invalidate()
        exitTimer = nil
    }
}

// MARK: - HID Keyboard Callback (detects Command keys while keyboard is seized)

private func hidKeyboardCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context = context else { return }
    let manager = Unmanaged<CleaningManager>.fromOpaque(context).takeUnretainedValue()
    manager.handleHIDKeyboard(value: value)
}

// MARK: - C Event Tap Callback (fallback for any events not caught by HID seize)

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Re-enable tap if the system disabled it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = CleaningManager.shared?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    // Detect both Command keys (Left ⌘ + Right ⌘) to exit cleaning mode.
    // NX_DEVICELCMDKEYMASK = 0x08, NX_DEVICERCMDKEYMASK = 0x10
    // These device-dependent flag bits distinguish left vs right Command.
    if type == .flagsChanged || type == .keyDown || type == .keyUp {
        let rawFlags = event.flags.rawValue
        let leftCmd  = (rawFlags & 0x08) != 0
        let rightCmd = (rawFlags & 0x10) != 0
        let bothPressed = leftCmd && rightCmd

        DispatchQueue.main.async {
            guard let manager = CleaningManager.shared, manager.isCleaning else { return }
            if bothPressed && !manager.isExiting {
                manager.startExitSequence()
            } else if !bothPressed && manager.isExiting {
                manager.cancelExitSequence()
            }
        }
    }

    // Suppress ALL events (keyboard, trackpad, mouse, media keys)
    return nil
}
