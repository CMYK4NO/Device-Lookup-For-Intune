import Foundation
import os

/// Minimal Microsoft Graph (beta) client: bearer auth, paging, 429/503 retry, error mapping.
struct GraphClient: Sendable {
    static let baseURL = URL(string: "https://graph.microsoft.com/beta")!
    private static let maxRetryAfter: TimeInterval = 120
    private static let maxBackoff: TimeInterval = 30

    /// No disk cache, cookie store or credential store. Graph answers can hold passwords and recovery keys, and the shared
    /// session's cache could write them to disk.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    let session: URLSession
    let tokenProvider: @Sendable () async throws -> String
    let maxRetries: Int
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let logger = Logger(subsystem: "DeviceLookupForIntune", category: "graph")

    init(
        session: URLSession = GraphClient.defaultSession,
        tokenProvider: @escaping @Sendable () async throws -> String,
        maxRetries: Int = 6,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false) else {
            throw GraphError.invalidRequest
        }
        components.path += path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GraphError.invalidRequest }
        return url
    }

    /// GET a single JSON object.
    func get<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        let data = try await send(url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GraphError.decoding(error.localizedDescription)
        }
    }

    /// POST with no body, for Intune remote actions (they answer 204).
    func post(url: URL) async throws {
        _ = try await send(url, method: "POST")
    }

    /// POST a JSON body and return the response, for Intune report requests.
    func post(url: URL, json: [String: Any]) async throws -> Data {
        try await send(url, method: "POST", body: try JSONSerialization.data(withJSONObject: json))
    }

    /// GET one page of a collection, keeping each item's raw JSON.
    func page<T: Decodable>(_ type: T.Type, url: URL) async throws -> GraphPage<T> {
        let data = try await send(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["value"] as? [Any]
        else { throw GraphError.invalidResponse }

        let decoder = JSONDecoder()
        var items: [GraphItem<T>] = []
        items.reserveCapacity(values.count)
        for value in values {
            guard JSONSerialization.isValidJSONObject(value),
                  let itemData = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            else { throw GraphError.invalidResponse }
            do {
                items.append(GraphItem(value: try decoder.decode(T.self, from: itemData),
                                       raw: String(decoding: itemData, as: UTF8.self)))
            } catch {
                throw GraphError.decoding(error.localizedDescription)
            }
        }

        var next: URL?
        if let link = root["@odata.nextLink"] as? String {
            // Never send the bearer token to anything but Graph.
            guard let url = URL(string: link), url.scheme == "https", url.host == Self.baseURL.host else {
                throw GraphError.invalidResponse
            }
            next = url
        }
        return GraphPage(items: items, nextLink: next)
    }

    /// Follows `@odata.nextLink` until exhausted. `progress` receives the running count of items scanned after each page.
    /// `include` drops items as each page arrives, so large collections do not have to be held in memory.
    /// A 400 on a request that asks for `$top` is retried once without it, because not every Intune collection accepts a page size.
    func collect<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = [],
        progress: (@MainActor (Int) -> Void)? = nil,
        include: ((GraphItem<T>) -> Bool)? = nil
    ) async throws -> [GraphItem<T>] {
        do {
            return try await collectPages(type, path: path, query: query, progress: progress, include: include)
        } catch GraphError.http(400, _) where query.contains(where: { $0.name == "$top" }) {
            return try await collectPages(type, path: path, query: query.filter { $0.name != "$top" }, progress: progress, include: include)
        }
    }

    private func collectPages<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem],
        progress: (@MainActor (Int) -> Void)?,
        include: ((GraphItem<T>) -> Bool)?
    ) async throws -> [GraphItem<T>] {
        var all: [GraphItem<T>] = []
        var scanned = 0
        var next: URL? = try url(path: path, query: query)
        while let current = next {
            let page = try await page(type, url: current)
            scanned += page.items.count
            all.append(contentsOf: include.map { page.items.filter($0) } ?? page.items)
            if let progress { await progress(scanned) }
            next = page.nextLink
        }
        return all
    }

    // MARK: Transport

    private func send(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let started = Date()
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                throw GraphError.network(error.localizedDescription)
            }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else { throw GraphError.invalidResponse }
            // Path only: the query can hold user names, and nothing here ever includes a token.
            logger.info("\(method, privacy: .public) \(url.path, privacy: .public) -> \(http.statusCode) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s")

            switch http.statusCode {
            case 200..<300:
                return data
            case 429, 503:
                guard attempt < maxRetries else { throw GraphError.throttled }
                let delay = Self.delay(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                logger.info("Graph returned \(http.statusCode); retrying in \(delay, format: .fixed(precision: 0), privacy: .public)s")
                try await sleep(delay)
                attempt += 1
            case 504:
                // Gateway timeouts are often transient on large Intune lists; a couple of retries, not the full backoff.
                guard attempt < 2 else { throw GraphError.http(status: 504, message: Self.message(from: data)) }
                try await sleep(Self.delay(attempt: attempt, retryAfter: nil))
                attempt += 1
            case 401:
                throw GraphError.unauthorized
            case 403:
                throw GraphError.forbidden(message: Self.message(from: data))
            default:
                throw GraphError.http(status: http.statusCode, message: Self.message(from: data))
            }
        }
    }

    static func delay(attempt: Int, retryAfter: String?) -> TimeInterval {
        if let seconds = retryAfter.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }) {
            return min(max(seconds, 0), maxRetryAfter)
        }
        return min(pow(2, Double(attempt)), maxBackoff)
    }

    /// Graph error text. Intune backends often nest a JSON document inside `message`, so unwrap its `Message`.
    static func message(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              var text = error["message"] as? String
        else { return nil }
        if text.hasPrefix("{"),
           let inner = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           let nested = (inner["Message"] ?? inner["message"]) as? String {
            text = nested
        }
        let flattened = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flattened.isEmpty ? nil : flattened
    }
}
