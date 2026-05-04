import XCTest
@testable import TUSKit

// These tests verify that progress is reported via the URLSession delegate path
// (TUSAPI.handleProgressForTask) rather than KVO, so that reconnected background
// tasks — which TUSKit never gets a fresh handle on — still fire progress events.

final class TUSClient_ProgressTests: XCTestCase {

    var api: TUSAPI!
    var files: Files!
    var relativeStoragePath: URL!
    var fullStoragePath: URL!
    var data: Data!

    override func setUp() {
        super.setUp()
        relativeStoragePath = URL(string: "TUSTEST")!
        data = Data("hello from Fat Mike".utf8)

        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockURLProtocol.self]
        api = TUSAPI(sessionConfiguration: configuration)

        do {
            files = try Files(storageDirectory: relativeStoragePath)
            fullStoragePath = files.storageDirectory
            clearDirectory(dir: fullStoragePath)
        } catch {
            XCTFail("Could not set up Files: \(error)")
        }
        MockURLProtocol.reset()
    }

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
        clearDirectory(dir: fullStoragePath)
    }

    // MARK: - observeTask registers a progress callback

    func testObserveTaskRegistersCallbackThatRoutesToProgressDelegate() throws {
        let id = UUID()
        let filePath = try files.store(data: data, id: id)
        let metaData = UploadMetadata(
            id: id,
            filePath: filePath,
            uploadURL: URL(string: "https://tus.example.net/files")!,
            size: data.count
        )
        metaData.remoteDestination = URL(string: "https://tus.example.net/files/\(id.uuidString)")!

        let uploadTask = try UploadDataTask(
            api: api,
            metaData: metaData,
            files: files,
            headerGenerator: HeaderGenerator(handler: nil)
        )

        let mockDelegate = MockProgressDelegate()
        uploadTask.progressDelegate = mockDelegate

        if #available(iOS 11.0, macOS 10.13, *) {
            uploadTask.observeTask(task: URLSessionUploadTask(), size: data.count)
        } else {
            return
        }

        let mockTask = MockURLSessionTask(taskDescription: id.uuidString)
        api.handleProgressForTask(mockTask, totalBytesSent: 8, totalBytesExpectedToSend: Int64(data.count))

        let flush = expectation(description: "dispatch queue flushed")
        uploadTask.queue.async { DispatchQueue.main.async { flush.fulfill() } }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(mockDelegate.lastTotalUploaded, 8)
        XCTAssertEqual(mockDelegate.lastMetaData?.id, id)
    }

    func testObserveTaskOffsetIncludesAlreadyUploadedBytes() throws {
        let id = UUID()
        let filePath = try files.store(data: data, id: id)
        let alreadyUploaded = 5
        let metaData = UploadMetadata(
            id: id,
            filePath: filePath,
            uploadURL: URL(string: "https://tus.example.net/files")!,
            size: data.count
        )
        metaData.remoteDestination = URL(string: "https://tus.example.net/files/\(id.uuidString)")!
        metaData.uploadedRange = 0..<alreadyUploaded

        let uploadTask = try UploadDataTask(
            api: api,
            metaData: metaData,
            files: files,
            range: alreadyUploaded..<data.count,
            headerGenerator: HeaderGenerator(handler: nil)
        )

        let mockDelegate = MockProgressDelegate()
        uploadTask.progressDelegate = mockDelegate

        if #available(iOS 11.0, macOS 10.13, *) {
            uploadTask.observeTask(task: URLSessionUploadTask(), size: data.count - alreadyUploaded)
        } else {
            return
        }

        let mockTask = MockURLSessionTask(taskDescription: id.uuidString)
        api.handleProgressForTask(mockTask, totalBytesSent: 3, totalBytesExpectedToSend: Int64(data.count - alreadyUploaded))

        let flush = expectation(description: "dispatch queue flushed")
        uploadTask.queue.async { DispatchQueue.main.async { flush.fulfill() } }
        waitForExpectations(timeout: 1)

        // Should report alreadyUploaded (5) + bytes sent this chunk (3) = 8
        XCTAssertEqual(mockDelegate.lastTotalUploaded, alreadyUploaded + 3)
    }

    func testProgressCallbackNotFiredForDifferentTaskIdentifier() throws {
        let id = UUID()
        let filePath = try files.store(data: data, id: id)
        let metaData = UploadMetadata(
            id: id,
            filePath: filePath,
            uploadURL: URL(string: "https://tus.example.net/files")!,
            size: data.count
        )
        metaData.remoteDestination = URL(string: "https://tus.example.net/files/\(id.uuidString)")!

        let uploadTask = try UploadDataTask(
            api: api,
            metaData: metaData,
            files: files,
            headerGenerator: HeaderGenerator(handler: nil)
        )

        let mockDelegate = MockProgressDelegate()
        uploadTask.progressDelegate = mockDelegate

        if #available(iOS 11.0, macOS 10.13, *) {
            uploadTask.observeTask(task: URLSessionUploadTask(), size: data.count)
        } else {
            return
        }

        let unrelatedTask = MockURLSessionTask(taskDescription: UUID().uuidString)
        api.handleProgressForTask(unrelatedTask, totalBytesSent: 8, totalBytesExpectedToSend: Int64(data.count))

        let flush = expectation(description: "dispatch queue flushed")
        uploadTask.queue.async { DispatchQueue.main.async { flush.fulfill() } }
        waitForExpectations(timeout: 1)

        XCTAssertNil(mockDelegate.lastTotalUploaded, "Progress from an unrelated task should not reach this upload's delegate")
    }
}

// MARK: - Helpers

private final class MockProgressDelegate: ProgressDelegate {
    var lastTotalUploaded: Int?
    var lastMetaData: UploadMetadata?

    func progressUpdatedFor(metaData: UploadMetadata, totalUploadedBytes: Int) {
        lastMetaData = metaData
        lastTotalUploaded = totalUploadedBytes
    }
}
