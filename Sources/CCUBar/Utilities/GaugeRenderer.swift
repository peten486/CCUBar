import Foundation

enum GaugeTier {
    case normal
    case warning
    case critical
}

enum GaugeRenderer {
    static let filled: Character = "█"
    static let empty: Character = "░"
    static let loading: Character = "·"

    static func tier(for percent: Double) -> GaugeTier {
        let p = clamp(percent)
        if p >= 85 { return .critical }
        if p >= 60 { return .warning }
        return .normal
    }

    static func render(percent: Double, width: Int = 10) -> String {
        let p = clamp(percent)
        let filledCount = Int((p / 100.0 * Double(width)).rounded())
        let emptyCount = max(0, width - filledCount)
        let bar = String(repeating: String(filled), count: filledCount)
            + String(repeating: String(empty), count: emptyCount)
        let label = percentLabel(p)
        return "[\(bar)] \(label)"
    }

    static func renderLoading(width: Int = 10) -> String {
        let bar = String(repeating: String(loading), count: width)
        return "[\(bar)] ---%"
    }

    static func percentLabel(_ percent: Double) -> String {
        let p = clamp(percent).rounded()
        return "\(Int(p))%"
    }

    private static func clamp(_ percent: Double) -> Double {
        return min(100, max(0, percent))
    }
}
