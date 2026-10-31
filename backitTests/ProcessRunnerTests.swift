import XCTest
@testable import backit

final class ProcessRunnerTests: XCTestCase {

    // A pipe that isn't read until exit fills at ~64 KB and blocks the child forever;
    // this would hang if stderr were collected that way.
    func testCollectsStderrLargerThanPipeBuffer() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "yes 'no space left on device' | head -c 300000 >&2"]
        let stderr = await ProcessRunner.runCollectingStderr(proc)
        XCTAssertEqual(stderr?.utf8.count, 300_000)
        XCTAssertEqual(proc.terminationStatus, 0)
    }

    func testReturnsNilWhenProcessCannotLaunch() async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/nonexistent/rclone")
        let stderr = await ProcessRunner.runCollectingStderr(proc)
        XCTAssertNil(stderr)
    }
}
