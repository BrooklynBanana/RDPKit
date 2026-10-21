import Foundation

enum RDPStaticVirtualChannelFlags {
    static let first: UInt32 = 0x0000_0001
    static let last: UInt32 = 0x0000_0002
    static let showProtocol: UInt32 = 0x0000_0010
    static let suspend: UInt32 = 0x0000_0020
    static let resume: UInt32 = 0x0000_0040
    static let compressed: UInt32 = 0x0020_0000
    static let atFront: UInt32 = 0x0040_0000
    static let flushed: UInt32 = 0x0080_0000
    static let compressionTypeMask: UInt32 = 0x000F_0000
    static let complete: UInt32 = first | last
    static let completeWithShowProtocol: UInt32 = complete | showProtocol
    static let compressionFlags: UInt32 = compressed | atFront | flushed | compressionTypeMask
    static let shadowPersistent: UInt32 = 0x0000_0080
    static let supportedMask: UInt32 = complete
        | showProtocol
        | suspend
        | resume
        | shadowPersistent
        | compressionFlags
}

struct RDPStaticVirtualChannelPDU: Equatable, Sendable {
    static let headerByteCount = 8
    static let defaultChunkByteCount = 1_600
    static let maximumNegotiatedChunkByteCount = 16_256
    static let maximumPayloadByteCount = min(
        defaultChunkByteCount,
        MCSSendDataRequestPDU.maximumUserDataByteCount - headerByteCount
    )

    var totalLength: UInt32
    var flags: UInt32
    var payload: Data

    init(
        payload: Data,
        flags: UInt32 = RDPStaticVirtualChannelFlags.complete
    ) {
        precondition(payload.count <= Int(UInt32.max))
        precondition(payload.count <= Self.maximumPayloadByteCount)

        totalLength = UInt32(payload.count)
        self.flags = flags
        self.payload = payload
    }

    var isComplete: Bool {
        flags & RDPStaticVirtualChannelFlags.first != 0
            && flags & RDPStaticVirtualChannelFlags.last != 0
            && totalLength == payload.count
    }

    var isStandalone: Bool {
        flags & RDPStaticVirtualChannelFlags.first == 0
            && flags & RDPStaticVirtualChannelFlags.last == 0
            && totalLength == payload.count
            && !isFlowControl
    }

    var canDispatchPayload: Bool {
        isComplete || isStandalone
    }

    var isFlowControl: Bool {
        let flowControlFlags = RDPStaticVirtualChannelFlags.suspend | RDPStaticVirtualChannelFlags.resume
        return flags & flowControlFlags != 0
    }

    static func canEncodeSinglePayload(_ payload: Data) -> Bool {
        payload.count <= maximumPayloadByteCount
    }

    func encodedUserData() -> Data {
        var data = Data()
        data.appendLittleEndianUInt32(totalLength)
        data.appendLittleEndianUInt32(flags)
        data.append(payload)
        return data
    }

    func encodedTPKT(initiator: UInt16, channelID: UInt16) -> Data {
        MCSSendDataRequestPDU(
            initiator: initiator,
            channelID: channelID,
            userData: encodedUserData()
        ).encodedTPKT()
    }

    static func parseIfPresent(
        fromTPKT packet: Data,
        channelID expectedChannelID: UInt16,
        maximumChunkByteCount: Int = maximumPayloadByteCount
    ) throws -> RDPStaticVirtualChannelPDU? {
        guard let indication = try? MCSSendDataIndicationPDU.parse(fromTPKT: packet) else {
            return nil
        }
        guard indication.channelID == expectedChannelID else {
            return nil
        }
        return try parse(
            fromUserData: indication.userData,
            maximumChunkByteCount: maximumChunkByteCount
        )
    }

    static func parse(
        fromUserData userData: Data,
        maximumChunkByteCount: Int = maximumPayloadByteCount
    ) throws -> RDPStaticVirtualChannelPDU {
        guard userData.count >= 8 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        guard isValidChunkByteCount(maximumChunkByteCount) else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        var cursor = ByteCursor(userData)
        let totalLength = try cursor.readLittleEndianUInt32()
        let flags = try cursor.readLittleEndianUInt32()
        let payload = cursor.readRemainingData()
        guard flags & ~RDPStaticVirtualChannelFlags.supportedMask == 0 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        guard flags & RDPStaticVirtualChannelFlags.compressionFlags == 0 else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        guard payload.count <= maximumChunkByteCount else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        guard payload.count <= Int(UInt32.max), totalLength >= UInt32(payload.count) else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        let hasFirst = flags & RDPStaticVirtualChannelFlags.first != 0
        let hasLast = flags & RDPStaticVirtualChannelFlags.last != 0
        let hasShowProtocol = flags & RDPStaticVirtualChannelFlags.showProtocol != 0
        let flowControlFlags = RDPStaticVirtualChannelFlags.suspend | RDPStaticVirtualChannelFlags.resume
        let flowControl = flags & flowControlFlags
        let isFlowControl = flowControl != 0
        if isFlowControl {
            let validFlowControlMask = flowControlFlags | RDPStaticVirtualChannelFlags.shadowPersistent
            guard (flowControl == RDPStaticVirtualChannelFlags.suspend
                || flowControl == RDPStaticVirtualChannelFlags.resume),
                flags & ~validFlowControlMask == 0,
                totalLength == 0,
                payload.isEmpty
            else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
        }
        if hasFirst && hasLast {
            guard totalLength == UInt32(payload.count) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
        } else if isFlowControl {
            guard totalLength == 0, payload.isEmpty else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
        }
        // Chunks of a larger message: CHANNEL_FLAG_SHOW_PROTOCOL is only present when the channel was opened with
        // CHANNEL_OPTION_SHOW_PROTOCOL – Windows sends clipboard chunks without it (first 0x1, middle 0x0, last 0x2).
        _ = hasShowProtocol

        return RDPStaticVirtualChannelPDU(
            totalLength: totalLength,
            flags: flags,
            payload: payload
        )
    }

