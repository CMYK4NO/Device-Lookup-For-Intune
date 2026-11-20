import Foundation
import Network

enum LoopbackRequestParser {
    /// Returns the query items of a `GET /?...state=...` request, or nil for anything else
    /// (favicon requests, preconnects, other methods).
    static func queryItems(fromRequest data: Data) -> [URLQueryItem]? {
        guard let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost" + String(parts[1])),
              components.path == "/",
              let items = components.queryItems,
              items.contains(where: { $0.name == "state" })
        else { return nil }
        return items
    }
}

/// One-shot HTTP listener on the loopback interface that receives the OAuth redirect.
/// Every stored property is a constant and all callbacks run on `queue`, so sharing it between threads is safe.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let results: AsyncThrowingStream<[URLQueryItem], Error>
    private let resultContinuation: AsyncThrowingStream<[URLQueryItem], Error>.Continuation

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
        var continuation: AsyncThrowingStream<[URLQueryItem], Error>.Continuation!
        results = AsyncThrowingStream { continuation = $0 }
        resultContinuation = continuation
    }

    /// Starts listening on a free port and returns it.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port?.rawValue, once.first() {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if once.first() {
                        continuation.resume(throwing: AuthError.network(error.localizedDescription))
                    }
                    self?.resultContinuation.finish(throwing: AuthError.network(error.localizedDescription))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// Lets the state handler, which runs only on `queue`, resume the start continuation exactly once.
    private final class Once: @unchecked Sendable {
        private var used = false
        func first() -> Bool {
            if used { return false }
            used = true
            return true
        }
    }

    /// Waits for the redirect. Throws on timeout or task cancellation.
    func waitForCallback(timeout: TimeInterval = 300) async throws -> [URLQueryItem] {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resultContinuation.finish(throwing: AuthError.timedOut)
        }
        return try await withTaskCancellationHandler {
            for try await items in results { return items }
            throw AuthError.cancelled
        } onCancel: { [resultContinuation] in
            resultContinuation.finish(throwing: CancellationError())
        }
    }

    func stop() {
        listener.cancel()
        resultContinuation.finish()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let items = data.flatMap(LoopbackRequestParser.queryItems(fromRequest:))
            let response = items == nil
                ? Self.response(status: "404 Not Found", body: "Not found")
                : Self.response(status: "200 OK", body: Self.donePage)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            if let items {
                self?.resultContinuation.yield(items)
                self?.resultContinuation.finish()
            }
        }
    }

    private static let donePage = """
        <html><body style="font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh">\
        <h2>Return to Device Lookup for Intune</h2><p>You can close this tab.</p></body></html>
        """

    private static func response(status: String, body: String) -> Data {
        Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
    }
}
