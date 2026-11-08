import Combine
import Foundation
import MorphCore

public enum PairingStage: Equatable { case account, code, devices, complete }

public struct PairingDevice: Identifiable, Equatable {
    public var id: String { serial }
    public let name: String
    public let serial: String
    public init(name: String, serial: String) { self.name = name; self.serial = serial }
}

@MainActor
protocol PairingCloudClient {
    func beginLogin(email: String) async throws -> String
    func completeLogin(email: String, password: String, challengeId: String, otpCode: String) async throws -> (token: String, accountId: String)
    func devices(token: String) async throws -> [DysonCloud.Device]
    func fetchLtk(serial: String, token: String) async throws -> String
}

extension DysonCloud: PairingCloudClient {}

@MainActor
public final class PairingModel: ObservableObject {
    @Published public var email = ""
    @Published public var password = ""
    @Published public var country = "AT"
    @Published public var otp = ""
    @Published public private(set) var stage: PairingStage = .account
    @Published public private(set) var devices: [PairingDevice] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var errorMessage: String?
    private var localizedErrorKey: String?

    private let cloudFactory: (String) -> PairingCloudClient
    private var challengeID: String?
    private var challengeEmail = ""
    private var challengeCountry = ""
    private var candidates: [String: LampCredentials] = [:]
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var demoIsActive = false

    public convenience init() { self.init(cloudFactory: { DysonCloud(country: $0) }) }

    #if DEBUG
    public static func isolatedSetupPreview() -> PairingModel {
        PairingModel(cloudFactory: { _ in IsolatedPreviewCloud() })
    }
    #endif

    init(cloudFactory: @escaping (String) -> PairingCloudClient) { self.cloudFactory = cloudFactory }

