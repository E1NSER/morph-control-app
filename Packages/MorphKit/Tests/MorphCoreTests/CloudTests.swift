import XCTest
@testable import MorphCore

private final class TestHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseHandler: ((URLRequest) -> (Int, Data))?

    static func configure(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        responseHandler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.responseHandler
        Self.lock.unlock()
        let (status, data) = handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CloudTests: XCTestCase {
    private func session() -> URLSession {
        let config = DysonCloud.ephemeralConfiguration()
        config.protocolClasses = [TestHTTPProtocol.self]
        return URLSession(configuration: config)
    }

    func testHTTPErrorNeverContainsResponseSecrets() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        TestHTTPProtocol.configure { _ in (403, Data("password-secret bearer-secret private-account".utf8)) }
        let cloud = DysonCloud(country: "AT", session: session)
        do {
            _ = try await cloud.completeLogin(email: "test@example.com", password: "password-secret", challengeId: "challenge", otpCode: "123456")
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? DysonCloudError, .httpStatus(403))
            XCTAssertFalse(String(describing: error).contains("secret"))
            XCTAssertFalse(String(describing: error).contains("private-account"))
        }
    }

    func testMalformedResponseDoesNotIncludeRawBody() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        TestHTTPProtocol.configure { _ in (200, Data("not-json-with-private-secret".utf8)) }
        do {
            _ = try await DysonCloud(country: "AT", session: session).devices(token: "bearer-secret")
            XCTFail("Expected malformed response")
        } catch {
            XCTAssertEqual(error as? DysonCloudError, .invalidResponse)
            XCTAssertFalse(String(describing: error).contains("private-secret"))
        }
    }

    func testChinaRouteAndHeadersAndKeyValidation() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        TestHTTPProtocol.configure { request in
            XCTAssertEqual(request.url?.host, "appapi.cp.dyson.cn")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ephemeral-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Dyson-ApiAuthCode"), "80541406")
            XCTAssertFalse(request.httpShouldHandleCookies)
            return (200, Data("{\"ltk\":\"\(String(repeating: "ab", count: 32))\"}".utf8))
        }
        let key = try await DysonCloud(country: "CN", session: session).fetchLtk(serial: "TEST-EU-12345678", token: "ephemeral-token")
        XCTAssertEqual(key.count, 64)
        TestHTTPProtocol.configure { _ in (200, Data("{\"ltk\":\"bad-key\"}".utf8)) }
        do {
            _ = try await DysonCloud(country: "CN", session: session).fetchLtk(serial: "TEST", token: "ephemeral-token")
            XCTFail("Expected invalid key")
        } catch { XCTAssertEqual(error as? DysonCloudError, .unexpectedResponse(.lampKey)) }
    }

    func testRealLampKeySizesAndFormattedHexAreAccepted() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        for key in [String(repeating: "ab", count: 16), String(repeating: "cd", count: 32),
                    Array(repeating: "EF", count: 16).joined(separator: ":")] {
            TestHTTPProtocol.configure { _ in (200, Data("{\"ltk\":\"\(key)\"}".utf8)) }
            let result = try await DysonCloud(country: "AT", session: session).fetchLtk(serial: "TEST", token: "ephemeral-token")
            XCTAssertEqual(result, key.replacingOccurrences(of: ":", with: "").lowercased())
        }
    }

    func testEmptyOddAndNonHexKeysAreRejectedWithoutLeakingContent() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        for key in ["", "abc", "private-not-a-key"] {
            TestHTTPProtocol.configure { _ in (200, Data("{\"ltk\":\"\(key)\"}".utf8)) }
            do {
                _ = try await DysonCloud(country: "AT", session: session).fetchLtk(serial: "TEST", token: "ephemeral-token")
                XCTFail("Expected an invalid key")
            } catch {
                XCTAssertEqual(error as? DysonCloudError, .unexpectedResponse(.lampKey))
                XCTAssertFalse(String(describing: error).contains("private-not-a-key"))
            }
        }
    }

    func testLoginNormalizesAccountGUIDWithoutHyphens() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        TestHTTPProtocol.configure { _ in
            (200, Data("{\"token\":\"ephemeral\",\"account\":\"1234567890ABCDEF1234567890ABCDEF\"}".utf8))
        }
        let result = try await DysonCloud(country: "AT", session: session).completeLogin(
            email: "test@example.com", password: "not-stored", challengeId: "challenge", otpCode: "123456")
        XCTAssertEqual(result.accountId, "12345678-90ab-cdef-1234-567890abcdef")
        XCTAssertEqual(result.token, "ephemeral")
    }

    func testResponseErrorsIdentifyTheStageWithoutRawFields() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        TestHTTPProtocol.configure { _ in (200, Data("{\"unexpected\":\"private-response\"}".utf8)) }
        do {
            _ = try await DysonCloud(country: "AT", session: session).devices(token: "ephemeral")
            XCTFail("Expected invalid manifest")
        } catch {
            XCTAssertEqual(error as? DysonCloudError, .unexpectedResponse(.devices))
            XCTAssertFalse(String(describing: error).contains("private-response"))
        }
    }

    func testEphemeralConfigurationHasNoPersistentStores() {
        let configuration = DysonCloud.ephemeralConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testInvalidCountryCannotStartRequest() async {
        TestHTTPProtocol.configure { _ in XCTFail("No HTTP request expected"); return (500, Data()) }
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await DysonCloud(country: "invalid", session: session).beginLogin(email: "test@example.com")
            XCTFail("Expected country validation")
        } catch { XCTAssertEqual(error as? DysonCloudError, .invalidCountry) }
    }
}
