import Darwin
import Foundation

public enum ProcessLifetime {
    /// A best-effort preflight, not an atomic process handle or protection
    /// against two PID lifetimes beginning in the same whole second.
    public static func validateForControl(_ id: ProcessID) throws {
        guard id.pid > 0 else {
            throw ProviderError.underlying("Process control requires a positive PID.")
        }
        guard id.startTime != 0 else { throw ProviderError.unsupported }
        guard try nativeStartTime(id.pid) == id.startTime else { throw ProviderError.processGone }
    }

    private static func nativeStartTime(_ pid: Int32) throws -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        let code = errno
        guard count == size else {
            switch code {
            case ESRCH: throw ProviderError.processGone
            case EPERM, EACCES: throw ProviderError.notPermitted
            default:
                throw ProviderError.underlying("Cannot establish process lifetime (OS error \(code), \(count)/\(size) bytes).")
            }
        }
        return info.pbi_start_tvsec
    }
}
