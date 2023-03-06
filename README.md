# PeerTunnel

A secure, peer-to-peer tunnel using Bonjour and the `Network` framework. 

## Installation

Via SPM:

```swift
dependencies: [
    // ..
    .package(url: "https://github.com/valentinradu/swift-peer-tunnel.git", from: .init(0, 0, 1))
],
// ..
targets: [
    .target(
        // ..
        dependencies: [
            .product(name: "swift-peer-tunnel", package: "PeerTunnel")
        ]
    )
]
```

## Usage

`PeerTunnel` enables communication between two processes through Bonjour. To establish a connection, we first have to advertise a service by providing the service name, password required to join, and message type. 

```swift
/// `HelloPeerMessageKind` will be passed between our two peers 
enum HelloPeerMessageKind: UInt32, PeerMessageKindProtocol {
    case hello
}

// `PeerClamant` advertises `hello-service` over the network using Bonjour
let peerA = try PeerClamant<TestPeerMessageKind>(serviceName: "hello-service",
                                                 password: "password")
await peerA.listen()

// Then waits until the first peer connects 
let connectionA = peerA.waitForConnection()

// Once we have a connection, we can use it to send and receive data
connectionA.send(messageKind: .hello, data: Data())
``` 

On the other side, we try to find the service and connect to it. 

```swift
/// `HelloPeerMessageKind` needs to be declared here as well and it has to match the 
/// declaration on the clamant's side. You can do this by sharing it via a framework. 
enum HelloPeerMessageKind: UInt32, PeerMessageKindProtocol {
    case hello
}

// `PeerSuppliant` looks for `hello-service` via Bonjour
let peerB = PeerSuppliant<TestPeerMessageKind>(targetService: "hello-service",
                                               password: "password")
await peerB.discover()

// Then waits until it finds the service
let connectionB = try await peerB.waitForConnection()

// Once we have a connection, we can use it to send and receive data
for await message in connectionB.messages.values {
    print(message.kind)
}
``` 

## Security

`PeerTunnel` generates a pre-shared key from the provided password using the `TLS_AES_128_GCM_SHA256` cipher suite. `Network.framework` handles all the lower-level encrypting/decrypting functionality following the industry standards.

If you plan to use `PeerTunnel` for security-critical applications, we recommend auditing the code first.
