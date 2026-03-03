import Foundation

struct NetworkInfo {
    static func getLocalIPAddress() -> String? {
        APIServer.getLocalIPAddress()
    }

    static func getMemoryUsage() -> (used: UInt64, total: UInt64) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        let used: UInt64 = result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        let total = ProcessInfo.processInfo.physicalMemory

        return (used, total)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
