import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import SwiftUI

/// `SleepLess --e2e <dir>` (run it from test-e2e.sh): every user-facing function, driven the way a user reaches it —
/// the status item's click handler, the quick menu's items, the panel's controls through their accessibility
/// elements (what a click or a screen reader presses), sleepless:// links through the app delegate, reopening — on a copy
/// with its own bundle id and settings domain, and the Mac behind FakeHardware (Hardware.swift). Every step asserts
/// what came of it: settings, labels, the fake's log, and this process's own sleep assertions read back from IOKit.
/// Prints a table (one row per function, also <dir>/report.txt) and exits 0 only when every row passed.
@MainActor enum E2E {
    static let bundleID = "io.github.cyborgfingers.sleepless.e2e"
    private(set) static var hardware: FakeHardware?
    static var out = URL(fileURLWithPath: "/tmp")
    static var quitAllowed = false
    static var quitAsked = 0

    /// Quit (the menu's, the panel's) is counted, not obeyed, until the run's own last step.
    static func mayQuit() -> Bool {
        guard hardware != nil, !quitAllowed else { return true }
        quitAsked += 1
        return false
    }

    /// Before the app delegate runs: refuses anything but the e2e copy, wipes its settings domain and seeds it as an
    /// upgrade from 1.2.1 that crashed with the lid shut, stubs the network and builds the fake Mac.
    static func prepare(dir: String) {
        guard Bundle.main.bundleIdentifier == bundleID, !Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            print("E2E: run this from a copy with the e2e bundle id, outside /Applications (test-e2e.sh)")
            exit(2)
        }
        out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSTimeZone.default = TimeZone(identifier: "Pacific/Auckland")!   // 27 Sep 2026 02:00 springs forward
        let d = UserDefaults.standard
        d.removePersistentDomain(forName: bundleID)
        d.set(Data(#"{"screenOn":false,"dims":false,"level":0.35,"delay":120,"lidOn":false,"onlyWhileCharging":false,"pauseWhenHot":true,"batteryCutoff":30,"autoWhenCharging":true,"offAfter":0}"#.utf8), forKey: "settings")
        d.set(try? JSONEncoder().encode(LidDark(screen: 0.6, keyboard: .init(brightness: 0.4, auto: false))), forKey: "lidDark")
        UpdateFeedStub.install()
        let fake = FakeHardware()
        fake.ready = false          // an app update changed the helper: the signed self-update is asked for…
        fake.updateSucceeds = false // …and fails, so the setup card has to do it
        hardware = fake
    }

    // MARK: - Rows

    private struct Row { var function: String; var how: String; var result: String }
    private static var rows: [Row] = []

    static func check(_ function: String, _ how: String, _ ok: Bool, _ why: @autoclosure () -> String = "") {
        rows.append(Row(function: function, how: how, result: ok ? "pass" : "FAIL: \(why())"))
        print(ok ? "pass  \(function)" : "FAIL  \(function) — \(why())")
        fflush(stdout)
    }
    static func skip(_ function: String, _ why: String) { rows.append(Row(function: function, how: "—", result: "not exercised: \(why)")) }

    static func settle(_ seconds: TimeInterval = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func until(_ seconds: TimeInterval = 3, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { settle(0.05) }
        return done()
    }

    // MARK: - The Mac, as this process sees it

    static let both: Set<String> = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep"]
    static let systemOnly: Set<String> = ["PreventUserIdleSystemSleep"]

    /// This process's sleep assertions, read back from IOKit.
    static func held() -> Set<String> {
        var byPID: Unmanaged<CFDictionary>?
        IOPMCopyAssertionsByProcess(&byPID)
        let all = byPID?.takeRetainedValue() as? [Int: [[String: Any]]] ?? [:]
        return Set((all[Int(getpid())] ?? []).compactMap { $0["AssertType"] as? String })
    }

    /// Whether a hot key is registered in this process right now: a second registration of it is refused.
    static func registered(_ key: HotKey) -> Bool {
        var ref: EventHotKeyRef?
        let rc = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: OSType(0x4532_4520), id: 9), GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return rc == OSStatus(eventHotKeyExistsErr)
    }

    /// The hot-key-pressed event Carbon sends when the combination is typed anywhere, delivered to this app only.
    static func fireHotKey() {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event)
        var id = EventHotKeyID(signature: OSType(0x534C_5353), id: 1)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
        SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)
        settle()
    }

    /// A key press inside this app (the shortcut recorder and Esc listen with local monitors).
    static func keyDown(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(e)
        settle()
    }
    static let hyper: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    // MARK: - The panel, through its accessibility elements

    static var host: NSHostingView<AnyView>!
    static var window: NSWindow?
    static var opened: [URL] = []   // links the panel asked to open (intercepted: no browser)

    /// SwiftUI's nodes answer the accessibility methods without formally adopting the protocol, so: KVC.
    static func ax(_ o: NSObject, _ key: String) -> Any? { o.responds(to: Selector(key)) ? o.value(forKey: key) : nil }
    static func elements(under root: NSObject) -> [NSObject] {
        [root] + (ax(root, "accessibilityChildren") as? [NSObject] ?? []).flatMap { elements(under: $0) }
    }
    /// What a screen reader reads first: the label, or a static text's value.
    static func label(_ e: NSObject) -> String {
        let text = ax(e, "accessibilityLabel") as? String ?? ""
        return text.isEmpty ? value(e) as? String ?? "" : text
    }
    static func value(_ e: NSObject) -> Any? { ax(e, "accessibilityValue") }

    /// The element with this role (any role for "") whose label is `name` (or starts with it).
    static func find(_ name: String, _ role: String, prefix: Bool = false, in root: NSView? = nil) -> NSObject? {
        let root = root ?? host!
        root.layoutSubtreeIfNeeded()
        return elements(under: root).first { e in
            (role.isEmpty || ax(e, "accessibilityRole") as? String == role) && (prefix ? label(e).hasPrefix(name) : label(e) == name)
        }
    }
    /// Any text on screen containing `text`.
    static func shows(_ text: String, in root: NSView? = nil) -> Bool {
        let root = root ?? host!
        root.layoutSubtreeIfNeeded()
        return elements(under: root).contains { label($0).contains(text) || (value($0) as? String)?.contains(text) == true }
    }
    static func isOn(_ name: String) -> Bool? { find(name, "AXCheckBox").flatMap { (value($0) as? NSNumber)?.boolValue } }
    static func enabled(_ name: String, _ role: String) -> Bool? { find(name, role).flatMap { ax($0, "isAccessibilityEnabled") as? Bool } }

    /// Presses the control a user would click. False when the panel has no such control.
    @discardableResult
    static func press(_ name: String, _ role: String = "AXButton", prefix: Bool = false, in root: NSView? = nil) -> Bool {
        guard let e = find(name, role, prefix: prefix, in: root) else { return false }
        let sel = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
        typealias Press = @convention(c) (NSObject, Selector) -> Bool
        let done = unsafeBitCast(e.method(for: sel), to: Press.self)(e, sel)
        settle()
        return done
    }
    static func toggle(_ name: String) -> Bool { press(name, "AXCheckBox") }
    /// A segment of a segmented control (its press reports false even when it selects, so the caller checks the state).
    static func segment(_ name: String) -> Bool { press(name, "AXRadioButton"); return find(name, "AXRadioButton") != nil }

    /// A slider dragged `fraction` of the way along: its value, then its action, as the drag does.
    @discardableResult
    static func slide(_ name: String, to fraction: Double) -> Bool {
        guard let slider = views(host).compactMap({ $0 as? NSSlider }).first(where: { $0.accessibilityLabel() == name }) else { return false }
        slider.doubleValue = slider.minValue + fraction * (slider.maxValue - slider.minValue)
        slider.sendAction(slider.action, to: slider.target)
        settle()
        return true
    }

    static func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }

    /// A pop-up menu's item chosen, as a click on it does.
    @discardableResult
    static func choose(_ item: String, in name: String) -> Bool {
        guard let menu = views(host).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == name })?.menu,
              let i = menu.items.firstIndex(where: { $0.title == item }) else { return false }
        menu.performActionForItem(at: i)
        settle()
        return true
    }
    /// Runs `open`, which pops `menu` up and tracks it: `pick` runs on it as tracking begins, then it is dismissed
    /// (from a timer inside the tracking loop, and in any case within 3 s — a test never leaves a menu up).
    static func whileTracking(_ menu: @escaping () -> NSMenu?, open: () -> Void, pick: @escaping (NSMenu) -> Void) {
        var picked = false
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                guard !picked, let tracked = note.object as? NSMenu else { return }
                picked = true
                pick(tracked)
            }
        }
        let closer = Timer(timeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { if picked { menu()?.cancelTracking() } } }
        let deadline = Timer(timeInterval: 3, repeats: false) { _ in MainActor.assumeIsolated { menu()?.cancelTracking() } }
        RunLoop.main.add(closer, forMode: .common)
        RunLoop.main.add(deadline, forMode: .common)
        open()
        settle(0.2)
        closer.invalidate()
        deadline.invalidate()
        NotificationCenter.default.removeObserver(token)
    }

    /// A pull-down (SwiftUI builds its items as it opens): opened for real, `pick` chooses from its items while it
    /// is up. Returns what `pick` returned.
    static func pullDown(_ name: String, _ pick: @escaping (NSMenu) -> String?) -> String? {
        guard let popup = views(host).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == name }) else { return nil }
        var chosen: String?
        whileTracking({ popup.menu }, open: { popup.performClick(nil) }) { chosen = pick($0) }
        return chosen
    }
    static func menuTitles(_ name: String) -> [String] {
        views(host).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == name }?.menu?.items.map(\.title) ?? []
    }

    /// A time field set to `minute` past midnight today, as its stepper does.
    @discardableResult
    static func pick(_ name: String, minute: Int) -> Bool {
        guard let picker = views(host).compactMap({ $0 as? NSDatePicker }).first(where: { $0.accessibilityLabel() == name }) else { return false }
        picker.dateValue = Clock.date(minute: minute)
        picker.sendAction(picker.action, to: picker.target)
        settle()
        return true
    }
    static var progressBar: Bool { host.layoutSubtreeIfNeeded(); return views(host).contains { $0 is NSProgressIndicator } }

    // MARK: - The run

    static var keeper: Keeper!
    static var status: StatusItemController!
    static var delegate: AppDelegate!
    static var hw: FakeHardware { hardware! }

    /// From applicationDidFinishLaunching: the steps run from a timer once launching is over.
    static func run(delegate: AppDelegate, keeper: Keeper, status: StatusItemController) {
        self.delegate = delegate
        self.keeper = keeper
        self.status = status
        let updatingAtLaunch = keeper.helperUpdating, lidWhileUpdating = keeper.s.lidOn
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in MainActor.assumeIsolated { steps(updatingAtLaunch: updatingAtLaunch, lidWhileUpdating: lidWhileUpdating) } }
        RunLoop.main.add(timer, forMode: .default)
    }

    static func steps(updatingAtLaunch: Bool, lidWhileUpdating: Bool) {
        launch(updatingAtLaunch: updatingAtLaunch, lidWhileUpdating: lidWhileUpdating)
        host = NSHostingView(rootView: AnyView(Panel(keeper: keeper).environment(\.openURL, OpenURLAction { opened.append($0); return .handled })))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 344, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
        settle(0.5)
        setup()
        statusItem()
        quickMenu()
        modes()
        lid()
        safety()
        timer()
        more()
        timing()
        automations()
        loginAndUpdates()
        urlScheme()
        reopen()
        persistence()
        quit()
    }

    static func finish() -> Never {
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        skip("Add app: Other… (the open panel)", "a system file dialog; the bundle it returns is covered above")
        skip("Update card: the licence link inside its text", "an accessibility press on a link inside Text stalls the run; it is checked to be there")
        skip("Automatic update check (10 s after launch, then daily)", "a timer in the shared updater; Check Now runs the same check against the stub")
        skip("A sleepless:// link that launches the app", "arrives before the Keeper exists (AppDelegate queues it); the copy is deliberately not registered for the scheme")
        skip("A click in another app closes the panel", "the global mouse monitor sees other apps' clicks only; the in-app click and resign-active paths are covered")
        skip("Set up… with the real administrator prompt", "installs the root helper — covered by test-helper.sh and test-pkg.sh")
        skip("The real screen, keyboard light, charging light, pmset, login item, notification permission", "never touched here: FakeHardware stands in")
        let width = rows.map(\.function.count).max() ?? 0, howWidth = rows.map(\.how.count).max() ?? 0
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
        var table = "| \(pad("Function", width)) | \(pad("Reached by", howWidth)) | Result |\n|\(String(repeating: "-", count: width + 2))|\(String(repeating: "-", count: howWidth + 2))|--------|\n"
        for r in rows { table += "| \(pad(r.function, width)) | \(pad(r.how, howWidth)) | \(r.result) |\n" }
        let failed = rows.filter { $0.result.hasPrefix("FAIL") }.count, skipped = rows.filter { $0.result.hasPrefix("not") }.count
        table += "\n\(rows.count - failed - skipped) passed, \(failed) failed, \(skipped) not exercised\n"
        print(table)
        try? table.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        exit(failed == 0 ? 0 : 1)
    }
}

