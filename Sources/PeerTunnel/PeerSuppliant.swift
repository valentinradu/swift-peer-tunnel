//
//  File.swift
//
//
//  Created by Valentin Radu on 05/03/2023.
//

import Combine
import Foundation
import Network
import os

public enum PeerSuppliantError: Error {
    case failedToConnect
}

public actor PeerSuppliant<PeerMessageKind> where PeerMessageKind: PeerMessageKindProtocol {
    private let _logger: Logger = .init(subsystem: "com.peertunnel.framework", category: "peer-suppliant")
    private let _browser: NWBrowser
    private let _targetService: String
    private let _password: String
    private var _connectionPublisher: CurrentValueSubject<PeerConnection<PeerMessageKind>?, Never>

    public init(targetService: String, password: String) {
        let parameters = NWParameters()
        let serviceDescriptor: NWBrowser.Descriptor = .bonjour(type: "_peertunnel._tcp", domain: nil)
        _browser = NWBrowser(for: serviceDescriptor, using: parameters)
        _targetService = targetService
        _connectionPublisher = .init(nil)
        _password = password
    }

    public func discover() {
        if _browser.state != .setup {
            return
        }

        _browser.stateUpdateHandler = { [weak self] newState in
            Task { [weak self] in
                guard let self else { return }
                await self._browserStateUpdateHandler(newState: newState)
            }
        }

        _browser.browseResultsChangedHandler = { [weak self] _, _ in
            Task { [weak self] in
                guard let self else { return }
                await self._refreshResults()
            }
        }

        _browser.start(queue: .main)
    }

    public func waitForConnection() async throws -> PeerConnection<PeerMessageKind> {
        if let connection = _connectionPublisher.value {
            return connection
        }

        let timeoutPublisher = _connectionPublisher
            .dropFirst()
            .setFailureType(to: PeerSuppliantError.self)
            .timeout(.seconds(5), scheduler: DispatchQueue.main, customError: { .failedToConnect })

        for try await connection in timeoutPublisher.values {
            if let connection {
                return connection
            } else {
                throw PeerSuppliantError.failedToConnect
            }
        }

        throw PeerSuppliantError.failedToConnect
    }

    private func _browserStateUpdateHandler(newState: NWBrowser.State) {
        switch newState {
        case let .failed(error):
            _logger.fault("Peer browser failed with \(error), stopping")
            assertionFailure(error.debugDescription)
            _connectionPublisher.send(nil)
            _browser.cancel()
        case .ready:
            _refreshResults()
        default:
            break
        }
    }

    private func _refreshResults() {
        for result in _browser.browseResults {
            switch result.endpoint {
            case let .service(name, _, _, _):
                if name == _targetService, _connectionPublisher.value == nil {
                    let connection = PeerConnection<PeerMessageKind>(to: result.endpoint, password: _password)
                    _connectionPublisher.send(connection)
                }
            default:
                break
            }
        }
    }
}
