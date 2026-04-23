import Foundation

struct UsageParser {
    func parse(_ output: String, now: Date = Date()) throws -> UsageSnapshot {
        let cleaned = stripAnsi(output)
        guard let sessionPercent = firstPercent(in: cleaned, matching: sessionPatterns) else {
            throw FetchError.parseFailure(cleaned)
        }
        let weeklyPercent = firstPercent(in: cleaned, matching: weeklyPatterns)
        let resetAt = parseResetAt(in: cleaned, now: now)

        let session = UsageMetric(percent: sessionPercent, resetAt: resetAt, remainingMinutes: nil)
        let weekly = weeklyPercent.map { UsageMetric(percent: $0, resetAt: nil, remainingMinutes: nil) }

        return UsageSnapshot(
            session: session,
            weekly: weekly,
            sonnetWeekly: nil,
            fetchedAt: now,
            rawOutput: cleaned
        )
    }

    // MARK: - Patterns

    private let sessionPatterns: [String] = [
        #"(?i)(?:5[-\s]?hour|current)\s+session[^\d%]{0,40}(\d{1,3}(?:\.\d)?)\s*%"#,
        #"(?i)session[^\d%]{0,40}(\d{1,3}(?:\.\d)?)\s*%"#,
        #"(?i)5[-\s]?hour[^\d%]{0,40}(\d{1,3}(?:\.\d)?)\s*%"#
    ]

    private let weeklyPatterns: [String] = [
        #"(?i)(?:weekly|7[-\s]?day|week)[^\d%]{0,40}(\d{1,3}(?:\.\d)?)\s*%"#
    ]

    // MARK: - Helpers

    private func firstPercent(in text: String, matching patterns: [String]) -> Double? {
        for pattern in patterns {
            if let match = firstCapture(pattern: pattern, in: text),
               let value = Double(match) {
                return max(0, min(100, value))
            }
        }
        return nil
    }

    private func parseResetAt(in text: String, now: Date) -> Date? {
        if let (hours, minutes) = parseResetIn(text) {
            return now.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60))
        }
        if let clock = parseResetClock(text) {
            return nextOccurrence(of: clock, from: now)
        }
        return nil
    }

    private func parseResetIn(_ text: String) -> (Int, Int)? {
        // "resets in 2h 34m", "reset in 34m", "리셋 2시간 34분"
        let patterns = [
            #"(?i)reset[s]?\s+in\s+(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?"#,
            #"(\d+)\s*(?:시간|hours?)\s*(\d+)\s*(?:분|minutes?)"#,
            #"(\d+)\s*(?:분|minutes?)\s+(?:후|later)"#
        ]
        for pattern in patterns {
            if let groups = captureGroups(pattern: pattern, in: text) {
                let h = groups.indices.contains(0) ? Int(groups[0] ?? "") ?? 0 : 0
                let m = groups.indices.contains(1) ? Int(groups[1] ?? "") ?? 0 : 0
                if h == 0 && m == 0 { continue }
                return (h, m)
            }
        }
        return nil
    }

    private func parseResetClock(_ text: String) -> (Int, Int)? {
        let pattern = #"(?i)reset[s]?\s+at\s+(\d{1,2}):(\d{2})(?:\s*([AP]M))?"#
        guard let groups = captureGroups(pattern: pattern, in: text),
              groups.indices.contains(1),
              let hourStr = groups[0],
              let minStr = groups[1],
              var hour = Int(hourStr),
              let minute = Int(minStr)
        else { return nil }

        if groups.indices.contains(2), let meridian = groups[2]?.uppercased() {
            if meridian == "PM" && hour < 12 { hour += 12 }
            if meridian == "AM" && hour == 12 { hour = 0 }
        }
        return (hour, minute)
    }

    private func nextOccurrence(of clock: (Int, Int), from now: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = clock.0
        comps.minute = clock.1
        comps.second = 0
        guard var candidate = cal.date(from: comps) else { return nil }
        if candidate <= now {
            candidate = cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    private func captureGroups(pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        var groups: [String?] = []
        for i in 1..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append(nil)
            }
        }
        return groups
    }

    private func stripAnsi(_ input: String) -> String {
        // Remove CSI sequences: ESC[...letter
        let ansiPattern = #"\u{1B}\[[0-9;?]*[@-~]"#
        // Remove other escape sequences: ESC(letter, ESC)letter, ESC=, ESC>, OSC, etc.
        let oscPattern = #"\u{1B}\][0-9]*;[^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)"#
        let otherPattern = #"\u{1B}[()*+#=>]."#
        var s = input
        for p in [ansiPattern, oscPattern, otherPattern] {
            if let re = try? NSRegularExpression(pattern: p) {
                s = re.stringByReplacingMatches(
                    in: s,
                    range: NSRange(s.startIndex..., in: s),
                    withTemplate: ""
                )
            }
        }
        // Strip control chars except tab/newline
        let scalars = s.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D { return true }
            return v >= 0x20
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
