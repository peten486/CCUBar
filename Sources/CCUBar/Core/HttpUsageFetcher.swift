import Foundation

/// Fetches usage from a local `claude_usage_scraper`-compatible Flask API.
/// The endpoint URL is built from the port configured in Settings.
struct HttpUsageFetcher: UsageFetching {
    let endpoint: URL
    let session: URLSession
    let timeout: TimeInterval

    init(endpoint: URL,
         session: URLSession = .shared,
         timeout: TimeInterval = 3.0) {
        self.endpoint = endpoint
        self.session = session
        self.timeout = timeout
    }

    func fetch() async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw FetchError.timeout
        } catch {
            throw FetchError.claudeNotFound
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.processFailed(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.processFailed(Int32(http.statusCode))
        }

        do {
            return try Self.parseResponse(data: data, now: Date())
        } catch let err as FetchError {
            throw err
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw FetchError.parseFailure(raw)
        }
    }

    static func parseResponse(data: Data, now: Date) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.parseFailure(String(data: data, encoding: .utf8) ?? "")
        }
        guard let session = parseMetric(root["five_hour"]) else {
            throw FetchError.parseFailure(String(data: data, encoding: .utf8) ?? "")
        }
        let weekly = parseMetric(root["seven_day"])
        let sonnetWeekly = parseMetric(root["seven_day_sonnet"])

        let pretty = (try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )).flatMap { String(data: $0, encoding: .utf8) } ?? ""

        return UsageSnapshot(
            session: session,
            weekly: weekly,
            sonnetWeekly: sonnetWeekly,
            fetchedAt: now,
            rawOutput: pretty
        )
    }

    private static func parseMetric(_ raw: Any?) -> UsageMetric? {
        guard let block = raw as? [String: Any],
              let utilization = doubleValue(block["utilization"]) else {
            return nil
        }
        let resetAt = (block["resets_at"] as? String).flatMap(Self.parseISO)
        let remaining: Int? = {
            if let v = block["remaining_minutes"] as? Int { return v }
            if let v = block["remaining_minutes"] as? Double { return Int(v) }
            return nil
        }()
        return UsageMetric(percent: utilization, resetAt: resetAt, remainingMinutes: remaining)
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? NSNumber { return v.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO(_ string: String) -> Date? {
        if let d = iso8601Fractional.date(from: string) { return d }
        if let d = iso8601Plain.date(from: string) { return d }
        return nil
    }
}
