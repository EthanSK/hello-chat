// Passive UI status only: no real call, Accessibility read, key or media action.
import Foundation

@main enum VoiceStatusRefreshTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        var p = VoiceStatusRefresh()
        p.observe(.inactive, at: 1)
        check(!p.takeIfIdle(true), "Initial inactivity is not an external End")
        p.observe(.active, at: 2)
        p.observe(.unknown, at: 3)
        check(!p.takeIfIdle(true), "Unknown does not clear a known call")
        p.observe(.inactive, at: 4)
        check(p.takeIfIdle(true) && !p.takeIfIdle(true), "A verified End updates once")
        p.observe(.inactive, at: 5)
        check(!p.takeIfIdle(true), "Repeated absence does not repeat UI work")
        p.observe(.active, at: 6); p.observe(.inactive, at: 7)
        for _ in 0..<10 { check(!p.takeIfIdle(false) && p.pending, "Opening/ending/busy keeps the update pending") }
        check(p.takeIfIdle(true), "Finishing the operation drains the deferred update")
        p.observe(.active, at: 8); p.observe(.inactive, at: 9); p.observe(.active, at: 9)
        check(!p.takeIfIdle(true), "End(old) then Active(new) in one native read preserves the new call")
        p.observe(.inactive, at: 10)
        p.confirmedLocalState(active: true, at: 11)
        check(!p.takeIfIdle(true), "A locally confirmed new Start supersedes a queued old End")
        p.observe(.inactive, at: 10.5)
        check(!p.takeIfIdle(true), "A stale in-flight native read cannot clear the new Start")
        p.observe(.unknown, at: 12); p.observe(.inactive, at: 11.5)
        check(!p.takeIfIdle(true), "An out-of-order read is ignored")
        p.observe(.inactive, at: 13)
        check(p.takeIfIdle(true), "A later verified End can clear the new call")
        p.confirmedLocalState(active: false, at: 14)
        p.observe(.inactive, at: 15)
        check(!p.takeIfIdle(true), "Own End needs no extra UI refresh")
        p.observe(.active, at: 16)
        for time in [Double.nan, Double.infinity, -1] { p.observe(.inactive, at: time) }
        p.observe(.inactive, at: nil)
        check(!p.takeIfIdle(true), "Missing, non-finite and stale timestamps are not evidence")
        for _ in 0..<100_000 { precondition(!p.takeIfIdle(true), "Idle UI does not schedule polling") }
        print("Passed \(checks) passive Voice status checks and 100000 idle polls; no native call or key")
    }
}
