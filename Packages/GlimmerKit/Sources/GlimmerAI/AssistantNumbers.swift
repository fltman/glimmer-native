import Foundation

/// The Assistant never states a number that looks like it comes from Glimmer (a size, a
/// count, a zoom, a colour value, a price, a time) unless Glimmer gave it that number: in
/// the editor state it was sent, in what the person wrote, or in the plan's own steps. A
/// model can state an invented figure with full confidence, and the reader can't tell.
///
/// Sentences with a number nobody gave it are taken out of the Assistant's text, and the
/// plan records what was taken out. Prices are held hardest: a sentence about money stays
/// only if its figure was given.
public enum AssistantNumbers {
    /// The numbers written in `text` ("2 400", "2,400" and "2400" are one number; "0,5" is 0.5).
    public static func numbers(in text: String) -> [Double] {
        var found: [Double] = []
        // Digits with optional thousands groups (space, thin space, comma or dot before three digits) and a decimal part.
        let pattern = #"\d{1,3}(?:[  ,.]\d{3})+(?![\d])|\d+(?:[.,]\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            let grouped = token.range(of: #"^\d{1,3}(?:[  ,.]\d{3})+$"#, options: .regularExpression) != nil
            let plain = grouped ? token.filter(\.isNumber) : token.replacingOccurrences(of: ",", with: ".")
            if let value = Double(plain) { found.append(value) }
        }
        return found
    }

    /// Said once in an answer that lost a sentence, so it doesn't just read oddly.
    public static let notice = "Glimmer left out a figure it could not verify."

    /// `text` with `notice` after it when something was removed (once, however many sentences went).
    public static func noted(_ text: String?, removed: Bool) -> String? {
        guard removed else { return text }
        return [text, notice].compactMap { $0 }.joined(separator: " ")
    }

    /// Words of a claim about cost that carries no figure ("it is free"): nothing the model
    /// can know. The evaluation measures it as a known gap; nothing is removed for it.
    public static func claimsACost(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["free", "gratis", "no cost", "no charge", "costs nothing", "kostar inget", "kostar ingenting", "kostnadsfri", "cheap", "billig", "expensive", "dyr"]
            .contains { lower.contains($0) }
    }

    private static let money = ["$", "€", "£", "kr", "sek", "usd", "eur", "cent", "credit", "dollar", "euro", "kronor", "öre"]

    private static func sentences(_ text: String) -> [String] {
        var parts: [String] = [], current = ""
        let characters = Array(text)
        for (i, c) in characters.enumerated() {
            current.append(c)
            let next = i + 1 < characters.count ? characters[i + 1] : " "
            if c == "\n" || ((c == "." || c == "!" || c == "?") && next.isWhitespace) {
                parts.append(current); current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// `text` without the sentences that state a number not in `given`, and those numbers.
    /// `given`: every text Glimmer or the person supplied. `steps`: how many steps the plan
    /// has, so "step 2" and "3 steps" are allowed.
    /// What may be shown of an answer that is still arriving. `text` is everything received so
    /// far. Finished sentences are checked as in `checked`; the unfinished one at the end is
    /// shown as it comes only while it holds no digit and no money word, and is otherwise
    /// held back whole until it is finished and checked. A figure the check would remove is
    /// therefore never shown, not even for a moment. (A sentence that gets a digit late
    /// disappears from view until it is finished.)
    public static func shownWhileArriving(_ text: String, given: [String]) -> String {
        var parts = sentences(text)
        var pending = ""
        // The last part is finished only when white space follows it: "2400." may go on as "2400.5".
        if let last = text.last, !last.isWhitespace, !parts.isEmpty { pending = parts.removeLast() }
        var shown = parts.filter { checked($0, given: given).removed.isEmpty }.joined()
        let lower = pending.lowercased()
        if !pending.contains(where: \.isNumber), !money.contains(where: { lower.contains($0) }) { shown += pending }
        return shown
    }

    /// `pricesOnly`: for text that proposes an edit ("crop to 4:5"), whose numbers are the
    /// proposal itself; only a sentence about money with a figure goes.
    public static func checked(_ text: String, given: [String], steps: Int = 0, pricesOnly: Bool = false) -> (text: String?, removed: [String]) {
        var backed = Set(given.flatMap(numbers(in:)))
        // A share given as 0.5 may be said as 50 (percent).
        for n in backed where n > 0 && n <= 1 { backed.insert((n * 100).rounded()) }
        for n in 0...max(steps, 1) { backed.insert(Double(n)) }
        var kept: [String] = [], removed: [String] = []
        for sentence in sentences(text) {
            let stated = numbers(in: sentence)
            let unbacked = stated.filter { n in !backed.contains { abs($0 - n) <= max(0.005, abs(n) * 0.005) } }
            let lower = sentence.lowercased()
            let about = money.contains { lower.contains($0) } ? "price" : "number"
            if unbacked.isEmpty || (pricesOnly && about != "price") {
                kept.append(sentence)
            } else {
                removed.append(contentsOf: unbacked.map { "\(about) \($0 == $0.rounded() ? String(Int($0)) : String($0))" })
            }
        }
        let result = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.isEmpty ? nil : result, removed)
    }
}
