// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ViewStereo",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ViewStereo",
            targets: ["ViewStereo"]
        )
    ],
    dependencies: [
        .package(path: "../StereoStudioCore"),
        .package(path: "../stalign_src/Packages/StereoCore")
    ],
    targets: [
        .executableTarget(
            name: "ViewStereo",
            dependencies: [
                "StereoStudioCore",
                "StereoCore"
            ],
            path: "Sources/ViewStereo",
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/WelcomeIcon.png"),
                .process("Resources/help_ja.html"),
                .process("Resources/help_en.html"),
                .process("Resources/ja.lproj"),
                .process("Resources/en.lproj"),
                .copy("Resources/StereoCardSeg.mlmodelc"),
                .copy("Resources/MobileSAMEncoder.mlmodelc"),
                .copy("Resources/MobileSAMDecoder.mlmodelc"),
                .copy("Resources/SAM2_1TinyImageEncoderFLOAT16.mlmodelc"),
                .copy("Resources/SAM2_1TinyPromptEncoderFLOAT16.mlmodelc"),
                .copy("Resources/SAM2_1TinyMaskDecoderFLOAT16.mlmodelc"),
                .copy("Resources/NAFNetDeblur.mlmodelc")
            ],
            cSettings: [
                .define("ACCELERATE_NEW_LAPACK", to: "1"),
                .define("ACCELERATE_LAPACK_ILP64", to: "1")
            ],
            swiftSettings: [
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64")
            ]
        )
    ]
)
