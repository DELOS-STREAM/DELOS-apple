import Darwin
import Foundation
import Network
import Synchronization

/// Wake-on-LAN as Moonlight sends it: the magic packet to every known address of the PC and to the IPv4 broadcast
/// address, each on port 9, port 47009 (Moonlight Internet Hosting Tool) and the GameStream ports shifted by the
/// PC's HTTP port.
public enum WakeOnLan {
    /// 6 × 0xFF, then the MAC address 16 times (102 bytes). Nil when `macAddress` is not six hexadecimal bytes
    /// separated by `:` or `-`, or is all zero (hosts that do not know their MAC send zeros).
    public static func magicPacket(macAddress: String) -> Data? {
        let parts = macAddress.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 }),
              let mac = Hex.decode(parts.joined()), mac.contains(where: { $0 != 0 })
        else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(mac) }
        return packet
    }

    /// The destination ports for a PC whose HTTP port is `httpPort`: 9 and 47009, then 47998, 47999, 48000, 48002
    /// and 48010 moved by `httpPort - 47989`.
    public static func ports(httpPort: Int) -> [UInt16] {
        let shifted = [47998, 47999, 48000, 48002, 48010].map { $0 - HostAddress.defaultHTTPPort + httpPort }
        return [9, 47009] + shifted.filter { (1...65535).contains($0) }.map { UInt16($0) }
    }

    /// Sends the magic packet to `addresses` (each with its own port set) and, with `broadcast`, to 255.255.255.255.
    /// Returns how many datagrams were handed to the network; it cannot know whether the PC woke.
    @discardableResult
    public static func wake(macAddress: String, addresses: [HostAddress], broadcast: Bool = true) async -> Int {
        guard let packet = magicPacket(macAddress: macAddress) else { return 0 }
        var sent = 0
        for address in addresses {
            for port in ports(httpPort: address.port) {
                if await send(packet, to: address.host, port: port) { sent += 1 }
            }
        }
        if broadcast {
            for port in ports(httpPort: HostAddress.defaultHTTPPort) {
                if sendBroadcast(packet, port: port) { sent += 1 }
            }
        }
        return sent
    }

    private static func send(_ packet: Data, to host: String, port: UInt16) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        defer { connection.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceBool(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: packet, completion: .contentProcessed { once.resume($0 == nil) })
                case .failed, .waiting, .cancelled:
                    once.resume(false)
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }

    /// Network.framework cannot send to a broadcast address, so this one datagram goes through a BSD socket with
    /// `SO_BROADCAST`. On iOS it needs the multicast networking entitlement; without it the system refuses it.
    private static func sendBroadcast(_ packet: Data, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32.max
        let result = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result == packet.count
    }
}

private final class OnceBool: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: Bool) {
        continuation.withLock { stored in
            stored?.resume(returning: value)
            stored = nil
        }
    }
}
