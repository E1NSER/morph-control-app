import Foundation

/// The owning transport awaits frames serially. This helper paces the raw
/// characteristic writes inside each frame as well as across successive frames.
@MainActor
final class EffectFrameWriter {
    private let minimumGap: Duration
    private var lastCompletion: ContinuousClock.Instant?
    private var lastBrightness: Int?
    private var lastKelvin: Int?
    private var generation = UUID()

    init(minimumGap: Duration = .milliseconds(150)) {
        self.minimumGap = minimumGap
    }

    func reset() {
        generation = UUID()
        lastBrightness = nil
        lastKelvin = nil
    }

    func write(_ frame: LightEffectFrame, baseline: LightEffectFrame?,
               ifAllowed: @escaping () -> Bool,
               setBrightness: @escaping (Int) async throws -> Void,
               setKelvin: @escaping (Int) async throws -> Void) async throws {
        let session = generation
        if frame.brightness != (lastBrightness ?? baseline?.brightness) {
            guard try await pace(session: session, ifAllowed: ifAllowed) else { return }
            do {
                try await setBrightness(frame.brightness)
                if generation == session { lastBrightness = frame.brightness }
                lastCompletion = .now
            } catch {
                lastCompletion = .now
                throw error
            }
        }
        if frame.kelvin != (lastKelvin ?? baseline?.kelvin) {
            guard try await pace(session: session, ifAllowed: ifAllowed) else { return }
            do {
                try await setKelvin(frame.kelvin)
                if generation == session { lastKelvin = frame.kelvin }
                lastCompletion = .now
            } catch {
                lastCompletion = .now
                throw error
            }
        }
    }

    private func pace(session: UUID, ifAllowed: () -> Bool) async throws -> Bool {
        guard generation == session, ifAllowed() else { return false }
        try Task.checkCancellation()
        if let lastCompletion {
            try await ContinuousClock().sleep(until: lastCompletion.advanced(by: minimumGap))
        }
        try Task.checkCancellation()
        return generation == session && ifAllowed()
    }
}
