import XCTest
@testable import TUSKit // Testable only to store an upload's metadata the way an earlier run would have.

/// The delegate hears when a failed request is retried and when an upload continues after an interruption.
final class TUSClient_UploadEventsTests: XCTestCase {

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
    }

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset(testID: mockTestID)
        clearDirectory(dir: fullStoragePath)
    }

    func testDroppedRequestReportsTheRetryAndTheServerOffsetItResumesFrom() throws {
        let server = FakeTUSServer(length: data.count, patchOutcomes: [.dropAfter(bytes: 40)])
        try startClient(server: server, retryPolicy: TUSRetryPolicy(maximumRetries: 3, initialDelay: 0, maximumDelay: 0))

        let id = try client.upload(data: data)
        waitForUploadsToFinish()

        XCTAssertEqual(tusDelegate.retries.map(\.id), [id])
        XCTAssertEqual(tusDelegate.retries.map(\.attempt), [1])
        XCTAssertEqual(tusDelegate.resumes.map(\.offset), [40])
        XCTAssertEqual(tusDelegate.resumes.map(\.reason), [.serverOffset])
    }

    func testEachRetryReportsItsAttemptAndBackoff() throws {
        let server = FakeTUSServer(length: data.count, patchOutcomes: [.status(423)], headOutcomes: [.status(423), .report])
        try startClient(server: server, retryPolicy: TUSRetryPolicy(maximumRetries: 3, initialDelay: 0.3, maximumDelay: 1))

        try client.upload(data: data)
        waitForUploadsToFinish()

        XCTAssertEqual(tusDelegate.retries.map(\.attempt), [1, 2])
        XCTAssertEqual(tusDelegate.retries.map(\.delay), [0, 0.3])
    }

    func testStartReportsStoredUploadsItPicksUp() throws {
        let server = FakeTUSServer(length: data.count, offset: 25)
        let id = try storeUpload(uploadedBytes: 25, remoteDestination: URL(string: "https://tus.example.net/files/stored")!)
        try startClient(server: server, retryPolicy: TUSRetryPolicy(maximumRetries: 3, initialDelay: 0, maximumDelay: 0), reset: false)

        client.start()
        waitForUploadsToFinish()

        XCTAssertEqual(tusDelegate.resumes.map(\.id), [id, id])
        XCTAssertEqual(tusDelegate.resumes.map(\.reason), [.storedUpload, .serverOffset])
        XCTAssertEqual(tusDelegate.resumes.map(\.offset), [25, 25])
        XCTAssertTrue(tusDelegate.retries.isEmpty)
    }

    // MARK: - Helpers

    private func startClient(server: FakeTUSServer, retryPolicy: TUSRetryPolicy, reset: Bool = true) throws {
        server.install(testID: mockTestID)
        client = makeClient(storagePath: relativeStoragePath,
                            sessionIdentifier: "TEST-\(mockTestID!)",
                            mockTestID: mockTestID,
                            chunkSize: 0,
                            retryPolicy: retryPolicy)
        tusDelegate = TUSMockDelegate()
        client.delegate = tusDelegate
        if reset {
            try client.reset()
        }
    }

    /// Stores the file and metadata of an upload the server has already received `uploadedBytes` of.
    private func storeUpload(uploadedBytes: Int, remoteDestination: URL) throws -> UUID {
        let files = try Files(storageDirectory: relativeStoragePath)
        let id = UUID()
        let path = try files.store(data: data, id: id)
        let metaData = UploadMetadata(id: id, filePath: path, uploadURL: remoteDestination, size: data.count, customHeaders: [:], mimeType: nil)
        metaData.remoteDestination = remoteDestination
        metaData.uploadedRange = 0..<uploadedBytes
        try files.encodeAndStore(metaData: metaData)
        return id
    }

    private func waitForUploadsToFinish(_ amount: Int = 1) {
        let uploadExpectation = expectation(description: "Waiting for upload to finish")
        uploadExpectation.expectedFulfillmentCount = amount
        tusDelegate.finishUploadExpectation = uploadExpectation
        waitForExpectations(timeout: 6, handler: nil)
    }
}
