import XCTest
import TUSKit // No testable import: these exercise the public API against a fake server.

/// Interrupted and rejected uploads resume from the server's offset instead of starting over.
final class TUSClient_ResumeTests: XCTestCase {

    var client: TUSClient!
    var tusDelegate: TUSMockDelegate!
    var relativeStoragePath: URL!
    var fullStoragePath: URL!
    var mockTestID: String!
    let data = Data((0..<100).map { UInt8($0) })

    override func setUp() {
        super.setUp()
        relativeStoragePath = URL(string: UUID().uuidString)!
        mockTestID = UUID().uuidString
        MockURLProtocol.reset(testID: mockTestID)
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fullStoragePath = docDir.appendingPathComponent(relativeStoragePath.absoluteString)
        clearDirectory(dir: fullStoragePath)
        tusDelegate = TUSMockDelegate()
    }

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset(testID: mockTestID)
        clearDirectory(dir: fullStoragePath)
    }

    // MARK: - Resuming from the server offset

    func testInterruptedSingleRequestUploadResumesFromServerOffset() throws {
        let server = FakeTUSServer(length: data.count, patchOutcomes: [.dropAfter(bytes: 40)])
        try startClient(server: server, chunkSize: 0)

        try client.upload(data: data)
        waitForUploadsToFinish()

        XCTAssertEqual(server.receivedPatchOffsets, [0, 40])
        XCTAssertTrue(tusDelegate.failedUploads.isEmpty)
    }

    func testConflictResyncsWithServerAndResumes() throws {
        // The server already has bytes the client doesn't know about, so the first PATCH is rejected with 409.
        let server = FakeTUSServer(length: data.count, offset: 30)
        try startClient(server: server, chunkSize: 0)

        try client.upload(data: data)
        waitForUploadsToFinish()

        XCTAssertEqual(server.receivedPatchOffsets, [0, 30])
        XCTAssertTrue(tusDelegate.failedUploads.isEmpty)
    }

    func testHeadShowingCompleteUploadFinishes() throws {
        // Every byte arrived, but the connection dropped before the response.
        let server = FakeTUSServer(length: data.count, patchOutcomes: [.dropAfter(bytes: 100)])
        try startClient(server: server, chunkSize: 0)

        try client.upload(data: data)
        waitForUploadsToFinish()

        XCTAssertEqual(server.receivedPatchOffsets, [0])
        XCTAssertTrue(tusDelegate.failedUploads.isEmpty)
    }

    // MARK: - Retry budget

    func testRetriesContinueWhileTheServerOffsetAdvances() throws {
        // More consecutive failures than the 2 retries allowed, but each one stores more bytes.
        let drops = [FakeTUSServer.PatchOutcome](repeating: .dropAfter(bytes: 20), count: 4)
        let server = FakeTUSServer(length: data.count, patchOutcomes: drops)
        try startClient(server: server, chunkSize: 0)

        try client.upload(data: data)
        waitForUploadsToFinish()

        XCTAssertEqual(server.receivedPatchOffsets, [0, 20, 40, 60, 80])
    }

    func testRetriesStopWhenTheServerOffsetDoesNotAdvance() throws {
        let drops = [FakeTUSServer.PatchOutcome](repeating: .dropAfter(bytes: 0), count: 10)
        let server = FakeTUSServer(length: data.count, patchOutcomes: drops)
        try startClient(server: server, chunkSize: 0)

        try client.upload(data: data)
        waitForUploadsToFail()

        XCTAssertEqual(server.receivedPatchOffsets, [0, 0, 0])
    }

    // MARK: - Chunked uploads

    func testChunkedUploadCompletes() throws {
        let server = FakeTUSServer(length: data.count)
        try startClient(server: server, chunkSize: 25)

        try client.upload(data: data)
        waitForUploadsToFinish()

        XCTAssertEqual(server.receivedPatchOffsets, [0, 25, 50, 75])
    }

    func testInterruptedChunkResumesFromServerOffset() throws {
        let server = FakeTUSServer(length: data.count, patchOutcomes: [.accept, .dropAfter(bytes: 10)])
        try startClient(server: server, chunkSize: 25)

        try client.upload(data: data)
        waitForUploadsToFinish()

        XCTAssertEqual(server.receivedPatchOffsets, [0, 25, 35, 60, 85])
    }

    // MARK: - Helpers

    private func startClient(server: FakeTUSServer, chunkSize: Int) throws {
        server.install(testID: mockTestID)
        client = makeClient(storagePath: relativeStoragePath,
                            sessionIdentifier: "TEST-\(mockTestID!)",
                            mockTestID: mockTestID,
                            chunkSize: chunkSize)
        tusDelegate = TUSMockDelegate()
        client.delegate = tusDelegate
        try client.reset()
    }

    private func waitForUploadsToFinish(_ amount: Int = 1) {
        let uploadExpectation = expectation(description: "Waiting for upload to finish")
        uploadExpectation.expectedFulfillmentCount = amount
        tusDelegate.finishUploadExpectation = uploadExpectation
        waitForExpectations(timeout: 6, handler: nil)
    }

    private func waitForUploadsToFail(_ amount: Int = 1) {
        let uploadFailedExpectation = expectation(description: "Waiting for upload to fail")
        uploadFailedExpectation.expectedFulfillmentCount = amount
        tusDelegate.uploadFailedExpectation = uploadFailedExpectation
        waitForExpectations(timeout: 6, handler: nil)
    }
}
