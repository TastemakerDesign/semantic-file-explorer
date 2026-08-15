import Foundation

// Converts a range of seconds (70, 80) to a string "1:10 - 1:20".
enum TimeRangeLabel {
    static func formatted(_ range: ClosedRange<Double>) -> String {
        let start = timecode(range.lowerBound)
        guard range.upperBound - range.lowerBound >= 0.5 else {
            return start
        }
        return "\(start) – \(timecode(range.upperBound))"
    }

    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        guard minutes >= 60 else {
            return String(format: "%d:%02d", minutes, remainder)
        }
        return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, remainder)
    }
}
