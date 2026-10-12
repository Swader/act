import Darwin

// Root helper: samples every process once per second and streams per-app totals over a Unix socket.
// It samples only while at least one client is connected.
//
// Frame format (tab-separated lines, frame ends with an empty line):
//   T  <total CPU, tenths of a percent>  <memory used, bytes>  <memory total, bytes>  <logical cores>
//      <data held compressed, bytes>  <RAM used by the compressor, bytes>  <swap used, bytes>
//   A  <CPU, tenths of a percent>  <memory footprint, bytes>  <process count>  <app name>
//   P  <CPU, tenths of a percent>  <memory footprint, bytes>  <pid>  <process name>   (top processes of the A above)
// 100% CPU is one full core, as in Activity Monitor. Footprints count compressed and swapped memory
// at full size, as Activity Monitor does, so app totals can exceed physical RAM.

let intervalNanos: UInt64 = 1_000_000_000
let appsPerRanking = 25
let processesPerRanking = 10
let maxClients = 8
let renameCheckInterval: UInt64 = 30

typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
let responsiblePID: ResponsibleFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: ResponsibleFunction.self) }

final class AppGroup {
    let name: String
    var cpu: UInt64 = 0
    var memory: UInt64 = 0
    var processes = 0
    /// Processes seen in the current sample. Cleared at the start of each sample.
    var members: [TrackedProcess] = []

    init(name: String) { self.name = name }
}

final class TrackedProcess {
    let pid: pid_t
    let start: UInt64
    let parent: pid_t
    var name: String
    var group: AppGroup
    var cpu: UInt64
    var cpuThisSample: UInt64 = 0
    var memory: UInt64 = 0
    /// CPU of children this process has reaped, which the kernel adds to the parent.
    var childCPU: UInt64
    var reapedThisSample: UInt64 = 0
    /// CPU of dead children that was already counted directly, not yet matched by `childCPU` growth.
    var credit: UInt64 = 0
    var generation: UInt64 = 0
    var settled = false

    init(pid: pid_t, start: UInt64, parent: pid_t, name: String, group: AppGroup, cpu: UInt64, childCPU: UInt64) {
        self.pid = pid
        self.start = start
        self.parent = parent
        self.name = name
        self.group = group
        self.cpu = cpu
        self.childCPU = childCPU
    }
}

struct Identity {
    let app: String?
    let executable: String
}

let appMarker = Array(".app/".utf8)

func cleanName<C: Collection<UInt8>>(_ bytes: C) -> String {
    String(decoding: bytes.map { $0 < 0x20 ? 0x20 : $0 }, as: UTF8.self)
}

func firstIndex(of needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Int? {
    guard haystack.count >= needle.count else { return nil }
    for index in haystack.startIndex...(haystack.endIndex - needle.count)
    where haystack[index..<(index + needle.count)].elementsEqual(needle) {
        return index
    }
    return nil
}

/// The outermost `.app` bundle in the executable path, if any, and the executable name.
func identity(of pid: pid_t) -> Identity? {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
    if length > 0 {
        let path = buffer[..<length]
        let slash = UInt8(ascii: "/")
        let executable = cleanName(path[(path.lastIndex(of: slash).map { $0 + 1 } ?? 0)...])
        guard let marker = firstIndex(of: appMarker, in: path) else { return Identity(app: nil, executable: executable) }
        let start = path[..<marker].lastIndex(of: slash).map { $0 + 1 } ?? 0
        return Identity(app: cleanName(path[start..<marker]), executable: executable)
    }
    var name = [UInt8](repeating: 0, count: 64)
    let nameLength = Int(proc_name(pid, &name, UInt32(name.count)))
    return nameLength > 0 ? Identity(app: nil, executable: cleanName(name[..<nameLength])) : nil
}

func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

func names(for pid: pid_t, info: proc_bsdinfo?) -> (group: String, process: String) {
    // Only a process that has already exited has neither a path nor a name.
    guard let own = identity(of: pid) else { return ("Exited processes", "(exited)") }
    if let app = own.app { return (app, own.executable) }
    // Commands started from a shell count as themselves, not as the terminal app that owns the shell.
    let hasTerminal = (info?.pbi_flags ?? 0) & UInt32(PROC_FLAG_CONTROLT) != 0
    if !hasTerminal,
       let owner = responsiblePID?(pid), owner > 0, owner != pid,
       let ownerIdentity = identity(of: owner) {
        return (ownerIdentity.app ?? ownerIdentity.executable, own.executable)
    }
    return (own.executable, own.executable)
}

/// V1 adds reaped-children CPU to V0. Both cost about half as much as V4, which also gathers per-thread counters.
func readUsage(_ pid: pid_t, into usage: inout rusage_info_v1) -> Bool {
    withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V1, $0) == 0
        }
    }
}

