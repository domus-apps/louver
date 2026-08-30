import CoreGraphics
import Testing

@testable import Louver

@Test func curveEndpointsAreExact() {
    #expect(VolumeCurve.gain(at: 0) == 0)
    #expect(VolumeCurve.gain(at: 1) == 1)
}

@Test func curveIsMonotonic() {
    var previous: Float = -1
    for step in 0...100 {
        let gain = VolumeCurve.gain(at: Double(step) / 100)
        #expect(gain >= previous)
        previous = gain
    }
}

@Test func curveIsCubicNotLinear() {
    /* Half slider ≈ an eighth of the gain — the perceptual taper. */
    #expect(abs(VolumeCurve.gain(at: 0.5) - 0.125) < 0.0001)
}

@Test func curveClampsOutOfRangeInput() {
    #expect(VolumeCurve.gain(at: -0.5) == 0)
    #expect(VolumeCurve.gain(at: 1.5) == 1)
}

@Test func passthroughDetection() {
    #expect(AppVolumeSetting(position: 1, muted: false).isPassthrough)
    #expect(!AppVolumeSetting(position: 0.99, muted: false).isPassthrough)
    #expect(!AppVolumeSetting(position: 1, muted: true).isPassthrough)
}
