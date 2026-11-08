import Foundation

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward an account password or bearer token to a redirect target.
        completionHandler(nil)
    }
}

/// Errors deliberately contain no response body, account identifier, URL or token.
public enum DysonResponseStage: String {
    case login, devices, lampKey
}

public enum DysonCloudError: Error, Equatable {
    case httpStatus(Int)
    case invalidResponse
    case invalidCountry
    case unexpectedResponse(DysonResponseStage)
}

/// The undocumented MyDyson API is used only to obtain local lamp credentials.
/// Nothing is persisted by the HTTP client: no cookies, cache or credential store.
public final class DysonCloud {
    static let ltkAuthCode = "80541406"
    static let userAgent = "android client"

    public struct Device {
        public let serial: String
        public let name: String
        public let category: String?
        public let connectionCategory: String?

        public init(serial: String, name: String, category: String?, connectionCategory: String?) {
            self.serial = serial
            self.name = name
            self.category = category
            self.connectionCategory = connectionCategory
        }

        public var isBluetoothLight: Bool { category == "light" && connectionCategory != "wifiOnly" }
    }

    private let country: String
    private let culture: String
    private let session: URLSession
    private let ownsSession: Bool

    public init(country: String, culture: String? = nil, session: URLSession? = nil) {
        self.country = country.uppercased()
        self.culture = culture ?? Self.culture(for: country.uppercased())
        self.session = session ?? URLSession(configuration: Self.ephemeralConfiguration(), delegate: RejectRedirects(), delegateQueue: nil)
        self.ownsSession = session == nil
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    static func culture(for country: String) -> String {
        let languages = ["DE": "de", "AT": "de", "CH": "de", "FR": "fr", "IT": "it", "ES": "es", "NL": "nl"]
        return "\(languages[country] ?? "en")-\(country)"
    }

    public func beginLogin(email: String) async throws -> String {
        _ = try await request("GET", "/v1/provisioningservice/application/Android/version")
        _ = try await request("POST", "/v3/userregistration/email/userstatus", query: ["country": country], body: ["email": email])
        let data = try await request("POST", "/v3/userregistration/email/auth", query: ["country": country, "culture": culture], body: ["email": email])
        guard let challenge = (data as? [String: Any])?["challengeId"] as? String, !challenge.isEmpty else {
            throw DysonCloudError.invalidResponse
        }
        return challenge
    }

    public func completeLogin(email: String, password: String, challengeId: String, otpCode: String) async throws -> (token: String, accountId: String) {
        let data = try await request("POST", "/v3/userregistration/email/verify", query: ["country": country, "culture": culture],
            body: ["challengeId": challengeId, "email": email, "otpCode": otpCode, "password": password])
        guard let dictionary = data as? [String: Any],
              let token = dictionary["token"] as? String, !token.isEmpty,
              let rawAccount = dictionary["account"] as? String,
              let account = MorphCrypto.normalizedAccountID(rawAccount) else {
            throw DysonCloudError.unexpectedResponse(.login)
        }
        return (token, account)
    }

    public func devices(token: String) async throws -> [Device] {
        let data = try await request("GET", "/v3/manifest", headers: ["Authorization": "Bearer \(token)"])
        guard let entries = data as? [[String: Any]] else { throw DysonCloudError.unexpectedResponse(.devices) }
        return entries.compactMap { entry in
            guard let serial = entry["serialNumber"] as? String, !serial.isEmpty else { return nil }
            return Device(serial: serial, name: entry["name"] as? String ?? serial,
                category: entry["category"] as? String, connectionCategory: entry["connectionCategory"] as? String)
        }
    }

    public func fetchLtk(serial: String, token: String) async throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard let encoded = serial.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw DysonCloudError.invalidResponse
        }
        let data = try await request("GET", "/v1/lec/\(encoded)/ltk", headers: ["Authorization": "Bearer \(token)", "X-Dyson-ApiAuthCode": Self.ltkAuthCode])
        guard let key = (data as? [String: Any])?["ltk"] as? String else {
            throw DysonCloudError.unexpectedResponse(.lampKey)
        }
        // Real lamps use different LTK sizes. HKDF derives the fixed-size AES
        // key; imposing the size of a test vector here rejects valid lamps.
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-"))
        guard key.unicodeScalars.allSatisfy({ separators.contains($0) || CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            throw DysonCloudError.unexpectedResponse(.lampKey)
        }
        let hex = key.filter(\.isHexDigit)
        guard let bytes = Data(hex: hex), !bytes.isEmpty else {
            throw DysonCloudError.unexpectedResponse(.lampKey)
        }
        return bytes.hex
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:],
                         body: [String: String]? = nil, headers: [String: String] = [:]) async throws -> Any {
        try Task.checkCancellation()
        guard country.count == 2, country.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) else {
            throw DysonCloudError.invalidCountry
        }
        let host = country == "CN" ? "https://appapi.cp.dyson.cn" : "https://appapi.cp.dyson.com"
        guard var components = URLComponents(string: host + path) else { throw DysonCloudError.invalidResponse }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw DysonCloudError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw DysonCloudError.invalidResponse }
        guard (200..<300).contains(status) else { throw DysonCloudError.httpStatus(status) }
        if data.isEmpty { return [String: Any]() }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw DysonCloudError.invalidResponse
        }
        return json
    }
}