    /// Splits a message into channel chunks of at most `maximumPayloadByteCount` bytes (CHANNEL_FLAG_FIRST/LAST,
    /// MS-RDPBCGR 3.1.5.2.1); every chunk carries the total length. A message that fits stays a single PDU.
    static func chunks(for payload: Data, flags extraFlags: UInt32 = 0) -> [RDPStaticVirtualChannelPDU] {
        precondition(payload.count <= Int(UInt32.max))
        let totalLength = UInt32(payload.count)
        var chunks: [RDPStaticVirtualChannelPDU] = []
        var offset = payload.startIndex
        repeat {
            let end = payload.index(offset, offsetBy: maximumPayloadByteCount, limitedBy: payload.endIndex)
                ?? payload.endIndex
            var flags = extraFlags
            if offset == payload.startIndex { flags |= RDPStaticVirtualChannelFlags.first }
            if end == payload.endIndex { flags |= RDPStaticVirtualChannelFlags.last }
            chunks.append(RDPStaticVirtualChannelPDU(totalLength: totalLength, flags: flags,
                                                     payload: Data(payload[offset ..< end])))
            offset = end
        } while offset < payload.endIndex
        return chunks
    }

    fileprivate init(totalLength: UInt32, flags: UInt32, payload: Data) {
        self.totalLength = totalLength
        self.flags = flags
        self.payload = payload
    }

    private static func isValidChunkByteCount(_ byteCount: Int) -> Bool {
        byteCount >= defaultChunkByteCount
            && byteCount <= maximumNegotiatedChunkByteCount
            && byteCount <= MCSSendDataRequestPDU.maximumUserDataByteCount - headerByteCount
    }
}

struct RDPStaticVirtualChannelReassembler: Sendable {
    private var totalLength: UInt32?
    private var payload = Data()

    mutating func append(
        _ pdu: RDPStaticVirtualChannelPDU,
        maximumChunkByteCount: Int = RDPStaticVirtualChannelPDU.maximumPayloadByteCount
    ) throws -> RDPStaticVirtualChannelPDU? {
        guard pdu.payload.count <= maximumChunkByteCount else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }
        if pdu.isFlowControl {
            return nil
        }
        let hasFirst = pdu.flags & RDPStaticVirtualChannelFlags.first != 0
        let hasLast = pdu.flags & RDPStaticVirtualChannelFlags.last != 0
        // While a message is being collected, chunks without CHANNEL_FLAG_FIRST continue it (middle chunks carry no
        // flags at all); otherwise a chunk without FIRST/LAST that holds the whole message stands alone.
        let continuesMessage = totalLength != nil && !hasFirst
        if !continuesMessage, pdu.isComplete || pdu.isStandalone {
            guard totalLength == nil else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            return pdu
        }

        if hasFirst {
            guard totalLength == nil, pdu.totalLength >= UInt32(pdu.payload.count) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            totalLength = pdu.totalLength
            payload = pdu.payload
        } else {
            guard let expectedTotalLength = totalLength,
                  pdu.totalLength == expectedTotalLength else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            payload.append(pdu.payload)
        }

        guard let expectedTotalLength = totalLength,
              payload.count <= Int(expectedTotalLength) else {
            throw RDPDecodeError.invalidStaticVirtualChannelPDU
        }

        if hasLast {
            guard payload.count == Int(expectedTotalLength) else {
                throw RDPDecodeError.invalidStaticVirtualChannelPDU
            }
            let completePDU = RDPStaticVirtualChannelPDU(
                totalLength: expectedTotalLength,
                flags: RDPStaticVirtualChannelFlags.completeWithShowProtocol,
                payload: payload
            )
            totalLength = nil
            payload = Data()
            return completePDU
        }

        return nil
    }
}
