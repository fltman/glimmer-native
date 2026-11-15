import Foundation

/// Fuzzy matching for the ⌘K palette and the omnibar.
public enum FuzzyMatch {
    /// Score of `query` against `text` (higher is better), nil when the query's
    /// characters don't appear in order. Rewards prefixes, word starts and runs.
    public static func score(_ query: String, _ text: String) -> Double? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        guard q.count <= t.count else { return nil }
        var score = 0.0
        var ti = 0
        var previousMatch = -2
        var firstMatch = -1
        for qc in q {
            var found = false
            while ti < t.count {
                if t[ti] == qc {
                    found = true
                    if firstMatch < 0 { firstMatch = ti }
                    let atWordStart = ti == 0 || !(t[ti - 1].isLetter || t[ti - 1].isNumber)
                    score += 1
                    if atWordStart { score += 2 }
                    if ti == previousMatch + 1 { score += 1.5 }
                    previousMatch = ti
                    ti += 1
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }
        if firstMatch == 0 { score += 3 }
        // Prefer shorter candidates for the same matches.
        score -= Double(t.count) * 0.02
        if t.starts(with: q) { score += 4 }
        // A contiguous run ("blur" in "Gaussian Blur") beats scattered word initials.
        let lowered = String(t), needle = String(q)
        if let r = lowered.range(of: needle) {
            score += 4 + Double(q.count)
            if r.lowerBound == lowered.startIndex || !(lowered[lowered.index(before: r.lowerBound)].isLetter) { score += 3 }
        }
        return score
    }
}

/// Something the palette can run.
public struct PaletteItem: Identifiable, Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case command(CommandID)
        case tool(String)
        case preset(String)
        /// A saved assistant plan, by id.
        case savedAction(String)
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let keywords: [String]
    public let action: Action

    public init(id: String, title: String, subtitle: String, keywords: [String] = [], action: Action) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.action = action
    }
}

/// How often and how recently a palette item was used.
public struct CommandUsage: Codable, Sendable, Equatable {
    public var count: Int
    public var last: Date

    public init(count: Int = 0, last: Date = .distantPast) {
        self.count = count
        self.last = last
    }

    /// Ranking bonus: grows with use (logarithmically) and halves every two
    /// weeks without use, so it breaks ties without burying better matches.
    public func boost(now: Date) -> Double {
        guard count > 0 else { return 0 }
        let days = max(0, now.timeIntervalSince(last) / 86_400)
        return min(3, 1.2 * log2(1 + Double(count))) * pow(0.5, days / 14)
    }

    /// Records one use in a usage table, dropping the stalest entries past `limit`.
    public static func record(_ id: String, in table: inout [String: CommandUsage], now: Date = Date(), limit: Int = 200) {
        var u = table[id] ?? CommandUsage()
        u.count += 1
        u.last = now
        table[id] = u
        if table.count > limit {
            for key in table.sorted(by: { $0.value.boost(now: now) < $1.value.boost(now: now) }).prefix(table.count - limit).map(\.key) {
                table[key] = nil
            }
        }
    }
}

public enum CommandSearch {
    /// Ranked matches: the title counts most, then the group, then keywords.
    /// `usage` lifts the things you use often (see `CommandUsage.boost`).
    public static func search(_ query: String, in items: [PaletteItem], limit: Int = 12,
                              usage: [String: CommandUsage] = [:], now: Date = Date()) -> [(item: PaletteItem, score: Double)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items.prefix(limit).map { ($0, 0) } }
        var results: [(PaletteItem, Double)] = []
        for item in items {
            var best = FuzzyMatch.score(trimmed, item.title).map { $0 * 1.0 }
            if let s = FuzzyMatch.score(trimmed, "\(item.subtitle) \(item.title)") { best = max(best ?? -.infinity, s * 0.8) }
            for k in item.keywords {
                if let s = FuzzyMatch.score(trimmed, k) { best = max(best ?? -.infinity, s * 0.7) }
            }
            if let best { results.append((item, best + (usage[item.id]?.boost(now: now) ?? 0))) }
        }
        return Array(results.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    /// Whether the text reads as a request for the assistant rather than a
    /// command lookup: several words, or no convincing command match.
    /// Options worth showing a language model for a free-text request: matches
    /// for the whole text and for each word in it, best first.
    public static func candidates(for request: String, in items: [PaletteItem], limit: Int = 15) -> [PaletteItem] {
        let words = request.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
        var best: [String: (item: PaletteItem, score: Double)] = [:]
        for query in [request] + words {
            for (item, score) in search(query, in: items, limit: 8) {
                // Normalise by query length so short words don't dominate.
                let s = score / Double(max(query.count, 1))
                if s > (best[item.id]?.score ?? -.infinity) { best[item.id] = (item, s) }
            }
        }
        return best.values.sorted { $0.score > $1.score }.prefix(limit).map(\.item)
    }

    public static func looksLikeAssistantRequest(_ query: String, bestScore: Double?) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        if words.count >= 4 { return true }
        guard let bestScore else { return words.count >= 2 }
        let perChar = bestScore / Double(max(query.filter { !$0.isWhitespace }.count, 1))
        return words.count >= 2 && perChar < 2.2
    }
}
