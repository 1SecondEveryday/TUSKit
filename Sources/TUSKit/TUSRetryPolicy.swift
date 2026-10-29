//
//  TUSRetryPolicy.swift
//
//

import Foundation

/// How a `TUSClient` retries an upload after a failed request.
///
/// The first retry is immediate; later ones wait, doubling each time up to `maximumDelay`. The retry count resets
/// whenever a retry finds the server's offset has moved forward, so a slow connection keeps going while it makes
/// progress. A status check answering one of `permanentStatusCodes` fails the upload without retrying.
public struct TUSRetryPolicy: Equatable {
    /// The statuses the TUS protocol uses for an upload that is unknown or has expired.
    public static let defaultPermanentStatusCodes: Set<Int> = [404, 410]

    /// How many times to retry before reporting the upload as failed. 2 means 3 attempts in total.
    public var maximumRetries: Int
    /// The wait before the second consecutive retry. Later waits double up to `maximumDelay`.
    public var initialDelay: TimeInterval
    /// The longest wait between retries.
    public var maximumDelay: TimeInterval
    /// Statuses from a status check (`HEAD`) meaning the upload can never finish. Add to
    /// `defaultPermanentStatusCodes` for servers that use others, e.g. 400 for an expired signature.
    public var permanentStatusCodes: Set<Int>

    public init(maximumRetries: Int = 2, initialDelay: TimeInterval = 1, maximumDelay: TimeInterval = 30,
                permanentStatusCodes: Set<Int> = TUSRetryPolicy.defaultPermanentStatusCodes) {
        self.maximumRetries = maximumRetries
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.permanentStatusCodes = permanentStatusCodes
    }

    public static let `default` = TUSRetryPolicy()

    /// The wait before retry number `retry`, counting from 1.
    func delay(beforeRetry retry: Int) -> TimeInterval {
        guard retry > 1, initialDelay > 0 else { return 0 }
        let exponent = Double(min(retry - 2, 30))
        return min(maximumDelay, initialDelay * pow(2, exponent))
    }
}
