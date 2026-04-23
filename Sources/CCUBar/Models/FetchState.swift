import Foundation

enum FetchError: Error, Equatable {
    case claudeNotFound
    case timeout
    case parseFailure(String)
    case processFailed(Int32)
}

enum FetchState: Equatable {
    case idle
    case loading
    case success(UsageSnapshot)
    case failure(FetchError)
}
