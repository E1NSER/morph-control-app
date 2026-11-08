# Privacy notice for Morph Control

Preliminary notice for the local version, as of October 30, 2026.

Morph Control is an independent macOS app for controlling a Dyson Solarcycle Morph. There is no Morph Control server, no advertising, and no built-in analytics SDKs.

## Responsible entity

Sacha Eisner / E1NSER, Arnsteingasse 26/36, 1150 Vienna, Austria.

Contact: support@einser.at.

## Setup through Dyson

To retrieve the lamp key, Morph Control sends the selected country, your email address, password, and the one-time code received by email over HTTPS directly to Dyson's account interface. Dyson receives this data and processes it under its own privacy terms. Setup uses the undocumented interface of the MyDyson app.

The password, one-time code, and temporary sign-in tokens are needed only for this setup process and are not saved as account credentials. The app does not require an additional Morph Control account.

## Local control and storage

After setup, Morph Control communicates directly with the lamp over Bluetooth. This requires your macOS Bluetooth permission. The lamp key is stored in the macOS Keychain. Device association and app settings are kept locally. Normal lighting control requires neither a Morph Control server nor an internet connection.

Display mode, accent color, a custom color code, and the connection settings `connection.keepAlive` and `connection.syncPowerWithMac` are stored exclusively in the local app preferences (the app's UserDefaults). These preferences are not sent to Dyson or any other service. Reset in Appearance restores the default display choices; the connection setting is changed separately using its own option.

The selected app language (System, Deutsch, or English) is also stored only locally under `morph.language`. Changing language does not change your saved pairing or your Dyson account.

Keep connected is enabled by default. At startup, the app makes one Bluetooth connection attempt to the saved lamp and keeps the connection open when the control panel is closed. When this option is disabled, an unused connection is released after 60 seconds while all control views are closed. Manually releasing the connection pauses automatic connection until you explicitly connect, enable the option again, or restart the app. The pause is kept only in memory for the current app session. The connection is closed when the Mac sleeps. On wake or an unexpected disconnect, at most two attempts are made per recovery phase when a connection is needed and no manual pause is set. A remembered device identifier is kept only in memory during the app process to help find the lamp. On screen return or renewed interaction, an older unconfirmed session may be checked using a local status request. This connection management requires no additional cloud service and does not retry errors indefinitely.

The local Switch light with Mac option (`connection.syncPowerWithMac`) is disabled by default. When enabled, it uses app startup and wake to connect once and turn the light on, even when Keep connected is disabled. Before sleep or system shutdown, the app tries to turn the lamp off only through an already active connection; it does not reconnect for this action. A manual connection pause prevents this automation. Quitting the app normally disconnects without turning the light off. The option does not enable a login item or create another account association; Launch at login must be chosen separately and voluntarily to start the app after login. macOS may interrupt a turn-off command during sleep or shutdown.

Forget lamp removes the saved device association and its key. Bluetooth permission can be withdrawn in System Settings → Privacy & Security → Bluetooth. A voluntarily enabled launch at login can be disabled under General → Login Items.

## Development status

Setup and basic control have been checked with a real Solarcycle Morph. Additional devices and operating system versions, as well as the final distribution package, must be checked before publication. The public privacy URL is still pending; this local resource is not yet a published Store privacy policy.

Support: support@einser.at.

Morph Control is not affiliated with Dyson and is not supported by Dyson.
