import XCTest
@testable import backit

final class DropboxJobOutcomeTests: XCTestCase {

    func testCleanSyncIsDone() {
        XCTAssertEqual(DropboxJob.outcome(syncSucceeded: true, uncopiedFiles: 0, incompleteFolders: 0), .done)
    }

    func testSkippedFilesAreAWarning() {
        XCTAssertEqual(DropboxJob.outcome(syncSucceeded: true, uncopiedFiles: 3, incompleteFolders: 0), .warning)
        XCTAssertEqual(DropboxJob.outcome(syncSucceeded: false, uncopiedFiles: 3, incompleteFolders: 0), .warning)
    }

    func testIncompleteFoldersAreAWarning() {
        XCTAssertEqual(DropboxJob.outcome(syncSucceeded: true, uncopiedFiles: 0, incompleteFolders: 2), .warning)
    }

    func testFailedSyncWithNothingIdentifiedIsFailed() {
        XCTAssertEqual(DropboxJob.outcome(syncSucceeded: false, uncopiedFiles: 0, incompleteFolders: 0), .failed)
    }

    func testWarningReasonCountsFilesAndFolders() {
        XCTAssertNil(DropboxJob.warningReason(uncopiedFiles: 0, incompleteFolders: 0))
        XCTAssertEqual(DropboxJob.warningReason(uncopiedFiles: 1, incompleteFolders: 0),
                       "1 file couldn't be copied")
        XCTAssertEqual(DropboxJob.warningReason(uncopiedFiles: 3, incompleteFolders: 2),
                       "3 files couldn't be copied; 2 folders couldn't be fully synced")
    }

    func testCleanupOutputWithRealErrorsMeansFolderIncomplete() {
        let fileError = """
        {"level":"error","msg":"Failed to copy: unexpected EOF","object":"Docs/a.pdf"}
        """
        let dirError = """
        {"level":"error","msg":"error reading source directory: 500","object":"Docs"}
        """
        XCTAssertTrue(DropboxJob.cleanupLeftErrors(fileError))
        XCTAssertTrue(DropboxJob.cleanupLeftErrors(dirError))
    }

    func testCleanupOutputWithOnlyBenignErrorsIsComplete() {
        let modtime = """
        {"level":"error","msg":"failed to set directory modtime: chtimes x: no such file or directory","object":"Docs"}
        """
        let rateLimit = """
        {"level":"error","msg":"Failed to copy: too_many_requests/retry_after","object":"Docs/a.pdf"}
        """
        let stats = """
        {"level":"notice","msg":"stats","stats":{"errors":0}}
        """
        XCTAssertFalse(DropboxJob.cleanupLeftErrors([modtime, rateLimit, stats, ""].joined(separator: "\n")))
    }
}
