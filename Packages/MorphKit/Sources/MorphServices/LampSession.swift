import Combine
import Foundation

/// Keeps the user's lamp separate from the public, fully local demonstration.
/// Entering a demo never replaces or reloads the user's stored credentials.
@MainActor
public final class LampSession: ObservableObject {
    @Published public private(set) var controller: LampController
    @Published public private(set) var isSwitchingMode = false
    private var realController: LampController?
    private let realControllerFactory: () -> LampController
    private let demoControllerFactory: () -> LampController
    private var controllerObservation: AnyCancellable?
    private var isTerminating = false

    public init(controller: LampController, realControllerFactory: @escaping () -> LampController,
                demoControllerFactory: (() -> LampController)? = nil) {
        self.controller = controller
        self.realControllerFactory = realControllerFactory
        self.demoControllerFactory = demoControllerFactory ?? { LampController(demo: true) }
        if !controller.isDemo { realController = controller }
        observeController()
    }

    public func enterDemo() async {
        guard !isTerminating, !isSwitchingMode, !controller.isDemo else { return }
        isSwitchingMode = true
        defer { isSwitchingMode = false }
        // Cancel commands, effects and recovery before exposing the simulation.
        // Releasing a connection does not switch off or alter the physical lamp.
        await controller.deactivateSession()
        guard !isTerminating else { return }
        controller = demoControllerFactory()
        observeController()
        await controller.connect()
    }

    public func exitDemo() async {
        guard !isTerminating, !isSwitchingMode, controller.isDemo else { return }
        isSwitchingMode = true
        defer { isSwitchingMode = false }
        await controller.releaseConnection()
        guard !isTerminating else { return }
        let restored = realController ?? realControllerFactory()
        realController = restored
        restored.activateSession()
        controller = restored
        observeController()
        // Connecting is an explicit panel/setup action after returning. In
        // particular, exiting a demo must not invoke the Mac power-on policy.
    }

    public func beginTermination() {
        isTerminating = true
        terminationControllers.forEach { $0.beginTermination() }
    }

    public func prepareForTermination(powerOff: Bool) async {
        beginTermination()
        for controller in terminationControllers {
            await controller.prepareForTermination(powerOff: powerOff)
        }
    }

    public func forceAbortConnections() async {
        for controller in terminationControllers { await controller.forceAbortConnections() }
    }

    private var terminationControllers: [LampController] {
        if let realController, realController !== controller { return [realController, controller] }
        return [controller]
    }

    private func observeController() {
        controllerObservation = controller.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
