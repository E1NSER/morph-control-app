import AppKit
import SwiftUI
import MorphCore
import MorphServices
import Combine

@main
@MainActor
struct MorphApp: App {
    @NSApplicationDelegateAdaptor(MorphAppDelegate.self) private var appDelegate
    @StateObject private var pairing: PairingModel
    @StateObject private var theme: ThemeSettings
    @StateObject private var language: LanguageSettings
    @StateObject private var windows: AppWindows

    init() {
        if DebugOptions.isolatedSetup { ServiceLocalization.setTemporaryLanguage("system") }
        let controller: LampController
        let pairing: PairingModel
        var isolatedFactory: (() -> LampController)? = nil
        #if DEBUG
        if DebugOptions.isolatedSetup {
            controller = DebugOptions.isolatedControls ? LampController.isolatedControlPreview() : LampController.isolatedSetupPreview()
            pairing = PairingModel.isolatedSetupPreview()
            isolatedFactory = { LampController.isolatedSetupPreview() }
        } else {
            controller = LampController(demo: DebugOptions.demo,
                                        keepConnectionAlive: ConnectionPreferences.keepAlive,
                                        syncPowerWithMac: ConnectionPreferences.syncPowerWithMac)
            pairing = PairingModel()
        }
        #else
        controller = LampController(keepConnectionAlive: ConnectionPreferences.keepAlive,
                                    syncPowerWithMac: ConnectionPreferences.syncPowerWithMac)
        pairing = PairingModel()
        #endif
        // Debug uses a separate bundle identifier and therefore a separate
        // standard preferences container from the installed app.
        let theme = ThemeSettings(defaults: DebugOptions.isolatedSetup ? nil : .standard)
        let language = LanguageSettings(defaults: DebugOptions.isolatedSetup ? nil : .standard)
        let windows = AppWindows(controller: controller, pairing: pairing, theme: theme, language: language,
                                 realControllerFactory: isolatedFactory, isolatedPreview: DebugOptions.isolatedSetup)
        _pairing = StateObject(wrappedValue: pairing)
        _theme = StateObject(wrappedValue: theme)
        _language = StateObject(wrappedValue: language)
        _windows = StateObject(wrappedValue: windows)
        MorphAppDelegate.windows = windows
    }

    var body: some Scene {
        MenuBarExtra {
            LampPanel()
                .id(ObjectIdentifier(controller))
                .environmentObject(controller)
                .environmentObject(windows)
                .disabled(windows.isSwitchingMode)
                .modifier(MorphTheme(theme: theme))
                .modifier(MorphLanguage(language: language))
        } label: {
            Image(nsImage: MenuBarLampIcon.image(for: menuBarIconState))
                .renderingMode(.template)
                .frame(width: 20, height: 20)
                .accessibilityLabel(menuBarTitle)
                .help(menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }

    private var controller: LampController { windows.controller }

    private var menuBarIconState: MenuBarLampIcon.State {
        guard controller.connection == .connected else { return .disconnected }
        return controller.state?.power == true ? .on : .off
    }

    private var menuBarTitle: String {
        if controller.isDemo { return AppText.string("Morph Control – Demo") }
        guard controller.connection == .connected else { return AppText.string("Morph Control – nicht verbunden") }
        if let effect = controller.activeLightEffect { return AppText.format("menu.effect.active", effect.title) }
        return controller.state?.power == true ? AppText.string("Morph Control – Licht an") : AppText.string("Morph Control – Licht aus")
    }
}

enum DebugOptions {
    static var isolatedControls: Bool {
        #if DEBUG
        return Bundle.main.bundleIdentifier == "at.einser.morphcontrol.iconcapture"
        #else
        return false
        #endif
    }

    static var isolatedSetup: Bool {
        #if DEBUG
        return isolatedControls || Bundle.main.bundleIdentifier == "at.einser.morphcontrol.demoqa"
            || ProcessInfo.processInfo.arguments.contains("--preview-setup")
        #else
        return false
        #endif
    }

    static var demo: Bool {
        #if DEBUG
        // The separate Preview app is safe to launch from tools or Finder.
        // Hardware debugging is an explicit opt-in, never the preview default.
        return !ProcessInfo.processInfo.arguments.contains("--live")
        #else
        return false
        #endif
    }
}

enum ConnectionPreferences {
    private static let keepAliveKey = "connection.keepAlive"
    private static let syncPowerKey = "connection.syncPowerWithMac"

    static var keepAlive: Bool {
        get { UserDefaults.standard.object(forKey: keepAliveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: keepAliveKey) }
    }

    static var syncPowerWithMac: Bool {
        get { UserDefaults.standard.bool(forKey: syncPowerKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncPowerKey) }
    }
}

@MainActor
final class AppWindows: NSObject, ObservableObject, NSWindowDelegate {
    private let session: LampSession
    var controller: LampController { session.controller }
    @Published private(set) var isSwitchingMode = false
    let isIsolatedPreview: Bool
    var allowsSystemIntegration: Bool { !isIsolatedPreview && !controller.isDemo }
    let pairing: PairingModel
    let theme: ThemeSettings
    let language: LanguageSettings
    private var languageObserver: NSObjectProtocol?
    private var sessionObservation: AnyCancellable?
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var controlsWindow: NSWindow?
    private var visibleControlPanels: Set<UUID> = []
    private var isTerminating = false

    init(controller: LampController, pairing: PairingModel, theme: ThemeSettings, language: LanguageSettings,
         realControllerFactory: (() -> LampController)? = nil, isolatedPreview: Bool = false) {
        self.session = LampSession(controller: controller, realControllerFactory: realControllerFactory ?? {
            LampController(keepConnectionAlive: ConnectionPreferences.keepAlive,
                           syncPowerWithMac: ConnectionPreferences.syncPowerWithMac)
        })
        self.isIsolatedPreview = isolatedPreview
        self.pairing = pairing
        self.theme = theme
        self.language = language
        super.init()
        sessionObservation = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if controller.isDemo {
            pairing.setDemoMode(true)
            theme.beginDemo()
            language.beginDemo()
        }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .morphLanguageDidChange, object: language, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadLocalizedText() }
        }
    }

