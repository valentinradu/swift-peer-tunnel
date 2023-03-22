//
//  File.swift
//
//
//  Created by Valentin Radu on 04/03/2023.
//
import Combine
import CryptoKit
import Foundation
import Network
import os

public enum PeerClamantError: Error {
    case failedToConnect
}

public actor PeerClamant<PeerMessageKind> where PeerMessageKind: PeerMessageKindProtocol {
    private let _listener: NWListener
    private let _logger: Logger = .init(subsystem: "com.peertunnel", category: "peer-clamant")
    private var _connectionPublisher: CurrentValueSubject<PeerConnection<PeerMessageKind>?, Never>

    public init(serviceName: String, password: String) throws {
        let password = password.data(using: .utf8)!
        let listener = try NWListener(using: .securePeerConnectionParameters(password: password,
                                                                             relaying: PeerMessageKind.self))
        listener.service = NWListener.Service(name: serviceName, type: "_peertunnel._tcp")

        _listener = listener
        _connectionPublisher = .init(nil)
    }

    public func listen() {
        if _listener.state != .setup && _listener.state != .cancelled {
            return
        }

        _listener.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task {
                await self._listenerStateUpdateHandler(newState: newState)
            }
        }

        _listener.newConnectionHandler = { [weak self] newConnection in
            guard let self else { return }
            Task {
                await self._listenerNewConnectionHandler(newConnection: newConnection)
            }
        }

        _listener.start(queue: .main)
    }

    public func waitForConnection() async throws -> PeerConnection<PeerMessageKind> {
        if let connection = _connectionPublisher.value {
            return connection
        }

        let timeoutPublisher = _connectionPublisher
            .dropFirst()
            .setFailureType(to: PeerClamantError.self)
            .timeout(.seconds(5), scheduler: DispatchQueue.main, customError: { .failedToConnect })

        for try await connection in timeoutPublisher.values {
            if let connection {
                await connection.waitUntilReady()
                return connection
            } else {
                throw PeerClamantError.failedToConnect
            }
        }

        throw PeerClamantError.failedToConnect
    }
    
    public func cancel() {
        _listener.cancel()
    }

    private func _listenerStateUpdateHandler(newState: NWListener.State) {
        switch newState {
        case .ready:
            let portDebugDescription = _listener.port?.debugDescription ?? "unknown port"
            _logger.info("Listener ready on \(portDebugDescription)")
        case let .failed(error):
            _logger.fault("Listener failed with \(error), stopping")
            assertionFailure(error.debugDescription)
            _listener.cancel()
        case .cancelled:
            _connectionPublisher.send(nil)
        default:
            break
        }
    }

    private func _listenerNewConnectionHandler(newConnection: NWConnection) {
        if _connectionPublisher.value != nil {
            newConnection.cancel()
            return
        }

        let newPeerConnection = PeerConnection<PeerMessageKind>(wrapping: newConnection)
        _connectionPublisher.send(newPeerConnection)
    }
}
