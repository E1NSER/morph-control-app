import Foundation
import MorphCore

enum LampAction: Equatable {
    case power(Bool), brightness(Int), kelvin(Int), daylight(Bool)
    case autoBrightness(Bool), movement(Bool), preset(Preset?), refresh
    case effectFrame(LightEffectFrame)

    var key: Int {
        switch self {
        case .power: return 0
        case .brightness: return 1
        case .kelvin: return 2
        case .daylight: return 3
        case .autoBrightness: return 4
        case .movement: return 5
        case .preset: return 6
        case .refresh: return 7
        case .effectFrame: return 8
        }
    }
}

/// The sole owner of command ordering. The next value is selected *after* the
/// pacing delay so that slider movement during the delay is coalesced as well.
@MainActor
final class CommandQueue {
    private struct PendingAction {
        let action: LampAction
        let isAllowed: () -> Bool
    }
    private var pending: [PendingAction] = []
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var lastCompletion: ContinuousClock.Instant?
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let minimumGap: Duration
    private let execute: (LampAction) async throws -> Void
    private let onError: (Error) -> Void
    private let onBusy: (Bool) -> Void

    init(minimumGap: Duration = .milliseconds(150),
         execute: @escaping (LampAction) async throws -> Void,
         onError: @escaping (Error) -> Void,
         onBusy: @escaping (Bool) -> Void = { _ in }) {
        self.minimumGap = minimumGap
        self.execute = execute
        self.onError = onError
        self.onBusy = onBusy
    }

    func enqueue(_ action: LampAction, ifAllowed: @escaping () -> Bool = { true }) {
        pending.removeAll { $0.action.key == action.key }
        pending.append(PendingAction(action: action, isAllowed: ifAllowed))
        startWorkerIfNeeded()
    }

    /// Used for a final lifecycle command: finish the active write first, but
    /// drop obsolete slider values before the final power-off operation.
    func replacePending(with action: LampAction) {
        replacePending(with: [action])
    }

    func replacePending(with actions: [LampAction], ifAllowed: @escaping () -> Bool = { true }) {
        pending = actions.map { PendingAction(action: $0, isAllowed: ifAllowed) }
        startWorkerIfNeeded()
    }

    func discardPending(where shouldDiscard: (LampAction) -> Bool) {
        pending.removeAll { shouldDiscard($0.action) }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let generation = self.generation
        onBusy(true)
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.worker = nil
                    self.onBusy(false)
                    self.resumeIdleWaiters()
                }
            }
            do {
                while !self.pending.isEmpty, self.generation == generation {
                    if let last = self.lastCompletion {
                        try await ContinuousClock().sleep(until: last.advanced(by: self.minimumGap))
                    }
                    try Task.checkCancellation()
                    guard self.generation == generation, !self.pending.isEmpty else { break }
                    let pendingAction = self.pending.removeFirst()
                    guard pendingAction.isAllowed() else { continue }
                    try await self.execute(pendingAction.action)
                    self.lastCompletion = .now
                }
            } catch is CancellationError {
                // Explicit release/forget cancels work without producing an error banner.
            } catch {
                guard self.generation == generation else { return }
                self.pending.removeAll()
                self.onError(error)
            }
        }
    }

    func cancel() {
        generation = UUID()
        pending.removeAll()
        worker?.cancel()
        worker = nil
        onBusy(false)
        resumeIdleWaiters()
    }

    func waitUntilIdle() async {
        guard worker != nil else { return }
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || worker == nil { continuation.resume() }
                else { idleWaiters[id] = continuation }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.idleWaiters.removeValue(forKey: id)?.resume() }
        })
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters.values
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
