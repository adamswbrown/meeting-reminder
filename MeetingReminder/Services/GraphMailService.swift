import AppKit
import Foundation

/// Sends booking emails from the user's Exchange account via Microsoft Graph
/// (`POST /me/sendMail`), authenticated with the OAuth 2.0 **device code flow**.
///
/// Why this exists: the user has no admin rights (so no app registration, no
/// SMTP AUTH, no application Graph permissions) and uses "New Outlook" (no
/// AppleScript). Device code flow is delegated user auth — the user signs in as
/// themselves and consents to the `Mail.Send` scope (which does *not* require
/// admin consent) — so mail genuinely sends *from* `adam.brown@altra.cloud`.
///
/// Design:
/// - **Public client**: piggybacks on Microsoft's first-party "Graph Command
///   Line Tools" client (`14d82eec-…`), so no app registration is needed.
/// - **Refresh token in Keychain** (`msGraphRefreshToken`). Each send exchanges
///   it for a short-lived access token (cached in memory until ~1 min before
///   expiry). Entra's 90-day rolling inactivity window means regular use keeps
///   it alive indefinitely; a password change / session revoke / Conditional
///   Access sign-in-frequency policy can force a reconnect.
/// - **`needsReauth`**: a `refresh_token` grant that fails with `invalid_grant`
///   clears the stored token and surfaces as a distinct error so the caller can
///   notify the user and fall back.
@MainActor
final class GraphMailService: ObservableObject {
    // MARK: - Config

    /// Microsoft "Graph Command Line Tools" public client — supports device code
    /// flow and dynamic Graph delegated scopes with no app registration.
    private static let clientID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
    /// Tenant is pinned to the Exchange domain so sign-in targets the right org.
    private static let tenant = "altra.cloud"
    private static let scope = "https://graph.microsoft.com/Mail.Send offline_access openid profile"

    private static let refreshTokenKey = "msGraphRefreshToken"
    private static let connectedEmailKey = "msGraphConnectedEmail"

    private static var deviceCodeURL: URL {
        URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/devicecode")!
    }
    private static var tokenURL: URL {
        URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
    }

    // MARK: - Published state

    @Published var isConnected: Bool
    @Published var connectedEmail: String?
    @Published var lastAuthError: String?

    /// Device-code flow UI state — populated while a `connect()` is in flight.
    @Published var isConnecting = false
    @Published var deviceCodeUserCode: String?
    @Published var deviceCodeVerificationURI: String?

    // MARK: - In-memory access token cache

    private var cachedAccessToken: String?
    private var accessTokenExpiry: Date?

    // MARK: - Init

    init() {
        let hasRT = KeychainHelper.read(key: Self.refreshTokenKey) != nil
        self.isConnected = hasRT
        self.connectedEmail = UserDefaults.standard.string(forKey: Self.connectedEmailKey)
    }

    var hasRefreshToken: Bool {
        guard let rt = KeychainHelper.read(key: Self.refreshTokenKey) else { return false }
        return !rt.isEmpty
    }

    // MARK: - Connect / disconnect (device code flow)

    /// Runs the full device-code flow: requests a code, opens the verification
    /// page in the browser, publishes the user code for display, then polls for
    /// the token. On success stores the refresh token + connected email.
    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        lastAuthError = nil
        defer {
            isConnecting = false
            deviceCodeUserCode = nil
            deviceCodeVerificationURI = nil
        }

