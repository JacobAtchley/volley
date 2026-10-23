import Foundation

/// Typo-tolerant search for notifications: every query token must appear, in order but not necessarily
/// contiguously, in the app name, title or text. Tighter and word-start matches rank higher.
enum FuzzySearch {
    private static let consecutiveBonus = 5
    private static let wordStartBonus = 8

    /// Score of `token` as a subsequence of `field`, or nil if it isn't one. Higher is better.
    static func score(_ token: String, in field: String) -> Int? {
        let q = normalize(token), f = normalize(field)
        guard let first = q.first, !f.isEmpty else { return q.isEmpty ? 0 : nil }
        // Try each place the first character occurs and keep the best greedy alignment from there.
        var best: Int?
        for start in f.indices where f[start] == first {
            if let s = align(q, in: f, from: start), s > (best ?? .min) { best = s }
        }
        return best
    }

    /// Items matching every whitespace-separated token, best first, then newest first. Blank query → `items`.
    static func search(_ query: String, in items: [StoredNotification]) -> [StoredNotification] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return items }
        let scored: [(StoredNotification, Int)] = items.compactMap { item in
            var total = 0
            for token in tokens {
                let best = [item.appName, item.title, item.text].compactMap { score(token, in: $0) }.max()
                guard let best else { return nil }
                total += best
            }
            return (item, total)
        }
        return scored.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.postedAt > b.0.postedAt }.map(\.0)
    }

    private static func align(_ q: [Character], in f: [Character], from start: Int) -> Int? {
        var total = 0
        var fi = start
        var previous: Int?
        for c in q {
            while fi < f.count, f[fi] != c { fi += 1 }
            guard fi < f.count else { return nil }
            total += 1
            if let p = previous, p == fi - 1 { total += consecutiveBonus }
            if fi == 0 || !(f[fi - 1].isLetter || f[fi - 1].isNumber) { total += wordStartBonus }
            previous = fi
            fi += 1
        }
        return total
    }

    private static func normalize(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }
}
