import Foundation

/// Merges notifications into the app's live state without polling the lamp.
extension LampState {
    /// A fresh full-mode read is authoritative even when it reports unknown.
    mutating func applyLightingModeSnapshot(_ snapshot: LampState) -> Bool {
        let before = self
        daylight = snapshot.daylight
        preset = snapshot.preset
        return self != before
    }

    /// - Returns: true when the value changed the state.
    mutating func apply(characteristic uuid: String, value: Data) -> Bool {
        let before = self
        switch uuid {
        case CharUUID.power:
            if let byte = value.first { power = byte != 0 }
        case CharUUID.brightnessLm:
            if let word = readLE16(value) {
                lumens = word
                brightness = lumensToPercent(word)
            }
        case CharUUID.colorTemp:
            if let word = readLE16(value) { kelvin = word }
        case CharUUID.autoBrightness:
            if let byte = value.first { autoBrightness = byte != 0 }
        case CharUUID.movement:
            if let byte = value.first { movement = byte != 0 }
        default:
            break
        }
        return self != before
    }

    /// - Returns: true when the value changed the state.
    mutating func apply(attribute: UInt16, value: Data) -> Bool {
        guard let byte = value.first else { return false }
        let before = self
        if attribute == Attribute.daylight {
            daylight = byte != 0
        } else if let named = Preset.allCases.first(where: { $0.attribute == attribute }) {
            // The lamp reports the old preset as off when a new one starts, in any sequence.
            if byte != 0 {
                preset = named
            } else if preset == named {
                preset = nil
            }
        }
        return self != before
    }

    /// The characteristics that hold the state and that can notify.
    static let liveCharacteristics = [
        CharUUID.power, CharUUID.brightnessLm, CharUUID.colorTemp, CharUUID.autoBrightness, CharUUID.movement,
    ]
}
