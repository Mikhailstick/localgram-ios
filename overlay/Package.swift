// swift-tools-version: 5.9
import PackageDescription

// This package exercises only the Foundation ledger; it does not replace the Bazel iOS build.
let package = Package(
    name: "LocalGiftsLedger",
    products: [.library(name: "LocalGiftsLedger", targets: ["LocalGiftsLedger"])],
    targets: [
        .target(name: "LocalGiftsLedger", path: "submodules/TelegramCore/Sources/LocalGifts",
            exclude: ["LocalGiftsStore.swift"], sources: ["LocalGiftsLedger.swift"]),
        .testTarget(name: "LocalGiftsLedgerTests", dependencies: ["LocalGiftsLedger"], path: "LocalGifts/Tests")
    ]
)
