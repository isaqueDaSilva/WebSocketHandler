//
//  WebSocketError.swift
//  
//
//  Created by Isaque da Silva on 02/07/24.
//

import Foundation

extension WebSocketService: Error, LocalizedError {
    /// An error collection that may occur when execution the WebSocket channel..
    public enum WebSocketError: Error, LocalizedError, Sendable {
        case decodingError
        case noConnection
        case unknownError(Error)
        
        public var errorDescription: String? {
            switch self {
            case .decodingError:
                NSLocalizedString("Failed to decode a data coming from the channel.", comment: "")
            case .noConnection:
                NSLocalizedString("They are no connections available to handle with this task.", comment: "")
            case .unknownError(let error):
                NSLocalizedString("An unexpected error occur. Error: \(error.localizedDescription)", comment: "")
            }
        }
    }
}
