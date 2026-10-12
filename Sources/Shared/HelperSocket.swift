import Darwin

let helperSocketPath = "/var/run/com.brunoskvorc.act.helper.sock"

func withHelperSocketAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = Array(helperSocketPath.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}
