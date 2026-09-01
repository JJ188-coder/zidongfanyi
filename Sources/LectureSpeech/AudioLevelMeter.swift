import Foundation

public struct AudioLevel: Codable, Hashable, Sendable {
    public let rmsDecibels: Double
    public let peakDecibels: Double
    public let normalized: Double

    public init(rmsDecibels: Double, peakDecibels: Double, normalized: Double) {
        self.rmsDecibels = rmsDecibels
        self.peakDecibels = peakDecibels
        self.normalized = normalized
    }
}

public enum AudioLevelMeter {
    public static let floorDecibels = -96.0
    public static let visibleFloorDecibels = -60.0
    public static let visibleCeilingDecibels = -12.0

    public static func measure(samples: [Float]) -> AudioLevel {
        guard !samples.isEmpty else {
            return AudioLevel(rmsDecibels: floorDecibels, peakDecibels: floorDecibels, normalized: 0)
        }

        var sumOfSquares = 0.0
        var peak = 0.0
        for sample in samples {
            let magnitude = abs(Double(sample))
            sumOfSquares += magnitude * magnitude
            peak = max(peak, magnitude)
        }

        let rms = sqrt(sumOfSquares / Double(samples.count))
        let rmsDecibels = decibels(forAmplitude: rms)
        let peakDecibels = decibels(forAmplitude: peak)
        // Classroom speech normally sits between roughly -45 dBFS and -15 dBFS.
        // Mapping the full digital range (-96...0) made ordinary speech and room
        // noise look almost identical in the UI. A little peak contribution keeps
        // consonants visible without making a single click pin the meter at 100%.
        let displayDecibels = max(rmsDecibels, peakDecibels - 12)
        let normalized = normalizeForDisplay(displayDecibels)
        return AudioLevel(rmsDecibels: rmsDecibels, peakDecibels: peakDecibels, normalized: normalized)
    }

    public static func measure(interleavedSamples: UnsafeBufferPointer<Float>) -> AudioLevel {
        measure(samples: Array(interleavedSamples))
    }

    private static func decibels(forAmplitude amplitude: Double) -> Double {
        guard amplitude > 0 else { return floorDecibels }
        return max(floorDecibels, 20 * log10(amplitude))
    }

    private static func normalizeForDisplay(_ decibels: Double) -> Double {
        let linear = (decibels - visibleFloorDecibels)
            / (visibleCeilingDecibels - visibleFloorDecibels)
        return max(0, min(1, linear))
    }
}
