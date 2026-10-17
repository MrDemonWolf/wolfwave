//
//  DiscordRPCService+FrameIO.swift
//  WolfWave
//
//  Created by Nathanial Henniges on 2026-10-16.
//  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
//

import Darwin
import Foundation

/// Discord IPC frame I/O for ``DiscordRPCService``: the ``ipcQueue`` bridge,
/// socket timeouts and deadlines, full reads and writes, frame encoding, and
/// the request/response transaction used by every command.
extension DiscordRPCService {

    // MARK: - Frame I/O

    /// Suspends the actor and runs `work` on ``ipcQueue``, resuming with its result.
    ///
    /// This is the bridge that keeps the blocking socket syscalls off the actor's
    /// serial executor. `work` runs on the dedicated serial `ipcQueue`; the actor
    /// `await`s the continuation, so a stalled `read`/`write`/`connect` parks only
    /// the queue's worker thread, never the actor. Because `ipcQueue` is serial,
    /// only one such block runs at a time, preserving single-threaded socket
    /// access. `work` must be self-contained: it takes only `Sendable` inputs and
    /// touches no actor state, so the hop is safe.
    func runOnIPCQueue<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        let observer = ipcWorkEnqueuedObserver
        return await withCheckedContinuation { continuation in
            ipcQueue.async {
                continuation.resume(returning: work())
            }
            // DispatchQueue.async has accepted the block before this fires,
            // giving tests a real enqueue happens-before edge.
            observer?()
        }
    }

    /// Installs the optional queue-enqueue observer used by deterministic socket
    /// transaction tests.
    func setIPCWorkEnqueuedObserver(_ observer: (@Sendable () -> Void)?) {
        ipcWorkEnqueuedObserver = observer
    }

    /// Applies send/receive timeouts to the IPC socket.
    ///
    /// Also sets `SO_NOSIGPIPE`, so a write to a socket Discord closed returns
    /// `EPIPE` instead of raising SIGPIPE.
    ///
    /// The frame I/O itself now polls against a monotonic deadline and uses
    /// `MSG_DONTWAIT` `send`/`recv`, so these kernel timeouts are a backstop for
    /// any blocking call on the descriptor rather than the primary bound.
    /// Pure: no actor state.
    ///
    /// - Returns: `false` (after logging) if any option could not be set; the
    ///   caller then closes the fd.
    nonisolated static func setSocketTimeouts(_ fd: Int32) -> Bool {
        var tv = timeval(tv_sec: AppConstants.Discord.socketTimeoutSeconds, tv_usec: 0)
        var noSigPipe: Int32 = 1
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let err = errno
            Log.error(
                "DiscordRPCService: Failed to suppress SIGPIPE: errno \(err)",
                category: .discord
            )
            return false
        }
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size) == 0 else {
            let err = errno
            Log.error(
                "DiscordRPCService: Failed to set receive timeout: errno \(err)",
                category: .discord
            )
            return false
        }
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size) == 0 else {
            let err = errno
            Log.error(
                "DiscordRPCService: Failed to set send timeout: errno \(err)",
                category: .discord
            )
            return false
        }
        return true
    }

    /// Current monotonic time used for socket deadlines.
    nonisolated static func monotonicNow() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Saturating absolute monotonic deadline, in `uptimeNanoseconds`. Clamps
    /// to `UInt64.max` instead of wrapping.
    nonisolated static func monotonicDeadline(
        afterNanoseconds interval: UInt64
    ) -> UInt64 {
        let now = monotonicNow()
        let (deadline, overflow) = now.addingReportingOverflow(interval)
        return overflow ? UInt64.max : deadline
    }

    /// Remaining `poll(2)` timeout, rounded up so a sub-millisecond remainder
    /// does not become a premature zero-timeout poll.
    nonisolated static func pollTimeoutMilliseconds(
        deadline: UInt64,
        now: UInt64
    ) -> Int32 {
        guard deadline > now else { return 0 }
        let remaining = deadline - now
        let whole = remaining / 1_000_000
        let rounded = whole + (remaining % 1_000_000 == 0 ? 0 : 1)
        return Int32(Swift.min(rounded, UInt64(Int32.max)))
    }

    /// Waits until `fd` is ready for the requested operation, recomputing the
    /// remaining time after signals so one absolute deadline bounds every retry.
    ///
    /// - Returns: 0 when ready, `ETIMEDOUT` past the deadline, `EBADF` for
    ///   `POLLNVAL`, or the `poll` errno. Hangup and error conditions return 0
    ///   so the following `send`/`recv` surfaces the real error.
    private nonisolated static func waitForSocket(
        _ fd: Int32,
        events: Int16,
        deadline: UInt64
    ) -> Int32 {
        while true {
            let now = monotonicNow()
            guard now < deadline else { return ETIMEDOUT }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(
                &descriptor,
                nfds_t(1),
                pollTimeoutMilliseconds(deadline: deadline, now: now)
            )
            if result > 0 {
                guard monotonicNow() < deadline else { return ETIMEDOUT }
                return descriptor.revents & Int16(POLLNVAL) == 0 ? 0 : EBADF
            }
            if result == 0 { return ETIMEDOUT }
            if errno == EINTR { continue }
            return errno
        }
    }

    /// Result of a blocking write, carrying the failing `errno` captured on the
    /// same `ipcQueue` worker thread that ran the syscall.
    ///
    /// `errno` is thread-local, so it must be read inside the queue closure (right
    /// after the failing syscall) rather than back on the actor executor where it
    /// reflects unrelated work. `errno` is meaningful only when `ok == false`.
    struct WriteResult: Sendable {
        let ok: Bool
        let errno: Int32
    }

    /// Result of a blocking read, carrying the bytes (nil on failure) plus the
    /// failing `errno` captured on the `ipcQueue` worker thread. `errno` is
    /// meaningful only when `data == nil`.
    struct ReadResult: Sendable {
        let data: Data?
        let errno: Int32
    }

    /// Writes all of `data` to socket `fd`, looping over partial writes.
    ///
    /// A stream socket may accept fewer bytes than requested per `write`, so a
    /// single call can't be assumed to flush the whole frame. Returns `ok: false`
    /// (with the captured `errno`) if the socket errors or times out before
    /// everything is written. The `errno` is read on this worker thread so it
    /// reflects the actual failure, not later actor-executor work. Pure of actor
    /// state (takes `fd` explicitly) so it can run on ``ipcQueue``.
    nonisolated static func writeFully(
        _ data: Data,
        fd: Int32,
        deadline: UInt64
    ) -> WriteResult {
        guard !data.isEmpty else { return WriteResult(ok: true, errno: 0) }
        return data.withUnsafeBytes { raw -> WriteResult in
            guard let base = raw.baseAddress else { return WriteResult(ok: false, errno: 0) }
            var total = 0
            while total < data.count {
                let waitError = waitForSocket(
                    fd,
                    events: Int16(POLLOUT),
                    deadline: deadline
                )
                guard waitError == 0 else {
                    return WriteResult(ok: false, errno: waitError)
                }
                let n = Darwin.send(
                    fd,
                    base + total,
                    data.count - total,
                    Int32(MSG_DONTWAIT)
                )
                if n > 0 {
                    total += n
                } else if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                } else {
                    return WriteResult(ok: false, errno: n == 0 ? EPIPE : errno)
                }
            }
            return WriteResult(ok: true, errno: 0)
        }
    }

    /// Reads exactly `count` bytes from socket `fd`, looping over partial reads.
    ///
    /// A stream socket may return fewer bytes than requested per `read`, so a
    /// single call can't be assumed to fill the buffer. Returns `data: nil` (with
    /// the captured `errno`) if the peer closes (`read` returns 0) or the socket
    /// errors/times out before `count` bytes arrive. The `errno` is read on this
    /// worker thread so it reflects the actual failure, not later actor-executor
    /// work. A clean peer close (`read` returns 0) leaves `errno == 0`. Pure of
    /// actor state (takes `fd` explicitly) so it can run on ``ipcQueue``.
    private nonisolated static func readFully(
        _ count: Int,
        fd: Int32,
        deadline: UInt64
    ) -> ReadResult {
        guard count > 0 else { return ReadResult(data: Data(), errno: 0) }
        var buffer = Data(count: count)
        var failErrno: Int32 = 0
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var total = 0
            while total < count {
                let waitError = waitForSocket(
                    fd,
                    events: Int16(POLLIN),
                    deadline: deadline
                )
                guard waitError == 0 else {
                    failErrno = waitError
                    return false
                }
                let n = Darwin.recv(
                    fd,
                    base + total,
                    count - total,
                    Int32(MSG_DONTWAIT)
                )
                if n > 0 {
                    total += n
                } else if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                } else {
                    // peer closed (n == 0, errno stays 0) or error/timeout (n < 0)
                    failErrno = n < 0 ? errno : 0
                    return false
                }
            }
            return true
        }
        return ok ? ReadResult(data: buffer, errno: 0) : ReadResult(data: nil, errno: failErrno)
    }

    /// One decoded IPC frame carried across the ``ipcQueue`` continuation.
    struct IPCFrame: Sendable {
        /// Raw opcode; may be a value outside ``Opcode``.
        let opcode: UInt32
        /// JSON body bytes, or `nil` for a zero-length frame.
        let payload: Data?
    }

    /// Result of reading one complete IPC frame on ``ipcQueue``.
    struct FrameReadResult: Sendable {
        let frame: IPCFrame?
        let errno: Int32
    }

    /// Result of one queue-owned write/read exchange.
    ///
    /// `response` is non-nil only for a matched reply. When it is nil with a
    /// successful write, `readErrno` is the read failure, or 0 for a CLOSE
    /// frame, a mismatch, or an exhausted drain bound.
    struct IPCTransactionResult: Sendable {
        let writeResult: WriteResult
        let response: IPCFrame?
        let readErrno: Int32
    }

    /// Response identity used while draining an IPC transaction.
    enum IPCResponseExpectation: Sendable {
        /// Handshake: a `DISPATCH` / `READY` frame.
        case ready
        /// Command: a frame echoing this `cmd` and `nonce`.
        case command(nonce: String, command: String)
    }

    /// Finite drain bound for a malformed or hostile peer that continuously
    /// sends unmatched frames. READY and command transactions share the same
    /// policy because WolfWave does not subscribe to Discord event frames.
    private nonisolated static let ipcTransactionMaximumFrames = 32

    /// Encodes one Discord IPC frame.
    ///
    /// Frame format: `[opcode: UInt32 LE][length: UInt32 LE][JSON payload]`.
    /// Guards invalid JSON leaves and oversized payloads before integer
    /// conversion so malformed app state cannot trap the process.
    nonisolated static func encodeFrame(
        opcode: Opcode,
        payload: [String: Any]
    ) -> Data? {
        guard let jsonData = JSONObjectSerialization.data(from: payload),
              let length = UInt32(exactly: jsonData.count),
              length < AppConstants.Discord.maxIPCFrameBytes else {
            return nil
        }

        var header = Data(count: 8)
        header.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: opcode.rawValue.littleEndian, toByteOffset: 0, as: UInt32.self)
            buf.storeBytes(of: length.littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        return header + jsonData
    }

    /// Encodes a frame whose body must be preserved byte-for-byte (PING/PONG).
    /// Returns `nil` when the body reaches `maxIPCFrameBytes`.
    nonisolated static func encodeRawFrame(
        opcode: Opcode,
        payload: Data
    ) -> Data? {
        guard let length = UInt32(exactly: payload.count),
              length < AppConstants.Discord.maxIPCFrameBytes else { return nil }
        var header = Data(count: 8)
        header.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: opcode.rawValue.littleEndian, toByteOffset: 0, as: UInt32.self)
            buf.storeBytes(of: length.littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        return header + payload
    }

    /// Sends one command and consumes its matching Discord reply atomically.
    ///
    /// The entire write plus reply-drain loop is a single ``ipcQueue`` block.
    /// Actor reentrancy can enqueue another transaction while this method awaits,
    /// but that transaction cannot write until this command's nonce-matched reply
    /// has been consumed.
    ///
    /// A write failure or a missing / mismatched reply is treated as a lost
    /// connection (disconnect plus scheduled reconnect). A Discord `ERROR` reply
    /// keeps the connection; for `SET_ACTIVITY` it requests one retry.
    ///
    /// - Parameter payload: Must carry a non-empty `nonce` and `cmd`.
    /// - Returns: `true` only for a matched, non-error reply on the still-current
    ///   connection.
    @discardableResult
    func sendCommandFrame(_ payload: [String: Any]) async -> Bool {
        guard let nonce = payload["nonce"] as? String,
              !nonce.isEmpty,
              let command = payload["cmd"] as? String,
              !command.isEmpty,
              let outbound = Self.encodeFrame(opcode: .frame, payload: payload) else {
            Log.error("DiscordRPCService: Invalid command payload", category: .discord)
            return false
        }

        let fd = socketFD
        guard fd >= 0 else { return false }
        let generation = connectionGeneration
        let readBuffer = ipcReadBuffer
        let timeoutNanoseconds = ipcTransactionTimeoutNanoseconds
        let result = await runOnIPCQueue {
            Self.performIPCTransaction(
                outbound,
                expecting: .command(nonce: nonce, command: command),
                fd: fd,
                readBuffer: readBuffer,
                timeoutNanoseconds: timeoutNanoseconds
            )
        }

        guard ownsConnection(fd: fd, generation: generation) else { return false }

        guard result.writeResult.ok else {
            let err = result.writeResult.errno
            let reason = "\(err) (\(String(cString: strerror(err))))"
            Log.error(
                "DiscordRPCService: Command write failed/timed out: \(reason)",
                category: .discord
            )
            await handleConnectionLost(fd: fd, generation: generation)
            return false
        }

        guard let response = result.response,
              let payloadData = response.payload,
              let responsePayload = Self.decodeFramePayload(payloadData) else {
            if result.readErrno != 0 {
                let err = result.readErrno
                let reason = "\(err) (\(String(cString: strerror(err))))"
                Log.error(
                    "DiscordRPCService: Command reply read failed/timed out: \(reason)",
                    category: .discord
                )
            } else {
                Log.warn("DiscordRPCService: Missing or mismatched command reply", category: .discord)
            }
            await handleConnectionLost(fd: fd, generation: generation)
            return false
        }

        if responsePayload["evt"] as? String == "ERROR" {
            Log.warn("DiscordRPCService: Discord rejected \(command)", category: .discord)
            if command == "SET_ACTIVITY",
               let args = payload["args"] as? [String: Any], let activity = args["activity"] as? [String: Any] {
                retryRejectedPresence(activity, nonce: nonce)
            }
            return false
        }
        return true
    }

    /// A rejected handshake belongs only to the still-enabled socket generation.
    ///
    /// - Returns: `true` after recording ``ConnectionFailure/handshakeRejected``;
    ///   `false` (nothing recorded) when the attempt is stale or disabled, which
    ///   tells ``connectIfNeeded()`` to stop.
    func recordHandshakeRejectionIfCurrent(fd: Int32, generation: UInt64) -> Bool {
        guard ownsConnection(fd: fd, generation: generation), isEnabled else { return false }
        lastFailure = .handshakeRejected
        return true
    }

    /// Performs a write plus response match as one serial-queue transaction.
    ///
    /// Unmatched frames are drained inside the same block. A CLOSE frame,
    /// malformed frame, timeout, or exhausted drain bound fails the transaction;
    /// no reply is left unread for the next command to accidentally consume.
    nonisolated static func performIPCTransaction(
        _ outbound: Data,
        expecting expectation: IPCResponseExpectation,
        fd: Int32,
        readBuffer: IPCReadBuffer,
        timeoutNanoseconds: UInt64
    ) -> IPCTransactionResult {
        // A single absolute deadline covers the write and every subsequent
        // header/body/PONG/unmatched-frame operation. Receiving one byte or one
        // stale frame never resets the budget.
        let deadline = monotonicDeadline(afterNanoseconds: timeoutNanoseconds)
        let writeResult = writeFully(outbound, fd: fd, deadline: deadline)
        guard writeResult.ok else {
            return IPCTransactionResult(
                writeResult: writeResult,
                response: nil,
                readErrno: 0
            )
        }

        for _ in 0..<Self.ipcTransactionMaximumFrames {
            guard monotonicNow() < deadline else {
                return IPCTransactionResult(
                    writeResult: writeResult,
                    response: nil,
                    readErrno: ETIMEDOUT
                )
            }
            let readResult = readIPCFrame(
                fd: fd,
                readBuffer: readBuffer,
                deadline: deadline
            )
            guard let frame = readResult.frame else {
                return IPCTransactionResult(
                    writeResult: writeResult,
                    response: nil,
                    readErrno: readResult.errno
                )
            }
            guard frame.opcode != Opcode.close.rawValue else {
                return IPCTransactionResult(
                    writeResult: writeResult,
                    response: nil,
                    readErrno: 0
                )
            }
            if frame.opcode == Opcode.ping.rawValue {
                guard let pong = encodeRawFrame(
                    opcode: .pong,
                    payload: frame.payload ?? Data()
                ) else {
                    return IPCTransactionResult(
                        writeResult: WriteResult(ok: false, errno: EMSGSIZE),
                        response: nil,
                        readErrno: 0
                    )
                }
                let pongResult = writeFully(pong, fd: fd, deadline: deadline)
                guard pongResult.ok else {
                    return IPCTransactionResult(
                        writeResult: pongResult,
                        response: nil,
                        readErrno: 0
                    )
                }
                continue
            }
            if response(frame, matches: expectation) {
                return IPCTransactionResult(
                    writeResult: writeResult,
                    response: frame,
                    readErrno: 0
                )
            }
        }

        return IPCTransactionResult(
            writeResult: writeResult,
            response: nil,
            readErrno: 0
        )
    }

    /// Reads one complete framed message. Must run on ``ipcQueue``.
    ///
    /// Serves from bytes already buffered first, then reads exactly what is
    /// missing (header, then body). An advertised length at or above
    /// `maxIPCFrameBytes` fails with `EMSGSIZE` before any body is read, and
    /// the buffer is discarded.
    private nonisolated static func readIPCFrame(
        fd: Int32,
        readBuffer: IPCReadBuffer,
        deadline: UInt64
    ) -> FrameReadResult {
        while true {
            if let parsed = popIPCFrame(from: readBuffer) { return parsed }

            let targetCount: Int
            if readBuffer.data.count < 8 {
                targetCount = 8
            } else {
                let length = readBuffer.data.withUnsafeBytes { buf in
                    UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                }
                guard length < AppConstants.Discord.maxIPCFrameBytes else {
                    readBuffer.data.removeAll(keepingCapacity: true)
                    return FrameReadResult(frame: nil, errno: EMSGSIZE)
                }
                targetCount = 8 + Int(length)
            }

            let missing = targetCount - readBuffer.data.count
            let readResult = readFully(missing, fd: fd, deadline: deadline)
            guard let bytes = readResult.data else {
                return FrameReadResult(frame: nil, errno: readResult.errno)
            }
            readBuffer.data.append(bytes)
        }
    }

    /// Removes one complete frame from the shared queue-owned byte buffer.
    ///
    /// - Returns: `nil` when no complete frame is buffered yet; an `EMSGSIZE`
    ///   result (buffer cleared) for an oversized advertised length.
    nonisolated static func popIPCFrame(
        from readBuffer: IPCReadBuffer
    ) -> FrameReadResult? {
        guard readBuffer.data.count >= 8 else { return nil }
        let opcode = readBuffer.data.withUnsafeBytes { buf in
            UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        let length = readBuffer.data.withUnsafeBytes { buf in
            UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        guard length < AppConstants.Discord.maxIPCFrameBytes else {
            readBuffer.data.removeAll(keepingCapacity: true)
            return FrameReadResult(frame: nil, errno: EMSGSIZE)
        }
        let total = 8 + Int(length)
        guard readBuffer.data.count >= total else { return nil }
        let payload = length == 0
            ? nil
            : readBuffer.data.subdata(in: 8..<total)
        readBuffer.data.removeSubrange(0..<total)
        return FrameReadResult(
            frame: IPCFrame(opcode: opcode, payload: payload),
            errno: 0
        )
    }

    /// Tests a decoded frame against the active transaction expectation.
    /// Frames whose body is empty or not a JSON object never match.
    private nonisolated static func response(
        _ frame: IPCFrame,
        matches expectation: IPCResponseExpectation
    ) -> Bool {
        guard let payloadData = frame.payload,
              let payload = decodeFramePayload(payloadData) else {
            return false
        }

        switch expectation {
        case .ready:
            return isReadyHandshakeResponse(opcode: frame.opcode, payload: payload)
        case let .command(nonce, command):
            return isCommandResponse(
                opcode: frame.opcode,
                payload: payload,
                nonce: nonce,
                command: command
            )
        }
    }

    /// Pure validator for Discord's handshake response.
    nonisolated static func isReadyHandshakeResponse(
        opcode: UInt32,
        payload: [String: Any]?
    ) -> Bool {
        opcode == Opcode.frame.rawValue
            && payload?["cmd"] as? String == "DISPATCH"
            && payload?["evt"] as? String == "READY"
    }

    /// Pure validator for a command response. Both command and nonce must match.
    nonisolated static func isCommandResponse(
        opcode: UInt32,
        payload: [String: Any]?,
        nonce: String,
        command: String
    ) -> Bool {
        opcode == Opcode.frame.rawValue
            && payload?["cmd"] as? String == command
            && payload?["nonce"] as? String == nonce
    }

    /// Decodes a Discord IPC frame body into a JSON object, or nil if the bytes
    /// aren't a JSON object. Pure and static so it's unit-testable without a live
    /// socket. `JSONSerialization.jsonObject(with:)` throws (caught by `try?`) on
    /// malformed input and never raises, so a hostile or garbled frame can't crash.
    nonisolated static func decodeFramePayload(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
