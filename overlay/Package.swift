// swift-tools-version: 5.9
import PackageDescription

// This package exercises only the Foundation ledger; it does not replace the Bazel iOS build.
let package = Package(
    name: "LocalGiftsLedger",
    products: [.library(name: "LocalGiftsLedger", targets: ["LocalGiftsLedger"])],
    targets: [
        .target(name: "LocalGiftsLedger", path: "submodules/TelegramCore/Sources/LocalGifts",
            exclude: ["LocalGiftsStore.swift", "LocalGiftsMarketFilterSettings.swift"], sources: ["LocalGiftsLedger.swift", "LocalGiftsAppPolicy.swift", "LocalGiftsBackup.swift", "LocalGiftsMarketFilter.swift"]),
        .testTarget(name: "LocalGiftsLedgerTests", dependencies: ["LocalGiftsLedger"], path: "LocalGifts/Tests"),
        .target(name: "LocalPremiumModel", path: "Ghostgram/Features/Shared/Sources/Interface",
            exclude: ["InterfaceShared.swift", "EGLocalPremiumSettings.swift", "EGAnimationSettings.swift"], sources: ["EGLocalEmojiStatus.swift"]),
        .testTarget(name: "LocalPremiumModelTests", dependencies: ["LocalPremiumModel"], path: "LocalGifts/PremiumTests"),
        .target(name: "LocalAnimationModel", path: "Ghostgram/GGCore/Sources/Animations", exclude: ["EGAnimationControls.swift"], sources: ["EGAnimationPolicy.swift"]),
        .testTarget(name: "LocalAnimationModelTests", dependencies: ["LocalAnimationModel"], path: "LocalGifts/AnimationTests")
    ]
)
