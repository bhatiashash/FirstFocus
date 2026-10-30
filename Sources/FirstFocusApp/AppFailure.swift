import Foundation

public struct AppFailure: Identifiable, Equatable, Sendable {
    public let id: String
    public let message: String
    public let canRetry: Bool
}
