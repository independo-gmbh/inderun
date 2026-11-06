import XCTest
@testable import IndeRunDemo

/// Answers requests from `handler`, so the real `URLSessionNeuralTransport` runs without a network.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLProtocol, URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self, request) }
    override func stopLoading() {}
}

final class URLSessionTransportTests: XCTestCase {
    private func transport() -> URLSessionNeuralTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionNeuralTransport(configuration: configuration)
    }

    override func tearDown() { StubProtocol.handler = nil }

    func testCancellingBeforeTheResponseEndsPromptlyWithCancellationError() async throws {
        // The stub never answers: only the cancel can end the request.
        StubProtocol.handler = { _, _ in }
        let subject = transport()
        let url = try XCTUnwrap(URL(string: "https://example.com/a"))
        let task = Task { try await subject.open(url) }
        task.cancel()
        let outcome = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do { _ = try await task.value; return "returned" } catch is CancellationError { return "cancelled" } catch { return "other \(error)" }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return "hung"
            }
            let first = await group.next() ?? "none"
            group.cancelAll()
            return first
        }
        XCTAssertEqual(outcome, "cancelled")
    }

    func testAlreadyCancelledTaskDoesNotHang() async throws {
        StubProtocol.handler = { _, _ in }
        let subject = transport()
        let url = try XCTUnwrap(URL(string: "https://example.com/a"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await subject.open(url)
        }
        let outcome = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do { _ = try await task.value; return "returned" } catch is CancellationError { return "cancelled" } catch { return "other \(error)" }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return "hung"
            }
            let first = await group.next() ?? "none"
            group.cancelAll()
            return first
        }
        XCTAssertEqual(outcome, "cancelled")
    }

    func testAnswersWithStatusFinalURLAndBody() async throws {
        StubProtocol.handler = { proto, request in
            let url = request.url!
            proto.client?.urlProtocol(proto, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            proto.client?.urlProtocol(proto, didLoad: Data("hello".utf8))
            proto.client?.urlProtocolDidFinishLoading(proto)
        }
        let response = try await transport().open(try XCTUnwrap(URL(string: "https://example.com/a")))
        XCTAssertEqual(response.status, 200)
        var body = Data()
        for try await chunk in response.body { body.append(chunk) }
        XCTAssertEqual(body, Data("hello".utf8))
    }

    func testARedirectToHTTPIsRefused() async throws {
        StubProtocol.handler = { proto, request in
            let url = request.url!
            if url.scheme == "http" {
                // Only reached if the redirect was followed.
                proto.client?.urlProtocol(proto, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                proto.client?.urlProtocolDidFinishLoading(proto)
                return
            }
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://example.com/b"])!
            proto.client?.urlProtocol(proto, wasRedirectedTo: URLRequest(url: URL(string: "http://example.com/b")!), redirectResponse: redirect)
            // A refused redirect leaves the 3xx answer as the final response.
            proto.client?.urlProtocol(proto, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            proto.client?.urlProtocolDidFinishLoading(proto)
        }
        let response = try await transport().open(try XCTUnwrap(URL(string: "https://example.com/a")))
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(response.finalURL.scheme, "https")
    }
}
