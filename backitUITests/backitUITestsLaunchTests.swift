//
//  backitUITestsLaunchTests.swift
//  backitUITests
//
//  Created by Joe McMahon on 3/5/26.
//

import XCTest

final class backitUITestsLaunchTests: XCTestCase {

    // Cycling through UI configurations flips the system light/dark appearance,
    // which can make background agents (e.g. Adobe's AdobeCRDaemon) register and
    // vanish mid-test; XCTest then waits 120s on them and fails. One run is enough.
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
