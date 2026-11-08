import SwiftUI
import MorphCore
import MorphServices

struct LampPanel: View {
    @EnvironmentObject private var language: LanguageSettings
    @Environment(\.morphAccent) private var accent
    @EnvironmentObject private var controller: LampController
    @EnvironmentObject private var windows: AppWindows
    @State private var brightness = 50.0
    @State private var kelvin = 4000.0
    @State private var editingBrightness = false
    @State private var editingKelvin = false
    @State private var showAutomation = false
    @State private var panelVisible = false
    @State private var panelID = UUID()
    @State private var manualModeRefresh: Task<Void, Never>?

    private var connected: Bool { controller.connection == .connected }
    private var poweredOn: Bool { controller.state?.power == true }
    private var lightControlsEnabled: Bool {
        connected && !controller.isRestoringAutomaticLighting && !controller.isStartingLightEffect
    }
    private var automaticLightingActive: Bool {
        guard connected, !controller.isStartingLightEffect,
              controller.activeLightEffect == nil, let state = controller.state else { return false }
        return state.daylight == true && state.autoBrightness && state.preset == nil
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            panelContent.fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) { panelContent }
        }
        .frame(width: 340, height: min(650, maximumPanelHeight))
        .background(Color(nsColor: .windowBackgroundColor))
        .background(PanelVisibilityObserver(onChange: updatePanelVisibility))
        .tint(accent)
        .disabled(windows.isSwitchingMode)
        .onAppear { syncValues() }
        .onDisappear { updatePanelVisibility(false) }
        .onChange(of: controller.state) { _ in syncValues() }
    }

    private var panelContent: some View {
        VStack(spacing: 16) {
            if controller.isDemo { DemoModeNotice() }
            header
            if controller.hasCredentials {
                if let message = controller.errorMessage {
                    InlineMessage(text: message)
                }
                if !connected { connectionCard }
                lightingMode
                controls
                    .disabled(!lightControlsEnabled)
                    .opacity(connected ? 1 : 0.48)
                presets
                    .disabled(!lightControlsEnabled)
                    .opacity(connected ? 1 : 0.48)
                lightEffects
                automation
                    .disabled(!lightControlsEnabled)
            } else {
                welcome
            }
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity)
    }

    private var maximumPanelHeight: CGFloat {
        min(760, max(380, (NSScreen.main?.visibleFrame.height ?? 850) - 60))
    }

    private var header: some View {
        HStack(spacing: 11) {
            LampMark(size: 42, isOn: poweredOn)
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.hasCredentials ? controller.lampName : "Morph Control")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if controller.connection == .connecting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle()
                            .fill(connected ? Color.green.opacity(0.8) : Color.secondary.opacity(0.5))
                            .frame(width: 5, height: 5)
                    }
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 5)
            if controller.hasCredentials {
                Button { controller.setPower(!poweredOn) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 42, height: 42)
                        .foregroundStyle(poweredOn ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                        .background(poweredOn ? accent : Color.primary.opacity(0.055), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!lightControlsEnabled)
                .help(poweredOn ? AppText.string("Lampe ausschalten") : AppText.string("Lampe einschalten"))
                .accessibilityLabel(poweredOn ? AppText.string("Lampe ausschalten") : AppText.string("Lampe einschalten"))
                .accessibilityValue(poweredOn ? AppText.string("Ein") : AppText.string("Aus"))
            }
        }
    }

    private var lightingMode: some View {
        MorphCard {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lightingModeTitle)
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(lightingModeSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if automaticLightingActive && !controller.isRestoringAutomaticLighting {
                    Label(AppText.string("Aktiv"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                        .accessibilityLabel(AppText.string("Tageslichtsteuerung und automatische Helligkeit sind aktiv"))
                } else {
                    Button {
                        manualModeRefresh?.cancel()
                        Task { await controller.restoreAutomaticLighting() }
                    } label: {
                        HStack(spacing: 5) {
                            if controller.isRestoringAutomaticLighting || controller.isStartingLightEffect {
                                ProgressView().controlSize(.mini)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            Text(AppText.string("Zur Automatik"))
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!lightControlsEnabled)
                    .accessibilityLabel(AppText.string("Zur Automatik wechseln"))
                    .accessibilityHint(AppText.string("Beendet aktive Lichtprofile und aktiviert Tageslichtsteuerung sowie automatische Helligkeit. Die Bewegungserkennung bleibt unverändert."))
                    .help(AppText.string("Tageslicht und automatische Helligkeit aktivieren"))
                }
            }
        }
    }

    private var lightingModeTitle: String {
        if controller.isStartingLightEffect { return AppText.string("Effekt startet …") }
        if controller.isRestoringAutomaticLighting { return AppText.string("Wird aktiviert …") }
        if let effect = controller.activeLightEffect { return AppText.format("effect.running", effect.title) }
        guard connected, let state = controller.state else { return AppText.string("Lichtautomatik") }
        if let preset = state.preset {
            switch preset {
            case .study: return AppText.string("Lernen aktiv")
            case .relax: return AppText.string("Entspannen aktiv")
            case .precision: return AppText.string("Präzision aktiv")
            }
        }
        guard let daylight = state.daylight else { return AppText.string("Status unbekannt") }
        if automaticLightingActive { return AppText.string("Automatik aktiv") }
        if daylight { return AppText.string("Tageslicht aktiv") }
        if state.autoBrightness { return AppText.string("Helligkeit automatisch") }
        return AppText.string("Manuell eingestellt")
    }

    private var lightingModeSubtitle: String {
        guard connected else { return AppText.string("Verbindung erforderlich") }
        switch controller.activeLightEffect {
        case .morph: return AppText.string("Sanfter Warm-Kühl-Verlauf")
        case .party: return AppText.string("Lebendiger Lichtrhythmus")
        case nil: return AppText.string("Tageslicht und Helligkeit")
        }
    }

    private var lightEffects: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionCaption(text: AppText.string("Lichteffekte"))
                Spacer()
                if controller.activeLightEffect != nil || controller.isStartingLightEffect {
                    Button(AppText.string("Anhalten")) {
                        manualModeRefresh?.cancel()
                        controller.stopLightEffect()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(accent)
                    .disabled(!connected || controller.isRestoringAutomaticLighting)
                    .accessibilityLabel(AppText.string("Lichteffekt anhalten"))
                    .accessibilityHint(AppText.string("Beendet die Animation und behält das aktuelle Licht bei."))
                }
            }
            HStack(spacing: 7) {
                ForEach(LightEffect.allCases) { effect in
                    lightEffectButton(effect)
                }
            }
            Text(controller.activeLightEffect == nil
                 ? AppText.string("Für indirektes Licht den Kopf zur Lichtsäule ausrichten.")
                 : AppText.string("Anhalten behält das Licht bei. „Zur Automatik“ schaltet zurück."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lightEffectButton(_ effect: LightEffect) -> some View {
        let selected = controller.activeLightEffect == effect
        return Button {
            guard !selected else { return }
            manualModeRefresh?.cancel()
            Task { await controller.startLightEffect(effect) }
        } label: {
            VStack(spacing: 4) {
                Label(effect.title, systemImage: effect == .morph ? "waveform.path" : "sparkles")
                    .font(.system(size: 12, weight: .medium))
                Text(effect == .morph ? AppText.string("Sanfter Verlauf") : AppText.string("Lebendiger Rhythmus"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 49)
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.8))
            .background(selected ? accent.opacity(0.11) : MorphStyle.surface.opacity(0.8),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(selected ? accent.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!lightControlsEnabled)
        .accessibilityLabel(AppText.format("effect.start.accessibility", effect.title))
        .accessibilityValue(selected ? AppText.string("Aktiv") : AppText.string("Inaktiv"))
        .accessibilityHint(AppText.string("Animiert Helligkeit und Weißtemperatur. Mit Anhalten oder Zur Automatik beenden."))
        .help(effect == .morph ? AppText.string("Langsamer Verlauf von warmem zu kühlerem Weiß") : AppText.string("Schnellerer Helligkeits- und Weißtemperaturrhythmus"))
    }

    private var controls: some View {
        MorphCard {
            VStack(spacing: 21) {
                VStack(spacing: 8) {
                    controlHeading(AppText.string("Helligkeit"), value: "\(Int(brightness))", unit: "%")
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").font(.system(size: 12)).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { brightness }, set: {
                            brightness = $0
                            controller.setBrightness(Int($0.rounded()))
                            scheduleModeRefresh()
                        }), in: 0...100, step: 1, onEditingChanged: {
                            editingBrightness = $0
                            if !$0 { scheduleModeRefresh() }
                        })
                        .accessibilityLabel(AppText.string("Helligkeit"))
                        .accessibilityValue(AppText.format("brightness.percent", Int(brightness)))
                        Image(systemName: "sun.max").font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                }
                Divider().opacity(0.65)
                VStack(spacing: 8) {
                    controlHeading(AppText.string("Lichttemperatur"), value: "\(Int(kelvin))", unit: "K")
                    HStack(spacing: 10) {
                        Circle().fill(MorphStyle.warm).frame(width: 9, height: 9).accessibilityHidden(true)
                        Slider(value: Binding(get: { kelvin }, set: {
                            kelvin = $0
                            controller.setKelvin(Int($0.rounded()))
                            scheduleModeRefresh()
                        }), in: 2700...6500, step: 100, onEditingChanged: {
                            editingKelvin = $0
                            if !$0 { scheduleModeRefresh() }
                        })
                        .accessibilityLabel(AppText.string("Lichttemperatur"))
                        .accessibilityValue(AppText.format("temperature.kelvin", Int(kelvin)))
                        Circle().fill(MorphStyle.cool).frame(width: 9, height: 9).accessibilityHidden(true)
                    }
                    HStack {
                        Text(AppText.string("Warm"))
                        Spacer()
                        Text(AppText.string("Kühl"))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private func controlHeading(_ title: String, value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption(text: AppText.string("Lichtprofile"))
            HStack(spacing: 7) {
                presetButton(.study, title: AppText.string("Lernen"), symbol: "book.closed")
                presetButton(.relax, title: AppText.string("Entspannen"), symbol: "leaf")
                presetButton(.precision, title: AppText.string("Präzision"), symbol: "scope")
            }
        }
    }

    private func presetButton(_ preset: Preset, title: String, symbol: String) -> some View {
        let selected = controller.state?.preset == preset
        return Button {
            controller.setPreset(selected ? nil : preset)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 59)
            .foregroundStyle(selected ? accent : Color.primary.opacity(0.75))
            .background(selected ? accent.opacity(0.11) : MorphStyle.surface.opacity(0.8),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(selected ? accent.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppText.format("profile.accessibility", title))
        .accessibilityValue(selected ? AppText.string("Aktiv") : AppText.string("Inaktiv"))
        .help(selected ? AppText.string("Profil deaktivieren") : AppText.format("profile.activate", title))
    }

    private var automation: some View {
        DisclosureGroup(isExpanded: $showAutomation) {
            VStack(spacing: 12) {
                Toggle(AppText.string("Tageslicht folgen"), isOn: Binding(
                    get: { controller.state?.daylight ?? false }, set: { controller.setDaylight($0) }))
                    .disabled(controller.state?.daylight == nil)
                    .help(AppText.string("Passt das Licht dem Tagesverlauf am eingerichteten Standort an."))
                Toggle(AppText.string("Helligkeit automatisch"), isOn: Binding(
                    get: { controller.state?.autoBrightness ?? false }, set: { controller.setAutoBrightness($0) }))
                    .help(AppText.string("Die Lampe gleicht das Umgebungslicht aus."))
                Toggle(AppText.string("Bewegung erkennen"), isOn: Binding(
                    get: { controller.state?.movement ?? false }, set: { controller.setMovement($0) }))
                    .help(AppText.string("Die Lampe reagiert auf Anwesenheit am Schreibtisch."))
                if controller.state?.autoBrightness == true {
                    Text(AppText.string("Die Lampe regelt ihre Helligkeit selbst nach."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 11))
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.top, 13)
        } label: {
            Label(AppText.string("Automatikoptionen"), systemImage: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(MorphStyle.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
    }

    private var connectionCard: some View {
        HStack(spacing: 12) {
            Text(connectionMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if controller.connection != .connecting {
                Button(AppText.string("Verbinden")) { Task { await controller.connect() } }
                    .controlSize(.small)
                    .disabled(controller.isBusy)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Divider().padding(.vertical, 2)
            Text(AppText.string("Dein Licht. Direkt am Mac."))
                .font(.system(size: 17, weight: .medium, design: .rounded))
            Text(AppText.string("Verbinde deine Solarcycle Morph einmal mit deinem Dyson-Konto. Danach steuerst du sie lokal über Bluetooth."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button(AppText.string("Lampe einrichten")) { windows.showSetup() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 3)
        }
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button { windows.showSettings() } label: {
                Label(AppText.string("Einstellungen"), systemImage: "gearshape")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Menu {
                if controller.hasCredentials {
                    Button(AppText.string("Status aktualisieren")) { Task { await controller.refresh() } }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(!connected)
                    if windows.allowsSystemIntegration {
                        Button(AppText.string("Verbindung freigeben")) { Task { await controller.releaseConnection() } }
                            .disabled(!connected && controller.connection != .connecting)
                    }
                    Divider()
                }
                Button(AppText.string("Morph Control beenden")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(AppText.string("Weitere Aktionen"))
            .accessibilityLabel(AppText.string("Weitere Aktionen"))
        }
        .padding(.top, 1)
    }

    private var statusText: String {
        if controller.isDemo {
            return AppText.string(poweredOn ? "demo.status.on" : "demo.status.off")
        }
        switch controller.connection {
        case .unpaired: return AppText.string("Noch keine Lampe eingerichtet")
        case .disconnected: return controller.isConnectionPaused ? AppText.string("Verbindung freigegeben") : AppText.string("Bereit zum Verbinden")
        case .connecting: return AppText.string("Verbindung wird hergestellt")
        case .connected: return poweredOn ? AppText.string("Verbunden · Licht an") : AppText.string("Verbunden · Licht aus")
        case .failed: return AppText.string("Nicht verbunden")
        }
    }

    private var connectionMessage: String {
        if controller.connection == .connecting { return AppText.string("Deine Lampe wird verbunden …") }
        if controller.isConnectionPaused { return AppText.string("Verbindung für MyDyson freigegeben. Mit „Verbinden“ fortfahren.") }
        return AppText.string("Für die Steuerung mit deiner Lampe verbinden.")
    }

    private func syncValues() {
        guard let state = controller.state else { return }
        if !editingBrightness { brightness = Double(state.brightness) }
        if !editingKelvin { kelvin = Double(state.kelvin) }
    }

    private func scheduleModeRefresh() {
        manualModeRefresh?.cancel()
        manualModeRefresh = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 400_000_000) }
            catch { return }
            guard !editingBrightness, !editingKelvin,
                  !controller.isRestoringAutomaticLighting else { return }
            await controller.refresh()
        }
    }

    private func updatePanelVisibility(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        windows.updateControlsVisibility(id: panelID, visible: visible)
    }
}

/// Keep simulated controls unmistakable in both the menu panel and Settings.
struct DemoModeNotice: View {
    @EnvironmentObject private var language: LanguageSettings
    @EnvironmentObject private var windows: AppWindows
    @Environment(\.morphAccent) private var accent
    var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(AppText.string("demo.mode.title"), systemImage: "play.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(AppText.string("demo.exit.title")) {
                    Task { await windows.exitDemo() }
                }
                .buttonStyle(.link)
                .font(.system(size: 10, weight: .medium))
                .disabled(windows.isSwitchingMode)
                .accessibilityHint(AppText.string("demo.exit.hint"))
            }
            Text(AppText.string(showsDetails ? "demo.mode.details" : "demo.mode.description"))
                .font(.system(size: showsDetails ? 11 : 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
    }
}

/// MenuBarExtra may retain its content after hiding; observe the native window
/// instead of treating SwiftUI's view lifetime as the panel lifetime.
private struct PanelVisibilityObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) { view.onChange = onChange }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.stop() }

    @MainActor
    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observations: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else { onChange?(false); return }
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observations.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.reportVisibility() }
                })
            }
            observations.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onChange?(false) }
            })
            DispatchQueue.main.async { [weak self] in self?.reportVisibility() }
        }

        func stop() {
            removeObservers()
            onChange?(false)
            onChange = nil
        }

        private func reportVisibility() {
            guard let window else { onChange?(false); return }
            onChange?(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }

        private func removeObservers() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
        }
    }
}
