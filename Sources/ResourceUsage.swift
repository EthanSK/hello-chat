import Darwin
import Foundation

struct ResourceUsage {
    static func neuralFootprintMB() -> Double {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? Double(info.ri_neural_footprint) / 1_048_576 : -1
    }
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    private var previousCPU: Double?
    private var previousTime: Double?
    mutating func sample() -> String {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let now = ProcessInfo.processInfo.systemUptime
        let percent = previousCPU.flatMap { old in previousTime.map { (cpu - old) / max(0.001, now - $0) * 100 } }
        previousCPU = cpu; previousTime = now
        let footprint = Self.footprintMB()
        let memory = footprint >= 0 ? "Memory \(Int(footprint)) MB" : "Memory unavailable"
        return percent.map { "CPU \(String(format: "%.1f", max(0, $0)))% of one core · \(memory)" } ?? memory
    }
}
