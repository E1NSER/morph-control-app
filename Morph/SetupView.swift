import SwiftUI
import MorphServices

struct SetupView: View {
    @EnvironmentObject private var language: LanguageSettings
    @Environment(\.morphAccent) private var accent
    @EnvironmentObject private var controller: LampController
    @EnvironmentObject private var pairing: PairingModel
    @EnvironmentObject private var windows: AppWindows
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, password, code }
    private var accountValid: Bool {
        pairing.email.contains("@") && !pairing.password.isEmpty && pairing.country.count == 2
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 23) {
            HStack {
                LampMark(size: 44)
                Spacer()
                if pairing.stage != .complete {
                    Text(AppText.format("setup.step.upper", step))
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .tracking(-0.6)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pairing.stage != .complete { progressIndicator }
            if pairing.stage == .account { demoEntry }
            Group {
                switch pairing.stage {
                case .account: accountForm
                case .code: codeForm
                case .devices: deviceList
                case .complete: completion
                }
            }
            if let message = pairing.errorMessage {
                InlineMessage(text: message)
            }
            Spacer(minLength: 4)
            footer
        }
        .padding(28)
        .frame(minHeight: 570, alignment: .topLeading)
        }
        .frame(width: 480, height: min(680, max(480, (NSScreen.main?.visibleFrame.height ?? 820) - 100)))
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .disabled(windows.isSwitchingMode)
        .onAppear { focusedField = .email }
        .onChange(of: pairing.stage) { stage in
            if stage == .code { focusedField = .code }
        }
    }

    private var demoEntry: some View {
        Button {
            Task { await windows.enterDemo() }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "play.circle")
                    .font(.system(size: 21))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppText.string("demo.entry.title"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(AppText.string("demo.entry.description"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(windows.isSwitchingMode)
        .accessibilityLabel(AppText.string("demo.entry.title"))
        .accessibilityHint(AppText.string("demo.entry.description"))
    }

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(AppText.string("Land deines Dyson-Kontos")).font(.system(size: 12, weight: .medium))
                Picker(AppText.string("Land deines Dyson-Kontos"), selection: $pairing.country) {
                    ForEach(CountryOption.all) { country in
                        Text(verbatim: country.name).tag(country.id)
                    }
                }
                .id(language.locale.identifier)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(AppText.string("E-Mail-Adresse")).font(.system(size: 12, weight: .medium))
                TextField(AppText.string("name@beispiel.at"), text: $pairing.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .focused($focusedField, equals: .email)
                    .accessibilityLabel(AppText.string("E-Mail-Adresse deines Dyson-Kontos"))
                    .onSubmit { focusedField = .password }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(AppText.string("Passwort")).font(.system(size: 12, weight: .medium))
                SecureField(AppText.string("Dyson-Passwort"), text: $pairing.password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .accessibilityLabel(AppText.string("Passwort deines Dyson-Kontos"))
                    .onSubmit { if accountValid { sendCode() } }
            }
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text(AppText.string("Die Anmeldung erfolgt direkt bei Dyson. Dein Passwort wird nicht gespeichert."))
                    .lineSpacing(3)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .disabled(pairing.isBusy)
    }

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppText.string("Bestätigungscode")).font(.system(size: 12, weight: .medium))
                TextField("000000", text: $pairing.otp)
                    .font(.system(size: 25, weight: .medium, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.oneTimeCode)
                    .focused($focusedField, equals: .code)
                    .accessibilityLabel(AppText.string("Sechsstelliger Bestätigungscode aus deiner E-Mail"))
                    .onChange(of: pairing.otp) { value in
                        let cleaned = String(value.filter(\.isNumber).prefix(6))
                        if cleaned != value { pairing.otp = cleaned }
                    }
                    .onSubmit { if pairing.otp.count == 6 { verifyCode() } }
            }
            Text(AppText.format("setup.code.sent", pairing.email))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Button(AppText.string("Anderes Konto verwenden")) { pairing.reset() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .disabled(pairing.isBusy)
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pairing.devices.isEmpty {
                InlineMessage(text: AppText.string("In diesem Konto wurde keine unterstützte Bluetooth-Lampe gefunden. Registriere deine Solarcycle Morph zuerst in MyDyson und melde dich anschließend erneut an."), symbol: "lamp.desk")
                Button(AppText.string("Erneut anmelden")) { pairing.reset() }
                    .controlSize(.large)
            } else {
                ForEach(pairing.devices) { device in
                    Button {
                        Task { await pairing.pair(device, controller: controller) }
                    } label: {
                        HStack(spacing: 12) {
                            LampMark(size: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.system(size: 13, weight: .medium))
                                Text(device.serial).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pairing.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(13)
                        .background(MorphStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(pairing.isBusy)
                    .accessibilityLabel(AppText.format("setup.device.accessibility", device.name, device.serial))
                }
            }
        }
    }

    private var completion: some View {
        MorphCard {
            VStack(alignment: .leading, spacing: 15) {
                Label(AppText.string("Schlüssel sicher gespeichert"), systemImage: "checkmark.shield")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                Text(AppText.string("Ab jetzt genügt Bluetooth. Du findest Morph Control oben in deiner Menüleiste."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                Divider()
                Text(AppText.string("Schließe MyDyson am Smartphone, bevor du dich verbindest. Die Lampe erlaubt jeweils eine aktive Steuerverbindung."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
    }

    private var footer: some View {
        HStack {
            if pairing.isBusy {
                ProgressView().controlSize(.small)
                Text(AppText.string("Einen Moment …")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if pairing.stage == .account {
                Text(AppText.string("Einmalige Einrichtung"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            switch pairing.stage {
            case .account:
                Button(AppText.string("Code anfordern"), action: sendCode)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!accountValid || pairing.isBusy)
                    .keyboardShortcut(.defaultAction)
            case .code:
                Button(AppText.string("Code bestätigen"), action: verifyCode)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(pairing.otp.count != 6 || pairing.isBusy)
                    .keyboardShortcut(.defaultAction)
            case .devices:
                if !pairing.isBusy {
                    Text(AppText.string("Wähle deine Lampe aus."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .complete:
                Button(AppText.string("Steuerung öffnen")) {
                    windows.closeSetup()
                    windows.showControls()
                    Task { await controller.connect() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var progressIndicator: some View {
        HStack(spacing: 5) {
            ForEach(1...3, id: \.self) { number in
                Capsule()
                    .fill(number <= step ? accent : Color.primary.opacity(0.07))
                    .frame(height: 3)
            }
        }
        .accessibilityLabel(AppText.format("setup.step.accessibility", step))
    }

    private var step: Int {
        switch pairing.stage { case .account: return 1; case .code: return 2; case .devices, .complete: return 3 }
    }
    private var title: String {
        switch pairing.stage {
        case .account: return AppText.string("Licht an. Ganz einfach.")
        case .code: return AppText.string("Ein kurzer Sicherheitscheck.")
        case .devices: return AppText.string("Deine Lampe wartet.")
        case .complete: return AppText.string("Alles bereit.")
        }
    }
    private var subtitle: String {
        switch pairing.stage {
        case .account: return AppText.string("Melde dich mit dem Dyson-Konto an, in dem deine Solarcycle Morph bereits über MyDyson registriert ist.")
        case .code: return AppText.string("Dyson hat dir einen sechsstelligen Code per E-Mail geschickt.")
        case .devices: return AppText.string("Wähle die Lampe aus, die du mit diesem Mac steuern möchtest.")
        case .complete: return AppText.format("setup.complete.subtitle", controller.lampName)
        }
    }

    private func sendCode() { Task { await pairing.sendCode() } }
    private func verifyCode() { Task { await pairing.verifyCode() } }
}

private struct CountryOption: Identifiable {
    let id: String
    let name: String
    static var all: [CountryOption] { Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }.map { code in
        CountryOption(id: code, name: AppLocale.locale.localizedString(forRegionCode: code) ?? code)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
