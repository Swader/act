import Foundation

enum HelperClient {
    /// Streams snapshots from the helper on a dedicated thread. Sends nil while disconnected, and reconnects on its own.
    static func start(onUpdate: @escaping @Sendable (Snapshot?) -> Void) {
        let thread = Thread { run(onUpdate) }
        thread.name = "HelperClient"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static func run(_ onUpdate: @Sendable (Snapshot?) -> Void) -> Never {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd >= 0, withHelperSocketAddress({ connect(fd, $0, $1) }) == 0 {
                var pending: [UInt8] = []
                while pending.count < 1 << 20 {
                    let count = read(fd, &chunk, chunk.count)
                    guard count > 0 else { break }
                    pending.append(contentsOf: chunk[..<count])
                    while let end = frameEnd(in: pending) {
                        if let snapshot = Snapshot(frame: Substring(decoding: pending[..<end], as: UTF8.self)) {
                            onUpdate(snapshot)
                        }
                        pending.removeSubrange(..<(end + 2))
                    }
                }
            }
            if fd >= 0 { close(fd) }
            onUpdate(nil)
            sleep(2)
        }
    }

    private static func frameEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        let newline = UInt8(ascii: "\n")
        return (0..<(bytes.count - 1)).first { bytes[$0] == newline && bytes[$0 + 1] == newline }
    }
}
