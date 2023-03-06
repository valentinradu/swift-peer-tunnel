//
//  File.swift
//
//
//  Created by Valentin Radu on 05/03/2023.
//

import Foundation
import Network
import os

public protocol PeerMessageKindProtocol: RawRepresentable where Self.RawValue == UInt32 {}

private struct PeerMessageHeader {
    let kind: UInt32
    let length: UInt32

    init(kind: UInt32, length: UInt32) {
        self.kind = kind
        self.length = length
    }

    init(_ buffer: UnsafeMutableRawBufferPointer) {
        var kind: UInt32 = 0
        var length: UInt32 = 0

        withUnsafeMutableBytes(of: &kind) { kindPtr in
            kindPtr.copyMemory(from: UnsafeRawBufferPointer(start: buffer.baseAddress!.advanced(by: 0),
                                                            count: MemoryLayout<UInt32>.size))
        }
        withUnsafeMutableBytes(of: &length) { lengthPtr in
            lengthPtr
                .copyMemory(from: UnsafeRawBufferPointer(start: buffer.baseAddress!
                        .advanced(by: MemoryLayout<UInt32>.size),
                    count: MemoryLayout<UInt32>.size))
        }

        self.kind = kind
        self.length = length
    }

    var encodedData: Data {
        var tempKind = kind
        var tempLength = length
        var data = Data(bytes: &tempKind, count: MemoryLayout<UInt32>.size)
        data.append(Data(bytes: &tempLength, count: MemoryLayout<UInt32>.size))
        return data
    }

    static var encodedSize: Int {
        MemoryLayout<UInt32>.size * 2
    }
}

class PeerMessageDefinition: NWProtocolFramerImplementation {
    static let definition: NWProtocolFramer.Definition = .init(implementation: PeerMessageDefinition.self)

    private let _logger: Logger = .init(subsystem: "com.peertunnel", category: "peer-message-framer")

    static var label: String { "PeerMessageFramer" }

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        .ready
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var tempHeader: PeerMessageHeader?
            let headerSize = PeerMessageHeader.encodedSize
            let parsed = framer.parseInput(minimumIncompleteLength: headerSize,
                                           maximumLength: headerSize) { buffer, isComplete -> Int in
                guard let buffer = buffer else {
                    return 0
                }
                if buffer.count < headerSize {
                    return 0
                }
                tempHeader = PeerMessageHeader(buffer)
                return headerSize
            }

            guard parsed, let header = tempHeader else {
                return headerSize
            }

            let message = NWProtocolFramer.Message(kind: header.kind)

            if !framer.deliverInputNoCopy(length: Int(header.length),
                                          message: message,
                                          isComplete: true) {
                return 0
            }
        }
    }

    func handleOutput(
        framer: NWProtocolFramer.Instance,
        message: NWProtocolFramer.Message,
        messageLength: Int,
        isComplete: Bool
    ) {
        let header = PeerMessageHeader(kind: message.kind, length: UInt32(messageLength))

        framer.writeOutput(data: header.encodedData)

        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            _logger.error("\(error)")
        }
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool {
        true
    }

    func cleanup(framer: NWProtocolFramer.Instance) {}
}

public struct PeerMessage<PeerMessageKind> where PeerMessageKind: PeerMessageKindProtocol {
    public let kind: PeerMessageKind
    public let data: Data
}

extension NWProtocolFramer.Message {
    convenience init(kind: UInt32) {
        self.init(definition: PeerMessageDefinition.definition)
        self["MessageKind"] = kind
    }

    var kind: UInt32 {
        guard let value = self["MessageKind"] as? UInt32 else {
            return 0
        }
        return value
    }
}
