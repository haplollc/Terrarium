// swift-tools-version: 5.9
//
// Terrarium — embedded Python runtime for iOS / macOS apps.
//
// Bundles every resource the runner needs directly inside the SwiftPM
// product. Consumers add a single SwiftPM dependency and get the full
// Python 3.13 interpreter, the bundled standard library, ~30 pure-Python
// packages, the C-extension shim layer, and the Pyodide host bridge —
// no manual Xcode folder references required.
//
// One-time setup before first build:
//
//   ./Scripts/setup-python.sh    # downloads Python.xcframework
//
// (We can't ship the framework in git — it's a 112 MB binary blob. The
// script pulls a pinned BeeWare release.)

import PackageDescription

let package = Package(
    name: "Terrarium",
    platforms: [
        .iOS(.v17),     // ContentUnavailableView + new SwiftUI animation APIs
        .macOS(.v14)
    ],
    products: [
        .library(name: "Terrarium", targets: ["Terrarium"]),
    ],
    dependencies: [
        // Used by the package manager to unzip wheels downloaded from
        // PyPI. Pure Swift, no native deps.
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        // CPython framework — must exist on disk before SwiftPM resolves.
        // Run Scripts/setup-python.sh to fetch it from BeeWare's
        // Python-Apple-support release. Gitignored.
        .binaryTarget(
            name: "Python",
            path: "Python.xcframework"
        ),
        // Headers + module map giving Swift code access to Python's
        // public C API.
        .systemLibrary(
            name: "CPython",
            path: "Sources/CPython",
            pkgConfig: nil,
            providers: []
        ),
        .target(
            name: "Terrarium",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                "CPython",
                "Python"
            ],
            path: "Sources/Terrarium",
            // Every consumer of `import Terrarium` gets these resources
            // inside `Bundle.module` automatically. No host-app wiring
            // required — the package is self-contained.
            resources: [
                .copy("Resources/python-stdlib"),      // 47 MB — Python stdlib
                .copy("Resources/site-packages"),      // 13 MB — curated pure-Python packages
                .copy("Resources/lib-dynload"),        // 14 MB — C extension shims
                .copy("Resources/pyodide-host"),       // tiny — Pyodide WKWebView host
            ],
            swiftSettings: [
                .interoperabilityMode(.C)
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "TerrariumTests",
            dependencies: ["Terrarium"],
            path: "Tests/TerrariumTests"
        ),
    ]
)