    func showInitialWindow() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if DebugOptions.isolatedControls { showControls(); return }
        if DebugOptions.isolatedSetup { showSetup(); return }
        if arguments.contains("--preview-panel") { showControls(); return }
        if DebugOptions.demo { showControls(); return }
        #endif
        if !controller.hasCredentials { showSetup() }
    }

    func showSetup() {
        guard !isTerminating, !isSwitchingMode else { return }
        guard !controller.isDemo else { showControls(); return }
        if setupWindow == nil {
            setupWindow = makeWindow(
                title: AppText.string("Morph Control einrichten"), size: NSSize(width: 480, height: 590),
                content: SetupView()
                    .modifier(MorphTheme(theme: theme))
                    .modifier(MorphLanguage(language: language))
                    .environmentObject(controller)
                    .environmentObject(pairing)
                    .environmentObject(self))
        }
        show(setupWindow)
    }

    func closeSetup() {
        setupWindow?.close()
        pairing.reset()
    }

    func enterDemo() async {
        guard !isTerminating, !isSwitchingMode, !controller.isDemo else { return }
        isSwitchingMode = true
        defer { isSwitchingMode = false }
        pairing.setDemoMode(true)
        closeModeWindows()
        theme.beginDemo()
        language.beginDemo()
        await session.enterDemo()
        isSwitchingMode = false
        showControls()
    }

    func exitDemo() async {
        guard !isTerminating, !isSwitchingMode, controller.isDemo else { return }
        isSwitchingMode = true
        defer { isSwitchingMode = false }
        closeModeWindows()
        await session.exitDemo()
        theme.endDemo()
        language.endDemo()
        pairing.setDemoMode(false)
        controller.reloadLocalizedText()
        isSwitchingMode = false
        if controller.hasCredentials { showControls() } else { showSetup() }
    }

    private func closeModeWindows() {
        let windows = [setupWindow, settingsWindow, controlsWindow].compactMap { $0 }
        windows.forEach { $0.close() }
        visibleControlPanels.removeAll()
    }

    func showSettings() {
        guard !isTerminating, !isSwitchingMode else { return }
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: AppText.string("Morph Control Einstellungen"), size: NSSize(width: 500, height: 570),
                content: SettingsView()
                    .modifier(MorphTheme(theme: theme))
                    .modifier(MorphLanguage(language: language))
                    .environmentObject(controller)
                    .environmentObject(self))
        }
        show(settingsWindow)
    }

    func showControls() {
        guard !isTerminating, !isSwitchingMode else { return }
        if controlsWindow == nil {
            controlsWindow = makeWindow(
                title: AppText.string("Morph Control Steuerung"), size: NSSize(width: 340, height: 560),
                content: LampPanel()
                    .modifier(MorphTheme(theme: theme))
                    .modifier(MorphLanguage(language: language))
                    .environmentObject(controller)
                    .environmentObject(self))
        }
        show(controlsWindow)
    }

    func updateControlsVisibility(id: UUID, visible: Bool) {
        guard !isTerminating, !isSwitchingMode else { return }
        let wasVisible = !visibleControlPanels.isEmpty
        if visible { visibleControlPanels.insert(id) } else { visibleControlPanels.remove(id) }
        let isVisible = !visibleControlPanels.isEmpty
        guard wasVisible != isVisible else { return }
        if isVisible { controller.panelOpened() } else { controller.panelClosed() }
    }

    func beginTermination() {
        isTerminating = true
        pairing.reset()
        session.beginTermination()
    }

    func prepareForTermination(powerOff: Bool) async {
        await session.prepareForTermination(powerOff: powerOff && allowsSystemIntegration)
    }

    func forceAbortConnections() async { await session.forceAbortConnections() }

    private func reloadLocalizedText() {
        setupWindow?.title = AppText.string("Morph Control einrichten")
        settingsWindow?.title = AppText.string("Morph Control Einstellungen")
        controlsWindow?.title = AppText.string("Morph Control Steuerung")
        controller.reloadLocalizedText()
        pairing.reloadLocalizedText()
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .none
        window.delegate = self
        let hostingView = NSHostingView(rootView: content)
        // AppKit owns these utility windows. Letting the hosting view resize
        // its window during layout can create a constraint feedback loop.
        hostingView.sizingOptions = []
        let fittingSize = hostingView.fittingSize
        if fittingSize.width > 0 && fittingSize.height > 0 {
            window.setContentSize(fittingSize)
        }
        window.contentView = hostingView
        window.center()
        return window
    }

    private func show(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === setupWindow {
            pairing.reset()
            setupWindow = nil
        } else if window === settingsWindow {
            settingsWindow = nil
        } else if window === controlsWindow {
            controlsWindow = nil
        }
    }
}

