import AppKit
import Carbon.HIToolbox

/// The --e2e steps (E2E.swift has the harness): one function per area, in the order `steps` runs them. Each leaves
/// the app as it found it — off, no timer, sections as they were — except where the next step says otherwise.
extension E2E {
    static func launch(updatingAtLaunch: Bool, lidWhileUpdating: Bool) {
        let s = keeper.s, fresh = Settings()
        check("Settings migration (a 1.2.1 blob)", "Keeper.init reading the seeded settings",
              s.level == 0.35 && s.delay == 120 && s.batteryCutoff == 30 && s.pauseWhenHot && s.autoWhenCharging && !s.screenOn && s.offAfter == 0
                && s.apps.isEmpty && s.days == fresh.days && s.hotKey == nil && !s.notify && !s.timeInMenuBar, "\(s)")
        check("Launch at login: on by default, once", "first launch", hw.login && hw.log.contains("login item true")
              && UserDefaults.standard.bool(forKey: "loginItemOffered"), "\(hw.log)")
        check("Levels owed from a crash with the lid shut", "first tick with the lid open",
              hw.level == 0.6 && hw.keys == .init(brightness: 0.4, auto: false) && UserDefaults.standard.data(forKey: "lidDark") == nil,
              "brightness \(hw.level) keyboard \(hw.keys)")
        check("Helper self-update after an app update", "launch with a stale helper installed",
              updatingAtLaunch && hw.log.contains("helper update") && !keeper.helperUpdating && !keeper.helperReady && keeper.helperStale,
              "updating \(updatingAtLaunch) ready \(keeper.helperReady) log \(hw.log)")
        check("Turn on when charging, across a helper update", "launch on the charger: on while the update runs, off with the setup note when it fails",
              lidWhileUpdating && !keeper.s.lidOn && keeper.note == "Lid-closed mode is off until its helper is set up — click Set up.",
              "while updating \(lidWhileUpdating) after \(keeper.s.lidOn) note \(keeper.note ?? "-")")
        check("Off at launch", "no mode on", held().isEmpty && status.item.button?.accessibilityLabel() == "SleepLess: off" && !keeper.isOn,
              "held \(held())")
    }

    static func setup() {
        check("Setup card (helper needs updating)", "shown in the panel", shows("SleepLess's helper needs updating") && enabled("Keep awake with lid closed", "AXCheckBox") == false,
              "lid switch enabled: \(String(describing: enabled("Keep awake with lid closed", "AXCheckBox")))")
        hw.installOutcome = .cancelled
        let asked = press("Set up now") && hw.log.last == "install helper" && !keeper.helperReady && shows("helper needs updating")
        check("Setup card: Set up now (cancelled at the prompt)", "panel button → the one admin prompt (fake)", asked)
        press("Later")
        check("Setup card: Later", "panel button", keeper.setupLater && !shows("helper needs updating"))
        delegate.application(NSApp, open: [URL(string: "sleepless://lid?on=1")!])
        check("Lid-closed mode refused without the helper", "sleepless://lid?on=1", !keeper.s.lidOn && keeper.note == "Lid-closed mode needs the one-time setup — click Set up.",
              keeper.note ?? "no note")
        press("Set up…")
        let cancelled = !keeper.helperReady && keeper.note == nil && hw.log.last == "install helper"
        hw.installOutcome = .failed("The helper didn't install.")
        press("Set up…")
        let failed = !keeper.helperReady && keeper.note == "The helper didn't install." && shows("Warning: The helper didn't install.")
        press("Warning: The helper didn't install.")
        let dismissed = keeper.note == nil
        hw.installOutcome = .done
        press("Set up…")
        check("Set up… (cancelled, failed, done)", "Lid card button → the one admin prompt (fake)",
              cancelled && failed && dismissed && keeper.helperReady && find("Set up…", "AXButton") == nil && enabled("Keep awake with lid closed", "AXCheckBox") == true,
              "cancelled \(cancelled) failed \(failed) dismissed \(dismissed) ready \(keeper.helperReady)")
        press("Notice: Click the menu-bar icon", prefix: true)
        check("First-run tip: dismiss", "the tip's × button", UserDefaults.standard.bool(forKey: "tapHintSeen") && !shows("Click the menu-bar icon"))
        keeper.setAutoWhenCharging(false)   // the seeded rule, off again: its switch is exercised under Safety
        keeper.note = nil
    }

