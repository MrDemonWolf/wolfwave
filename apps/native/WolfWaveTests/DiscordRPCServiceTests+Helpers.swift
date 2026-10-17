//
//  DiscordRPCServiceTests+Helpers.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Darwin
import XCTest

@testable import WolfWave

/// Test seams that adopt a test socket descriptor as the live connection.
extension DiscordRPCService {
    /// Adopts `fd` as the live connection. `connected: false` leaves the handshake pending,
    /// `supersedingConnection` bumps the connection generation, and `presenceInterval` sets the
    /// minimum interval between presence frames
    /// (`presenceMinimumInterval`). Leaves the state `.connecting` when `connected` is false.
    func installTestSocket(
        _ fd: Int32,
        connected: Bool = true,
        supersedingConnection: Bool = false,
        presenceInterval: TimeInterval = 0
    ) {
        if supersedingConnection { connectionGeneration &+= 1 }
        socketFD = fd
        ipcReadBuffer = IPCReadBuffer()
        isEnabled = true
        presenceMinimumInterval = presenceInterval
        state = connected ? .connected : .connecting
    }

    /// Enables the service and resets it to `.disconnected` so `connectIfNeeded()` runs.
    func prepareTestConnect() {
        isEnabled = true
        state = .disconnected
    }

    func prepareTestConnect(waitingFor close: IPCDescriptorClose) {
        isEnabled = true
        state = .disconnected
        ipcCloseInProgress = close
    }

    /// Sets the enabled flag directly, skipping the side effects of `setEnabled(_:)`.
    func setEnabledForTesting(_ enabled: Bool) {
        isEnabled = enabled
    }

    /// Disconnects and leaves the service disabled, closing the adopted descriptor.
    func releaseTestSocket() async {
        await disconnect()
        isEnabled = false
    }

    /// Whether a descriptor close is still pending.
    func hasTestCloseInProgress() -> Bool {
        ipcCloseInProgress != nil
    }
}

/// What `DiscordGatedSocketCloser` observed: close count, the original and reused descriptor
/// numbers, the peer, and any setup errno.
nonisolated struct DiscordGatedCloseSnapshot: Sendable {
    let closeCount: Int
    let originalFD: Int32
    let reusedFD: Int32
    let peerFD: Int32
    let setupErrno: Int32
}

/// Closes the source-owned descriptor, deliberately reuses its integer for a
/// fresh socket, then gates the cancel handler before it can signal completion.
nonisolated final class DiscordGatedSocketCloser: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var closeCount = 0
    private var originalFD: Int32 = -1
    private var reusedFD: Int32 = -1
    private var peerFD: Int32 = -1
    private var setupErrno: Int32 = 0

    func closeAndReuse(_ fd: Int32) {
        lock.lock()
        closeCount += 1
        originalFD = fd
        lock.unlock()

        Darwin.close(fd)
        var replacement = [Int32](repeating: -1, count: 2)
        let socketResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &replacement)
        var nextReusedFD: Int32 = -1
        var nextPeerFD: Int32 = -1
        var nextErrno: Int32 = 0
        if socketResult == 0 {
            if replacement[0] == fd {
                nextReusedFD = replacement[0]
                nextPeerFD = replacement[1]
            } else if replacement[1] == fd {
                nextReusedFD = replacement[1]
                nextPeerFD = replacement[0]
            } else if dup2(replacement[0], fd) == fd {
                Darwin.close(replacement[0])
                nextReusedFD = fd
                nextPeerFD = replacement[1]
            } else {
                nextErrno = errno
                Darwin.close(replacement[0])
                Darwin.close(replacement[1])
            }
        } else {
            nextErrno = errno
        }

        lock.lock()
        reusedFD = nextReusedFD
        peerFD = nextPeerFD
        setupErrno = nextErrno
        lock.unlock()
        entered.signal()
        _ = releaseGate.wait(timeout: .now() + 2)
    }

    func release() {
        releaseGate.signal()
    }

    func snapshot() -> DiscordGatedCloseSnapshot {
        lock.lock()
        let result = DiscordGatedCloseSnapshot(
            closeCount: closeCount,
            originalFD: originalFD,
            reusedFD: reusedFD,
            peerFD: peerFD,
            setupErrno: setupErrno
        )
        lock.unlock()
        return result
    }
}