@MainActor
final class MorphAppDelegate: NSObject, NSApplicationDelegate {
    static weak var windows: AppWindows?
    private var isTerminating = false
    private var sleepObserver: NSObjectProtocol?
    private var systemSleepCoordinator: SystemSleepCoordinator?
    private var wakeObserver: NSObjectProtocol?
    private var returnObservers: [NSObjectProtocol] = []
    private var terminationPreparation: TerminationPreparation?
    private var terminationSender: NSApplication?
    private var terminationFinished = false
    private var didReplyToTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Self.windows?.theme.applyAppearance()
        Self.windows?.controller.start()
        Self.windows?.showInitialWindow()
        if Self.windows?.allowsSystemIntegration == true {
            let coordinator = SystemSleepCoordinator(prepare: { [weak self] in
                guard self?.isTerminating == false, let windows = Self.windows,
                      !windows.isSwitchingMode, windows.allowsSystemIntegration else { return }
                await windows.controller.suspendForSleep()
            }, force: {
                await Self.windows?.forceAbortConnections()
            })
            if coordinator.start() { systemSleepCoordinator = coordinator }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // IOKit supplies a bounded acknowledgement window. The Cocoa
                // observer alone is only an advisory fallback.
                guard self?.isTerminating == false, self?.systemSleepCoordinator?.isRegistered != true,
                      let windows = Self.windows, !windows.isSwitchingMode,
                      windows.allowsSystemIntegration else { return }
                await windows.controller.suspendForSleep()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.isTerminating == false, let windows = Self.windows,
                      !windows.isSwitchingMode, windows.allowsSystemIntegration else { return }
                self?.systemSleepCoordinator?.cancelPendingForWake()
                windows.controller.resumeAfterWake()
            }
        }
        // Display sleep and session switching do not always put the Mac to
        // sleep. Verify an idle BLE session when the user returns as well.
        returnObservers = [NSWorkspace.screensDidWakeNotification,
                           NSWorkspace.sessionDidBecomeActiveNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard self?.isTerminating == false, let windows = Self.windows,
                          !windows.isSwitchingMode, windows.allowsSystemIntegration else { return }
                    windows.controller.recoverAfterInactivity()
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification, object: nil)
    }

    @objc private func systemWillPowerOff(_ notification: Notification) {
        beginTermination(powerOff: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isTerminating, let windows = Self.windows else { return false }
        if windows.controller.hasCredentials { windows.showControls() } else { windows.showSetup() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationFinished { return .terminateNow }
        terminationSender = sender
        beginTermination(powerOff: false)
        return .terminateLater
    }

    private func beginTermination(powerOff: Bool) {
        guard !isTerminating else { return }
        isTerminating = true
        let windows = Self.windows
        windows?.beginTermination()
        systemSleepCoordinator?.stop()
        let preparation = TerminationPreparation(prepare: {
            await windows?.prepareForTermination(powerOff: powerOff)
        }, force: {
            await windows?.forceAbortConnections()
        })
        terminationPreparation = preparation
        preparation.begin { [weak self] _ in self?.finishTermination() }
    }

    private func finishTermination() {
        terminationFinished = true
        systemSleepCoordinator?.stop()
        systemSleepCoordinator = nil
        guard !didReplyToTermination, let sender = terminationSender else { return }
        didReplyToTermination = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}
