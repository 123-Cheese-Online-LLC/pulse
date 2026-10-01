import Foundation

struct CPUTicks {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64
}

func cpuPercent(previous: CPUTicks?, current: CPUTicks) -> Double? {
    guard let previous,
          current.user >= previous.user, current.system >= previous.system,
          current.idle >= previous.idle, current.nice >= previous.nice else { return nil }
    let busy = Double(current.user - previous.user) + Double(current.system - previous.system) + Double(current.nice - previous.nice)
    let total = busy + Double(current.idle - previous.idle)
    return total > 0 ? min(100, max(0, 100 * busy / total)) : nil
}

struct ProcessReading {
    let pid: Int32
    let parentPID: Int32
    let start: UInt64
    let cpuTime: UInt64
    let memory: UInt64
    let path: String
}

func processCPU(previous: ProcessReading?, current: ProcessReading, elapsed: Double) -> Double {
    guard let previous, elapsed > 0, previous.pid == current.pid,
          previous.start == current.start, current.cpuTime >= previous.cpuTime else { return 0 }
    return Double(current.cpuTime - previous.cpuTime) / 1_000_000_000 / elapsed * 100
}

func outerAppPath(_ path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return String(path[..<range.upperBound].dropLast())
}

struct History {
    var values: [Double] = []
    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > 41 { values.removeFirst(values.count - 41) }
    }
}

struct AppUsage: Identifiable {
    let id: String
    let name: String
    let appPath: String?
    var cpu: Double
    var memory: UInt64
    var pids: [Int32]
}

func groupProcesses(_ readings: [ProcessReading], previous: [Int32: ProcessReading], elapsed: Double) -> [AppUsage] {
    let byPID = Dictionary(readings.map { ($0.pid, $0) }, uniquingKeysWith: { _, new in new })
    var groups: [String: AppUsage] = [:]
    for process in readings {
        var appPath = outerAppPath(process.path)
        // Helpers outside a bundle can still belong to a running app. Limit and detect cycles.
        var parent = process.parentPID
        var visited: Set<Int32> = [process.pid]
        for _ in 0..<12 where appPath == nil && parent > 1 {
            guard visited.insert(parent).inserted, let ancestor = byPID[parent] else { break }
            appPath = outerAppPath(ancestor.path)
            parent = ancestor.parentPID
        }
        let id = appPath ?? "pid:\(process.pid):\(process.start)"
        // Name is built once per group, with string ops only (URL(fileURLWithPath:) hits the disk).
        var group = groups[id] ?? AppUsage(id: id, name: appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            ?? (process.path as NSString).lastPathComponent, appPath: appPath, cpu: 0, memory: 0, pids: [])
        group.cpu += processCPU(previous: previous[process.pid], current: process, elapsed: elapsed)
        group.memory += process.memory
        group.pids.append(process.pid)
        groups[id] = group
    }
    return Array(groups.values)
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1_048_576)
}
