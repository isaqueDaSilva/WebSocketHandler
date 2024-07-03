//
//  WebSocketService.swift
//
//
//  Created by Isaque da Silva on 02/07/24.
//

import Combine
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOFoundationCompat

/// An object that handle with the WebSocket channel on client side.
public struct WebSocketService<ReceiveMessage: Decodable> {
    /// The host to connect to.
    private let host: String
    
    /// The port to connect to.
    private let port: Int
    
    /// The uri for access the channel.
    private let uri: String
    
    /// The authorization value for establish connection with the ws server.
    private let authorizationValue: String?
    
    /// A default event loop group for this aplication.
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    
    /// A default WebSocket Upgrader for this aplication.
    private var wsUpgrader: EventLoopFuture<UpgradeResult>?
    
    private var outboundWriter: NIOAsyncChannelOutboundWriter<WebSocketFrame>?
    
    /// The default Combine's subject that stores the current message or an error to send back to the top level aplication.
    public let messageReceivedSubject: PassthroughSubject<ReceiveMessage, WebSocketError>
    
    
    /// Starts the WebSocket channel
    public mutating func start<M: Codable>(with initialMessage: M) async throws {
        self.wsUpgrader = try await getUpgraderResult()
        
        guard let wsUpgrader else {
            return try await disconnect()
        }
        
        try await channelUpgradeResult(with: wsUpgrader, and: initialMessage)
    }
    
    /// Establish the WebSoclet channel connection
    /// - Returns: Returns a `EventLoopFuture` for handle with the WebSocket channel
    private func getUpgraderResult() async throws -> EventLoopFuture<UpgradeResult> {
        let upgradeResult: EventLoopFuture<UpgradeResult> = try await ClientBootstrap(group: eventLoopGroup)
            .connect(
                host: host,
                port: port
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult> { (channel, _) in
                        channel.eventLoop.makeCompletedFuture {
                            let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                            return UpgradeResult.websocket(asyncChannel)
                        }
                    }
                    
                    var header = HTTPHeaders()
                    
                    if let authorizationValue {
                        header.add(name: "Authorization", value: authorizationValue)
                    }
                    
                    header.add(name: "Content-Type", value: "application/vnd.api+json")
                    
                    let requestHead = HTTPRequestHead(
                        version: .http1_1,
                        method: .GET,
                        uri: uri,
                        headers: header
                    )
                    
                    let clientUpgradeConfig = NIOTypedHTTPClientUpgradeConfiguration(
                        upgradeRequestHead: requestHead,
                        upgraders: [upgrader]
                    ) { channel in
                        channel.eventLoop.makeCompletedFuture {
                            return UpgradeResult.notUpgraded
                        }
                    }
                    
                    let negotiationResultFeature = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                        configuration: .init(upgradeConfiguration: clientUpgradeConfig)
                    )
                    
                    return negotiationResultFeature
                }
            }
        
        return upgradeResult
    }
    
    /// Handles with the upgrade result.
    /// - Parameters:
    ///   - upgradeResult: An `EventLoopFuture` that stores the status of the WebSocket channel.
    ///   - initialMessage: An initial message object for send to the WebSocket channel for starts the connection.
    private mutating func channelUpgradeResult<M: Codable>(
        with upgrader: EventLoopFuture<UpgradeResult>,
        and initialMessage: M
    ) async throws {
        switch try await upgrader.get() {
        case .websocket(let wsChannel):
            print("Handling websocket connection")
            try await handleWebsocketChannel(wsChannel, and: initialMessage)
            print("Done handling websocket connection")
        case .notUpgraded:
            print("Upgrade declined")
        }
    }
    
    /// Starts the WebSocket channel and observers the all messages that coming when the channel is alive.
    /// - Parameters:
    ///   - channel: The actual WebSocket channel.
    ///   - initialMessage: An initial message object for send to the WebSocket channel for starts the connection.
    private mutating func handleWebsocketChannel<M: Codable>(
        _ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        and initialMessage: M
    ) async throws {
        let encoder = JSONEncoder()
        
        // Encodes the message for send in the channel.
        let modelData = try encoder.encode(initialMessage)
        
        // Transform the data in an actual WebSocketFrame model
        // for send in the channel.
        let message = WebSocketFrame(fin: true, opcode: .binary, data: .init(bytes: [UInt8](modelData)))
        
        // Executes the channel.
        try await channel.executeThenClose { inbound, outbound in
            // Sends the initial message for the channel.
            self.outboundWriter = outbound
            
            guard let outboundWriter else {
                try await disconnect()
                return
            }
            
            try await outboundWriter.write(message)
            
            // Creates a stream for receive
            // the all data that coming
            // from the WebSocket channel.
            for try await frame in inbound {
                switch frame.opcode {
                case .pong:
                    print("Pong Received: \(String(buffer: frame.data))")
                case .binary:
                    onReceive(frame.data)
                case .connectionClose:
                    try await disconnect()
                default:
                    break
                }
            }
        }
    }
    
    /// Handles with the messages that received from the channel.
    /// - Parameter buffer: The buffer that stores the binary data representation for the message.
    private func onReceive(_ buffer: ByteBuffer) {
        guard let message = try? JSONDecoder().decode(ReceiveMessage.self, from: buffer) else {
            messageReceivedSubject.send(completion: .failure(.decodingError))
            return
        }
        
        messageReceivedSubject.send(message)
    }
    
    /// Disconnect the active channel.
    /// - Parameter closeMode: What kind of close operation is requested.
    public mutating func disconnect(with closeMode: CloseMode = .all) async throws {
        guard let wsUpgrader else { return }
        
        switch try await wsUpgrader.get() {
        case .websocket(let wsChannel):
            do {
                try await wsChannel.channel.close(mode: closeMode)
                self.wsUpgrader = nil
                self.outboundWriter = nil
            } catch {
                messageReceivedSubject.send(completion: .failure(.unknownError(error)))
            }
            messageReceivedSubject.send(completion: .finished)
        case .notUpgraded:
            return
        }
    }
    
    /// Sends a ping frame for the WebSocket channel.
    public func sendPing() async throws {
        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: .init(string: "I'm here."))
        
        guard let wsUpgrader else { return }
        
        let channel = try await wsUpgrader.get()
        
        switch channel {
        case .websocket(let wsChannel):
            do {
                try await wsChannel.executeThenClose { _, outbound in
                    try await outbound.write(pingFrame)
                }
            } catch {
                messageReceivedSubject.send(completion: .failure(.unknownError(error)))
            }
        case .notUpgraded:
            messageReceivedSubject.send(completion: .failure(.noConnection))
        }
    }
    
    /// Sends a message for the WebSocket channel
    /// - Parameter message: The message data representation for send to the channel.
    public func send(_ message: Data) async throws {
        let messageByte = [UInt8](message)
        let messageFrame = WebSocketFrame(fin: true, opcode: .binary, data: .init(bytes: messageByte))
        
        guard let wsUpgrader else { throw WebSocketError.noConnection }
        
        guard let outboundWriter else { return }
        
        try await outboundWriter.write(messageFrame)
    }
    
    public init(
        host: String,
        port: Int,
        uri: String,
        authorizationValue: String? = nil,
        eventLoopGroup: MultiThreadedEventLoopGroup = .singleton
    ) {
        self.host = host
        self.port = port
        self.uri = uri
        self.authorizationValue = authorizationValue
        self.eventLoopGroup = eventLoopGroup
        messageReceivedSubject = .init()
    }
}

extension WebSocketService {
    enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded
    }
}