/// Sends one byte from `sourceFD` and checks the same byte arrives on `peerFD`, proving two
/// descriptors are still a live pair.
nonisolated func exchangeProbeByte(from sourceFD: Int32, to peerFD: Int32) -> Bool {
    var sent: UInt8 = 0xA5
    let writeCount = withUnsafePointer(to: &sent) { pointer in
        Darwin.send(sourceFD, pointer, 1, Int32(MSG_DONTWAIT))
    }
    guard writeCount == 1 else { return false }

    var received: UInt8 = 0
    let readCount = withUnsafeMutablePointer(to: &received) { pointer in
        Darwin.recv(peerFD, pointer, 1, Int32(MSG_DONTWAIT))
    }
    return readCount == 1 && received == sent
}

/// Counts IPC enqueues and lets a test await a target count, so it can wait on an observable event
/// instead of sleeping.
actor DiscordIPCEnqueueGate {
    private var count = 0
    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    func recordEnqueue() {
        count += 1
        let ready = waiters.filter { count >= $0.value.target }
        ready.forEach { id, waiter in
            waiters[id] = nil
            waiter.continuation.resume(returning: true)
        }
    }

    func waitForEnqueueCount(
        _ target: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        guard count < target else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[id] = Waiter(target: target, continuation: continuation)
                Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.finishWaiter(id, result: false)
                }
            }
        } onCancel: {
            Task { await self.finishWaiter(id, result: false) }
        }
    }

    private func finishWaiter(_ id: UUID, result: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: result)
    }
}

/// Failures from the raw socket helpers in this file.
nonisolated enum DiscordTestSocketError: Error, Sendable {
    case readFailed(Int32)
    case writeFailed(Int32)
    case invalidOpcode(UInt32)
    case invalidPayload
    case timedOut
}

/// What the fake Discord saw in one command: whether it carried an activity, and its `details`.
nonisolated struct DiscordCommandSnapshot: Sendable {
    let hasActivity: Bool
    let activityDetails: String?
}

/// The first command and the one restored after a disable/enable race.
nonisolated struct DiscordPresenceProbe: Sendable {
    let initial: DiscordCommandSnapshot
    let restored: DiscordCommandSnapshot
}

/// Whether a second command reached the socket before the first one's reply, and whether their
/// nonces differed.
nonisolated struct DiscordTransactionProbe: Sendable {
    let secondArrivedBeforeFirstReply: Bool
    let noncesDiffer: Bool
}

/// One IPC frame: opcode and raw payload.
nonisolated struct DiscordRawFrame: Sendable {
    let opcode: UInt32
    let payload: Data
}

/// One-second send/receive timeouts plus `SO_NOSIGPIPE`, so a stuck peer fails a test instead of
/// hanging it.
nonisolated func configureTestSocketTimeouts(_ fd: Int32) -> Bool {
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    var noSigPipe: Int32 = 1
    let size = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        return false
    }
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0 else {
        return false
    }
    return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0
}

/// Plays Discord: reads one command, replies with a matching nonce (an `ERROR` event when
/// `rejected`), and reports what the command carried.
nonisolated func readAndAcknowledgeCommand(
    from fd: Int32,
    rejected: Bool = false
) throws -> DiscordCommandSnapshot {
    let payload = try readRPCPayload(from: fd)
    guard let command = payload["cmd"] as? String,
          let nonce = payload["nonce"] as? String else {
        throw DiscordTestSocketError.invalidPayload
    }

    try writeRPCPayload(
        rejected ? ["cmd": command, "nonce": nonce, "evt": "ERROR"] : ["cmd": command, "nonce": nonce],
        to: fd
    )

    let args = payload["args"] as? [String: Any]
    let activity = args?["activity"] as? [String: Any]
    return DiscordCommandSnapshot(
        hasActivity: activity != nil,
        activityDetails: activity?["details"] as? String
    )
}