func sysctlInteger<T: FixedWidthInteger>(_ name: String, as type: T.Type) -> T {
    var value: T = 0
    var size = MemoryLayout<T>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : 0
}

final class Sampler {
    private var processes: [pid_t: TrackedProcess] = [:]
    private var groups: [String: AppGroup] = [:]
    private var pids = [pid_t](repeating: 0, count: 4096)
    private var deadPIDs: [pid_t] = []
    private var deadGroups: [String] = []
    private var usage = rusage_info_v1()
    private var generation: UInt64 = 0
    private var lastSample: UInt64 = 0
    private let staleTicks: UInt64
    private let host = mach_host_self()
    private let pageSize = UInt64(getpagesize())
    private let memoryTotal = sysctlInteger("hw.memsize", as: UInt64.self)
    private let cores = Int(sysctlInteger("hw.logicalcpu", as: Int32.self))

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        staleTicks = 3 * intervalNanos * UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    /// Returns nil when there is no recent sample to compare against.
    func sample() -> [UInt8]? {
        let previous = lastSample
        let now = mach_absolute_time()
        lastSample = now
        generation += 1

        var count = listPIDs()
        while count >= pids.count {
            pids = [pid_t](repeating: 0, count: pids.count * 2)
            count = listPIDs()
        }

        for group in groups.values {
            group.cpu = 0
            group.memory = 0
            group.processes = 0
            group.members.removeAll(keepingCapacity: true)
        }

        // The list holds live processes newest first, ending with pid 0, then zombies. Reading parents
        // before children, and zombies last, means a child reaped during the sweep is missing from this
        // sample instead of being counted both on its own and in its parent's reaped CPU.
        let listed = pids[..<max(count, 0)]
        let liveEnd = listed.firstIndex(of: 0).map { $0 + 1 } ?? listed.endIndex
        for pid in listed[..<liveEnd].reversed() { track(pid, previous: previous) }
        for pid in listed[liveEnd...] { track(pid, previous: previous) }

        settleExits()
        pruneGroups()
        guard previous != 0, now - previous < staleTicks else { return nil }
        return frame(elapsed: now - previous)
    }

