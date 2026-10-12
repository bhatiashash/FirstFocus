import Foundation

/// Production `Screener`: TypeSafe AI's hosted Jev model (ADR 0036), asked
/// one Yes/No probability question per message.
///
/// The timeout is short on purpose. Jev normally answers in 70–500 ms, and
/// a message whose Screening stalls just goes to the local model instead,
/// so waiting longer only delays that fallback.
public final class JEVScreener: Screener {
    public let serviceName = "JEV (\(jevModelID))"
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, timeout: TimeInterval = 2) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func probability(for input: ScreeningInput) async throws -> Double {
        var request = URLRequest(url: jevEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jevRequestBody(for: input)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw JEVResponseError.httpStatus(http.statusCode)
        }
        return try parseJevProbability(data)
    }
}
