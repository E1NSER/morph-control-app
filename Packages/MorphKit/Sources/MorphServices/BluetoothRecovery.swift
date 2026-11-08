import Foundation
import MorphCore

/// Retries one stale-session failure after the caller replaces its Bluetooth runtime.
/// The attempt includes authentication and the initial live-state read.
@MainActor
func retryOnceWithFreshBluetoothSession<T>(
    attempt: () async throws -> T,
    reset: () async -> Void,
    cooldown: () async throws -> Void = { try await Task.sleep(nanoseconds: 2_000_000_000) }
) async throws -> T {
    try Task.checkCancellation()
    do {
        return try await attempt()
    } catch {
        guard case MorphError.lampStuck = error else { throw error }
        try Task.checkCancellation()
        await reset()
        try Task.checkCancellation()
        try await cooldown()
        try Task.checkCancellation()
        return try await attempt()
    }
}
