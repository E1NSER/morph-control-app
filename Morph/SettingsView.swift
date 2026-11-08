import ServiceManagement
import SwiftUI
import MorphServices

struct SettingsView: View {
    @EnvironmentObject private var language: LanguageSettings
    @EnvironmentObject private var controller: LampController
    @EnvironmentObject private var windows: AppWindows
    @EnvironmentObject private var theme: ThemeSettings
    @Environment(\.morphAccent) private var morphAccent
    @State private var lampName = ""
    @State private var nameBaseline = ""
    @State private var launchAtLogin = false
    @State private var loginNeedsApproval = false
    @State private var updatingLoginItem = false
    @State private var showForgetConfirmation = false
    @State private var errorMessage: String?
    @State private var document: InformationDocument?
    @State private var customHexDraft = ""
    @State private var customHexError: String?
    @FocusState private var nameFocused: Bool
    @FocusState private var hexFieldFocused: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                LampMark(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Morph Control").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(AppText.string("Licht, das zu deinem Mac passt.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(appVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if controller.isDemo { DemoModeNotice(showsDetails: true) }
            if let message = errorMessage.map(AppText.string) ?? controller.errorMessage { InlineMessage(text: message) }
            languageSection
            appearanceSection
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    SectionCaption(text: AppText.string("Deine Lampe"))
                    Spacer()
                    if controller.hasCredentials {
                        Button { windows.showControls() } label: {
                            Label(AppText.string("Steuerung öffnen"), systemImage: "slider.horizontal.3")
                        }
                        .controlSize(.small)
                    }
                }
                MorphCard {
                    if controller.hasCredentials {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(AppText.string("Name")).font(.system(size: 12, weight: .medium))
                                Spacer()
                                TextField(AppText.string("Meine Lampe"), text: $lampName)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                                    .focused($nameFocused)
                                    .accessibilityLabel(AppText.string("Name der Lampe"))
                                    .onSubmit { saveName(); nameFocused = false }
                            }
                            Text(controller.serial)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            if windows.allowsSystemIntegration {
                                Divider()
                                Toggle(isOn: Binding(get: { controller.keepConnectionAlive }, set: { enabled in
                                    guard controller === windows.controller, windows.allowsSystemIntegration, !windows.isSwitchingMode else { return }
                                    ConnectionPreferences.keepAlive = enabled
                                    controller.setKeepConnectionAlive(enabled)
                                })) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(AppText.string("Verbindung aufrechterhalten")).font(.system(size: 12, weight: .medium))
                                        Text(AppText.string("Verbindet die Lampe beim App-Start und hält sie bei geschlossenem Panel bereit."))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel(AppText.string("Verbindung aufrechterhalten"))
                                .accessibilityHint(AppText.string("Hält die Bluetooth-Verbindung auch bei geschlossenem Steuerpanel. MyDyson benötigt eine freigegebene Verbindung."))
                                if !controller.keepConnectionAlive {
                                    Text(AppText.string("Bei geschlossenem Steuerpanel wird die Verbindung nach 60 Sekunden ohne Bedienung freigegeben."))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Divider()
                                Toggle(isOn: Binding(get: { controller.syncPowerWithMac }, set: { enabled in
                                    guard controller === windows.controller, windows.allowsSystemIntegration, !windows.isSwitchingMode else { return }
                                    ConnectionPreferences.syncPowerWithMac = enabled
                                    controller.setSyncPowerWithMac(enabled)
                                })) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(AppText.string("Licht mit dem Mac schalten")).font(.system(size: 12, weight: .medium))
                                        Text(AppText.string("Beim App-Start und Aufwachen ein; vor Ruhezustand und Herunterfahren aus, solange die Lampe verbunden ist."))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityLabel(AppText.string("Licht mit dem Mac schalten"))
                                .accessibilityHint(AppText.string("Schaltet bei Start und Aufwachen ein und vor Ruhezustand und Herunterfahren aus. Eine manuell freigegebene Verbindung bleibt pausiert."))
                                if controller.syncPowerWithMac && !launchAtLogin {
                                    Text(AppText.string("Für den Computerstart aktiviere zusätzlich „Bei Anmeldung starten“."))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Divider()
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(AppText.string("Verbindung freigeben")).font(.system(size: 12, weight: .medium))
                                        Text(AppText.string("Damit MyDyson die Lampe steuern kann. Mit „Verbinden“ setzt du die Steuerung später fort."))
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Button(AppText.string("Freigeben")) { Task { await controller.releaseConnection() } }
                                        .controlSize(.small)
                                        .disabled(controller.connection == .disconnected || controller.connection == .unpaired)
                                }
                            }
                        }
                    } else if windows.allowsSystemIntegration {
                        HStack {
                            Text(AppText.string("Noch keine Lampe eingerichtet."))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button(AppText.string("Einrichten")) { windows.showSetup() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            if windows.allowsSystemIntegration {
                VStack(alignment: .leading, spacing: 9) {
                    SectionCaption(text: AppText.string("Allgemein"))
                    MorphCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: Binding(get: { launchAtLogin }, set: updateLoginItem)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(AppText.string("Bei Anmeldung starten")).font(.system(size: 12, weight: .medium))
                                    Text(AppText.string("Morph Control erscheint direkt in deiner Menüleiste."))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel(AppText.string("Bei Anmeldung starten"))
                            .accessibilityHint(AppText.string("Morph Control erscheint nach deiner Anmeldung automatisch in der Menüleiste."))
                            .disabled(updatingLoginItem)
                            if loginNeedsApproval {
                                HStack(alignment: .top) {
                                    Text(AppText.string("Bitte erlaube Morph Control in den Anmeldeobjekten."))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(AppText.string("Öffnen")) {
                                        guard controller === windows.controller, windows.allowsSystemIntegration, !windows.isSwitchingMode else { return }
                                        SMAppService.openSystemSettingsLoginItems()
                                    }
                                        .controlSize(.small)
                                }
                            }
                            Divider()
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(AppText.string("demo.settings.title"))
                                        .font(.system(size: 12, weight: .medium))
                                    Text(AppText.string("demo.entry.description"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Button(AppText.string("demo.start.title")) {
                                    Task { await windows.enterDemo() }
                                }
                                .controlSize(.small)
                                .disabled(windows.isSwitchingMode || updatingLoginItem)
                                .accessibilityHint(AppText.string("demo.entry.description"))
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                SectionCaption(text: AppText.string("Über Morph Control"))
                HStack(spacing: 16) {
                    Button(AppText.string("Datenschutz")) { document = .privacy }
                    Button(AppText.string("Open-Source-Lizenzen")) { document = .licenses }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                Text(AppText.string("Unabhängiges Projekt. Nicht mit Dyson verbunden."))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack {
                if controller.hasCredentials && windows.allowsSystemIntegration {
                    Button(AppText.string("Lampe vergessen …")) { showForgetConfirmation = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppText.string("Morph Control beenden")) { NSApp.terminate(nil) }
                    .controlSize(.small)
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 500, height: settingsHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(morphAccent)
        .disabled(windows.isSwitchingMode)
        .onAppear {
            lampName = controller.lampName
            nameBaseline = controller.lampName
            restoreHexDraft()
            readLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLoginStatus()
        }
        .onChange(of: controller.lampName) { value in
            if !nameFocused || lampName == nameBaseline { lampName = value }
            nameBaseline = value
        }
        .onChange(of: language.selection) { _ in
            nameFocused = false
            hexFieldFocused = false
        }
        .onChange(of: nameFocused) { focused in if !focused { saveName() } }
        .onChange(of: hexFieldFocused) { focused in if !focused { applyHexDraft() } }
        .onChange(of: theme.customHex) { _ in
            if !hexFieldFocused { restoreHexDraft() }
        }
        .onChange(of: theme.accent) { palette in
            if palette == .custom && !hexFieldFocused { restoreHexDraft() }
        }
        .onDisappear {
            guard controller === windows.controller, windows.allowsSystemIntegration, !windows.isSwitchingMode else { return }
            saveName()
            if theme.accent == .custom { applyHexDraft() }
        }
        .confirmationDialog(AppText.string("Lampe von diesem Mac entfernen?"), isPresented: $showForgetConfirmation) {
            Button(AppText.string("Lampe vergessen"), role: .destructive) {
                Task {
                    guard controller === windows.controller, windows.allowsSystemIntegration, !windows.isSwitchingMode else { return }
                    do {
                        try await controller.forgetLamp()
                        windows.closeSetup()
                    }
                    catch { errorMessage = "Die gespeicherten Zugangsdaten konnten nicht entfernt werden. Bitte versuche es erneut." }
                }
            }
            Button(AppText.string("Abbrechen"), role: .cancel) {}
        } message: {
            Text(AppText.string("Die Bluetooth-Verbindung wird beendet und der Lampenschlüssel aus dem Schlüsselbund dieses Macs gelöscht. Deine Registrierung bei Dyson bleibt bestehen."))
        }
        .sheet(item: $document) { selected in
            InformationView(document: selected)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption(text: AppText.string("Erscheinungsbild"))
            MorphCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(AppText.string("Darstellung")).font(.system(size: 12, weight: .medium))
                        Picker(AppText.string("Darstellung"), selection: $theme.appearance) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(verbatim: appearance.title).tag(appearance)
                            }
                        }
                        // AppKit-backed pickers cache their items when the case IDs
                        // stay unchanged. Recreate only this control for a new locale.
                        .id(language.locale.identifier)
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel(AppText.string("Darstellung von Morph Control"))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 11) {
                        Text(AppText.string("Akzentfarbe")).font(.system(size: 12, weight: .medium))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 9) {
                            ForEach(AccentPalette.allCases) { palette in
                                accentSwatch(palette)
                            }
                        }
                        .id(language.locale.identifier)
                        if theme.accent == .custom {
                            VStack(alignment: .leading, spacing: 10) {
                                ColorPicker(AppText.string("Eigene Akzentfarbe"), selection: $theme.customColor, supportsOpacity: false)
                                    .font(.system(size: 12))
                                    .accessibilityLabel(AppText.string("Eigene Akzentfarbe auswählen"))
                                HStack {
                                    Text(AppText.string("Farbcode")).font(.system(size: 12))
                                    Spacer()
                                    TextField("D49559", text: $customHexDraft)
                                        .font(.system(size: 12, design: .monospaced))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 112)
                                        .focused($hexFieldFocused)
                                        .accessibilityLabel(AppText.string("Farbcode der eigenen Akzentfarbe"))
                                        .accessibilityHint(AppText.string("Sechs Hex-Zeichen eingeben, mit oder ohne Raute. Mit der Eingabetaste übernehmen."))
                                        .onSubmit { applyHexDraft(); hexFieldFocused = false }
                                        .onChange(of: customHexDraft) { _ in
                                            if hexFieldFocused { customHexError = nil }
                                        }
                                }
                                if let message = customHexError {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(AppText.string(message))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                        Button(AppText.string("Wiederherstellen")) { restoreHexDraft() }
                                            .buttonStyle(.link)
                                            .font(.system(size: 10))
                                            .accessibilityLabel(AppText.string("Gespeicherten Farbcode wiederherstellen"))
                                    }
                                } else {
                                    Text(AppText.string("Sechs Hex-Zeichen, zum Beispiel D49559. Eine Raute ist optional."))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    HStack {
                        Text(AppText.string(controller.isDemo ? "demo.appearance.scope" : "Gilt für Morph Control auf diesem Mac."))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(AppText.string("Zurücksetzen")) { theme.reset() }
                            .buttonStyle(.link)
                            .font(.system(size: 10))
                            .accessibilityLabel(AppText.string("Darstellung und Akzentfarbe zurücksetzen"))
                            .help(AppText.string("Systemdarstellung und Bernstein wiederherstellen"))
                    }
                }
            }
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption(text: AppText.string("Sprache"))
            MorphCard {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(AppText.string("App-Sprache"), selection: $language.selection) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(verbatim: option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel(AppText.string("App-Sprache"))
                    Text(AppText.string("System verwendet Deutsch bei deutscher Systemsprache, sonst English."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func accentSwatch(_ palette: AccentPalette) -> some View {
        let selected = theme.accent == palette
        return Button { theme.accent = palette } label: {
            VStack(spacing: 7) {
                Circle()
                    .fill(theme.previewColor(for: palette))
                    .frame(width: 27, height: 27)
                    .overlay { Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 1) }
                    .overlay {
                        if selected {
                            Circle().strokeBorder(morphAccent, lineWidth: 2).padding(-4)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.primary)
                                .frame(width: 13, height: 13)
                                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                                .offset(x: 3, y: 2)
                        }
                    }
                Text(verbatim: palette.title)
                    .font(.system(size: 10, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 61)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppText.format("accent.accessibility", palette.title))
        .accessibilityValue(selected ? AppText.string("Ausgewählt") : AppText.string("Nicht ausgewählt"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(palette.title)
    }

    private var settingsHeight: CGFloat {
        min(720, max(420, (NSScreen.main?.visibleFrame.height ?? 820) - 100))
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func applyHexDraft() {
        guard controller === windows.controller, !windows.isSwitchingMode, theme.accent == .custom else { return }
        var normalized = customHexDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("#") { normalized.removeFirst() }
        guard normalized.count == 6, normalized.allSatisfy(\.isHexDigit),
              let value = UInt32(normalized, radix: 16), value < 16_777_216 else {
            customHexError = "Bitte einen sechsstelligen Hex-Farbcode eingeben."
            return
        }
        let hex = normalized.uppercased()
        theme.customHex = hex
        customHexDraft = hex
        customHexError = nil
    }

    private func restoreHexDraft() {
        customHexDraft = theme.customHex.uppercased()
        customHexError = nil
    }

    private func saveName() {
        let trimmed = lampName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard controller === windows.controller, !windows.isSwitchingMode, controller.hasCredentials, !trimmed.isEmpty,
              trimmed != nameBaseline, trimmed != controller.lampName else { return }
        controller.renameLamp(lampName)
    }

    private func readLoginStatus() {
        guard controller === windows.controller, windows.allowsSystemIntegration, !windows.isSwitchingMode else { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    private func updateLoginItem(_ enabled: Bool) {
        guard controller === windows.controller, windows.allowsSystemIntegration, !windows.isSwitchingMode, !updatingLoginItem else { return }
        updatingLoginItem = true
        errorMessage = nil
        Task { @MainActor in
            defer { updatingLoginItem = false; readLoginStatus() }
            guard controller === windows.controller, windows.allowsSystemIntegration, !windows.isSwitchingMode else { return }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "Der automatische Start konnte nicht geändert werden. Verschiebe Morph Control bei Bedarf zuerst in den Programme-Ordner und versuche es erneut."
            }
        }
    }
}

private enum InformationDocument: String, Identifiable {
    case privacy, licenses
    var id: String { rawValue }
    var title: String { self == .privacy ? AppText.string("Datenschutz") : AppText.string("Open-Source-Lizenzen") }
    var content: String {
        switch self {
        case .privacy:
            guard let url = Bundle.main.url(forResource: AppLocale.languageCode == "en" ? "PRIVACY.en" : "PRIVACY", withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return AppText.string("Morph Control steuert die Lampe lokal über Bluetooth. Die Einrichtung erfolgt direkt über Dyson. Lampenschlüssel liegen im macOS-Schlüsselbund. Morph Control enthält keine Analyse- oder Trackingdienste. Die ausführlichen Datenschutzhinweise konnten nicht geladen werden.")
            }
            return text
        case .licenses:
            let names = ["Solarmorph-LICENSE.txt", "THIRD_PARTY_NOTICES.md"]
            let texts = names.compactMap { name -> String? in
                guard let url = Bundle.main.url(forResource: name, withExtension: nil),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return text
            }
            return AppText.string("licenses.intro") + texts.joined(separator: "\n\n––––––––––––––––––––\n\n")
        }
    }
}

private struct InformationView: View {
    let document: InformationDocument
    @EnvironmentObject private var language: LanguageSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(document.title).font(.system(size: 20, weight: .semibold, design: .rounded))
            ScrollView {
                if document == .privacy {
                    PrivacyContent(text: document.content)
                } else {
                    Text(document.content)
                        .font(.system(size: 12))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                Button(AppText.string("Schließen")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 550, height: 500)
    }
}

/// Only the bundled document's headings and paragraphs are needed here.
/// Keeping the parser small avoids introducing an external rendering library.
private struct PrivacyContent: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(blocks) { block in
                switch block.kind {
                case .title:
                    Text(block.text)
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                case .heading:
                    Text(block.text)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph:
                    Text(block.text)
                        .font(.system(size: 12))
                        .lineSpacing(5)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func append(_ kind: Block.Kind, _ value: String) {
            result.append(Block(id: result.count, kind: kind, text: value))
        }
        func finishParagraph() {
            guard !paragraph.isEmpty else { return }
            append(.paragraph, paragraph.joined(separator: " "))
            paragraph.removeAll()
        }
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                finishParagraph()
            } else if value.hasPrefix("## ") {
                finishParagraph()
                append(.heading, String(value.dropFirst(3)))
            } else if value.hasPrefix("# ") {
                finishParagraph()
                append(.title, String(value.dropFirst(2)))
            } else {
                paragraph.append(value)
            }
        }
        finishParagraph()
        return result
    }

    private struct Block: Identifiable {
        enum Kind { case title, heading, paragraph }
        let id: Int
        let kind: Kind
        let text: String
    }
}
