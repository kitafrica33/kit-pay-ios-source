/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if os(iOS)

import Foundation
import Network

/// A communication channel between two processes on the same machine.
final class IPCChannel: Sendable {
    fileprivate static let restartDelay: TimeInterval = 0.1
    static let restartDelayNanoseconds = UInt64(restartDelay * Double(NSEC_PER_SEC))
    fileprivate static let queue = DispatchQueue(label: "io.livekit.ipc.queue", qos: .userInitiated)

    private static let defaultParameters = {
        let parameters = NWParameters.tcp
        let ipcProtocol = NWProtocolFramer.Options(definition: IPCProtocol.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(ipcProtocol, at: 0)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }()

    private let connection: NWConnection

    enum Error: Swift.Error {
        case cancelled
        case corruptMessage
    }

    // MARK: - Connection

    /// Creates a channel by accepting a connection from the other process.
    init(acceptingOn socketPath: SocketPath) async throws {
        try? FileManager.default.removeItem(atPath: socketPath.path)

        let parameters = Self.defaultParameters
        parameters.requiredLocalEndpoint = NWEndpoint(socketPath)

        let listener = try NWListener(using: parameters)
        guard let connection = try await listener.firstConnection else {
            throw Error.cancelled
        }

        try await connection.waitUntilReady()
        self.connection = connection
    }

    /// Creates a channel by establishing a connection to the other process.
    init(connectingTo socketPath: SocketPath) async throws {
        connection = NWConnection(
            to: NWEndpoint(socketPath),
            using: Self.defaultParameters,
        )
        try await connection.waitUntilReady()
    }

    /// Whether or not the connection has been closed.
    var isClosed: Bool {
        connection.state != .ready
    }

    /// Closes the connection associated with this channel.
    func close() {
        connection.cancel()
    }

    // MARK: - Sending

    /// Sends a message to the connected process.
    func send(header: some Encodable, payload: Data? = nil) async throws {
        try await send(
            encodedHeader: encoder.encode(header),
            payload: payload,
        )
    }

    private let encoder = PropertyListEncoder()

    private func send(encodedHeader: Data, payload: Data?) async throws {
        let payloadSize = payload?.count ?? 0

        var messageData = encodedHeader
        if let payload { messageData.append(payload) }

        try await connection.send(
            content: messageData,
            contentContext: NWConnection.ContentContext.ipcMessage(payloadSize: payloadSize),
        )
    }

    // MARK: - Receiving

    /// An asynchronous sequence of incoming messages.
    ///
    /// The sequence ends when the connection is closed by either side.
    ///
    struct AsyncMessageSequence<Header: Decodable>: AsyncSequence, AsyncIteratorProtocol {
        fileprivate let upstream: NWConnection.AsyncMessageSequence
        private let decoder = PropertyListDecoder()

        func next() async throws -> (Header, Data?)? {
            guard let rawMessage = try await upstream.next() else {
                return nil
            }
            let (data, context, isComplete) = (rawMessage.data, rawMessage.context, rawMessage.isComplete)
            guard let data, isComplete else { return nil }

            guard let payloadSize = context?.ipcMessagePayloadSize,
                  payloadSize <= data.count else { throw IPCChannel.Error.corruptMessage }

            guard payloadSize > 0 else {
                return try (decoder.decode(Header.self, from: data), nil)
            }
            let headerSize = data.count - payloadSize
            guard let (headerData, payloadData) = data.partition(bytesInFirst: headerSize) else {
                throw Error.corruptMessage
            }
            return try (decoder.decode(Header.self, from: headerData), payloadData)
        }

        func makeAsyncIterator() -> Self { self }
    }

    /// Receives incoming messages from the connected process.
    /// - Parameter headerType: The type to decode from the message header.
    /// - Returns: An asynchronous sequence for receiving messages as they arrive.
    func incomingMessages<T: Decodable>(_: T.Type) -> AsyncMessageSequence<T> {
        AsyncMessageSequence(upstream: connection.incomingMessages)
    }
}

// MARK: - Extensions

extension Data {
    func partition(bytesInFirst: Int) -> (Data, Data)? {
        guard (0 ... count).contains(bytesInFirst) else { return nil }
        return (
            subdata(in: 0 ..< bytesInFirst),
            subdata(in: bytesInFirst ..< count),
        )
    }
}

/// An accepted socket must either reach its caller or be explicitly cancelled. AsyncStream's
/// cancellation can discard a buffered connection without closing it, leaving its peer open.
private final class IPCConnectionAcceptance: Sendable {
    typealias Continuation = CheckedContinuation<NWConnection?, any Error>
    private struct State {
        var continuation: Continuation?
        var result: Result<NWConnection?, any Error>?
    }

