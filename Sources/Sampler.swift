import Foundation

struct Snapshot {
    let date: Date
    let cpu: Double?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64
    let compressed: UInt64
    let swapUsed: UInt64?
    let pressure: Int
    let apps: [AppUsage]
    let skipped: Int
    let processError: Bool
}

final class Sampler {
    private var previousTicks: CPUTicks?
    private var previousProcesses: [Int32: ProcessReading] = [:]
    private var previousTime: TimeInterval?

    func sample() -> Snapshot {
        var host = PulseHost()
        pulse_host(&host)
        let now = ProcessInfo.processInfo.systemUptime
        let ticks = CPUTicks(user: host.user, system: host.system, idle: host.idle, nice: host.nice)
        let cpu = host.cpu_valid != 0 ? cpuPercent(previous: previousTicks, current: ticks) : nil
        previousTicks = host.cpu_valid != 0 ? ticks : nil
        let capacity = 8192
        let buffer = UnsafeMutablePointer<PulseProcess>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var skipped: Int32 = 0
        let count = pulse_processes(buffer, Int32(capacity), &skipped)
        var processes: [ProcessReading] = []
        if count > 0 {
            processes.reserveCapacity(Int(count))
            for index in 0..<Int(count) {
                var raw = buffer[index]
                let path = withUnsafePointer(to: &raw.path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
                }
                processes.append(ProcessReading(pid: raw.pid, parentPID: raw.parent_pid, start: raw.start,
                                                cpuTime: raw.cpu_time, memory: raw.memory, path: path))
            }
        }
        let elapsed = previousTime.map { now - $0 } ?? 0
        let apps = groupProcesses(processes, previous: previousProcesses, elapsed: elapsed)
        previousProcesses = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { _, new in new })
        previousTime = now
        return Snapshot(date: Date(), cpu: cpu, memoryUsed: host.memory_valid != 0 ? host.memory_used : nil,
                        memoryTotal: host.memory_total, compressed: host.compressed,
                        swapUsed: host.swap_valid != 0 ? host.swap_used : nil, pressure: Int(host.pressure),
                        apps: apps, skipped: Int(skipped), processError: count < 0)
    }
}
