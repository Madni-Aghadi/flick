import XCTest

/// Runs on a real iPhone against the Mac app in test mode (see Tools/e2e.sh), which
/// checks on the Mac side what actually arrived. Each test drives one surface.
final class FlickUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        let code = ProcessInfo.processInfo.environment["FLICK_CODE"] ?? "246810"
        app.launchArguments += ["-FlickTestPairCode", code, "-FlickFakeMotion"]
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for label in ["Allow", "OK", "Allow While Using App", "Continue"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    private func launch(mode: String, reset: Bool = false) {
        if reset { app.launchArguments.append("-FlickResetPairing") }
        app.launchArguments += ["-FlickMode", mode]
        app.launch()
        allowSystemAlerts()
        XCTAssertTrue(app.descendants(matching: .any)["status.connected"].waitForExistence(timeout: 25), "connected to the Mac")
    }

    /// Local Network / mic / speech prompts come from SpringBoard.
    private func allowSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<6 {
            let alert = springboard.alerts.firstMatch
            if alert.waitForExistence(timeout: 2) {
                for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    break
                }
            } else { break }
        }
    }

    func test1_PairAndConnect() {
        launch(mode: "trackpad", reset: true)
        snapshot("trackpad")
    }

    func test2_TrackpadMoves() {
        launch(mode: "trackpad")
        let pad = app.descendants(matching: .any)["trackpad"]
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        Thread.sleep(forTimeInterval: 0.5)
    }

    func test3_TypeIntoMac() {
        launch(mode: "keys")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "iOS keyboard is up")
        app.typeText("hi flick")
        app.descendants(matching: .any)["key.return"].tap()
        snapshot("keys")
        Thread.sleep(forTimeInterval: 0.5)
    }

    func test4_AirPointer() {
        launch(mode: "air")
        let clutch = app.descendants(matching: .any)["air.clutch"]
        XCTAssertTrue(clutch.waitForExistence(timeout: 5))
        snapshot("air")
        // Fake motion = steady turn right while the Air tab is open.
        Thread.sleep(forTimeInterval: 1.5)
    }

    func test5_ScreenView() {
        launch(mode: "screen")
        let video = app.descendants(matching: .any)["screen.video"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        let live = NSPredicate(format: "value == 'live'")
        expectation(for: live, evaluatedWith: video)
        waitForExpectations(timeout: 10)
        Thread.sleep(forTimeInterval: 1.5)
        snapshot("screen")
    }

    func test6_MoreAndModes() {
        launch(mode: "more")
        snapshot("more")
        app.descendants(matching: .any)["more.drive"].tap()
        let gas = app.descendants(matching: .any)["drive.gas"]
        XCTAssertTrue(gas.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)   // rotation to landscape
        snapshot("drive")
        app.descendants(matching: .any)["drive.close"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: gas)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 1.2)   // rotation back
        app.descendants(matching: .any)["more.present"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["present.laser"].waitForExistence(timeout: 5))
        snapshot("present")
        app.descendants(matching: .any)["present.close"].tap()
        app.descendants(matching: .any)["ask.open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ask.field"].waitForExistence(timeout: 5))
        snapshot("ask")
    }

    func test7_AskClaude() {
        launch(mode: "trackpad")
        app.descendants(matching: .any)["ask.open"].tap()
        let field = app.descendants(matching: .any)["ask.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Reply with exactly the word: pong\n")
        let answer = app.descendants(matching: .any)["ask.answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 120), "Claude answered")
        XCTAssertTrue(answer.label.lowercased().contains("pong"), "answer: \(answer.label)")
        snapshot("ask-answer")
    }

    /// Taps the live Mac screen where the Mac's probe window is, then right/left clicks with the trackpad.
    func test8_ScreenTapAndTrackpadClicks() {
        let env = ProcessInfo.processInfo.environment
        let px = Double(env["FLICK_PROBE_X"] ?? "0.24")!, py = Double(env["FLICK_PROBE_Y"] ?? "0.69")!
        let aspect = Double(env["FLICK_MAC_ASPECT"] ?? "1.545")!
        launch(mode: "screen")
        let video = app.descendants(matching: .any)["screen.video"]
        expectation(for: NSPredicate(format: "value == 'live'"), evaluatedWith: video)
        waitForExpectations(timeout: 10)
        let f = video.frame
        var w = f.width, h = f.width / aspect
        if h > f.height { h = f.height; w = h * aspect }
        let x = (f.width - w) / 2 + px * w, y = (f.height - h) / 2 + py * h
        video.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        app.descendants(matching: .any)["mode.trackpad"].tap()
        let pad = app.descendants(matching: .any)["trackpad"]
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        pad.twoFingerTap()
        Thread.sleep(forTimeInterval: 0.6)
        pad.tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    func test9_ShortcutConnection() {
        app.launchArguments.append("-FlickOneShotTest")
        launch(mode: "trackpad")
        XCTAssertTrue(app.descendants(matching: .any)["oneshot.ok"].waitForExistence(timeout: 15), "one-shot connection worked")
    }

    // MARK: Bluetooth mode (no Mac app). The Mac must be paired with "Flick" over Bluetooth.

    private func launchBluetooth(mode: String) {
        app = XCUIApplication()
        app.launchArguments = ["-FlickBluetoothOnly", "-FlickFakeMotion", "-FlickMode", mode]
        app.launch()
        allowSystemAlerts()
        XCTAssertTrue(app.descendants(matching: .any)["status.connected"].waitForExistence(timeout: 30), "Bluetooth host connected")
        XCTAssertTrue(app.staticTexts["Bluetooth"].exists, "talking over Bluetooth, not the Mac app")
    }

    func testB1_BluetoothTrackpad() {
        launchBluetooth(mode: "trackpad")
        let pad = app.descendants(matching: .any)["trackpad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        snapshot("bt-trackpad")
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        Thread.sleep(forTimeInterval: 0.6)
    }

    func testB2_BluetoothTyping() {
        launchBluetooth(mode: "keys")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Hi flick, 42!")
        app.descendants(matching: .any)["key.return"].tap()
        snapshot("bt-keys")
        Thread.sleep(forTimeInterval: 0.8)
    }

    func testB3_BluetoothClicks() {
        launchBluetooth(mode: "trackpad")
        let pad = app.descendants(matching: .any)["trackpad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        pad.tap()
        Thread.sleep(forTimeInterval: 0.7)
        pad.twoFingerTap()
        Thread.sleep(forTimeInterval: 0.7)
    }

    func testB4_BluetoothAir() {
        launchBluetooth(mode: "air")
        let orb = app.descendants(matching: .any)["air.clutch"]
        XCTAssertTrue(orb.waitForExistence(timeout: 5))
        snapshot("bt-air")
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Real gyro (no fake motion): the motion sensor must be delivering samples while Air is open.
    func testM1_MotionSensorDelivers() {
        app = XCUIApplication()
        app.launchArguments = ["-FlickMode", "air"]
        app.launch()
        allowSystemAlerts()
        let orb = app.descendants(matching: .any)["air.clutch"]
        XCTAssertTrue(orb.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2.5)
        let value = (orb.value as? String) ?? ""
        let n = Int(value.split(separator: " ").last ?? "0") ?? 0
        XCTAssertGreaterThan(n, 100, "gyro samples after 2.5 s: \(value)")
    }

    func testB5_BluetoothScreens() {
        launchBluetooth(mode: "more")
        snapshot("bt-more")
        app.descendants(matching: .any)["more.drive"].tap()
        let gas = app.descendants(matching: .any)["drive.gas"]
        XCTAssertTrue(gas.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        snapshot("bt-drive")
        app.descendants(matching: .any)["drive.close"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        app.descendants(matching: .any)["more.present"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["present.laser"].waitForExistence(timeout: 5))
        snapshot("bt-present")
        app.descendants(matching: .any)["present.close"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.descendants(matching: .any)["status.connected"].tap()
        Thread.sleep(forTimeInterval: 1)
        snapshot("bt-settings")
    }

    /// No Mac needed (runs on the simulator): over plain Bluetooth, Ask can't reach Claude, so it offers pairing.
    func testS1_AskWithoutMacOffersPairing() {
        app = XCUIApplication()
        app.launchArguments = ["-FlickBluetoothOnly", "-everConnected", "YES", "-FlickMode", "more", "-FlickOpen", "ask"]
        app.launch()
        let card = app.descendants(matching: .any)["ask.needsMac"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "Ask explains it needs Flick for Mac")
        XCTAssertFalse(app.descendants(matching: .any)["ask.field"].exists, "no prompt field to type into")
        snapshot("ask-needs-mac")
        app.descendants(matching: .any)["ask.pair"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "Ask sheet closed")
        XCTAssertTrue(app.staticTexts["Flick for Mac"].waitForExistence(timeout: 5), "pairing sheet opened")
        snapshot("ask-pair-sheet")
    }

    /// Wrong code (needs a Mac helper in pairing mode, e.g. Tools/sim-e2e.sh): rejected fast, keyboard back for a retype.
    func test0_WrongCodeIsRejected() {
        app = XCUIApplication()
        app.launchArguments = ["-FlickTestPairCode", "000000", "-FlickResetPairing", "-FlickMode", "trackpad"]
        app.launch()
        allowSystemAlerts()
        XCTAssertTrue(app.descendants(matching: .any)["pair.code"].waitForExistence(timeout: 15), "pairing sheet with the code")
        let started = Date()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 12), "code rejected, keyboard up to retype")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8.5, "wrong code shouldn't hang")
        XCTAssertFalse(app.descendants(matching: .any)["status.connected"].exists)
        snapshot("pair-wrong-code")
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
