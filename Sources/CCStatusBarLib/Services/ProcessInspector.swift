import Darwin
import Foundation

/// Facts about running processes, read from the kernel instead of spawning
/// `pgrep`, `ps` or `lsof`. A Codex scan needs them for every agent every few
/// seconds, and starting those tools was most of what a scan cost.
enum ProcessInspector {
    /// PIDs whose process name is exactly one of `names`, like `pgrep -x`.
    static func pids(named names: Set<String>) -> [pid_t] {
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0 else { return [] }
        // The table can grow between asking for its size and reading it.
        size += size / 8
        let stride = MemoryLayout<kinfo_proc>.stride
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&query, u_int(query.count), &table, &size, nil, 0) == 0 else { return [] }
        return table.prefix(size / stride).compactMap { info in
            names.contains(string(fromCString: info.kp_proc.p_comm)) ? info.kp_proc.p_pid : nil
        }
    }

    /// The arguments joined with spaces, like `ps -o command=`. Empty if unreadable.
    static func commandLine(of pid: pid_t) -> String {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, u_int(query.count), &buffer, &size, nil, 0) == 0 else { return "" }
        return commandLine(fromProcArgs: buffer.prefix(size))
    }

    /// Layout: argc as Int32, the executable path, NUL padding, then argv.
    static func commandLine(fromProcArgs bytes: ArraySlice<UInt8>) -> String {
        guard bytes.count > MemoryLayout<Int32>.size else { return "" }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var cursor = bytes.startIndex + MemoryLayout<Int32>.size
        cursor = bytes[cursor...].firstIndex(of: 0) ?? bytes.endIndex
        cursor = bytes[cursor...].firstIndex { $0 != 0 } ?? bytes.endIndex

        var arguments: [String] = []
        while arguments.count < argc, cursor < bytes.endIndex {
            let end = bytes[cursor...].firstIndex(of: 0) ?? bytes.endIndex
            arguments.append(String(decoding: bytes[cursor..<end], as: UTF8.self))
            cursor = min(end + 1, bytes.endIndex)
        }
        return arguments.joined(separator: " ")
    }

    /// Working directory and the paths of open files, like the vnode rows of `lsof -p`.
    static func openFiles(of pid: pid_t) -> (cwd: String?, paths: [String]) {
        var directory = proc_vnodepathinfo()
        let directorySize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let cwd = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &directory, directorySize) == directorySize
            ? string(fromCString: directory.pvi_cdir.vip_path)
            : nil

        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return (cwd, []) }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(listSize) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, listSize)
        guard filled > 0 else { return (cwd, []) }

        let fileSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        let paths = descriptors.prefix(Int(filled) / stride).compactMap { descriptor -> String? in
            guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
            var file = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &file, fileSize) == fileSize else {
                return nil
            }
            return string(fromCString: file.pvip.vip_path)
        }
        return (cwd, paths)
    }

    /// C `char[N]` fields arrive in Swift as tuples.
    private static func string<Tuple>(fromCString tuple: Tuple) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
