import Foundation
@testable import DeviceLookupForIntune

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Replies to every request with the given status and JSON body.
    static func reply(status: Int = 200, json: String) {
        handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
    }
}

extension URLRequest {
    /// URLProtocol receives bodies as streams, not httpBody.
    var bodyString: String {
        guard let stream = httpBodyStream else { return httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}


extension GraphClient {
    static func mocked() -> GraphClient {
        GraphClient(session: MockURLProtocol.session(), tokenProvider: { "tok" }, sleep: { _ in })
    }
}

extension MockURLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []

    /// Every request since the test last cleared it, whatever handler answered it. Recorded under a lock, because pages
    /// and the device list are often requested at the same time on different threads.
    static var requests: [URLRequest] {
        get { lock.lock(); defer { lock.unlock() }; return recorded }
        set { lock.lock(); recorded = newValue; lock.unlock() }
    }

    static func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    /// Clears the recorded requests and replies with the given (status, headers, body) in order; the last one repeats.
    static func script(_ responses: [(Int, [String: String], String)]) {
        var index = 0
        requests = []
        handler = { request in
            lock.lock()
            let position = min(index, responses.count - 1)
            index += 1
            lock.unlock()
            let (status, headers, body) = responses[position]
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(body.utf8))
        }
    }
}
