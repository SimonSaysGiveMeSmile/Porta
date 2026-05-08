# Porta iOS

SwiftUI app + share extension. Code is organized so the pure networking /
tunnel layer lives in `PortaCore` (a Swift Package), which both the app and
share extension depend on, and which has its own unit tests that can run on
macOS without an iPhone.

## Layout

```
ios/
├── PortaCore/                  SwiftPM package (no UIKit/SwiftUI)
│   ├── Package.swift
│   ├── Sources/PortaCore/
│   │   ├── TunnelFrame.swift   binary wire format (matches backend)
│   │   ├── TunnelClient.swift  outbound WebSocket + multiplexer
│   │   ├── PortaAPI.swift      typed client for backend REST
│   │   ├── DeviceIdentity.swift Ed25519 keypair in Keychain
│   │   └── ShareFile.swift     file metadata
│   └── Tests/PortaCoreTests/   frame + API tests
├── Porta/                      iOS app target
│   ├── App/                    PortaApp, AppState, deep links
│   ├── Views/                  Home, ActiveShare, ApprovalSheet
│   ├── Services/               FileServer (answers OpOpen requests)
│   └── Info.plist
└── PortaShareExtension/        iOS Share Extension (Photos / Files → app)
    ├── ShareViewController.swift
    └── Info.plist
```

## Opening in Xcode

This repo ships source files but not an Xcode `.xcodeproj`. Generate one with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) using the included
`project.yml`, or create a new Xcode workspace and add:

1. The `PortaCore` SwiftPM package (Add Package Dependency → Add Local).
2. An iOS App target pointing at `Porta/`.
3. An iOS Share Extension target pointing at `PortaShareExtension/`.

Both app targets should link `PortaCore`.

## Why a Swift package?

The tunnel wire format and API client are the parts most likely to be reused
elsewhere (macOS menu bar app, CLI). Putting them in a package also means
unit tests run under `swift test` without a simulator.
