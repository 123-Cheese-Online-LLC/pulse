import Foundation
import CoreGraphics

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { print("FAIL: \(message)"); failures += 1 }
}
let before = CPUTicks(user: 100, system: 100, idle: 800, nice: 0)
let after = CPUTicks(user: 120, system: 110, idle: 870, nice: 0)
check(cpuPercent(previous: before, current: after) == 30, "CPU uses interval deltas, not lifetime totals")
check(cpuPercent(previous: nil, current: after) == nil, "CPU first sample is unavailable")
check(cpuPercent(previous: after, current: before) == nil, "Counter resets do not produce false spikes")
check(cpuPercent(previous: before, current: before) == nil, "Zero interval is unavailable")
let p1 = ProcessReading(pid: 42, parentPID: 1, start: 100, cpuTime: 1_000_000_000, memory: 400, path: "/Applications/Example.app/Contents/MacOS/Example")
let p2 = ProcessReading(pid: 42, parentPID: 1, start: 100, cpuTime: 4_000_000_000, memory: 400, path: p1.path)
let reused = ProcessReading(pid: 42, parentPID: 1, start: 200, cpuTime: 8_000_000_000, memory: 400, path: p1.path)
check(processCPU(previous: p1, current: p2, elapsed: 2) == 150, "Multicore process may exceed 100 percent")
check(processCPU(previous: p1, current: reused, elapsed: 2) == 0, "Reused PID is not compared against old process")
check(processCPU(previous: p1, current: p2, elapsed: 0) == 0, "Zero elapsed duration is safe")
check(outerAppPath("/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper") == "/Applications/Example.app", "Helpers group under the outer app")
check(outerAppPath("/usr/libexec/windowserver") == nil, "System processes are not classified as apps")
var history = History()
for i in 0..<100 { history.append(Double(i)) }
check(history.values.count == 41, "History is bounded to two minutes at three-second intervals")
check(history.values.last == 99, "History retains newest sample")
let helper1 = ProcessReading(pid: 43, parentPID: 42, start: 100, cpuTime: 1_000_000_000, memory: 200, path: "/usr/libexec/helper")
let helper2 = ProcessReading(pid: 43, parentPID: 42, start: 100, cpuTime: 2_000_000_000, memory: 200, path: "/usr/libexec/helper")
let groups = groupProcesses([p2, helper2], previous: [42: p1, 43: helper1], elapsed: 2)
check(groups.count == 1, "External helper follows its parent app")
check(groups.first?.memory == 600, "Grouped memory includes helpers")
check(groups.first?.cpu == 200, "Grouped interval CPU includes helpers")
check(Set(groups.first?.pids ?? []) == [42, 43], "Details retain grouped process IDs")
let system = ProcessReading(pid: 90, parentPID: 1, start: 1, cpuTime: 10, memory: 100, path: "/usr/libexec/system")
check(groupProcesses([system], previous: [:], elapsed: 3).first?.appPath == nil, "System process never gains an app Quit action")
let cyclic1 = ProcessReading(pid: 91, parentPID: 92, start: 1, cpuTime: 1, memory: 1, path: "/a")
let cyclic2 = ProcessReading(pid: 92, parentPID: 91, start: 1, cpuTime: 1, memory: 1, path: "/b")
check(groupProcesses([cyclic1, cyclic2], previous: [:], elapsed: 3).count == 2, "Parent cycles terminate safely")
let displays = [
    CGRect(x: 0, y: 0, width: 1440, height: 875),
    CGRect(x: 80, y: 0, width: 944, height: 560),
    CGRect(x: -1920, y: 40, width: 1920, height: 1015),
    CGRect(x: 0, y: -900, width: 1440, height: 875)
]
for screen in displays {
    for x in [screen.minX + 20, screen.midX, screen.maxX - 20] {
        let anchor = CGRect(x: x, y: screen.maxY, width: 100, height: 25)
        let frame = panelFrame(anchor: anchor, visibleFrame: screen)
        check(screen.insetBy(dx: 8, dy: 8).contains(frame), "Entire panel stays inside display \(screen) at anchor \(x)")
        check(frame.maxY <= anchor.minY - 8, "Panel always opens below the menu bar")
    }
}
if failures > 0 { exit(1) }
print("All 41 metrics and panel placement checks passed")
