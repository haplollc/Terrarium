// swift-tools-version: 5.9
//
// Terrarium — embedded Python runtime for iOS / macOS apps.
//
// Provides a SwiftUI-friendly API for running Python scripts on-device
// using a bundled CPython 3.13 interpreter, plus an optional WebAssembly
// (Pyodide) fallback for the scientific stack (numpy, pandas, matplotlib,
// scipy, scikit-learn, etc.) where iOS-native wheels don't exist.
//
// To use:
//   1. Add this package to your Xcode project.
//   2. Run `./Scripts/setup-python.sh` once to fetch Python.xcframework.
//   3. Run `./Scripts/fetch-pyodide.sh` once if you want Pyodide support.
//   4. Drag `Resources/python-stdlib`, `Resources/site-packages`,
//      `Resources/lib-dynload`, `Resources/pyodide-host`, and (after
//      fetch) `Resources/pyodide-runtime` into your Xcode target as
//      folder references (blue folders).
//   5. `import Terrarium; let result = await Terrarium.shared.run(code: "print('hi')")`
//
// See README.md for the full integration walk-through.

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
        // System library shim that gives Swift code access to Python's
        // public C API. The actual `Python.xcframework` must be added
        // to the host app's Xcode project manually (or via the setup
        // script that drops it next to the package).
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
                "CPython"
            ],
            path: "Sources/Terrarium",
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
