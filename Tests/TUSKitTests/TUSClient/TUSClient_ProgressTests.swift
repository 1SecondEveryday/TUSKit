import XCTest
@testable import TUSKit

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

    func testProgressRoutedToProgressDelegate() {
        let id = UUID()
        let mockDelegate = MockProgressDelegate()
        api.progressDelegate = mockDelegate

        let task = MockURLSessionTask(taskDescription: id.uuidString)
        api.handleProgressForTask(task, totalBytesSent: 8, totalBytesExpectedToSend: Int64(data.count))

        let flush = expectation(description: "dispatch queue flushed")
        DispatchQueue.main.async { flush.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(mockDelegate.lastID, id)
        XCTAssertEqual(mockDelegate.lastTotalBytesSent, 8)
    }

    func testProgressForwardedForEachValidUUID() {
        let id1 = UUID()
        let id2 = UUID()
        let mockDelegate = MockProgressDelegate()
        api.progressDelegate = mockDelegate

        let task1 = MockURLSessionTask(taskDescription: id1.uuidString)
        api.handleProgressForTask(task1, totalBytesSent: 3, totalBytesExpectedToSend: Int64(data.count))

        let task2 = MockURLSessionTask(taskDescription: id2.uuidString)
        api.handleProgressForTask(task2, totalBytesSent: 7, totalBytesExpectedToSend: Int64(data.count))

        let flush = expectation(description: "dispatch queue flushed")
        DispatchQueue.main.async { flush.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(mockDelegate.lastID, id2)
        XCTAssertEqual(mockDelegate.lastTotalBytesSent, 7)
    }
}

// MARK: - Helpers

private final class MockProgressDelegate: ProgressDelegate {
    var lastID: UUID?
    var lastTotalBytesSent: Int64?

    func progressUpdated(forID id: UUID, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lastID = id
        lastTotalBytesSent = totalBytesSent
    }
}
