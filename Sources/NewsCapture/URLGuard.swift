import Foundation

/// Only public http(s) pages may be captured: no file://, no localhost, no addresses on the local network.
/// Applied to the pasted link, every redirect, and every image a page points at, because all of those are untrusted.
public enum URLGuard {
    public enum Rejection: LocalizedError, Equatable {
        case notWeb, localAddress
        public var errorDescription: String? {
            switch self {
            case .notWeb: return "只支持 http/https 链接"
            case .localAddress: return "不能保存本机或局域网地址"
            }
        }
    }

    /// Checks the scheme and the host as written. Does not touch the network.
    public static func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw Rejection.notWeb }
        guard var host = url.host?.lowercased(), !host.isEmpty else { throw Rejection.notWeb }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || !host.contains(".") && !host.contains(":") {
            throw Rejection.localAddress
        }
        if isPrivate(host) { throw Rejection.localAddress }
    }

    /// Also resolves the name, so a public-looking name that points into the LAN is refused. Blocking: call off the main thread.
    public static func checkResolved(_ url: URL) throws {
        try check(url)
        guard let host = url.host else { return }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { return } // an unknown name fails later, as a load error
        defer { freeaddrinfo(list) }
        var cur = list
        while let a = cur {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0,
               isPrivate(String(cString: buf)) {
                throw Rejection.localAddress
            }
            cur = a.pointee.ai_next
        }
    }

    /// Whether a numeric address is loopback, private, link-local or otherwise not on the public internet.
    /// Non-numeric hosts return false. inet_aton also catches spellings such as 127.1, 0x7f.0.0.1 and 2130706433.
    public static func isPrivate(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: "%").first.map(String.init) ?? rawHost
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return privateV4(b[12], b[13], b[14], b[15]) }
            if b[0..<15].allSatisfy({ $0 == 0 }) { return true } // :: and ::1
            if b[0] & 0xfe == 0xfc { return true } // fc00::/7
            if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return true } // fe80::/10
            return false
        }
        var v4 = in_addr()
        if inet_aton(host, &v4) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) }
            return privateV4(b[0], b[1], b[2], b[3])
        }
        return false
    }

    private static func privateV4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
        switch a {
        case 0, 10, 127: return true
        case 100: return (64...127).contains(b)
        case 169: return b == 254
        case 172: return (16...31).contains(b)
        case 192: return b == 168 || (b == 0 && c == 0)
        case 198: return b == 18 || b == 19
        case 224...255: return true
        default: return false
        }
    }
}