/// The update feed, in process: every request any ephemeral URLSession makes (the updater's are the only ones) is
/// answered here — releases/latest with `latest`, everything else (the signature, the zip) 404 — so nothing leaves
/// the Mac and nothing is ever downloaded.
final class UpdateFeedStub: URLProtocol {
    nonisolated(unsafe) static var latest = "0"
    nonisolated(unsafe) private static var seen: [URL] = []
    static let lock = NSLock()
    static var requests: [URL] { lock.withLock { seen } }

    /// Every ephemeral session made from now on consults this class first.
    static func install() {
        let sel = #selector(getter: URLSessionConfiguration.ephemeral)
        guard let m = class_getClassMethod(URLSessionConfiguration.self, sel) else { return }
        typealias Get = @convention(c) (AnyObject, Selector) -> URLSessionConfiguration
        let original = unsafeBitCast(method_getImplementation(m), to: Get.self)
        let block: @convention(block) (AnyObject) -> URLSessionConfiguration = { cls in
            let c = original(cls, sel)
            c.protocolClasses = [UpdateFeedStub.self] + (c.protocolClasses ?? [])
            return c
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        UpdateFeedStub.lock.withLock { UpdateFeedStub.seen.append(url) }
        let feed = url.path.hasSuffix("/releases/latest")
        let body = feed ? """
        {"tag_name":"v\(UpdateFeedStub.latest)","draft":false,"prerelease":false,"html_url":"https://github.com/Weta-Technologies/SleepLess/releases/tag/v\(UpdateFeedStub.latest)",
         "body":"## Stub\\n- the e2e feed","assets":[{"name":"SleepLess.app.zip","browser_download_url":"https://stub.invalid/SleepLess.app.zip"},
         {"name":"SleepLess.app.zip.sig","browser_download_url":"https://stub.invalid/SleepLess.app.zip.sig"}]}
        """ : "not here"
        let response = HTTPURLResponse(url: url, statusCode: feed ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
