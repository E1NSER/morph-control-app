import Foundation
import OSLog

/// One terminal cleanup window shared by Quit and system shutdown. Deliberately
/// uses unstructured tasks: cancellation cannot make an uncooperative child of
/// a task group finish, and must not indefinitely delay the OS termination reply.
@MainActor
public final class TerminationPreparation {
    public enum Outcome: Equatable {
        case graceful, forced, forceDeadline
    }

    private enum Phase { case idle, graceful, forcing, finished }
    private static let diagnostics = Logger(subsystem: "at.einser.morphcontrol", category: "Bluetooth")
    private let prepare: () async -> Void
    private let force: () async -> Void
    private let graceSeconds: TimeInterval
    private let forceSeconds: TimeInterval
    private var phase = Phase.idle
    private var completion: ((Outcome) -> Void)?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var forcedWork: Task<Void, Never>?
    private var finalDeadline: Task<Void, Never>?

    /// Default total budget: seven seconds for queued power-off/unsubscribe and
    /// one final second for a targeted local abort. Never starts another session.
    public init(graceSeconds: TimeInterval = 7, forceSeconds: TimeInterval = 1,
                prepare: @escaping () async -> Void, force: @escaping () async -> Void) {
        self.graceSeconds = Self.boundedSeconds(graceSeconds)
        self.forceSeconds = Self.boundedSeconds(forceSeconds)
        self.prepare = prepare
        self.force = force
    }

    public func begin(completion: @escaping (Outcome) -> Void) {
        guard phase == .idle else { return }
        phase = .graceful
        self.completion = completion
        work = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.prepare()
            // Once force began, a late graceful completion cannot reply before
            // the local abort has at least been issued.
            guard self.phase == .graceful else { return }
            self.finish(.graceful)
        }
        deadline = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.graceSeconds * 1_000_000_000)) }
            catch { return }
            guard self.phase == .graceful else { return }
            self.phase = .forcing
            self.work?.cancel()
            Self.diagnostics.notice("Termination cleanup deadline reached; aborting the old Bluetooth session")
            self.forcedWork = Task { [weak self] in
                guard let self, self.phase == .forcing else { return }
                // Start the last timer here, immediately before invoking force,
                // so no scheduler ordering can reply without invoking it first.
                self.finalDeadline = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(nanoseconds: UInt64(self.forceSeconds * 1_000_000_000)) }
                    catch { return }
                    guard self.phase == .forcing else { return }
                    Self.diagnostics.error("Local Bluetooth abort exceeded the final termination window")
                    self.finish(.forceDeadline)
                }
                await self.force()
                guard self.phase == .forcing else { return }
                self.finish(.forced)
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard phase != .finished else { return }
        phase = .finished
        work?.cancel(); work = nil
        deadline?.cancel(); deadline = nil
        forcedWork?.cancel(); forcedWork = nil
        finalDeadline?.cancel(); finalDeadline = nil
        let completion = completion
        self.completion = nil
        completion?(outcome)
    }

    private static func boundedSeconds(_ seconds: TimeInterval) -> TimeInterval {
        min(30, max(0.001, seconds.isFinite ? seconds : 1))
    }
}
