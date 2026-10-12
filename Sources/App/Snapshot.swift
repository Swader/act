struct ProcessUsage: Sendable {
    let name: String
    let pid: Int
    let cpuTenths: Int
    let memory: UInt64
}

struct AppUsage: Sendable {
    let name: String
    let cpuTenths: Int
    let memory: UInt64
    let processCount: Int
    var topProcesses: [ProcessUsage] = []
}

struct Snapshot: Sendable {
    let cpuTenths: Int
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let cores: Int
    let compressedData: UInt64
    let compressorMemory: UInt64
    let swapUsed: UInt64
    let apps: [AppUsage]

    /// Parses one helper frame. See the format in `Sources/Helper/main.swift`.
    init?(frame: Substring) {
        var totals: [Substring] = []
        var apps: [AppUsage] = []
        for line in frame.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: line.hasPrefix("T") ? 7 : 4, omittingEmptySubsequences: false)
            switch fields.first {
            case "T" where fields.count == 8:
                totals = fields
            case "A" where fields.count == 5:
                if let cpu = Int(fields[1]), let memory = UInt64(fields[2]), let count = Int(fields[3]) {
                    apps.append(AppUsage(name: String(fields[4]), cpuTenths: cpu, memory: memory, processCount: count))
                }
            case "P" where fields.count == 5 && !apps.isEmpty:
                if let cpu = Int(fields[1]), let memory = UInt64(fields[2]), let pid = Int(fields[3]) {
                    apps[apps.count - 1].topProcesses.append(ProcessUsage(name: String(fields[4]), pid: pid, cpuTenths: cpu, memory: memory))
                }
            default:
                continue
            }
        }
        let numbers = totals.dropFirst().compactMap { UInt64($0) }
        guard numbers.count == 7 else { return nil }
        cpuTenths = Int(numbers[0])
        memoryUsed = numbers[1]
        memoryTotal = numbers[2]
        cores = Int(numbers[3])
        compressedData = numbers[4]
        compressorMemory = numbers[5]
        swapUsed = numbers[6]
        self.apps = apps
    }
}
