import Foundation

/// One monitor's DDC/CI channel: raw I2C writes and reads at the DDC address.
public protocol DDCTransport: AnyObject {
    func write(_ bytes: [UInt8]) -> Bool
    func read(count: Int) -> [UInt8]?
}

public enum DDCError: LocalizedError, Equatable {
    case noReply
    case unsupported(UInt8)
    case notConfirmed(expected: UInt8, actual: UInt8)

    public var errorDescription: String? {
        switch self {
        case .noReply: return "The monitor didn't answer over DDC. Check that DDC/CI is on in the monitor's menu."
        case .unsupported(let code): return String(format: "The monitor doesn't support DDC setting 0x%02X.", code)
        case .notConfirmed(let expected, let actual):
            return
                "The monitor reported \(DDC.inputName(actual)) instead of \(DDC.inputName(expected)) after switching."
        }
    }
}

/// MCCS commands over a DDCTransport. Timing follows the pattern proven on Apple Silicon (MonitorControl's):
/// send each request twice 10 ms apart, read after 50 ms, retry after 20 ms. "6E 80 BE" replies mean "not ready".
public struct DDC {
    public static let inputSource: UInt8 = 0x60
    static let hostAddress: UInt8 = 0x51
    static let displayAddress: UInt8 = 0x6E
    static let replyChecksumSeed: UInt8 = 0x50

    private let transport: DDCTransport
    private let sleep: (UInt32) -> Void
    private let attempts: Int

    public init(transport: DDCTransport, attempts: Int = 5, sleep: @escaping (UInt32) -> Void = { usleep($0) }) {
        self.transport = transport
        self.attempts = attempts
        self.sleep = sleep
    }

    // MARK: Packets

    static func checksum(_ bytes: ArraySlice<UInt8>, seed: UInt8) -> UInt8 { bytes.reduce(seed, ^) }

    public static func getPacket(_ code: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, code, 0]
        packet[3] = checksum(packet[0..<3], seed: displayAddress ^ hostAddress)
        return packet
    }

    public static func setPacket(_ code: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(packet[0..<5], seed: displayAddress ^ hostAddress)
        return packet
    }

    public static func capabilitiesPacket(offset: Int) -> [UInt8] {
        var packet: [UInt8] = [0x83, 0xF3, UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF), 0]
        packet[4] = checksum(packet[0..<4], seed: displayAddress ^ hostAddress)
        return packet
    }

    public enum Reply: Equatable {
        case value(current: Int, maximum: Int)
        case notReady
        case unsupported
        case invalid
    }

    /// Parses a Get VCP Feature reply: 6E 88 02 result code type maxH maxL curH curL checksum.
    public static func parseGetReply(_ reply: [UInt8], code: UInt8) -> Reply {
        guard reply.count >= 11 else { return .invalid }
        if reply[1] == 0x80 { return .notReady }
        guard reply[2] == 0x02, reply[4] == code else { return .invalid }
        guard checksum(reply[0..<10], seed: replyChecksumSeed) == reply[10] else { return .invalid }
        guard reply[3] == 0x00 else { return .unsupported }
        return .value(current: Int(reply[8]) << 8 | Int(reply[9]), maximum: Int(reply[6]) << 8 | Int(reply[7]))
    }

    // MARK: Commands

    private func send(_ packet: [UInt8]) -> Bool {
        var ok = false
        for _ in 0..<2 {
            sleep(10_000)
            ok = transport.write(packet)
        }
        return ok
    }

    public func get(_ code: UInt8) throws -> (current: Int, maximum: Int) {
        for attempt in 0..<attempts {
            if attempt > 0 { sleep(20_000) }
            guard send(Self.getPacket(code)) else { continue }
            sleep(50_000)
            guard let reply = transport.read(count: 12) else { continue }
            switch Self.parseGetReply(reply, code: code) {
            case .value(let current, let maximum): return (current, maximum)
            case .unsupported: throw DDCError.unsupported(code)
            case .notReady, .invalid: continue
            }
        }
        throw DDCError.noReply
    }

    public func set(_ code: UInt8, value: UInt16) throws {
        guard send(Self.setPacket(code, value: value)) else { throw DDCError.noReply }
    }

    /// Reads the capabilities string in 32-byte fragments (reply opcode E3) until an empty fragment.
    public func capabilities() throws -> String {
        var text: [UInt8] = []
        var offset = 0
        while offset < 4096 {
            guard let fragment = capabilityFragment(at: offset) else {
                if text.isEmpty { throw DDCError.noReply }
                break
            }
            if fragment.isEmpty { break }
            text += fragment.filter { $0 != 0 }
            offset += fragment.count
        }
        return String(decoding: text, as: UTF8.self)
    }

    private func capabilityFragment(at offset: Int) -> [UInt8]? {
        for attempt in 0..<attempts {
            if attempt > 0 { sleep(20_000) }
            guard send(Self.capabilitiesPacket(offset: offset)) else { continue }
            sleep(50_000)
            guard let reply = transport.read(count: 38), reply.count >= 6 else { continue }
            let length = Int(reply[1] & 0x7F)  // opcode + 2 offset bytes + data
            guard reply[1] != 0x80, reply[2] == 0xE3, (3...35).contains(length), reply.count > 2 + length else {
                continue
            }
            guard Int(reply[3]) << 8 | Int(reply[4]) == offset else { continue }
            guard Self.checksum(reply[0..<(2 + length)], seed: Self.replyChecksumSeed) == reply[2 + length] else {
                continue
            }
            return Array(reply[5..<(2 + length)])
        }
        return nil
    }

    // MARK: Inputs

    /// Valid input-source codes from a capabilities string's "60(...)" group, in the monitor's order.
    public static func inputs(fromCapabilities capabilities: String) -> [UInt8] {
        guard let range = capabilities.range(of: #"(?<![0-9A-Fa-f])60\(([0-9A-Fa-f ]+)\)"#, options: .regularExpression)
        else { return [] }
        let list = capabilities[range].dropFirst(3).dropLast()
        return list.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    public static func inputName(_ code: UInt8) -> String {
        switch code {
        case 0x01, 0x02: return "VGA"
        case 0x03, 0x04: return "DVI"
        case 0x0F: return "DisplayPort"
        case 0x10: return "DisplayPort 2"
        case 0x11: return "HDMI"
        case 0x12: return "HDMI 2"
        case 0x1B: return "USB-C"
        default: return String(format: "Input 0x%02X", code)
        }
    }

    public func currentInput() throws -> UInt8 { UInt8(truncatingIfNeeded: try get(Self.inputSource).current) }

    /// Switches input and reads it back for up to ~1.2 s. A monitor that stops answering counts as switched (some
    /// ignore DDC on an input they aren't showing); one that keeps reporting a different input is an error.
    public func switchInput(to input: UInt8) throws {
        try set(Self.inputSource, value: UInt16(input))
        var lastSeen: UInt8?
        for _ in 0..<4 {
            sleep(300_000)
            guard let actual = try? currentInput() else { continue }
            if actual == input { return }
            lastSeen = actual
        }
        if let lastSeen { throw DDCError.notConfirmed(expected: input, actual: lastSeen) }
    }
}
