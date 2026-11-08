import XCTest
@testable import MorphServices

final class LightEffectCurveTests: XCTestCase {
    func testNamesPeriodsAndStableIdentity() {
        XCTAssertEqual(LightEffect.allCases, [.morph, .party])
        XCTAssertEqual(LightEffect.morph.id, "morph")
        XCTAssertEqual(LightEffect.party.id, "party")
        XCTAssertEqual(LightEffect.morph.title, "Morph")
        XCTAssertEqual(LightEffect.party.title, "Party")
        XCTAssertEqual(LightEffect.morph.period, 30)
        XCTAssertEqual(LightEffect.party.period, 6)
    }

    func testQuarterCyclesUseQuarterPhaseOffset() {
        let brightness: [LightEffect: [Int]] = [
            .morph: [48, 70, 48, 25],
            .party: [60, 85, 60, 35]
        ]
        let kelvin = [6500, 4600, 2700, 4600]
        for effect in LightEffect.allCases {
            for quarter in 0..<4 {
                XCTAssertEqual(effect.frame(at: effect.period * Double(quarter) / 4),
                    LightEffectFrame(brightness: brightness[effect]![quarter], kelvin: kelvin[quarter]))
            }
        }
    }

    func testEighthCyclesQuantizeToWholePercentAndHundredKelvin() {
        let expected: [LightEffect: [LightEffectFrame]] = [
            .morph: [
                .init(brightness: 63, kelvin: 5900), .init(brightness: 63, kelvin: 3300),
                .init(brightness: 32, kelvin: 3300), .init(brightness: 32, kelvin: 5900)
            ],
            .party: [
                .init(brightness: 78, kelvin: 5900), .init(brightness: 78, kelvin: 3300),
                .init(brightness: 42, kelvin: 3300), .init(brightness: 42, kelvin: 5900)
            ]
        ]
        for effect in LightEffect.allCases {
            for (index, eighth) in [1, 3, 5, 7].enumerated() {
                XCTAssertEqual(effect.frame(at: effect.period * Double(eighth) / 8), expected[effect]![index])
            }
        }
    }

    func testRepeatedCyclesAndNegativeElapsedWrapToSameFrames() {
        for effect in LightEffect.allCases {
            for sample in 0..<64 {
                let elapsed = effect.period * Double(sample) / 64
                let expected = effect.frame(at: elapsed)
                for cycle in -8...8 {
                    XCTAssertEqual(effect.frame(at: elapsed + effect.period * Double(cycle)), expected)
                }
            }
        }
    }

    func testBoundsAndQuantizationThroughoutBothCurves() {
        for effect in LightEffect.allCases {
            let limits = effect == .morph ? 25...70 : 35...85
            var brightnessValues = Set<Int>()
            var temperatures = Set<Int>()
            for sample in -960...960 {
                let frame = effect.frame(at: effect.period * Double(sample) / 240)
                XCTAssertTrue(limits.contains(frame.brightness))
                XCTAssertTrue((2700...6500).contains(frame.kelvin))
                XCTAssertEqual(frame.kelvin % 100, 0)
                brightnessValues.insert(frame.brightness)
                temperatures.insert(frame.kelvin)
            }
            XCTAssertTrue(brightnessValues.contains(limits.lowerBound))
            XCTAssertTrue(brightnessValues.contains(limits.upperBound))
            XCTAssertTrue(temperatures.contains(2700))
            XCTAssertTrue(temperatures.contains(6500))
        }
    }

    func testNonFiniteElapsedHasDeterministicInitialFrame() {
        for effect in LightEffect.allCases {
            for elapsed in [Double.nan, .infinity, -.infinity] {
                XCTAssertEqual(effect.frame(at: elapsed), effect.frame(at: 0))
            }
        }
    }
}