    public func sendCode() async {
        guard !demoIsActive, !isBusy else { return }
        email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        country = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard email.contains("@"), !email.contains(" "), !password.isEmpty else {
            setError(key: "Gib deine Dyson-E-Mail-Adresse und dein Passwort ein.")
            return
        }
        guard country.count == 2, country.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) }) else {
            setError(key: "Wähle das Land deines Dyson-Kontos.")
            return
        }
        candidates.removeAll()
        devices.removeAll()
        challengeID = nil
        otp = ""
        clearLocalizedError()
        isBusy = true
        generation = UUID()
        let currentGeneration = generation
        let selectedEmail = email
        let selectedCountry = country
        let cloud = cloudFactory(selectedCountry)
        let task = Task { [weak self] in
            do {
                let challenge = try await cloud.beginLogin(email: selectedEmail)
                try Task.checkCancellation()
                guard let self, self.generation == currentGeneration else { return }
                self.challengeID = challenge
                self.challengeEmail = selectedEmail
                self.challengeCountry = selectedCountry
                self.stage = .code
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.password = ""
                self.stage = .account
                if !(error is CancellationError) { self.setError(key: UserFacingError.key(for: error)) }
            }
            guard let self, self.generation == currentGeneration else { return }
            self.isBusy = false
            self.operation = nil
        }
        operation = task
        await task.value
    }

    public func verifyCode() async {
        guard !demoIsActive, !isBusy else { return }
        guard let challengeID, stage == .code else { return }
        let code = otp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }) else {
            setError(key: "Gib den sechsstelligen Code aus deiner E-Mail ein.")
            return
        }
        guard !password.isEmpty else {
            stage = .account
            self.challengeID = nil
            setError(key: "Gib dein Passwort erneut ein und fordere einen neuen Code an.")
            return
        }
        let secret = password
        password = ""
        otp = ""
        clearLocalizedError()
        isBusy = true
        let currentGeneration = generation
        let selectedEmail = challengeEmail
        let cloud = cloudFactory(challengeCountry)
        let task = Task { [weak self] in
            do {
                // Session token and password exist only in this cancelled-on-reset
                // operation, never as published or stored model properties.
                let session = try await cloud.completeLogin(email: selectedEmail, password: secret, challengeId: challengeID, otpCode: code)
                try Task.checkCancellation()
                let lights = try await cloud.devices(token: session.token).filter(\.isBluetoothLight)
                try Task.checkCancellation()
                guard !lights.isEmpty else { throw ServiceError.emptyDevices }
                var available: [PairingDevice] = []
                var credentials: [String: LampCredentials] = [:]
                var firstKeyError: Error?
                for light in lights {
                    try Task.checkCancellation()
                    do {
                        let key = try await cloud.fetchLtk(serial: light.serial, token: session.token)
                        let candidate = LampCredentials(serial: light.serial, accountID: session.accountId, longTermKey: key, name: light.name)
                        guard candidate.isValid else { throw ServiceError.invalidCredentials }
                        credentials[light.serial] = candidate
                        if !available.contains(where: { $0.serial == light.serial }) {
                            available.append(PairingDevice(name: light.name, serial: light.serial))
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if firstKeyError == nil { firstKeyError = error }
                    }
                }
                guard !available.isEmpty else { throw firstKeyError ?? ServiceError.emptyDevices }
                try Task.checkCancellation()
                guard let self, self.generation == currentGeneration else { return }
                self.candidates = credentials
                self.devices = available
                self.challengeID = nil
                self.stage = .devices
                if firstKeyError != nil {
                    self.setError(key: "Nicht alle Lampen konnten geladen werden. Du kannst eine verfügbare Lampe auswählen oder es später erneut versuchen.")
                }
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.candidates.removeAll()
                self.devices.removeAll()
                self.challengeID = nil
                self.stage = .account
                if !(error is CancellationError) { self.setError(key: UserFacingError.key(for: error)) }
            }
            guard let self, self.generation == currentGeneration else { return }
            self.password = ""
            self.otp = ""
            self.isBusy = false
            self.operation = nil
        }
        operation = task
        await task.value
    }

    public func pair(_ device: PairingDevice, controller: LampController) async {
        guard !demoIsActive, !controller.isDemo, !isBusy, stage == .devices, let candidate = candidates[device.serial] else { return }
        isBusy = true
        clearLocalizedError()
        let currentGeneration = generation
        do {
            try await controller.adopt(candidate, ifCurrent: { [weak self] in self?.generation == currentGeneration })
            guard generation == currentGeneration else { return }
            candidates.removeAll()
            devices.removeAll()
            stage = .complete
        } catch {
            guard generation == currentGeneration else { return }
            setError(key: UserFacingError.key(for: error))
        }
        isBusy = false
    }

    public func setDemoMode(_ active: Bool) {
        demoIsActive = active
        reset()
    }

    public func reset() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        candidates.removeAll()
        challengeID = nil
        challengeEmail = ""
        challengeCountry = ""
        email = ""
        password = ""
        otp = ""
        devices = []
        stage = .account
        isBusy = false
        clearLocalizedError()
    }

    public func clearError() { clearLocalizedError() }

    public func reloadLocalizedText() {
        errorMessage = localizedErrorKey.map { ServiceLocalization.text($0) }
    }

    private func setError(key: String) {
        localizedErrorKey = key
        errorMessage = ServiceLocalization.text(key)
    }

    private func clearLocalizedError() {
        localizedErrorKey = nil
        errorMessage = nil
    }
}

#if DEBUG
/// Fails locally even if someone fills the setup form in a QA fixture.
@MainActor
private final class IsolatedPreviewCloud: PairingCloudClient {
    func beginLogin(email: String) async throws -> String { throw CancellationError() }
    func completeLogin(email: String, password: String, challengeId: String, otpCode: String) async throws -> (token: String, accountId: String) { throw CancellationError() }
    func devices(token: String) async throws -> [DysonCloud.Device] { throw CancellationError() }
    func fetchLtk(serial: String, token: String) async throws -> String { throw CancellationError() }
}
#endif