    private let state = StateSync(State())

    func install(_ continuation: Continuation) {
        let completed = state.mutate { state -> Result<NWConnection?, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    @discardableResult
    func finish(_ result: Result<NWConnection?, any Error>) -> Bool {
        let (won, continuation) = state.mutate { state -> (Bool, Continuation?) in
            guard state.result == nil else { return (false, nil) }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        continuation?.resume(with: result)
        return won
    }
}

private extension NWListener {
    var firstConnection: NWConnection? {
        get async throws {
            defer { cancel() }
            let acceptance = IPCConnectionAcceptance()
            return try await withTaskCancellationHandler {
                guard !Task.isCancelled else { throw IPCChannel.Error.cancelled }
                return try await withCheckedThrowingContinuation { continuation in
                    acceptance.install(continuation)
                    newConnectionHandler = { [weak self] connection in
                        if !acceptance.finish(.success(connection)) { connection.cancel() }
                        self?.cancel()
                    }
                    stateUpdateHandler = { state in
                        switch state {
                        case .cancelled: acceptance.finish(.success(nil))
                        case let .waiting(error), let .failed(error): acceptance.finish(.failure(error))
                        default: break
                        }
                    }
                    start(queue: IPCChannel.queue)
                }
            } onCancel: {
                acceptance.finish(.success(nil))
                self.cancel()
            }
        }
    }
}

private extension NWConnection {
    func waitUntilReady() async throws {
        try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw IPCChannel.Error.cancelled }
            for await state in stateUpdates {
                guard !Task.isCancelled else { throw IPCChannel.Error.cancelled }
                switch state {
                case .ready: return
                case .setup, .preparing: continue
                case .waiting:
                    // Will enter this state when socket path does not exist yet.
                    do {
                        try await Task.sleep(nanoseconds: IPCChannel.restartDelayNanoseconds)
                    } catch {
                        throw IPCChannel.Error.cancelled
                    }
                    restart()
                    continue
                case let .failed(error): throw error
                case .cancelled:
                    throw IPCChannel.Error.cancelled
                @unknown default: continue
                }
            }
            throw IPCChannel.Error.cancelled
        } onCancel: {
            self.cancel()
        }
    }

    private var stateUpdates: AsyncStream<NWConnection.State> {
        AsyncStream { [weak self] continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stateUpdateHandler = nil
            }
            self?.stateUpdateHandler = { state in
                continuation.yield(state)
            }
            self?.start(queue: IPCChannel.queue)
        }
    }

    var incomingMessages: AsyncMessageSequence {
        AsyncMessageSequence(connection: self)
    }

    struct IncomingMessage {
        let data: Data?
        let context: NWConnection.ContentContext?
        let isComplete: Bool
    }

    struct AsyncMessageSequence: AsyncSequence, AsyncIteratorProtocol {
        let connection: NWConnection
        func next() async throws -> IncomingMessage? {
            try await connection.receiveSingleMessage()
        }

        func makeAsyncIterator() -> Self { self }
    }

    private func receiveSingleMessage() async throws -> IncomingMessage {
        try await withCheckedThrowingContinuation { [weak self] continuation in
            self?.receiveMessage { data, context, isComplete, error in
                guard let error else {
                    continuation.resume(returning: IncomingMessage(data: data, context: context, isComplete: isComplete))
                    return
                }
                continuation.resume(throwing: error)
            }
        }
    }

    func send(content: Data, contentContext: NWConnection.ContentContext) async throws {
        try await withCheckedThrowingContinuation { continuation in
            send(
                content: content,
                contentContext: contentContext,
                completion: .contentProcessed { error in
                    guard let error else {
                        continuation.resume()
                        return
                    }
                    continuation.resume(throwing: error)
                },
            )
        }
    }
}

#endif
