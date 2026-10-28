import Darwin
import Foundation

public final class MetricsSampler {
    private var timer: Timer?
    private var lastCPUTime: Double
    private var lastDate: Date
    public private(set) var cpuSamples: [Double] = []
    public private(set) var systemCpuSamples: [Double] = []
    public private(set) var peakRSSMB: Double = 0
    private var previousSystemTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    public init() {
        lastCPUTime = Self.processCPUTime()
        lastDate = Date()
    }

    public func start() {
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        sample()
    }

    public func sample() {
        let now = Date()
        let cpu = Self.processCPUTime()
        let elapsed = now.timeIntervalSince(lastDate)

        // 启动瞬间的采样窗口太短，会把百分比放大成几百，直接丢弃
        if elapsed >= 0.5 {
            cpuSamples.append(max(0, (cpu - lastCPUTime) / elapsed * 100))
            lastCPUTime = cpu
            lastDate = now
            if let system = systemCPUPercent() {
                systemCpuSamples.append(system)
            }
        }

        peakRSSMB = max(peakRSSMB, Self.residentMB())
    }

    public var cpuAverage: Double {
        guard !cpuSamples.isEmpty else { return 0 }
        return cpuSamples.reduce(0, +) / Double(cpuSamples.count)
    }

    public var cpuPeak: Double {
        cpuSamples.max() ?? 0
    }

    public var systemCpuAverage: Double {
        guard !systemCpuSamples.isEmpty else { return 0 }
        return systemCpuSamples.reduce(0, +) / Double(systemCpuSamples.count)
    }

    public var systemCpuPeak: Double {
        systemCpuSamples.max() ?? 0
    }

    private static func processCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private func systemCPUPercent() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let current = (
            user: load.cpu_ticks.0,
            system: load.cpu_ticks.1,
            idle: load.cpu_ticks.2,
            nice: load.cpu_ticks.3
        )
        defer { previousSystemTicks = current }
        guard let previous = previousSystemTicks else { return nil }

        let busy = (current.user &- previous.user)
            &+ (current.system &- previous.system)
            &+ (current.nice &- previous.nice)
        let idle = current.idle &- previous.idle
        let total = Double(busy) + Double(idle)
        guard total > 0 else { return nil }
        return Double(busy) / total * 100
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_024 / 1_024
    }
}
