import Foundation

enum IslandMotionStyle: String, CaseIterable, Sendable {
    case subtle, balanced, jelly
    var title: String {
        switch self {
        case .subtle: return "轻柔"
        case .balanced: return "自然"
        case .jelly: return "果冻"
        }
    }
    var amplitude: Double {
        switch self {
        case .subtle: return 0.45
        case .balanced: return 0.75
        case .jelly: return 1
        }
    }
}

/// One deliberate material accent after a monotonic opening. The notch edge
/// stays fixed: a small compression trades height for width, then makes one
/// lighter rebound. Every join has zero velocity, and the geometry rests
/// before the edge light fades. Sampling is independent of display refresh.
struct IslandCompletionMotion: Equatable, Sendable {
    static let duration: Double = 1.90
    static let openingDuration: Double = 0.42
    static let accentStart: Double = 0.55
    static let compressionPeak: Double = 0.70
    static let reboundPeak: Double = 0.94
    static let accentEnd: Double = 1.16
    static let glowHoldEnd: Double = 1.10

    let heightOffset: Double
    let widthOffset: Double
    let glow: Double
    let iconLift: Double
    let iconSquash: Double
    let reveal: Double
    let openingProgress: Double

    private static func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }

    private static func interpolate(at time: Double, from start: Double, to end: Double,
                                    startValue: Double, endValue: Double) -> Double {
        startValue + (endValue - startValue) * ease((time - start) / (end - start))
    }

    static func sample(at time: Double, style: IslandMotionStyle = .jelly,
                       reduceMotion: Bool = false) -> Self {
        guard !reduceMotion, time >= 0, time < duration else {
            return .init(heightOffset: 0, widthOffset: 0, glow: 0,
                         iconLift: 0, iconSquash: 0, reveal: 1, openingProgress: 1)
        }

        let accent: Double
        if time < accentStart || time >= accentEnd {
            accent = 0
        } else if time < compressionPeak {
            accent = interpolate(at: time, from: accentStart, to: compressionPeak,
                                 startValue: 0, endValue: 1)
        } else if time < reboundPeak {
            accent = interpolate(at: time, from: compressionPeak, to: reboundPeak,
                                 startValue: 1, endValue: -0.35)
        } else {
            accent = interpolate(at: time, from: reboundPeak, to: accentEnd,
                                 startValue: -0.35, endValue: 0)
        }
        let material = accent * style.amplitude
        let glow = time <= glowHoldEnd
            ? ease(time / openingDuration)
            : 1 - ease((time - glowHoldEnd) / (duration - glowHoldEnd))
        // Squaring the positive phase gives one lift with a smooth landing,
        // even where the geometry crosses into its small return rebound.
        let lift = max(0, accent)
        return .init(heightOffset: -3.5 * material, widthOffset: 4 * material,
                     glow: glow, iconLift: -5 * lift * lift * style.amplitude,
                     iconSquash: material * 0.055,
                     reveal: ease((time - 0.44) / 0.10),
                     openingProgress: ease(time / openingDuration))
    }
}