    private func track(_ pid: pid_t, previous: UInt64) {
        guard readUsage(pid, into: &usage) else { return }
        // rusage CPU times use mach_absolute_time units, so no timebase conversion is needed.
        let cpu = usage.ri_user_time &+ usage.ri_system_time
        let childCPU = usage.ri_child_user_time &+ usage.ri_child_system_time
        let process: TrackedProcess
        var delta: UInt64 = 0
        var reaped: UInt64 = 0
        if let known = processes[pid], known.start == usage.ri_proc_start_abstime {
            process = known
            delta = cpu >= known.cpu ? cpu - known.cpu : 0
            reaped = childCPU >= known.childCPU ? childCPU - known.childCPU : 0
            // The first sighting can land between fork and exec, and a process can exec later, so
            // resolve the name again on the second sighting and then every `renameCheckInterval` samples.
            if !known.settled || (generation &+ UInt64(pid)) % renameCheckInterval == 0 {
                let resolved = names(for: pid, info: bsdInfo(of: pid))
                known.group = group(named: resolved.group)
                known.name = resolved.process
                known.settled = true
            }
        } else {
            let info = bsdInfo(of: pid)
            let resolved = names(for: pid, info: info)
            process = TrackedProcess(
                pid: pid,
                start: usage.ri_proc_start_abstime,
                parent: pid_t(bitPattern: info?.pbi_ppid ?? 0),
                name: resolved.process,
                group: group(named: resolved.group),
                cpu: cpu,
                childCPU: childCPU
            )
            processes[pid] = process
            if previous != 0, usage.ri_proc_start_abstime >= previous {
                delta = cpu
                reaped = childCPU
            }
        }
        process.cpu = cpu
        process.childCPU = childCPU
        // launchd adopts orphans, so its reaped CPU includes processes already counted under their first parent.
        process.reapedThisSample = pid == 1 ? 0 : reaped
        process.generation = generation
        process.cpuThisSample = delta
        process.memory = usage.ri_phys_footprint
        process.group.cpu += delta
        process.group.memory += usage.ri_phys_footprint
        process.group.processes += 1
        process.group.members.append(process)
    }

    private func listPIDs() -> Int {
        Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    }

    private func group(named name: String) -> AppGroup {
        if let group = groups[name] { return group }
        let group = AppGroup(name: name)
        groups[name] = group
        return group
    }

    /// Bills CPU that short-lived processes used between samples to the app of the parent that reaped them.
    /// A parent's reaped CPU grows by each child's whole lifetime, so the part already counted
    /// directly, as of the child's last sample, is subtracted to avoid counting it twice.
    private func settleExits() {
        deadPIDs.removeAll(keepingCapacity: true)
        for (pid, process) in processes where process.generation != generation { deadPIDs.append(pid) }
        // The credit goes to the first live ancestor: a parent that exited in the same interval was
        // itself reaped, so its parent's reaped CPU includes this child too. Entries are removed only
        // after every credit is placed, so each walk can pass through dead ancestors.
        for pid in deadPIDs {
            guard let dead = processes[pid] else { continue }
            var child = dead
            while child.parent != 1, let parent = processes[child.parent], parent.start < child.start {
                if parent.generation == generation {
                    parent.credit += dead.cpu &+ dead.childCPU &+ dead.credit
                    break
                }
                child = parent
            }
        }
        for pid in deadPIDs { processes[pid] = nil }

        for process in processes.values where process.reapedThisSample > 0 {
            let reaped = process.reapedThisSample
            let uncounted = reaped > process.credit ? reaped - process.credit : 0
            process.cpuThisSample += uncounted
            process.group.cpu += uncounted
            process.credit = process.credit > reaped ? process.credit - reaped : 0
            process.reapedThisSample = 0
        }
    }

    private func pruneGroups() {
        deadGroups.removeAll(keepingCapacity: true)
        for (name, group) in groups where group.processes == 0 { deadGroups.append(name) }
        for name in deadGroups { groups[name] = nil }
    }

