// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Harbor",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Harbor", targets: ["Harbor"]),
    ],
    dependencies: [
        // 内嵌终端
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        // 自动更新（EdDSA 签名，GitHub Releases 托管）
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // 与界面无关的核心：读目录、监听、排序、导航历史、路径输入
        .target(name: "HarborCore", dependencies: ["CArchive"]),
        // 系统自带 libarchive 的声明（SDK 里没有头文件）
        .systemLibrary(name: "CArchive", path: "Sources/CArchive"),
        // AppKit 界面
        .executableTarget(name: "Harbor", dependencies: ["HarborCore", .product(name: "SwiftTerm", package: "SwiftTerm"),
                                                         .product(name: "Sparkle", package: "Sparkle")]),
        // 性能基准：读目录、排序的耗时
        .executableTarget(name: "HarborBench", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore", "CArchive"]),
    ]
)
