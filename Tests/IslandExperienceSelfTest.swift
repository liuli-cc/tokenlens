import Foundation

@main
struct IslandExperienceSelfTest {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "IslandExperience", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func near(_ value: Double, _ expected: Double, tolerance: Double = 1e-8) -> Bool {
            abs(value - expected) < tolerance
        }

        var minimum = 0.0, maximum = 0.0
        var previous = IslandCompletionMotion.sample(at: 0)
        var motionDirections: [Int] = []
        for frame in 1...300 {
            let time = Double(frame) / 120
            let sample = IslandCompletionMotion.sample(at: time)
            try check(sample.heightOffset.isFinite && sample.widthOffset.isFinite, "Motion produced invalid geometry")
            try check(sample.heightOffset >= -3.5 && sample.heightOffset <= 1.225 + 1e-8
                      && sample.widthOffset >= -1.4 && sample.widthOffset <= 4, "Material accent exceeded its small movement bounds")
            try check((0...1).contains(sample.glow) && (0...1).contains(sample.reveal)
                      && (0...1).contains(sample.openingProgress), "Opacity or opening progress escaped valid range")
            try check(near(sample.heightOffset * 4 + sample.widthOffset * 3.5, 0), "Material compression lost its paired width/height change")
            try check(sample.openingProgress >= previous.openingProgress, "Opening reversed direction")
            try check(sample.iconLift >= -5 && sample.iconLift <= 0, "Icon retained a repeated bounce")
            if time <= IslandCompletionMotion.accentStart || time >= IslandCompletionMotion.accentEnd {
                try check(sample.heightOffset == 0 && sample.widthOffset == 0, "Geometry moved before opening or after settling")
            }
            let difference = sample.heightOffset - previous.heightOffset
            if abs(difference) > 1e-8 {
                let direction = difference < 0 ? -1 : 1
                if motionDirections.last != direction { motionDirections.append(direction) }
            }
            minimum = min(minimum, sample.heightOffset)
            maximum = max(maximum, sample.heightOffset)
            previous = sample
        }
        try check(motionDirections == [-1, 1, -1], "Completion did not have exactly one compression and one return rebound")
        try check(near(minimum, -3.5) && maximum > 1.20 && maximum <= 1.225,
                  "The intended compression/rebound amplitudes changed")

        // Probe both sides of each segment boundary: there must be no position
        // jump and the velocity must agree from both directions.
        let epsilon = 1e-7
        let joins = [IslandCompletionMotion.openingDuration, 0.44, 0.54,
                     IslandCompletionMotion.accentStart, IslandCompletionMotion.compressionPeak,
                     IslandCompletionMotion.reboundPeak, IslandCompletionMotion.accentEnd,
                     IslandCompletionMotion.glowHoldEnd, IslandCompletionMotion.duration]
        for join in joins {
            let left = IslandCompletionMotion.sample(at: join - epsilon)
            let middle = IslandCompletionMotion.sample(at: join)
            let right = IslandCompletionMotion.sample(at: join + epsilon)
            for field in [\IslandCompletionMotion.heightOffset, \.widthOffset, \.iconLift,
                          \.iconSquash, \.glow, \.reveal, \.openingProgress] {
                let leftVelocity = (middle[keyPath: field] - left[keyPath: field]) / epsilon
                let rightVelocity = (right[keyPath: field] - middle[keyPath: field]) / epsilon
                try check(abs(leftVelocity - rightVelocity) < 0.0003, "A motion join at \(join) has a velocity discontinuity")
            }
        }

        let opened = IslandCompletionMotion.sample(at: IslandCompletionMotion.openingDuration)
        try check(opened.openingProgress == 1 && opened.heightOffset == 0 && opened.widthOffset == 0,
                  "Opening failed to finish before material compression")
        try check(IslandCompletionMotion.sample(at: 0.44).reveal == 0
                  && IslandCompletionMotion.sample(at: IslandCompletionMotion.accentStart).reveal == 1,
                  "Content appeared before the opening settled")
        for time in [0.42, 0.55, 0.70, 0.94, 1.10] {
            try check(IslandCompletionMotion.sample(at: time).glow == 1, "The bright edge did not hold throughout the accent")
        }
        var lastGlow = 1.0
        for frame in 132...228 {
            let sample = IslandCompletionMotion.sample(at: Double(frame) / 120)
            try check(sample.glow <= lastGlow, "The edge light flashed again while fading")
            lastGlow = sample.glow
        }

        let resting = IslandCompletionMotion.sample(at: 2)
        try check(resting.heightOffset == 0 && resting.widthOffset == 0 && resting.glow == 0
                  && resting.reveal == 1 && resting.openingProgress == 1, "Completion animation did not stop")
        for time in [0.0, 0.3, 0.7, 0.94, 1.3, 1.8] {
            let reduced = IslandCompletionMotion.sample(at: time, reduceMotion: true)
            try check(reduced == resting, "Reduce Motion retained a bounce or flash")
            let subtle = IslandCompletionMotion.sample(at: time, style: .subtle)
            let jelly = IslandCompletionMotion.sample(at: time, style: .jelly)
            try check(near(subtle.heightOffset, jelly.heightOffset * IslandMotionStyle.subtle.amplitude),
                      "Subtle mode changed timing or amplified the movement")
        }
        print("Island experience self-tests passed: monotonic opening, one bounded rebound, continuous velocity, sustained edge glow, Reduce Motion")
    }
}
