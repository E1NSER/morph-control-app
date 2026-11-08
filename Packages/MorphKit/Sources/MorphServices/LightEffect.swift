import Foundation

public struct LightEffectFrame: Equatable, Sendable {
    public let brightness: Int
    public let kelvin: Int

    public init(brightness: Int, kelvin: Int) {
        self.brightness = brightness
        self.kelvin = kelvin
    }
}

/// A pure lighting curve. The controller supplies elapsed monotonic time and
/// owns scheduling, so delayed frames do not accumulate timing drift.
public enum LightEffect: String, CaseIterable, Identifiable, Sendable {
    case morph, party

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .morph: return "Morph"
        case .party: return "Party"
        }
    }

    public var period: TimeInterval {
        switch self {
        case .morph: return 30
        case .party: return 6
        }
    }

    /// Brightness follows a sine wave; temperature leads it by one quarter
    /// cycle. Output is quantized to 1 percent and 100 kelvin.
    public func frame(at elapsed: TimeInterval) -> LightEffectFrame {
        let remainder = elapsed.isFinite ? elapsed.truncatingRemainder(dividingBy: period) : 0
        let wrapped = remainder < 0 ? remainder + period : remainder
        let angle = wrapped / period * (2 * Double.pi)
        let brightnessRange: ClosedRange<Int>
        switch self {
        case .morph: brightnessRange = 25...70
        case .party: brightnessRange = 35...85
        }
        let midpoint = Double(brightnessRange.lowerBound + brightnessRange.upperBound) / 2
        let amplitude = Double(brightnessRange.upperBound - brightnessRange.lowerBound) / 2
        let brightness = Int((midpoint + amplitude * sin(angle)).rounded())
        let kelvin = Int(((4600 + 1900 * cos(angle)) / 100).rounded()) * 100
        return LightEffectFrame(
            brightness: min(brightnessRange.upperBound, max(brightnessRange.lowerBound, brightness)),
            kelvin: min(6500, max(2700, kelvin)))
    }
}
