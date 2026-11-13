load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "LocalGiftsUI",
    module_name = "LocalGiftsUI",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        "//submodules/AccountContext",
        "//submodules/AsyncDisplayKit",
        "//submodules/ComponentFlow",
        "//submodules/Display",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/TelegramUI/Components/Gifts/GiftAnimationComponent",
    ],
    visibility = ["//visibility:public"],
)