        do {
            let dc = try await requestDeviceCode()
            deviceCodeUserCode = dc.userCode
            deviceCodeVerificationURI = dc.verificationURI
            if let url = URL(string: dc.verificationURI) {
                NSWorkspace.shared.open(url)
            }

            let tokens = try await pollForToken(
                deviceCode: dc.deviceCode,
                interval: dc.interval,
                expiresIn: dc.expiresIn
            )
            persist(tokens)

            let email = try? await fetchConnectedEmail(accessToken: tokens.accessToken)
            connectedEmail = email
            UserDefaults.standard.set(email, forKey: Self.connectedEmailKey)
            isConnected = true
        } catch {
            lastAuthError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isConnected = hasRefreshToken
        }
    }

    func disconnect() {
        KeychainHelper.delete(key: Self.refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.connectedEmailKey)
        cachedAccessToken = nil
        accessTokenExpiry = nil
        connectedEmail = nil
        isConnected = false
        lastAuthError = nil
    }

    // MARK: - Send

    /// Send an email via Graph. `icsContent` (the raw .ics text) is attached as a
    /// `text/calendar` file attachment when present. Throws `GraphMailError` on
    /// any failure (including `.needsReauth` when the refresh token is dead).
    func sendMail(to: String, subject: String, body: String,
                  icsContent: String?, icsFileName: String = "invite.ics") async throws {
        let token = try await accessToken()

        var message: [String: Any] = [
            "subject": subject,
            "body": ["contentType": "Text", "content": body],
            "toRecipients": [["emailAddress": ["address": to]]],
        ]
        if let ics = icsContent, let data = ics.data(using: .utf8) {
            message["attachments"] = [[
                "@odata.type": "#microsoft.graph.fileAttachment",
                "name": icsFileName,
                "contentType": "text/calendar; method=REQUEST",
                "contentBytes": data.base64EncodedString(),
            ]]
        }
        let payload: [String: Any] = ["message": message, "saveToSentItems": true]

        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/sendMail")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GraphMailError.invalidResponse }
        // sendMail returns 202 Accepted on success.
        guard http.statusCode == 202 else {
            throw GraphMailError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Token acquisition

    /// Return a valid access token, refreshing via the stored refresh token when
    /// the cached one is missing or about to expire.
    func accessToken() async throws -> String {
        if let token = cachedAccessToken, let expiry = accessTokenExpiry, expiry > Date() {
            return token
        }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = KeychainHelper.read(key: Self.refreshTokenKey), !refreshToken.isEmpty else {
            throw GraphMailError.notConnected
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "scope": Self.scope,
            "refresh_token": refreshToken,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if let error = json["error"] as? String {
            // A dead refresh token (revoked, expired, password changed, CA policy)
            // surfaces as invalid_grant — clear it and demand reconnection.
            if error == "invalid_grant" {
                KeychainHelper.delete(key: Self.refreshTokenKey)
                isConnected = false
                throw GraphMailError.needsReauth
            }
            throw GraphMailError.http(http?.statusCode ?? -1, json["error_description"] as? String ?? error)
        }

        guard let access = json["access_token"] as? String else {
            throw GraphMailError.http(http?.statusCode ?? -1, "no access_token in refresh response")
        }
        // A refresh issues a new refresh token — rotate it so the 90-day window resets.
        if let newRT = json["refresh_token"] as? String, !newRT.isEmpty {
            KeychainHelper.save(key: Self.refreshTokenKey, value: newRT)
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        cachedAccessToken = access
        accessTokenExpiry = Date().addingTimeInterval(expiresIn - 60)
        return access
    }

    // MARK: - Device code helpers

    private struct DeviceCode {
        let userCode: String
        let deviceCode: String
        let verificationURI: String
        let interval: Double
        let expiresIn: Double
    }

    private struct Tokens {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
    }

    private func requestDeviceCode() async throws -> DeviceCode {
        var request = URLRequest(url: Self.deviceCodeURL)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["client_id": Self.clientID, "scope": Self.scope])

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let deviceCode = json["device_code"] as? String,
              let verificationURI = json["verification_uri"] as? String else {
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let desc = json["error_description"] as? String {
                throw GraphMailError.http(-1, desc)
            }
            throw GraphMailError.invalidResponse
        }
        return DeviceCode(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURI: verificationURI,
            interval: (json["interval"] as? Double) ?? 5,
            expiresIn: (json["expires_in"] as? Double) ?? 900
        )
    }

    private func pollForToken(deviceCode: String, interval: Double, expiresIn: Double) async throws -> Tokens {
        let deadline = Date().addingTimeInterval(expiresIn)
        var wait = interval

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))

            var request = URLRequest(url: Self.tokenURL)
            request.httpMethod = "POST"
            request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody([
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": Self.clientID,
                "device_code": deviceCode,
            ])

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

            if let access = json["access_token"] as? String,
               let refresh = json["refresh_token"] as? String {
                return Tokens(accessToken: access, refreshToken: refresh,
                              expiresIn: (json["expires_in"] as? Double) ?? 3600)
            }

            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                wait += 5
                continue
            case .some(let other):
                throw GraphMailError.http(-1, json["error_description"] as? String ?? other)
            case .none:
                throw GraphMailError.invalidResponse
            }
        }
        throw GraphMailError.http(-1, "Device code expired before sign-in completed")
    }

    private func fetchConnectedEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=userPrincipalName,mail")!)
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json["mail"] as? String) ?? (json["userPrincipalName"] as? String) ?? "(unknown)"
    }

    // MARK: - Persistence

    private func persist(_ tokens: Tokens) {
        KeychainHelper.save(key: Self.refreshTokenKey, value: tokens.refreshToken)
        cachedAccessToken = tokens.accessToken
        accessTokenExpiry = Date().addingTimeInterval(tokens.expiresIn - 60)
    }

    // MARK: - Util

    private func formBody(_ params: [String: String]) -> Data {
        params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}

enum GraphMailError: LocalizedError {
    case notConnected
    case needsReauth
    case invalidResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConnected:  return "Exchange not connected — sign in via Settings → Availability."
        case .needsReauth:   return "Exchange sign-in expired — reconnect via Settings → Availability."
        case .invalidResponse: return "Unexpected response from Microsoft."
        case .http(let code, let body):
            return "Graph HTTP \(code)\(body.isEmpty ? "" : " — \(body.prefix(300))")"
        }
    }
}

private extension CharacterSet {
    /// URL query value encoding that escapes `+`, `&`, `=`, `/` etc. so form bodies
    /// (refresh tokens, scopes with `/` and spaces) round-trip correctly.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