    private func frame(elapsed: UInt64) -> [UInt8] {
        let all = Array(groups.values)
        let totalCPU = all.reduce(0) { $0 + $1.cpu }
        let memory = memoryStats()
        var text = "T\t\(totalCPU * 1000 / elapsed)\t\(memory.used)\t\(memoryTotal)\t\(cores)\t\(memory.compressed)\t\(memory.compressor)\t\(swapUsed())\n"
        var emitted = Set<ObjectIdentifier>()
        let byCPU = all.sorted { $0.cpu > $1.cpu }.prefix(appsPerRanking)
        let byMemory = all.sorted { $0.memory > $1.memory }.prefix(appsPerRanking)
        for group in byCPU + byMemory where emitted.insert(ObjectIdentifier(group)).inserted {
            text += "A\t\(group.cpu * 1000 / elapsed)\t\(group.memory)\t\(group.processes)\t\(group.name)\n"
            guard group.members.count > 1 else { continue }
            var listed = Set<ObjectIdentifier>()
            let topCPU = group.members.sorted { $0.cpuThisSample > $1.cpuThisSample }.prefix(processesPerRanking)
            let topMemory = group.members.sorted { $0.memory > $1.memory }.prefix(processesPerRanking)
            for process in topCPU + topMemory where listed.insert(ObjectIdentifier(process)).inserted {
                text += "P\t\(process.cpuThisSample * 1000 / elapsed)\t\(process.memory)\t\(process.pid)\t\(process.name)\n"
            }
        }
        text += "\n"
        return Array(text.utf8)
    }

    /// `used` matches Activity Monitor's "Memory Used": app memory + wired + compressed.
    private func memoryStats() -> (used: UInt64, compressed: UInt64, compressor: UInt64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        let appPages = UInt64(max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count)))
        let compressorPages = UInt64(stats.compressor_page_count)
        return (
            (appPages + UInt64(stats.wire_count) + compressorPages) * pageSize,
            UInt64(stats.total_uncompressed_pages_in_compressor) * pageSize,
            compressorPages * pageSize
        )
    }

    private func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : 0
    }
}

func fail(_ message: String) -> Never {
    fputs("act-helper: \(message): \(String(cString: strerror(errno)))\n", stderr)
    exit(1)
}

func setNonBlocking(_ fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
}

/// Discards anything a client sends. Returns false when the client has gone away.
func drain(_ fd: Int32, scratch: inout [UInt8]) -> Bool {
    while true {
        let count = read(fd, &scratch, scratch.count)
        if count > 0 { continue }
        return count < 0 && (errno == EAGAIN || errno == EINTR)
    }
}

func deliver(_ frame: [UInt8], to fd: Int32) -> Bool {
    let sent = frame.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    guard sent == frame.count else {
        close(fd)
        return false
    }
    return true
}

signal(SIGPIPE, SIG_IGN)
pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else { fail("socket") }
unlink(helperSocketPath)
guard withHelperSocketAddress({ bind(listener, $0, $1) }) == 0 else { fail("bind") }
guard chmod(helperSocketPath, 0o666) == 0 else { fail("chmod") }
guard listen(listener, 16) == 0 else { fail("listen") }
setNonBlocking(listener)

let sampler = Sampler()
var clients: [Int32] = []
var nextTick: UInt64 = 0
var scratch = [UInt8](repeating: 0, count: 512)
var sendBuffer: Int32 = 256 * 1024
var enabled: Int32 = 1

while true {
    var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
    fds += clients.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
    let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let timeout = clients.isEmpty ? -1 : Int32((nextTick > now ? nextTick - now + 999_999 : 0) / 1_000_000)
    if poll(&fds, nfds_t(fds.count), timeout) < 0 && errno != EINTR { fail("poll") }

    clients = fds.dropFirst().compactMap { entry in
        if entry.revents == 0 || drain(entry.fd, scratch: &scratch) { return entry.fd }
        close(entry.fd)
        return nil
    }

    if fds[0].revents != 0 {
        while case let fd = accept(listener, nil, nil), fd >= 0 {
            guard clients.count < maxClients else {
                close(fd)
                continue
            }
            setNonBlocking(fd)
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
            clients.append(fd)
        }
    }

    guard !clients.isEmpty else {
        nextTick = 0
        continue
    }
    let current = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    guard current >= nextTick else { continue }
    if let frame = sampler.sample() {
        clients = clients.filter { deliver(frame, to: $0) }
    }
    nextTick = nextTick == 0 || current - nextTick > intervalNanos ? current + intervalNanos : nextTick + intervalNanos
}
