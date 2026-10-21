import Foundation
import XCTest
@testable import TUSKit

/// Server gives inappropriorate offsets
/// - Parameter data: Data to upload
func prepareNetworkForWrongOffset(data: Data, testID: String? = nil) {
    MockURLProtocol.prepareResponse(for: "POST", testID: testID) { _ in
        MockURLProtocol.Response(status: 200, headers: ["Location": "www.somefakelocation.com"], data: nil)
    }
    
    // Mimick chunk uploading with offsets
    MockURLProtocol.prepareResponse(for: "PATCH", testID: testID) { headers in
        
        guard let headers = headers,
              let strOffset = headers["Upload-Offset"],
              let offset = Int(strOffset),
              let strContentLength = headers["Content-Length"],
              let contentLength = Int(strContentLength) else {
                  let error = "Did not receive expected Upload-Offset and Content-Length in headers"
                  XCTFail(error)
                  fatalError(error)
              }
        
        let newOffset = offset + contentLength - 1 // 1 offset too low. Trying to trigger potential inifnite upload loop. Which the client should handle, of course.
        return MockURLProtocol.Response(status: 200, headers: ["Upload-Offset": String(newOffset)], data: nil)
    }

    // Retries ask the server for its offset, which stays one byte short.
    MockURLProtocol.prepareResponse(for: "HEAD", testID: testID) { _ in
        MockURLProtocol.Response(status: 200, headers: ["Upload-Length": String(data.count),
                                                        "Upload-Offset": String(data.count - 1)], data: nil)
    }
}

func prepareNetworkForSuccesfulUploads(data: Data, lowerCasedKeysInResponses: Bool = false, testID: String? = nil) {
    MockURLProtocol.prepareResponse(for: "POST", testID: testID) { _ in
        let key: String
        if lowerCasedKeysInResponses {
            key = "location"
        } else {
            key = "Location"
        }
        return MockURLProtocol.Response(status: 200, headers: [key: "www.somefakelocation.com"], data: nil)
    }
    
    // Mimick chunk uploading with offsets
    MockURLProtocol.prepareResponse(for: "PATCH", testID: testID) { headers in
        
        guard let headers = headers,
              let strOffset = headers["Upload-Offset"],
              let offset = Int(strOffset),
              let strContentLength = headers["Content-Length"],
              let contentLength = Int(strContentLength) else {
                  let error = "Did not receive expected Upload-Offset and Content-Length in headers"
                  XCTFail(error)
                  fatalError(error)
              }
        
        let newOffset = offset + contentLength
        
        let key: String
        if lowerCasedKeysInResponses {
            key = "upload-offset"
        } else {
            key = "Upload-Offset"
        }
        return MockURLProtocol.Response(status: 200, headers: [key: String(newOffset)], data: nil)
    }
    
}

func prepareNetworkForErronousResponses(testID: String? = nil) {
    MockURLProtocol.prepareResponse(for: "POST", testID: testID) { _ in
        MockURLProtocol.Response(status: 401, headers: [:], data: nil)
    }
    MockURLProtocol.prepareResponse(for: "PATCH", testID: testID) { _ in
        MockURLProtocol.Response(status: 401, headers: [:], data: nil)
    }
    MockURLProtocol.prepareResponse(for: "HEAD", testID: testID) { _ in
        MockURLProtocol.Response(status: 401, headers: [:], data: nil)
    }
}

func prepareNetworkForSuccesfulStatusCall(data: Data, testID: String? = nil) {
    MockURLProtocol.prepareResponse(for: "HEAD", testID: testID) { _ in
        MockURLProtocol.Response(status: 200, headers: ["Upload-Length": String(data.count),
                                                        "Upload-Offset": "0"], data: nil)
    }
}