/// Reads one frame and parses it as a JSON object; throws if it is not an opcode-frame object.
nonisolated func readRPCPayload(from fd: Int32) throws -> [String: Any] {
    let frame = try readRPCFrame(from: fd)
    guard frame.opcode == DiscordRPCService.Opcode.frame.rawValue else {
        throw DiscordTestSocketError.invalidOpcode(frame.opcode)
    }
    let body = frame.payload
    guard let object = try? JSONSerialization.jsonObject(with: body),
          let payload = object as? [String: Any] else {
        throw DiscordTestSocketError.invalidPayload
    }
    return payload
}

/// Reads one raw frame (8-byte header, then payload) of any opcode.
nonisolated func readRPCFrame(from fd: Int32) throws -> DiscordRawFrame {
    let header = try readExactly(8, from: fd)
    let opcode = header.withUnsafeBytes { bytes in
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
    }
    let length = header.withUnsafeBytes { bytes in
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
    }
    return DiscordRawFrame(
        opcode: opcode,
        payload: try readExactly(Int(length), from: fd)
    )
}

/// Sends `payload` as a JSON opcode-frame.
nonisolated func writeRPCPayload(
    _ payload: [String: Any],
    to fd: Int32
) throws {
    guard let body = JSONObjectSerialization.data(from: payload),
          let length = UInt32(exactly: body.count) else {
        throw DiscordTestSocketError.invalidPayload
    }
    var header = Data(count: 8)
    header.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(
            of: DiscordRPCService.Opcode.frame.rawValue.littleEndian,
            toByteOffset: 0,
            as: UInt32.self
        )
        bytes.storeBytes(
            of: length.littleEndian,
            toByteOffset: 4,
            as: UInt32.self
        )
    }
    try writeExactly(header + body, to: fd)
}

/// Sends a frame of the given opcode with a raw payload.
nonisolated func writeRPCFrame(
    opcode: DiscordRPCService.Opcode,
    payload: Data,
    to fd: Int32
) throws {
    try writeExactly(makeRPCFrameData(opcode: opcode, payload: payload), to: fd)
}

/// Header plus payload bytes for one frame, without sending it.
nonisolated func makeRPCFrameData(
    opcode: DiscordRPCService.Opcode,
    payload: Data
) throws -> Data {
    guard let length = UInt32(exactly: payload.count) else {
        throw DiscordTestSocketError.invalidPayload
    }
    var header = Data(count: 8)
    header.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(of: opcode.rawValue.littleEndian, toByteOffset: 0, as: UInt32.self)
        bytes.storeBytes(of: length.littleEndian, toByteOffset: 4, as: UInt32.self)
    }
    return header + payload
}

/// Sends one byte without blocking; false if it could not go out.
nonisolated func sendDripByte(_ byte: UInt8, to fd: Int32) -> Bool {
    var byte = byte
    let count = withUnsafePointer(to: &byte) { pointer in
        Darwin.send(fd, pointer, 1, Int32(MSG_DONTWAIT))
    }
    return count == 1
}

/// Reads exactly `count` bytes, looping over short reads.
nonisolated func readExactly(_ count: Int, from fd: Int32) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let result = data.withUnsafeMutableBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.read(fd, baseAddress.advanced(by: offset), count - offset)
        }
        if result > 0 {
            offset += result
        } else if result < 0, errno == EINTR {
            continue
        } else {
            throw DiscordTestSocketError.readFailed(result < 0 ? errno : 0)
        }
    }
    return data
}

/// Writes all of `data`, looping over short writes.
nonisolated func writeExactly(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            throw DiscordTestSocketError.writeFailed(0)
        }
        var offset = 0
        while offset < data.count {
            let result = Darwin.write(
                fd,
                baseAddress.advanced(by: offset),
                data.count - offset
            )
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw DiscordTestSocketError.writeFailed(result < 0 ? errno : 0)
            }
        }
    }
}
