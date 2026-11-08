import Foundation

/// Acknowledges an OS sleep request after cleanup, with a hard upper bound.
/// Unstructured tasks are deliberate: an uncooperative operation must not
/// keep the Mac awake through a structured task group's implicit join.
@MainActor
public final class SleepPreparation {
    private final class Request {
        enum Phase { case graceful, forcing }
        let id = UUID()
        let acknowledge: () -> Void
        var phase = Phase.graceful
        init(acknowledge: @escaping () -> Void) { self.acknowledge = acknowledge }
    }

    private let prepare: () async -> Void
    private let force: () async -> Void
    private let graceSeconds: TimeInterval
    private let forceSeconds: TimeInterval
    private var request: Request?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var forcedWork: Task<Void, Never>?
    private var finalDeadline: Task<Void, Never>?

    public init(graceSeconds: TimeInterval = 5, forceSeconds: TimeInterval = 1,
                prepare: @escaping () async -> Void, force: @escaping () async -> Void) {
        self.graceSeconds = max(0.001, graceSeconds)
        self.forceSeconds = max(0.001, forceSeconds)
        self.prepare = prepare
        self.force = force
    }

    public func begin(acknowledge: @escaping () -> Void) {
        // A replaced notification must still be acknowledged exactly once.
        cancelPendingForWake()
        let current = Request(acknowledge: acknowledge)
        request = current
        work = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.prepare()
            guard self.request?.id == current.id, current.phase == .graceful else { return }
            self.finish(current.id)
        }
        deadline = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: Self.nanoseconds(self.graceSeconds)) }
            catch { return }
            guard self.request?.id == current.id else { return }
            current.phase = .forcing
            self.work?.cancel()
            self.forcedWork = Task { [weak self] in
                guard let self, self.request?.id == current.id, !Task.isCancelled else { return }
                // Start the hard timer only when force is about to be invoked;
                // scheduler ordering must not acknowledge before that call.
                self.finalDeadline = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(self.forceSeconds)) }
                    catch { return }
                    self.finish(current.id)
                }
                await self.force()
                self.finish(current.id)
            }
        }
    }

    /// A late pre-sleep timer must not abort a newly awakened connection.
    public func cancelPendingForWake() {
        if let request { finish(request.id) }
    }

    private func finish(_ id: UUID) {
        guard let current = request, current.id == id else { return }
        request = nil
        work?.cancel(); work = nil
        deadline?.cancel(); deadline = nil
        forcedWork?.cancel(); forcedWork = nil
        finalDeadline?.cancel(); finalDeadline = nil
        current.acknowledge()
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(min(30, seconds.isFinite ? seconds : 5) * 1_000_000_000)
    }
}