/// Create call can still succeed. This is useful for triggering a status call.
func prepareNetworkForFailingUploads(testID: String? = nil) {
    // Upload means patch. Letting that fail.
    MockURLProtocol.prepareResponse(for: "PATCH", testID: testID) { _ in
        MockURLProtocol.Response(status: 401, headers: [:], data: nil)
    }
    // Retries ask the server for its offset, which fails the same way.
    MockURLProtocol.prepareResponse(for: "HEAD", testID: testID) { _ in
        MockURLProtocol.Response(status: 401, headers: [:], data: nil)
    }
}

func resetReceivedRequests(testID: String? = nil) {
    MockURLProtocol.clearReceivedRequests(testID: testID)
}

/// A TUS server that tracks the upload offset, so tests can interrupt uploads and check how the client resumes.
final class FakeTUSServer {
    enum PatchOutcome {
        /// Stores every byte and answers 204 with the new offset.
        case accept
        /// Stores the first `bytes` of the request body, then the connection drops.
        case dropAfter(bytes: Int)
        /// Answers with `status` and stores nothing.
        case status(Int)
    }

    enum HeadOutcome {
        /// Reports the stored offset and length.
        case report
        /// Answers with `status`.
        case status(Int)
    }

    let length: Int
    private let lock = NSLock()
    private var storedOffset: Int
    private var patchOutcomes: [PatchOutcome]
    private var headOutcomes: [HeadOutcome]
    private var patchOffsets: [Int] = []
    private var headDates: [Date] = []

    init(length: Int, offset: Int = 0, patchOutcomes: [PatchOutcome] = [], headOutcomes: [HeadOutcome] = []) {
        self.length = length
        self.storedOffset = offset
        self.patchOutcomes = patchOutcomes
        self.headOutcomes = headOutcomes
    }

    /// The `Upload-Offset` of every PATCH received, in order.
    var receivedPatchOffsets: [Int] {
        lock.withLock { patchOffsets }
    }

    var receivedHeadDates: [Date] {
        lock.withLock { headDates }
    }

    func install(testID: String) {
        MockURLProtocol.prepareResponse(for: "POST", testID: testID) { _ in
            MockURLProtocol.Response(status: 201, headers: ["Location": "www.somefakelocation.com"], data: nil)
        }
        MockURLProtocol.prepareResponse(for: "PATCH", testID: testID) { [self] headers in
            lock.withLock { patchResponse(headers: headers ?? [:]) }
        }
        MockURLProtocol.prepareResponse(for: "HEAD", testID: testID) { [self] _ in
            lock.withLock { headResponse() }
        }
    }

    private func patchResponse(headers: [String: String]) -> MockURLProtocol.Response {
        let offset = headers["Upload-Offset"].flatMap(Int.init) ?? -1
        let contentLength = headers["Content-Length"].flatMap(Int.init) ?? 0
        patchOffsets.append(offset)
        let outcome = patchOutcomes.isEmpty ? .accept : patchOutcomes.removeFirst()

        if case let .status(status) = outcome {
            return MockURLProtocol.Response(status: status, headers: [:], data: nil)
        }
        guard offset == storedOffset else {
            return MockURLProtocol.Response(status: 409, headers: [:], data: nil)
        }
        switch outcome {
        case .accept:
            storedOffset += contentLength
            return MockURLProtocol.Response(status: 204, headers: ["Upload-Offset": String(storedOffset)], data: nil)
        case let .dropAfter(bytes):
            storedOffset += min(bytes, contentLength)
            return MockURLProtocol.Response(status: 0, headers: [:], data: nil, error: URLError(.networkConnectionLost))
        case .status:
            fatalError("Handled above")
        }
    }

    private func headResponse() -> MockURLProtocol.Response {
        headDates.append(Date())
        let outcome = headOutcomes.isEmpty ? .report : headOutcomes.removeFirst()
        switch outcome {
        case .report:
            return MockURLProtocol.Response(status: 200, headers: ["Upload-Offset": String(storedOffset), "Upload-Length": String(length)], data: nil)
        case let .status(status):
            return MockURLProtocol.Response(status: status, headers: [:], data: nil)
        }
    }
}
