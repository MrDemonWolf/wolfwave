//
//  DiscordIPCFramingTests.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-11.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Darwin
import Foundation
import Testing
@testable import WolfWave

/// Discord IPC wire framing, driven through the real handshake transaction over
/// a `socketpair(2)`.
///
/// Frame format: `[opcode: UInt32 LE][length: UInt32 LE][JSON payload]`. The
/// encoder and the frame reader are private to `DiscordRPCService`, so these
/// tests act as the Discord side of the socket: they decode what the service
/// writes and feed it well-formed, split, oversized, truncated, and wrong
/// replies. Nothing here changes service behaviour; it pins it.
@Suite("Discord IPC framing", .timeLimit(.minutes(1)))
struct DiscordIPCFramingTests {

    // MARK: - Round trip

    @Test("Handshake frame encodes a correct header and READY completes it")
    func handshakeRoundTrip() async throws {
        let pair = try FramingSocketPair()
        defer { pair.closePeer() }
        let service = DiscordRPCService(clientID: "framing-client")
        await service.installFramingTestSocket(pair.serviceFD)

        let peerFD = pair.peerFD
        let peer = Task.detached { () throws -> FramingRawFrame in
            let handshake = try framingReadFrame(from: peerFD)
            try framingWrite(
                framingFrame(opcode: .frame, json: ["cmd": "DISPATCH", "evt": "READY"]),
                to: peerFD)
            return handshake
        }

        let succeeded = await service.performHandshake()
        let handshake = try await peer.value
        await service.releaseFramingTestSocket()

        #expect(succeeded)
        #expect(handshake.opcode == DiscordRPCService.Opcode.handshake.rawValue)
        #expect(handshake.declaredLength == UInt32(handshake.payload.count))
        let body = try #require(DiscordRPCService.decodeFramePayload(handshake.payload))
        #expect(body["client_id"] as? String == "framing-client")
        #expect(body["v"] != nil)
    }

    @Test("Two frames in one write are both consumed in order")
    func backToBackFramesInOneWrite() async throws {
        let pair = try FramingSocketPair()
        defer { pair.closePeer() }
        let service = DiscordRPCService(clientID: "test")
        await service.installFramingTestSocket(pair.serviceFD)

        let peerFD = pair.peerFD
        let peer = Task.detached { () throws in
            _ = try framingReadFrame(from: peerFD)
            // An unrelated event, then READY, in a single write(2).
            let unrelated = try framingFrame(
                opcode: .frame, json: ["cmd": "DISPATCH", "evt": "ACTIVITY_JOIN"])
            let ready = try framingFrame(
                opcode: .frame, json: ["cmd": "DISPATCH", "evt": "READY"])
            try framingWrite(unrelated + ready, to: peerFD)
        }

        let succeeded = await service.performHandshake()
        try await peer.value
        let leftover = await service.framingTestBufferedByteCount()
        await service.releaseFramingTestSocket()

        #expect(succeeded)
        #expect(leftover == 0, "Both frames must be fully consumed")
    }

    // MARK: - Partial reads