    static func statusItem() {
        status.perform(.tap)
        let risen = until { keeper.icon.frame.rise == 1 && keeper.icon.frame.sun == 0 }
        check("Icon click (tap) turns on (glyph: the sun rises)", "StatusItemController.perform(.tap)",
              keeper.s.screenOn && held() == both && status.item.button?.accessibilityLabel() == "SleepLess: on" && risen, "held \(held()) glyph \(keeper.icon.frame)")
        status.perform(.tap)
        _ = until { keeper.icon.frame.rise == 0 }
        let remembered = UserDefaults.standard.data(forKey: "tapRestores").flatMap { try? JSONDecoder().decode(TapRestore.self, from: $0) }
        check("Icon click again turns off, remembering", "perform(.tap)", !keeper.isOn && held().isEmpty && remembered == TapRestore(screen: true, lid: false),
              "held \(held()) remembered \(String(describing: remembered))")
        status.perform(.hold)
        settle()
        let shown = status.panelView.map { shows("Keep awake", in: $0) } ?? false
        status.perform(.tap)
        let closed = until { status.panelView == nil }
        check("Press and hold opens the panel; a click closes it", "perform(.hold), then perform(.tap)",
              shown && closed && !keeper.isOn, "shown \(shown) still open \(status.panelView != nil) on \(keeper.isOn)")
        func click(in window: NSWindow?) {   // a press and release near a window's corner (its footer: nothing to hit)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 1, y: 1), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                NSApp.sendEvent(e)
            }
            settle()
        }
        status.perform(.hold)
        settle()
        click(in: status.panelView?.window)
        let stays = status.panelView != nil
        click(in: self.window)
        let leaves = until { status.panelView == nil }
        check("A click inside keeps the panel, one elsewhere closes it", "mouse-downs through the app's local monitor", stays && leaves, "stays \(stays) leaves \(leaves)")
        status.perform(.hold)
        settle()
        let up = status.panelView != nil
        keyDown(53, "\u{1b}")
        check("Esc closes the panel", "Esc through the app's local monitor", up && until { status.panelView == nil })
        status.perform(.hold)
        settle()
        let opened = status.panelView != nil
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)   // activation is the system's call, so: its notice
        check("Switching to another app closes the panel", "the resign-active notification", opened && until { status.panelView == nil })
        var seen: [String] = []
        whileTracking({ status.item.menu }, open: { status.perform(.menu) }) { seen = $0.items.map(\.title) }
        let detached = until { status.item.menu == nil }
        status.perform(.tap)
        let clickWorks = keeper.s.screenOn
        status.perform(.tap)
        check("Right-click opens the quick menu; clicks work after", "perform(.menu) (dismissed once it tracks), then perform(.tap)",
              seen.contains("Turn On") && seen.contains("Quit SleepLess") && detached && clickWorks && !keeper.isOn,
              "seen \(seen) detached \(detached) clickWorks \(clickWorks)")
        NSApp.deactivate()
    }

    /// Walks the quick menu the way a click on each item does.
    static func quickMenu() {
        func menu() -> NSMenu { status.quickMenu()! }
        func run(_ title: String) -> Bool {
            let m = menu()
            guard let i = m.items.firstIndex(where: { $0.title == title }) else { return false }
            m.performActionForItem(at: i)
            settle()
            return true
        }
        func checked(_ title: String) -> Bool { menu().items.first { $0.title == title }?.state == .on }
        hw.clock = Date()
        let first = menu().items.first
        check("Menu: status line", "quick menu", first?.title == "Your Mac sleeps normally" && first?.isEnabled == false, first?.title ?? "none")
        let on = run("Turn On") && keeper.s.screenOn && menu().items.first?.title == "Keeping your Mac awake" && menu().items[1].title == "Turn Off"
        let off = run("Turn Off") && !keeper.isOn && held().isEmpty
        check("Menu: Turn On / Turn Off", "quick menu", on && off)
        var durations: [String] = []
        for (minutes, title) in [(15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"), (240, "4 hours")] {
            hw.clock = Date()
            let ok = run(title) && keeper.s.screenOn && keeper.s.offAfter == minutes && keeper.s.offAt == hw.clock.addingTimeInterval(Double(minutes * 60))
                && checked(title) && !checked("Indefinitely") && menu().items[0].title.hasSuffix("· \(Clock.short(Double(minutes * 60) - 1)) left")
            if !ok { durations.append("\(title): offAfter \(keeper.s.offAfter) status '\(menu().items[0].title)'") }
        }
        check("Menu: Keep awake for 15 min … 4 h", "quick menu, each duration", durations.isEmpty, durations.joined(separator: "; "))
        let suggested = Clock.suggestedMinute(after: Date())
        let untilTime = run("Until a time…") && keeper.s.offAtMinute == suggested && checked("Until a time…") && status.panelView != nil
        status.close()
        _ = until { status.panelView == nil }
        check("Menu: Until a time…", "quick menu → panel opens for the time", untilTime, "offAtMinute \(String(describing: keeper.s.offAtMinute))")
        check("Menu: Indefinitely", "quick menu", run("Indefinitely") && keeper.s.offAfter == 0 && keeper.s.offAtMinute == nil && keeper.s.offAt == nil && checked("Indefinitely"))
        let settings = run("Settings…") && status.panelView != nil
        status.close()
        _ = until { status.panelView == nil }
        check("Menu: Settings…", "quick menu → panel", settings)
        let asked = quitAsked
        check("Menu: Quit SleepLess", "quick menu → NSApp.terminate (held back by the harness)", run("Quit SleepLess") && quitAsked == asked + 1)
        _ = run("Turn Off")
        NSApp.deactivate()
    }

    static func modes() {
        let main = toggle("SleepLess") && keeper.s.screenOn && isOn("SleepLess") == true
        let mainOff = toggle("SleepLess") && !keeper.isOn && held().isEmpty
        check("Panel: main switch", "header switch", main && mainOff)
        check("Keep awake", "Keep awake switch", toggle("Keep awake") && keeper.s.screenOn && held() == both && shows("Screen stays on, no idle sleep"), "held \(held())")
        check("When idle: Sleep", "segment", segment("Sleep") && keeper.s.screenSleeps && held() == systemOnly && shows("Screen may sleep, Mac stays awake"),
              "held \(held())")
        let dim = segment("Dim") && keeper.s.dims && !keeper.s.screenSleeps && held() == both
        let level = slide("Dim to", to: 0.3) && abs(keeper.s.level - 0.3) < 0.001
        let delay = choose("30 seconds", in: "Dim after") && keeper.s.delay == 30
        hw.idle = 45
        keeper.tick()
        let dimmed = hw.level == Float(0.3)
        hw.idle = 0
        keeper.tick()
        let back = hw.level == Float(0.6)
        slide("Dim to", to: 0.9)
        hw.idle = 45
        keeper.tick()
        let neverBrighter = hw.level == Float(0.6)
        hw.idle = 0
        keeper.tick()
        check("When idle: Dim (level, delay, restore)", "segment, Dim to slider, After pop-up; fake idle time",
              dim && level && delay && dimmed && back && neverBrighter, "dim \(dim) level \(level) delay \(delay) dimmed \(dimmed) back \(back) neverBrighter \(neverBrighter) brightness \(hw.level)")
        check("When idle: Stay on", "segment", segment("Stay on") && !keeper.s.dims && !keeper.s.screenSleeps && held() == both)
        check("Keep awake off", "Keep awake switch", toggle("Keep awake") && !keeper.s.screenOn && held().isEmpty)
    }

    static func lid() {
        let on = toggle("Keep awake with lid closed") && keeper.s.lidOn && hw.log.last == "lid 1"
        keeper.tick()
        let lifted = until { keeper.icon.frame.sun == 1 && keeper.icon.frame.rise == 1 }
        check("Lid-closed mode on (glyph: the sun lifts)", "lid switch → helper request (fake applies SleepDisabled)",
              on && keeper.lidActive && shows("Close the lid: screen goes dark, Mac keeps running") && shows("Even with the lid closed") && held().isEmpty && lifted,
              "lidActive \(keeper.lidActive) held \(held()) glyph \(keeper.icon.frame)")
        hw.lidShut = true
        keeper.tick()
        check("Lid shut: screen, keyboard light and charging light off", "fake lid closed",
              hw.level == 0 && hw.keys == .init(brightness: 0, auto: false) && !hw.lightOn && held() == both
                && UserDefaults.standard.data(forKey: "lidDark") != nil && UserDefaults.standard.bool(forKey: "lightIsOff"),
              "brightness \(hw.level) keys \(hw.keys) light \(hw.lightOn) held \(held())")
        hw.lidShut = false
        keeper.tick()
        check("Lid opened: levels and light back", "fake lid opened",
              hw.level == 0.6 && hw.keys == .init(brightness: 0.4, auto: false) && hw.lightOn && held().isEmpty && UserDefaults.standard.data(forKey: "lidDark") == nil,
              "brightness \(hw.level) keys \(hw.keys) light \(hw.lightOn)")
        hw.externalDisplay = true
        hw.lidShut = true
        let writes = hw.log.filter { $0.hasPrefix("brightness") }.count
        keeper.tick()
        let handsOff = hw.level == 0.6 && hw.log.filter { $0.hasPrefix("brightness") }.count == writes
        hw.lidShut = false
        hw.externalDisplay = false
        keeper.tick()
        check("Lid shut with a monitor: hands off", "fake lid closed + external display", handsOff, "brightness \(hw.level)")
        let requests = hw.log.filter { $0 == "lid 1" }.count
        hw.clock = hw.clock.addingTimeInterval(31)
        keeper.tick()
        check("Lid request renewed every 30 s (watchdog heartbeat)", "fake clock +31 s", hw.log.filter { $0 == "lid 1" }.count == requests + 1)
    }

    static func safety() {
        press("Safety:", prefix: true)
        let expanded = find("Only while charging", "AXCheckBox") != nil
        let only = toggle("Only while charging") && keeper.s.onlyWhileCharging
        hw.batteryState = .init(percent: 72, onAC: false)
        keeper.tick()
        let stopped = !keeper.s.lidOn && keeper.note == "Lid-closed mode turned off: not on the charger." && hw.log.last == "lid 0"
        _ = toggle("Keep awake with lid closed")
        let refused = !keeper.s.lidOn && keeper.note == "Can't keep awake with lid closed: not on the charger."
        _ = toggle("Only while charging")
        hw.batteryState = .init(percent: 72, onAC: true)
        check("Safety: Only while charging", "Safety disclosure, switch; fake unplug", expanded && only && stopped && refused && !keeper.s.onlyWhileCharging,
              "expanded \(expanded) only \(only) stopped \(stopped) refused \(refused) note \(keeper.note ?? "-")")
        let cutoff = slide("Low-battery cutoff", to: 0.5) && keeper.s.batteryCutoff == 50
        _ = toggle("Keep awake with lid closed")
        let lidOn = keeper.s.lidOn
        hw.batteryState = .init(percent: 45, onAC: false)
        keeper.tick()
        check("Safety: Low-battery cutoff", "slider; fake battery 45 % unplugged", cutoff && lidOn && !keeper.s.lidOn && keeper.note == "Lid-closed mode turned off: battery at 45%.",
              "cutoff \(keeper.s.batteryCutoff) note \(keeper.note ?? "-")")
        hw.batteryState = .init(percent: 72, onAC: true)
        _ = toggle("Keep awake with lid closed")
        hw.hot = true
        keeper.tick()
        let hotStop = !keeper.s.lidOn && keeper.note == "Lid-closed mode turned off: the Mac is running hot."
        let offRule = toggle("Pause when running hot") && !keeper.s.pauseWhenHot && toggle("Keep awake with lid closed") && keeper.s.lidOn
        _ = toggle("Keep awake with lid closed")
        _ = toggle("Pause when running hot")
        hw.hot = false
        check("Safety: Pause when running hot", "switch; fake thermal state", hotStop && offRule && keeper.s.pauseWhenHot)
        let auto = toggle("Turn on when charging") && keeper.s.autoWhenCharging && keeper.s.lidOn
        hw.batteryState = .init(percent: 72, onAC: false)
        keeper.tick()
        let unplugged = !keeper.s.lidOn
        hw.batteryState = .init(percent: 72, onAC: true)
        keeper.tick()
        let plugged = keeper.s.lidOn
        _ = toggle("Turn on when charging")
        _ = toggle("Keep awake with lid closed")
        check("Safety: Turn on when charging", "switch; fake plug and unplug", auto && unplugged && plugged && !keeper.s.autoWhenCharging && !keeper.s.lidOn)
        let lightRule = toggle("Charging light off when closed") && !keeper.lightOffWithLid && !UserDefaults.standard.bool(forKey: "lightOffWithLid")
        _ = toggle("Keep awake with lid closed")
        keeper.tick()
        hw.lidShut = true
        keeper.tick()
        let lightKept = hw.lightOn
        hw.lidShut = false
        keeper.tick()
        _ = toggle("Keep awake with lid closed")
        _ = toggle("Charging light off when closed")
        check("Safety: Charging light off when closed", "switch; fake lid", lightRule && lightKept && keeper.lightOffWithLid)
        let installs = hw.log.filter { $0 == "install helper" }.count
        check("Safety: Reinstall helper…", "link button → admin prompt (fake)", press("Reinstall helper…", "AXLink") && hw.log.filter { $0 == "install helper" }.count == installs + 1)
        press("Warning:", prefix: true)
    }

    static func timer() {
        hw.clock = Date()
        _ = toggle("Keep awake")
        let fifteen = choose("In 15 minutes", in: "Turn off") && keeper.s.offAfter == 15 && keeper.s.offAt == hw.clock.addingTimeInterval(900) && keeper.s.offFrom == hw.clock
        check("Turn off: In 15 minutes (progress bar)", "Turn off pop-up", fifteen && progressBar && !shows("Starts when a mode is on"), "offAt \(String(describing: keeper.s.offAt))")
        let inBar = toggle("Time left in the menu bar") && keeper.s.timeInMenuBar
        keeper.tick()
        let title = status.item.button?.title ?? ""
        _ = toggle("Time left in the menu bar")
        keeper.tick()
        check("Time left in the menu bar", "switch → the icon's title", inBar && title == "15m" && status.item.button?.title == "", "title '\(title)'")
        let suggested = Clock.suggestedMinute(after: Date())
        let at = choose("At a time", in: "Turn off") && keeper.s.offAtMinute == suggested && find("Turn off at", "AXDateTimeArea") != nil
        let target = (Clock.minute(of: Date()) + 150) % 1440
        let picked = pick("Turn off at", minute: target) && keeper.s.offAtMinute == target && keeper.s.offAt == Clock.next(minute: target, after: hw.clock)
        check("Turn off: At a time (time picker)", "Turn off pop-up, then the time field", at && picked, "offAtMinute \(String(describing: keeper.s.offAtMinute))")
        let never = choose("Never", in: "Turn off") && !keeper.s.hasTimer && keeper.s.offAt == nil && until { !progressBar && find("Time left in the menu bar", "AXCheckBox") == nil }
        check("Turn off: Never", "Turn off pop-up", never)
        _ = toggle("Keep awake")
        var chosen: [Int] = []
        for (minutes, title) in TimerSection.durations where choose(title, in: "Turn off") && keeper.s.offAfter == minutes && keeper.s.offAtMinute == nil { chosen.append(minutes) }
        check("Turn off: every duration", "Turn off pop-up, each In … item", chosen == TimerSection.durations.map(\.0), "\(chosen)")
        _ = choose("Never", in: "Turn off")
        let waits = choose("In 30 minutes", in: "Turn off") && keeper.s.offAt == nil && shows("Starts when a mode is on") && !progressBar
        _ = choose("Never", in: "Turn off")
        check("Timer waits for a mode", "Turn off pop-up with nothing on", waits)
        check("Turn off menu lists every choice", "the pop-up's items",
              menuTitles("Turn off").filter { !$0.isEmpty } == ["Never", "In 15 minutes", "In 30 minutes", "In 1 hour", "In 2 hours", "In 4 hours", "At a time"], "\(menuTitles("Turn off"))")
    }

    static func more() {
        press("More:", prefix: true)
        let key = HotKey(keyCode: 40, modifiers: HotKey.carbon(hyper), key: "K")
        let recording = press("Record shortcut") && find("Recording shortcut, press keys", "AXButton") != nil
        keyDown(40, "k")   // a plain key is refused: still recording
        let plainRefused = keeper.s.hotKey == nil && find("Recording shortcut, press keys", "AXButton") != nil
        keyDown(40, "k", hyper)
        let recorded = keeper.s.hotKey == key && registered(key) && shows("Shortcut ⌃⌥⇧⌘K") && keeper.note == nil
        let tip = status.quickMenu()?.items[1].toolTip ?? ""
        check("Keyboard shortcut: record", "Record button, key presses; Carbon registration read back",
              recording && plainRefused && recorded && tip.contains("⌃⌥⇧⌘K"), "recording \(recording) plainRefused \(plainRefused) recorded \(recorded) tip '\(tip)'")
        fireHotKey()
        let on = keeper.s.screenOn
        fireHotKey()
        check("Keyboard shortcut: pressing it", "Carbon hot-key event", on && !keeper.isOn)
        press("Shortcut ⌃⌥⇧⌘K")
        keyDown(53, "\u{1b}")
        check("Keyboard shortcut: Esc cancels recording", "Esc while recording", keeper.s.hotKey == key && registered(key) && find("Shortcut ⌃⌥⇧⌘K", "AXButton") != nil)
        let taken = HotKey(keyCode: 37, modifiers: HotKey.carbon(hyper), key: "L")
        var other: EventHotKeyRef?
        RegisterEventHotKey(taken.keyCode, taken.modifiers, EventHotKeyID(signature: OSType(0x4F54_4852), id: 1), GetApplicationEventTarget(), 0, &other)   // someone else's
        press("Shortcut ⌃⌥⇧⌘K")
        keyDown(37, "l", hyper)
        let note = keeper.note
        if let other { UnregisterEventHotKey(other) }
        check("Keyboard shortcut: a taken combination", "record one already registered", note == "⌃⌥⇧⌘L is taken by macOS or another app — try another shortcut.", note ?? "no note")
        keeper.note = nil
        press("Remove the shortcut")
        check("Keyboard shortcut: remove", "× button; Carbon registration read back", keeper.s.hotKey == nil && !registered(key) && !registered(taken) && find("Record shortcut", "AXButton") != nil)
        let asks = hw.log.filter { $0 == "ask notifications" }.count
        _ = toggle("Notify me")
        let granted = until { keeper.s.notify } && hw.log.filter { $0 == "ask notifications" }.count == asks + 1
        _ = toggle("Notify me")
        let off = !keeper.s.notify
        hw.grantsNotifications = false
        _ = toggle("Notify me")
        let refused = until { keeper.note != nil } && !keeper.s.notify && keeper.note == "Notifications are off for SleepLess in System Settings › Notifications."
        hw.grantsNotifications = true
        keeper.note = nil
        _ = toggle("Notify me")
        check("Notify me (permission asked, refusal)", "switch; fake permission", granted && off && refused && until { keeper.s.notify }, "granted \(granted) off \(off) refused \(refused)")
        let text = find("Scripting", "AXStaticText") != nil

        let verbs = ["on", "off", "toggle", "on?minutes=30", "on?until=17:30", "lid?on=1"]
        let documented = verbs.allSatisfy { shows($0) && Command.parse(URL(string: "sleepless://\($0)")!) != nil }
        check("Scripting row", "its text; every documented link parses", text && documented)
    }

    static func timing() {
        hw.clock = Date()
        _ = toggle("Keep awake")
        _ = choose("In 15 minutes", in: "Turn off")
        hw.clock = hw.clock.addingTimeInterval(15 * 60)
        let fired = until(2.5) { !keeper.s.screenOn }   // the app's own 1 s timer notices
        check("Timer fires (the app's own 1 s tick)", "fake clock +15 min",
              fired && keeper.note == "Timer finished, normal sleep is back." && held().isEmpty && hw.log.last == "notify: SleepLess timer finished — Your Mac sleeps normally again.",
              "fired \(fired) note \(keeper.note ?? "-") log \(hw.log.last ?? "-")")
        keeper.note = nil
        _ = toggle("Keep awake with lid closed")
        let mark = hw.log.count
        hw.hot = true
        keeper.tick()
        let stopped = hw.log[mark...].contains("notify: Lid-closed mode turned off — SleepLess stopped it: the Mac is running hot.")
        hw.hot = false
        press("Warning:", prefix: true)
        check("Notification when a safety rule stops lid-closed mode", "fake thermal state with Notify me on", stopped && !keeper.s.lidOn, "\(hw.log[mark...])")
        var nz = Calendar(identifier: .gregorian)
        nz.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        hw.clock = nz.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 23))!
        _ = toggle("Time left in the menu bar")
        _ = choose("At a time", in: "Turn off")
        pick("Turn off at", minute: 5 * 60)
        _ = toggle("Keep awake")
        let offAt = keeper.s.offAt ?? .distantPast
        let fiveHours = offAt.timeIntervalSince(hw.clock) == 5 * 3600 && nz.component(.hour, from: offAt) == 5 && nz.component(.day, from: offAt) == 27
        keeper.tick()
        let bar = status.item.button?.title ?? ""
        hw.clock = offAt.addingTimeInterval(-30)
        keeper.tick()
        let stillOn = keeper.s.screenOn && status.item.button?.title == "1m"
        hw.clock = offAt
        let off = until(2.5) { !keeper.s.screenOn }
        check("At a time across the DST change", "time field 05:00 at 23:00 on 26 Sep (NZ springs forward at 02:00)",
              Calendar.current.timeZone.identifier == "Pacific/Auckland" && fiveHours && bar == "5h" && stillOn && off,
              "offAt \(offAt) bar '\(bar)' stillOn \(stillOn) off \(off)")
        _ = toggle("Time left in the menu bar")
        _ = choose("Never", in: "Turn off")
        keeper.note = nil
        hw.clock = Date()
    }

    static func automations() {
        press("Automations:", prefix: true)
        let rule = toggle("While an app is running") && keeper.s.appsOn
        var offered: [String] = []
        let picked = pullDown("Add app") { menu in   // the first running app it offers (not named here)
            offered = menu.items.map(\.title)
            guard let i = menu.items.firstIndex(where: { $0.isEnabled && !$0.isSeparatorItem && !$0.title.isEmpty && $0.title != "Other…" }) else { return nil }
            menu.performActionForItem(at: i)
            return menu.items[i].title
        }
        let added = picked != nil && keeper.s.apps.count == 1 && keeper.s.apps.first?.name == picked
        guard let app = keeper.s.apps.first else { return check("Automations: while an app is running", "switch, Add app menu", false, "nothing added") }
        hw.running = [app.id]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: NSWorkspace.shared)
        settle()
        let holds = keeper.reasons == [.app(app)] && held() == both && shows(Automation.sentence([.app(app)])) && shows("Keeping your Mac awake now")
        hw.running = []
        keeper.tick()
        let stops = keeper.reasons.isEmpty && held().isEmpty
        check("Automations: while an app is running", "switch, Add app menu (a running app); fake app start and quit",
              rule && added && holds && stops, "rule \(rule) added \(added) holds \(holds) stops \(stops) held \(held())")
        hw.running = [app.id]
        keeper.tick()
        status.perform(.tap)
        let paused = !keeper.isOn && keeper.paused == [.app(app)] && held().isEmpty && shows(Automation.sentence([.app(app)], prefix: "Paused while "))
            && shows("Paused until this ends — you switched off")
        hw.running = []
        keeper.tick()
        let cleared = keeper.paused.isEmpty
        hw.running = [app.id]
        keeper.tick()
        let again = keeper.reasons == [.app(app)] && held() == both
        hw.running = []
        keeper.tick()
        check("A click pauses an automation until its reason ends", "icon tap while it holds; fake app quit and restart", paused && cleared && again,
              "paused \(paused) cleared \(cleared) again \(again)")
        let others = offered.contains("Other…")
        let sample = out.appendingPathComponent("Made Up.app")
        try? FileManager.default.createDirectory(at: sample.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try? (["CFBundleIdentifier": "com.example.madeup", "CFBundlePackageType": "APPL"] as NSDictionary).write(to: sample.appendingPathComponent("Contents/Info.plist"))
        let ref = AppRef(url: sample)
        try? FileManager.default.removeItem(at: sample)
        check("Add app: Other… (the chosen bundle)", "menu item present; AppRef(url:) on a made-up bundle", others && ref == AppRef(id: "com.example.madeup", name: "Made Up"),
              "\(String(describing: ref))")
        press(app.name)
        check("Remove an app", "the app row's × button", keeper.s.apps.isEmpty)
        _ = toggle("While an app is running")
        let power = toggle("On the power adapter") && keeper.s.powerOn && keeper.reasons == [.power] && held() == both
        hw.batteryState = .init(percent: 72, onAC: false)
        keeper.tick()
        let unplugged = keeper.reasons.isEmpty && held().isEmpty
        hw.batteryState = .init(percent: 72, onAC: true)
        _ = toggle("On the power adapter")
        check("Automations: on the power adapter", "switch; fake unplug", power && unplugged && keeper.reasons.isEmpty)
        let display = toggle("With an external display") && keeper.s.displayOn && keeper.reasons.isEmpty
        hw.externalDisplay = true
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        settle()
        let connected = keeper.reasons == [.display] && held() == both
        hw.externalDisplay = false
        keeper.tick()
        let gone = keeper.reasons.isEmpty && held().isEmpty
        _ = toggle("With an external display")
        check("Automations: with an external display", "switch; fake display connect (screen-change notification) and disconnect", display && connected && gone)
        var nz = Calendar(identifier: .gregorian)
        nz.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { nz.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))! }
        hw.clock = at(26, 10)   // a Saturday
        let schedule = toggle("On a schedule") && keeper.s.scheduleOn && keeper.reasons.isEmpty
        let saturday = toggle("Saturday") && keeper.s.days & 1 << 7 != 0 && keeper.reasons == [.schedule] && held() == both
        let times = pick("From", minute: 22 * 60) && pick("To", minute: 6 * 60) && keeper.s.from == 22 * 60 && keeper.s.to == 6 * 60 && keeper.reasons.isEmpty
        hw.clock = at(27, 3, 30)   // Sunday, the DST night: still Saturday's overnight window
        keeper.tick()
        let overnight = keeper.reasons == [.schedule]
        hw.clock = at(27, 6)
        keeper.tick()
        let ended = keeper.reasons.isEmpty && held().isEmpty
        let summary = shows(Schedule.summary(days: keeper.s.days, from: keeper.s.from, to: keeper.s.to))
        _ = toggle("Saturday")
        let week = keeper.s.days
        let days = Calendar.current.weekdaySymbols.enumerated().allSatisfy { i, day in
            toggle(day) && keeper.s.days == week ^ (1 << (i + 1)) && toggle(day) && keeper.s.days == week
        }
        _ = pick("From", minute: 9 * 60)
        _ = pick("To", minute: 17 * 60)
        _ = toggle("On a schedule")
        hw.clock = Date()
        keeper.tick()
        check("Automations: on a schedule (days, from, to)", "switch, day buttons, time fields; fake clock across the DST night",
              schedule && saturday && times && overnight && ended && summary && days,
              "schedule \(schedule) saturday \(saturday) times \(times) overnight \(overnight) ended \(ended) summary \(summary) days \(days)")
        check("Automations summary", "the collapsed line", shows("Automations: Off"))
    }

    static func loginAndUpdates() {
        let off = toggle("Launch at login") && !hw.login && hw.log.last == "login item false" && isOn("Launch at login") == false
        let on = toggle("Launch at login") && hw.login && isOn("Launch at login") == true
        hw.loginError = "Operation not permitted"
        _ = toggle("Launch at login")
        let error = keeper.note == "Operation not permitted" && hw.login && isOn("Launch at login") == true
        hw.loginError = nil
        keeper.note = nil
        check("Launch at login", "checkbox; fake login item (and a refusal)", off && on && error, "off \(off) on \(on) error \(error)")
        let auto = toggle("Check for updates automatically") && !Updater.shared.automatic && UserDefaults.standard.object(forKey: "updates.automatic") as? Bool == false
        _ = toggle("Check for updates automatically")
        check("Check for updates automatically", "checkbox", auto && Updater.shared.automatic)
        let current = Updater.shared.currentVersion.description
        UpdateFeedStub.latest = current
        press("Check Now")
        let upToDate = until { Updater.shared.state == .upToDate } && shows("SleepLess \(current) is up to date")
            && UpdateFeedStub.requests.last?.absoluteString == "https://api.github.com/repos/Weta-Technologies/SleepLess/releases/latest"
        check("Check Now: up to date", "button → the release feed (stubbed)", upToDate, "state \(Updater.shared.state) requests \(UpdateFeedStub.requests)")
        UpdateFeedStub.latest = "9.9.9"
        press("Check Now")
        let offered = until { Updater.shared.available != nil } && shows("SleepLess 9.9.9 is available")
        settle()
        let badged = status.item.button?.image !== keeper.icon.image
        check("Check Now: an update is offered (card, icon badge)", "button → stubbed feed with 9.9.9", offered && badged, "offered \(offered) badged \(badged)")
        let notes = press("What's new…", "") && opened.last?.absoluteString == "https://github.com/Weta-Technologies/SleepLess/releases/tag/v9.9.9"
        let licence = find("licence", "AXLink") != nil   // a link inside the card's text: present (not pressed — see the report)
        check("Update card: What's new… (and the licence link is there)", "link (intercepted)", notes && licence, "\(opened)")
        let later = press("Later") && Updater.shared.state == .idle && !shows("9.9.9 is available")
        settle()
        check("Update card: Later", "button", later && status.item.button?.image === keeper.icon.image)
        press("Check Now")
        _ = until { Updater.shared.available != nil }
        check("Update card: Skip", "button", press("Skip") && Updater.shared.state == .idle && UserDefaults.standard.string(forKey: "updates.skipped") == "v9.9.9")
        press("Check Now")   // a manual check still offers a skipped version
        let again = until { Updater.shared.available != nil }
        press("Update Now")
        let failed = until { if case .failed = Updater.shared.state { return true }; return false } && shows("Couldn't download the update's signature")
        let page = press("Open download page") && opened.last == Updater.shared.pageURL
        let dismissed = press("Dismiss") && Updater.shared.state == .idle
        let noDownload = !UpdateFeedStub.requests.contains { $0.pathExtension == "zip" }
        check("Update card: Update Now (the stub serves no download)", "button; then Open download page, Dismiss",
              again && failed && page && dismissed && noDownload, "again \(again) failed \(failed) page \(page) dismissed \(dismissed) requests \(UpdateFeedStub.requests)")
        let links = press("Licence", "AXLink") && press("Privacy", "AXLink") && press("GitHub", "AXLink")
        let urls = opened.suffix(3).map(\.absoluteString)
        check("Footer links: Licence, Privacy, GitHub", "links (intercepted)", links && urls == [
            "https://github.com/Weta-Technologies/SleepLess/blob/main/LICENSE", "https://github.com/Weta-Technologies/SleepLess/blob/main/PRIVACY.md",
            "https://github.com/Weta-Technologies/SleepLess"], "\(urls)")
        let asked = quitAsked
        check("Panel: Quit", "button → NSApp.terminate (held back by the harness)", press("Quit") && quitAsked == asked + 1)
    }

    static func urlScheme() {
        func open(_ link: String) { delegate.application(NSApp, open: [URL(string: link)!]); settle() }
        hw.clock = Date()
        open("sleepless://on")
        let on = keeper.s.screenOn && !keeper.s.hasTimer
        open("sleepless://off")
        let off = !keeper.isOn
        open("sleepless://on?minutes=30")
        let minutes = keeper.s.screenOn && keeper.s.offAfter == 30 && keeper.s.offAt == hw.clock.addingTimeInterval(1800)
        open("sleepless://on?until=17:30")
        let until = keeper.s.offAtMinute == 17 * 60 + 30 && keeper.s.offAt == Clock.next(minute: 17 * 60 + 30, after: hw.clock)
        open("sleepless://toggle")
        let toggledOff = !keeper.isOn
        open("sleepless://toggle")
        let toggledOn = keeper.s.screenOn
        open("sleepless://lid?on=1")
        let lidOn = keeper.s.lidOn
        open("sleepless://lid?on=0")
        let lidOff = !keeper.s.lidOn
        open("sleepless://off")
        check("sleepless:// on, off, minutes, until, toggle, lid", "AppDelegate.application(_:open:)",
              on && off && minutes && until && toggledOff && toggledOn && lidOn && lidOff && !keeper.isOn,
              "on \(on) off \(off) minutes \(minutes) until \(until) toggle \(toggledOff)/\(toggledOn) lid \(lidOn)/\(lidOff)")
        keeper.setOffAfter(0)
        let before = keeper.s
        for link in ["sleepless://on?minutes=0", "sleepless://on?minutes=-5", "sleepless://on?until=25:00", "sleepless://on?minutes=30&minutes=60",
                     "sleepless://run?cmd=rm%20-rf%20/", "sleepless://on/../off", "sleepless://on#off", "sleepless://user@on", "sleepless://on:80",
                     "sleepless://lid?on=maybe", "sleepless://toggle?x=1", "sleepless:on", "sleepless://", "https://on", "file:///etc/passwd",
                     "sleepless://on?minutes=30%0Aopen%20x"] {
            open(link)
        }
        check("sleepless:// hostile input changes nothing", "16 malformed links through the app delegate", keeper.s == before && !keeper.isOn && held().isEmpty)
    }

    static func reopen() {
        status.iconHiddenOverride = false
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        settle()
        let popover = status.panelView.map { shows("Keep awake", in: $0) } ?? false
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let once = status.panelView != nil && !status.floatingShown
        status.close()
        check("Reopen shows the panel", "applicationShouldHandleReopen (icon visible)", popover && once && until { status.panelView == nil }, "popover \(popover) once \(once)")
        status.iconHiddenOverride = true
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        settle()
        let floating = status.floatingShown && (status.panelView.map { shows("Your menu bar is full", in: $0) && shows("Keep awake", in: $0) } ?? false)
        func frame() -> NSRect { status.panelView?.window?.frame ?? .zero }
        let before = frame()
        let toggled = press("More:", prefix: true, in: status.panelView)
        let changed = frame()
        press("More:", prefix: true, in: status.panelView)
        let back = frame()
        let follows = changed.height != before.height && back == before && changed.maxX == before.maxX && changed.maxY == before.maxY
        press("Record shortcut", in: status.panelView)
        keyDown(53, "\u{1b}")   // cancels the recording, not the panel
        let recordingEsc = status.floatingShown && find("Record shortcut", "AXButton", in: status.panelView) != nil && !HotKeys.recording
        keyDown(53, "\u{1b}")
        check("Esc while recording a shortcut leaves the panel open", "floating panel: Record, Esc", recordingEsc)
        check("Reopen with the icon hidden: floating panel (resizes from its top-right corner), Esc closes", "applicationShouldHandleReopen (icon hidden), a section toggled, Esc",
              floating && toggled && follows && !status.floatingShown && status.panelView == nil,
              "floating \(floating) before \(before) changed \(changed) back \(back) still shown \(status.floatingShown)")
        status.iconHiddenOverride = nil
        NSApp.deactivate()
    }

    static func persistence() {
        let saved = UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        check("Settings persist", "the saved blob decoded", saved == keeper.s && UserDefaults.standard.object(forKey: "lightOffWithLid") as? Bool == true,
              "saved \(String(describing: saved))")
    }

    /// The real quit, last: lid-closed mode on with the lid shut (screen and lights dark), then NSApp.terminate — the
    /// Keeper's own willTerminate hand-backs must put everything back before the process exits.
    static func quit() {
        _ = toggle("Keep awake with lid closed")
        keeper.tick()
        hw.lidShut = true
        keeper.tick()
        let dark = hw.level == 0 && !hw.lightOn
        let mark = hw.log.count
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                let after = Array(hw.log[mark...])
                check("Quit hands everything back", "NSApp.terminate with the lid shut in lid-closed mode",
                      dark && after.contains("brightness 0.6") && after.contains("keyboard 0.4 auto false") && after.contains("light on") && after.contains("lid 0"), "\(after)")
                check("Quit (menu and panel) reached", "counted by the harness", quitAsked == 2, "\(quitAsked)")
                finish()
            }
        }
        quitAllowed = true
        NSApp.terminate(nil)
    }
}
