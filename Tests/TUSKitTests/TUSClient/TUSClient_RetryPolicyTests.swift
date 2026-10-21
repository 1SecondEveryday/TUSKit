import XCTest
@testable import TUSKit // Testable only for TUSRetryPolicy's delay schedule; the rest goes through the public API.

/// Backoff between retries, and statuses that end an upload without retrying.
final class TUSClient_RetryPolicyTests: XCTestCase {

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

    // MARK: - Backoff

    func testDelaysDoubleAfterAnImmediateFirstRetry() {
        let policy = TUSRetryPolicy(maximumRetries: 8, initialDelay: 2, maximumDelay: 30)
        XCTAssertEqual((1...7).map { policy.delay(beforeRetry: $0) }, [0, 2, 4, 8, 16, 30, 30])
    }

    func testLockedUploadBacksOffThenSucceeds() throws {
        let server = FakeTUSServer(length: data.count, patchOutcomes: [.status(423)], headOutcomes: [.status(423), .report])
        try startClient(server: server, retryPolicy: TUSRetryPolicy(maximumRetries: 3, initialDelay: 0.3, maximumDelay: 1))

        try client.upload(data: data)
        waitForUploadsToFinish()

        let headDates = server.receivedHeadDates
        XCTAssertEqual(headDates.count, 2)
        if headDates.count == 2 {
            XCTAssertGreaterThanOrEqual(headDates[1].timeIntervalSince(headDates[0]), 0.25)
        }
        XCTAssertTrue(tusDelegate.failedUploads.isEmpty)
    }

    func testCancellingDuringBackoffStopsTheRetry() throws {
        let server = FakeTUSServer(length: data.count, patchOutcomes: [.status(423)], headOutcomes: [.status(423), .report])
        try startClient(server: server, retryPolicy: TUSRetryPolicy(maximumRetries: 3, initialDelay: 1, maximumDelay: 1))

        let id = try client.upload(data: data)
        let firstHead = expectation(description: "First status check")
        DispatchQueue.global().async {
            while server.receivedHeadDates.isEmpty { usleep(10_000) }
            firstHead.fulfill()
        }
        wait(for: [firstHead], timeout: 3)
        try client.cancel(id: id)

        // Past the 1 s backoff: the cancelled retry must not run.
        let pause = expectation(description: "Wait out the backoff")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { pause.fulfill() }
        wait(for: [pause], timeout: 3)

        XCTAssertEqual(server.receivedHeadDates.count, 1)
        XCTAssertEqual(server.receivedPatchOffsets, [0])
    }

    // MARK: - Permanent failures

    func testGoneOrExpiredUploadFailsWithoutRetrying() throws {
        for status in [404, 410] {
            setUp()
            let server = FakeTUSServer(length: data.count, patchOutcomes: [.dropAfter(bytes: 10)], headOutcomes: [.status(status)])
            try startClient(server: server, retryPolicy: TUSRetryPolicy(maximumRetries: 5, initialDelay: 0, maximumDelay: 0))

            try client.upload(data: data)
            waitForUploadsToFail()

            XCTAssertEqual(server.receivedHeadDates.count, 1, "HEAD \(status) should not be retried")
            XCTAssertEqual(server.receivedPatchOffsets, [0], "HEAD \(status) should not lead to another PATCH")
            tearDown()
        }
    }

    func testCallerSuppliedStatusIsTreatedAsPermanent() throws {
        let policy = TUSRetryPolicy(maximumRetries: 5, initialDelay: 0, maximumDelay: 0,
                                    permanentStatusCodes: TUSRetryPolicy.defaultPermanentStatusCodes.union([400]))
        let server = FakeTUSServer(length: data.count, patchOutcomes: [.dropAfter(bytes: 10)], headOutcomes: [.status(400)])
        try startClient(server: server, retryPolicy: policy)

        try client.upload(data: data)
        waitForUploadsToFail()

        XCTAssertEqual(server.receivedHeadDates.count, 1)
        XCTAssertEqual(server.receivedPatchOffsets, [0])
    }

    func testOtherStatusesAreRetriedByDefault() throws {
        let server = FakeTUSServer(length: data.count, patchOutcomes: [.dropAfter(bytes: 10)], headOutcomes: [.status(400)])
        try startClient(server: server, retryPolicy: TUSRetryPolicy(maximumRetries: 5, initialDelay: 0, maximumDelay: 0))

        try client.upload(data: data)
        waitForUploadsToFinish()

        XCTAssertEqual(server.receivedHeadDates.count, 2)
        XCTAssertEqual(server.receivedPatchOffsets, [0, 10])
    }

    // MARK: - Helpers

    private func startClient(server: FakeTUSServer, retryPolicy: TUSRetryPolicy) throws {
        server.install(testID: mockTestID)
        client = makeClient(storagePath: relativeStoragePath,
                            sessionIdentifier: "TEST-\(mockTestID!)",
                            mockTestID: mockTestID,
                            chunkSize: 0,
                            retryPolicy: retryPolicy)
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