    @Test("A reply split across header and body reads is reassembled")
    func splitFrameIsReassembled() async throws {
        let pair = try FramingSocketPair()
        defer { pair.closePeer() }
        let service = DiscordRPCService(clientID: "test")
        await service.installFramingTestSocket(pair.serviceFD)

        let peerFD = pair.peerFD
        let peer = Task.detached { () async throws in
            _ = try framingReadFrame(from: peerFD)
            let ready = try framingFrame(
                opcode: .frame, json: ["cmd": "DISPATCH", "evt": "READY"])
            // Mid-header, end of header, mid-body, rest of body.
            let cuts = [0, 3, 8, 8 + (ready.count - 8) / 2, ready.count]
            for index in 0..<(cuts.count - 1) {
                try framingWrite(ready.subdata(in: cuts[index]..<cuts[index + 1]), to: peerFD)
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        let succeeded = await service.performHandshake()
        try await peer.value
        await service.releaseFramingTestSocket()

        #expect(succeeded)
    }

    @Test("A header that never finishes arriving times out")
    func truncatedHeaderTimesOut() async throws {
        let pair = try FramingSocketPair()
        defer { pair.closePeer() }
        let service = DiscordRPCService(
            clientID: "test",
            ipcTransactionTimeoutNanoseconds: 250_000_000)
        await service.installFramingTestSocket(pair.serviceFD)

        let peerFD = pair.peerFD
        let peer = Task.detached { () throws in
            _ = try framingReadFrame(from: peerFD)
            let ready = try framingFrame(
                opcode: .frame, json: ["cmd": "DISPATCH", "evt": "READY"])
            try framingWrite(ready.prefix(4), to: peerFD)
        }

        let clock = ContinuousClock()
        let started = clock.now
        let succeeded = await service.performHandshake()
        let elapsed = clock.now - started
        try await peer.value
        await service.releaseFramingTestSocket()

        #expect(!succeeded)
        #expect(elapsed < .seconds(2), "The transaction deadline must bound a stalled header")
    }

    // MARK: - Malformed frames

    @Test("An oversized length header is rejected without waiting for its body")
    func oversizedHeaderRejected() async throws {
        let pair = try FramingSocketPair()
        defer { pair.closePeer() }
        let service = DiscordRPCService(
            clientID: "test",
            ipcTransactionTimeoutNanoseconds: 5_000_000_000)
        await service.installFramingTestSocket(pair.serviceFD)

        let peerFD = pair.peerFD
        let peer = Task.detached { () throws in
            _ = try framingReadFrame(from: peerFD)
            try framingWrite(
                framingHeader(
                    opcode: DiscordRPCService.Opcode.frame.rawValue,
                    length: AppConstants.Discord.maxIPCFrameBytes),
                to: peerFD)
        }

        let clock = ContinuousClock()
        let started = clock.now
        let succeeded = await service.performHandshake()
        let elapsed = clock.now - started
        try await peer.value
        let leftover = await service.framingTestBufferedByteCount()
        await service.releaseFramingTestSocket()

        #expect(!succeeded)
        #expect(elapsed < .seconds(2), "Rejection must not wait out the 5 s deadline")
        #expect(leftover == 0, "A rejected header must not stay buffered")
    }

    @Test("A non-READY reply followed by CLOSE fails the handshake")
    func nonReadyHandshakeFails() async throws {
        let pair = try FramingSocketPair()
        defer { pair.closePeer() }
        let service = DiscordRPCService(
            clientID: "test",
            ipcTransactionTimeoutNanoseconds: 5_000_000_000)
        await service.installFramingTestSocket(pair.serviceFD)

        let peerFD = pair.peerFD
        let peer = Task.detached { () throws in
            _ = try framingReadFrame(from: peerFD)
            let error = try framingFrame(
                opcode: .frame,
                json: ["cmd": "DISPATCH", "evt": "ERROR", "data": ["code": 4000]])
            let close = try framingFrame(opcode: .close, json: ["code": 4000])
            try framingWrite(error + close, to: peerFD)
        }

        let clock = ContinuousClock()
        let started = clock.now
        let succeeded = await service.performHandshake()
        let elapsed = clock.now - started
        try await peer.value
        await service.releaseFramingTestSocket()

        #expect(!succeeded)
        #expect(elapsed < .seconds(2), "CLOSE must end the transaction, not the deadline")
    }
}

// MARK: - Service seams

private extension DiscordRPCService {
    /// Adopts `descriptor` as a handshaking connection without opening a real socket.
    func installFramingTestSocket(_ descriptor: Int32) {
        socketFD = descriptor
        ipcReadBuffer = IPCReadBuffer()
        isEnabled = true
        state = .connecting
    }

    /// Bytes still buffered after a transaction. The transaction has finished on
    /// the IPC queue by the time `performHandshake()` returns, so reading here
    /// cannot race it.
    func framingTestBufferedByteCount() -> Int {
        ipcReadBuffer.data.count
    }

    /// Closes the service side and leaves the service disabled.
    func releaseFramingTestSocket() async {
        await disconnect()
        isEnabled = false
    }
}

// MARK: - Peer helpers

/// A connected `AF_UNIX` stream pair. The service owns `serviceFD` (closed by
/// `disconnect()`); the test owns `peerFD`.
private nonisolated struct FramingSocketPair: Sendable {
    let serviceFD: Int32
    let peerFD: Int32

    init() throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0,
              sockets[0] >= 0, sockets[1] >= 0 else {
            throw FramingTestError.socket(errno)
        }
        serviceFD = sockets[0]
        peerFD = sockets[1]
        for socket in sockets {
            guard framingConfigureSocket(socket) else {
                Darwin.close(sockets[0])
                Darwin.close(sockets[1])
                throw FramingTestError.socket(errno)
            }
        }
    }

    func closePeer() {
        Darwin.close(peerFD)
    }
}

private nonisolated enum FramingTestError: Error, Sendable {
    case socket(Int32)
    case readFailed(Int32)
    case writeFailed(Int32)
    case invalidPayload
}

private nonisolated struct FramingRawFrame: Sendable {
    let opcode: UInt32
    let declaredLength: UInt32
    let payload: Data
}

/// One-second send/receive timeouts so a broken peer fails the test instead of
/// hanging it, plus `SO_NOSIGPIPE` so a closed service side cannot kill the host.
private nonisolated func framingConfigureSocket(_ descriptor: Int32) -> Bool {
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    var noSigPipe: Int32 = 1
    let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
    return setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
        && setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0
        && setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0
}

private nonisolated func framingHeader(opcode: UInt32, length: UInt32) -> Data {
    var header = Data(count: 8)
    header.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(of: opcode.littleEndian, toByteOffset: 0, as: UInt32.self)
        bytes.storeBytes(of: length.littleEndian, toByteOffset: 4, as: UInt32.self)
    }
    return header
}

private nonisolated func framingFrame(
    opcode: DiscordRPCService.Opcode,
    json: [String: Any]
) throws -> Data {
    guard let body = JSONObjectSerialization.data(from: json),
          let length = UInt32(exactly: body.count) else {
        throw FramingTestError.invalidPayload
    }
    return framingHeader(opcode: opcode.rawValue, length: length) + body
}

private nonisolated func framingReadFrame(from descriptor: Int32) throws -> FramingRawFrame {
    let header = try framingReadExactly(8, from: descriptor)
    let opcode = header.withUnsafeBytes { bytes in
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
    }
    let length = header.withUnsafeBytes { bytes in
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
    }
    return FramingRawFrame(
        opcode: opcode,
        declaredLength: length,
        payload: try framingReadExactly(Int(length), from: descriptor))
}

private nonisolated func framingReadExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let result = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.read(descriptor, baseAddress.advanced(by: offset), count - offset)
        }
        if result > 0 {
            offset += result
        } else if result < 0, errno == EINTR {
            continue
        } else {
            throw FramingTestError.readFailed(result < 0 ? errno : 0)
        }
    }
    return data
}

private nonisolated func framingWrite(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            throw FramingTestError.writeFailed(0)
        }
        var offset = 0
        while offset < data.count {
            let result = Darwin.write(descriptor, baseAddress.advanced(by: offset), data.count - offset)
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw FramingTestError.writeFailed(result < 0 ? errno : 0)
            }
        }
    }
}
