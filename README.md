# Morph Control

Morph Control is a free macOS menu bar app for the Dyson Solarcycle Morph desk lamp. It runs on Apple silicon Macs with macOS 13 or later. Control power, brightness, white light temperature, presets, and automatic lighting. The app also offers an optional link between your lamp and your Mac's sleep and wake cycle.

The source version is **0.2.9 (build 14)**. GitHub Releases lists published direct downloads and their checksums. Each release identifies the version and build of its downloadable app. See the [download page](https://morph-control.einser.at/en/#download) for current availability.

## Using the app

Register your lamp in MyDyson before setup. Morph Control uses your Dyson account directly during setup and stores the lamp's pairing information in the macOS Keychain. After setup, everyday control works offline over Bluetooth. The app includes its own Bluetooth and protocol implementation. Its interface is available in English and German.

Choose **Try without a lamp** during setup to explore the demo. It simulates the controls locally and requires no account or Bluetooth device. Morph Control is an independent project by Sacha Eisner / E1NSER, with no affiliation or endorsement from Dyson. See the [privacy notice](Morph/Resources/PRIVACY.en.md) for the setup and local storage details.

## Build and verify from source

Use a full Xcode installation with a Swift 6 toolchain on an Apple silicon Mac. Run these commands in a fresh checkout:

```sh
MORPH_CONFIGURATION=Debug ./scripts/build.sh
swift test --package-path Packages/MorphKit
./scripts/test-demo-preferences.sh
```

The Debug build uses local ad hoc signing and a separate preview bundle identifier. It requires no Apple Developer credentials. Open the isolated setup preview to try the demo:

```sh
open -n work/DerivedData/Build/Products/Debug/MorphControl.app --args --preview-setup
```

Maintainers can use [`scripts/direct-release.sh`](scripts/direct-release.sh) to stage a Developer ID build, notarize it using an existing Apple credential profile, and verify the final ZIP and checksum.

## License and artwork

The source is available under the [MIT License](LICENSE). The app includes notices for [Solarmorph](Morph/Resources/Solarmorph-LICENSE.txt) and [other third-party work](Morph/Resources/THIRD_PARTY_NOTICES.md). Permissions for Dyson's services, trademarks and third-party media are separate from the code license. This source distribution includes the app icon used by Xcode. The CAD model, website renders, manufacturer photographs and App Store badges remain separate materials.

Questions and support are welcome at [support@einser.at](mailto:support@einser.at).
