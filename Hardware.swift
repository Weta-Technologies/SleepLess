import AppKit

/// Everything the reconcile loop reads from or does to the Mac, behind one protocol so `--e2e` can drive the whole
/// app against a fake: nothing dims a screen, writes to the root helper, registers a login item or asks for a
/// permission. `RealHardware` is the pass-through to System.swift / Extras.swift; `FakeHardware` keeps the same
/// state in memory and logs every write. Sleep assertions and the keyboard shortcut stay real in both (they are
/// this process's own, and gone when it exits).
@MainActor protocol Hardware: AnyObject {
    func now() -> Date
    func battery() -> Power.Battery?
    func isHot() -> Bool
    func sleepDisabled() -> Bool
    func lidClosed() -> Bool
    func hasExternalDisplay() -> Bool
    func idleSeconds() -> Double
    func runningApps() -> Set<String>
    func brightness() -> Float?
    func setBrightness(_ value: Float)
    func keyboard() -> KeyboardLight.Level?
    func setKeyboard(_ level: KeyboardLight.Level)
    func helperReady() -> Bool
    func helperInstalled() -> Bool
    func installHelper() -> Admin.Outcome
    func requestLid(_ on: Bool)
    func requestLight(_ on: Bool)
    func requestHelperUpdate(completion: @escaping @MainActor (Bool) -> Void)
    func loginItem() -> Bool
    func setLoginItem(_ on: Bool) -> String?
    func enableNotifications(_ done: @escaping @MainActor (Bool) -> Void)
    func notify(_ title: String, _ body: String)
}

@MainActor final class RealHardware: Hardware {
    func now() -> Date { Date() }
    func battery() -> Power.Battery? { Power.battery() }
    func isHot() -> Bool { Power.isHot }
    func sleepDisabled() -> Bool { Power.sleepDisabled }
    func lidClosed() -> Bool { Power.lidClosed }
    func hasExternalDisplay() -> Bool { Display.hasExternal }
    func idleSeconds() -> Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
    func runningApps() -> Set<String> { AppWatch.running }
    func brightness() -> Float? { Brightness.get() }
    func setBrightness(_ value: Float) { Brightness.set(value) }
    func keyboard() -> KeyboardLight.Level? { KeyboardLight.get() }
    func setKeyboard(_ level: KeyboardLight.Level) { KeyboardLight.set(level) }
    func helperReady() -> Bool { LidHelper.isReady }
    func helperInstalled() -> Bool { LidHelper.isInstalled }
    func installHelper() -> Admin.Outcome { LidHelper.install() }
    func requestLid(_ on: Bool) { LidHelper.request(on) }
    func requestLight(_ on: Bool) { LidHelper.light(on) }
    func requestHelperUpdate(completion: @escaping @MainActor (Bool) -> Void) {
        HelperUpdate.request(ready: { LidHelper.isReady }) { ok in completion(ok) }
    }
    func loginItem() -> Bool { LoginItem.isOn }
    func setLoginItem(_ on: Bool) -> String? { LoginItem.set(on) }
    func enableNotifications(_ done: @escaping @MainActor (Bool) -> Void) { Notify.enable(done) }
    func notify(_ title: String, _ body: String) { Notify.post(title, body) }
}

/// The harness's Mac: a charging laptop at 72 %, screen at 80 %, keyboard light on auto, lid open, nothing running,
/// the helper installed and current. Every write lands in `log` (one line each) and updates the state the reads
/// return, so the app sees the effect of what it asked for — the root helper's SleepDisabled included, unless
/// `helperApplies` is off. The clock only moves when the harness moves it.
@MainActor final class FakeHardware: Hardware {
    var clock = Date()
    var batteryState: Power.Battery? = Power.Battery(percent: 72, onAC: true)
    var hot = false
    var sleepOff = false
    var lidShut = false
    var externalDisplay = false
    var idle = 0.0
    var running: Set<String> = []
    var level: Float = 0.8
    var keys = KeyboardLight.Level(brightness: 0.5, auto: true)
    var ready = true
    var installed = true
    var helperApplies = true
    var installOutcome = Admin.Outcome.done
    var updateSucceeds = true
    var lightOn = true
    var login = false
    var loginError: String?
    var grantsNotifications = true
    var log: [String] = []

    func now() -> Date { clock }
    func battery() -> Power.Battery? { batteryState }
    func isHot() -> Bool { hot }
    func sleepDisabled() -> Bool { sleepOff }
    func lidClosed() -> Bool { lidShut }
    func hasExternalDisplay() -> Bool { externalDisplay }
    func idleSeconds() -> Double { idle }
    func runningApps() -> Set<String> { running }
    func brightness() -> Float? { level }
    func setBrightness(_ value: Float) { level = value; log.append("brightness \(value)") }
    func keyboard() -> KeyboardLight.Level? { keys }
    func setKeyboard(_ level: KeyboardLight.Level) { keys = level; log.append("keyboard \(level.brightness) auto \(level.auto)") }
    func helperReady() -> Bool { ready }
    func helperInstalled() -> Bool { installed }
    func installHelper() -> Admin.Outcome {
        log.append("install helper")
        if installOutcome == .done { ready = true; installed = true }
        return installOutcome
    }
    func requestLid(_ on: Bool) {
        log.append("lid \(on ? 1 : 0)")
        if helperApplies { sleepOff = on }
    }
    func requestLight(_ on: Bool) { lightOn = on; log.append("light \(on ? "on" : "off")") }
    func requestHelperUpdate(completion: @escaping @MainActor (Bool) -> Void) {
        log.append("helper update")
        let ok = updateSucceeds
        DispatchQueue.main.async { MainActor.assumeIsolated { if ok { self.ready = true }; completion(ok) } }
    }
    func loginItem() -> Bool { login }
    func setLoginItem(_ on: Bool) -> String? {
        log.append("login item \(on)")
        if loginError == nil { login = on }
        return loginError
    }
    func enableNotifications(_ done: @escaping @MainActor (Bool) -> Void) {
        log.append("ask notifications")
        let granted = grantsNotifications
        DispatchQueue.main.async { MainActor.assumeIsolated { done(granted) } }
    }
    func notify(_ title: String, _ body: String) { log.append("notify: \(title) — \(body)") }
}
