//
//  TerrariumTests.swift — smoke tests that exercise the package surface.
//
//  These don't initialize the runtime (which requires Python.xcframework
//  to be linked into a host app), they just confirm the public API
//  compiles cleanly from outside the module.
//

import XCTest
@testable import Terrarium

final class TerrariumTests: XCTestCase {

    func testPublicAPISurfaceCompiles() {
        // Each of these references is a smoke test that the public type
        // exists and is exported. If any go red, the package API has
        // drifted in a breaking way.
        let _: Terrarium = Terrarium.shared
        let _: PythonRunResult = PythonRunResult.empty
        let _: PyodidePackageInfo? = nil
        let _: PyodideBridge = .shared
    }

    @MainActor
    func testEmptyResultIsSuccess() {
        let r = PythonRunResult.empty
        XCTAssertTrue(r.isSuccess)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout, "")
    }
}
