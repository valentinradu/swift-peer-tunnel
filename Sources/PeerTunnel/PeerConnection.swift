//
//  File.swift
//
//
//  Created by Valentin Radu on 05/03/2023.
//

import Combine
import CryptoKit
import Foundation
import Network
import os

extension NWParameters {
    static func securePeerConnectionParameters<PeerMessageKind>(password: Data,
                                                                relaying: PeerMessageKind.Type) -> NWParameters
        where PeerMessageKind: PeerMessageKindProtocol {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2

        let tlsOptions = NWProtocolTLS.Options()
        let authenticationKey = SymmetricKey(data: password)
        let identity = "com.peertunnel.framework"
        let identityData = identity.data(using: .utf8)!
        var authenticationCode = HMAC<SHA256>.authenticationCode(for: identityData,
                                                                 using: authenticationKey)

        let authenticationDispatchData = withUnsafeBytes(of: &authenticationCode) { (ptr: UnsafeRawBufferPointer) in
            DispatchData(bytes: ptr)
        }

        let identityDispatchData = withUnsafeBytes(of: identityData) { (ptr: UnsafeRawBufferPointer) in
            DispatchData(bytes: UnsafeRawBufferPointer(start: ptr.baseAddress, count: identityData.count))
        }

        sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions,
                                                authenticationDispatchData as __DispatchData,
                                                identityDispatchData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)

        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        parameters.includePeerToPeer = true

        let protocolOptions = NWProtocolFramer.Options(definition: PeerMessageDefinition.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(protocolOptions, at: 0)

        return parameters
    }
}

public class PeerConnection<PeerMessageKind> where PeerMessageKind: PeerMessageKindProtocol {
    private let _logger: Logger = .init(subsystem: "com.peertunnel.framework", category: "peer-connection")
    private let _connection: NWConnection
    private let _messages: PassthroughSubject<PeerMessage<PeerMessageKind>, Never>
    private let _state: CurrentValueSubject<NWConnection.State, Never>

    init(to endpoint: NWEndpoint, password: String) {
        let password = password.data(using: .utf8)!
        let parameters = NWParameters.securePeerConnectionParameters(password: password, relaying: PeerMessageKind.self)
        let connection = NWConnection(to: endpoint, using: parameters)
        _connection = connection
        _messages = PassthroughSubject()
        _state = CurrentValueSubject(connection.state)

        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            self._connectionStateUpdateHandler(newState: newState)
        }

        connection.start(queue: .main)
    }

    init(wrapping connection: NWConnection) {
        _messages = PassthroughSubject()
        _state = CurrentValueSubject(connection.state)
        _connection = connection
        _connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            self._connectionStateUpdateHandler(newState: newState)
        }
        _connection.start(queue: .main)
    }

    deinit {
        _connection.cancel()
    }

    public func waitUntilReady() async {
        if _state.value == .ready {
            return
        }
        for await message in _state.values {
            if message == .ready {
                return
            }
        }
    }

    public func send(messageKind: PeerMessageKind, data: Data) {
        let message = NWProtocolFramer.Message(kind: messageKind.rawValue)
        let context = NWConnection.ContentContext(identifier: "peertunnel.connection.message",
                                                  metadata: [message])

        _connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    assertionFailure(error.debugDescription)
                    self._logger.error("\(error.debugDescription)")
                }
            }
        )
    }

    public var messages: AnyPublisher<PeerMessage<PeerMessageKind>, Never> {
        _messages.eraseToAnyPublisher()
    }

    private func _receiveNextMessage() {
        _connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }

            guard let context else {
                self._logger.debug("Received message with nil context")
                return
            }

            guard let metadata = context.protocolMetadata(definition: PeerMessageDefinition.definition) else {
                self._logger.error("Received message with unexpected definition")
                assertionFailure()
                return
            }

            guard let message = metadata as? NWProtocolFramer.Message else {
                self._logger.error("Received message with unexpected metadata")
                assertionFailure()
                return
            }

            guard let kind = PeerMessageKind(rawValue: message.kind) else {
                self._logger.error("Received message with unexpected peer message kind")
                assertionFailure()
                return
            }

            guard let content else {
                self._logger.error("Received message with invalid content")
                assertionFailure()
                return
            }

            self._messages.send(.init(kind: kind, data: content))

            if error == nil {
                self._receiveNextMessage()
            }
        }
    }

    private func _connectionStateUpdateHandler(newState: NWConnection.State) {
        let connectionDebugDescription = _connection.debugDescription
        _state.send(newState)
        switch newState {
        case .ready:
            _logger.info("\(connectionDebugDescription) established")
            _receiveNextMessage()
        case let .failed(error):
            _logger.fault("\(connectionDebugDescription) failed with \(error)")
            _connection.cancel()
        default:
            break
        }
    }
}
