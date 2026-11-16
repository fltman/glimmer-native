import Foundation

/// The Assistant never states a number that looks like it comes from Glimmer (a size, a
/// count, a zoom, a colour value, a price, a time) unless Glimmer gave it that number: in
/// the editor state it was sent, in what the person wrote, or in the plan's own steps. A
/// model can state an invented figure with full confidence, and the reader can't tell.
///
/// Sentences with a number nobody gave it are taken out of the Assistant's text, and the
/// plan records what was taken out.
///
/// The rule was written against a model that invents figures; it must not punish one that
/// does the sum (the first real model, 2026-11-16, lost "2400 × 1350" beside a crop to 16:9
/// and "1200 × 800" beside "half as large"). So a figure also counts as given when it is in a
/// closed set of results the app itself works out from the document's size before it reads
/// the answer (`worked`), or, in a sentence that names an operation or its subject, in that
/// operation's own description, which was sent with the request. The check is membership,
/// never "looks plausible". What is said about the document itself (its megapixels, its shape
/// as a ratio) is backed only by the document's facts and the worked set, each kind of figure
/// only where it is said as that kind: "a 4:3 image" for a 3:2 document goes.
///
/// A figure given in words counts as given: "one and a half" in the request backs "1.5" in
/// the answer (`numbersInWords`; Jämmer lost true sentences that way, 2026-11-16).
///
/// Free as before: 0, 1 and the numbers up to the count of the plan's steps ("2 steps", a
/// numbered list of the steps), and counting words written as words.
///
/// Held hardest, whatever the arithmetic: money, how long something takes, sizes on disk,
/// quality figures and anything about a service. A sentence about one of those keeps its
/// figure only if the request or the editor state itself gave it.
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

    private static let money = ["$", "€", "£", "kr", "sek", "usd", "eur", "cent", "cents", "credit", "dollar", "euro", "kronor", "krona", "öre", "price", "pris"]
    /// Subjects whose figures only the app's own measured or stated values may give.
    private static let held = money + ["second", "seconds", "sekund", "sekunder", "minute", "minutes", "minut", "minuter", "hour", "hours", "timme", "timmar", "ms",
                                       "kb", "mb", "gb", "byte", "bytes", "kilobyte", "megabyte", "gigabyte", "quality", "kvalitet",
                                       "openrouter", "berget", "grunden", "openai", "google", "anthropic", "hedra", "ollama"]

    /// Whether the sentence has one of the words as a word of its own ("cent" is not in "centred"; "credit" is in "credits").
    private static func has(_ sentence: String, anyOf words: [String]) -> Bool {
        let lower = sentence.lowercased()
        var tokens: Set<String> = []
        var current = ""
        for c in lower {
            if c.isLetter { current.append(c) } else {
                if !current.isEmpty { tokens.insert(current); current = "" }
                if "$€£".contains(c) { tokens.insert(String(c)) }
            }
        }
        if !current.isEmpty { tokens.insert(current) }
        return words.contains { word in tokens.contains(word) || (word.count >= 5 && tokens.contains { $0.hasPrefix(word) }) }
    }

    /// What counts as given besides the request and the editor state.
    public struct Extra: Sendable {
        /// Sizes worked out from the document's: given in any sentence that is not about a held subject.
        public var sizes: [Double] = []
        /// The document's megapixels (rounded as a person would say them): given only beside the word.
        public var megapixels: [Double] = []
        /// The document's shape in lowest terms: given only when written as that ratio ("3:2").
        public var ratio: (Int, Int)?
        /// Each operation's own figures, with the words that name it: given only in a sentence that has one of the words.
        public var operations: [(names: [String], figures: [Double])] = []
        public init() {}
        public static let none = Extra()
    }

    /// The figures the app itself works out from a document's size before it reads an answer: a
    /// closed set. Halves, doubles and four times each side; the other side for an aspect ratio
    /// the request names ("16:9", "square"); a percentage the request names, of each side; the
    /// megapixels; and the size as a ratio in lowest terms (2400 × 1600 is 3:2).
    public static func worked(width: Int, height: Int, request: String) -> Extra {
        var extra = Extra()
        guard width > 0, height > 0 else { return extra }
        let w = Double(width), h = Double(height)
        for factor in [0.5, 2.0, 4.0] { extra.sizes += [(w * factor).rounded(), (h * factor).rounded()] }
        // Aspect ratios the request names: the largest centred box of that shape, as `crop` cuts it.
        var aspects: [Double] = []
        if let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*:\s*(\d+(?:[.,]\d+)?)"#) {
            for m in regex.matches(in: request, range: NSRange(request.startIndex..., in: request)) {
                guard let a = Range(m.range(at: 1), in: request), let b = Range(m.range(at: 2), in: request),
                      let x = Double(request[a].replacingOccurrences(of: ",", with: ".")), let y = Double(request[b].replacingOccurrences(of: ",", with: ".")), x > 0, y > 0 else { continue }
                aspects.append(x / y)
            }
        }
        let lower = request.lowercased()
        if ["square", "kvadrat"].contains(where: { lower.contains($0) }) { aspects.append(1) }
        for a in aspects {
            var cw = w, ch = (w / a).rounded()
            if ch > h { ch = h; cw = (h * a).rounded() }
            extra.sizes += [cw, ch]
        }
        if let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*(?:%|percent|procent)"#) {
            for m in regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
                guard let r = Range(m.range(at: 1), in: lower), let p = Double(lower[r].replacingOccurrences(of: ",", with: ".")), p > 0 else { continue }
                extra.sizes += [(w * p / 100).rounded(), (h * p / 100).rounded()]
            }
        }
        let megapixels = w * h / 1_000_000
        extra.megapixels = [megapixels.rounded(), (megapixels * 10).rounded() / 10, (megapixels * 100).rounded() / 100]
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(width, height)
        if width / g <= 100, height / g <= 100 { extra.ratio = (width / g, height / g) }
        return extra
    }

    // MARK: Figures given in words

    private static let units: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "noll": 0, "en": 1, "ett": 1, "två": 2, "tre": 3, "fyra": 4, "fem": 5, "sex": 6, "sju": 7, "åtta": 8, "nio": 9, "tio": 10,
        "elva": 11, "tolv": 12, "tretton": 13, "fjorton": 14, "femton": 15, "sexton": 16, "sjutton": 17, "arton": 18, "aderton": 18, "nitton": 19,
    ]
    private static let tens: [String: Double] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "tjugo": 20, "trettio": 30, "fyrtio": 40, "femtio": 50, "sextio": 60, "sjuttio": 70, "åttio": 80, "nittio": 90,
    ]
    private static let hundreds: Set<String> = ["hundred", "hundra"], thousands: Set<String> = ["thousand", "tusen"]
    private static let halves: Set<String> = ["half", "halv", "halva", "halvt", "hälften", "halvera", "halve"]
    private static let quarters: Set<String> = ["quarter", "kvart", "fjärdedel"]
    private static let doubles: [String: Double] = ["double": 2, "twice": 2, "dubbel": 2, "dubbla": 2, "dubbelt": 2, "triple": 3, "tredubbla": 3, "tredubbel": 3]

    /// One number word, also a Swedish one written together ("tjugofem", "tvåhundra").
    private static func wordValue(_ token: String) -> Double? {
        if let v = units[token] ?? tens[token] { return v }
        for (ten, value) in tens where token.hasPrefix(ten) && token.count > ten.count {
            if let unit = units[String(token.dropFirst(ten.count))], unit >= 1, unit <= 9 { return value + unit }
        }
        for hundred in hundreds where token.hasSuffix(hundred) && token.count > hundred.count {
            if let unit = units[String(token.dropLast(hundred.count))], unit >= 1, unit <= 9 { return unit * 100 }
        }
        return nil
    }

    /// The figures a text gives in words, English and Swedish: "one and a half" (1.5), "minus arton" (18, as the
    /// digits are read, without a sign), "twenty-five", "tvåhundra", "half" (0.5), "a quarter" (0.25), "double" (2).
    /// Used for what was GIVEN only: a figure said in words in the request backs the same figure in digits in the
    /// answer. Words in the answer are not figures to check.
    public static func numbersInWords(in text: String) -> [Double] {
        let tokens = text.lowercased().split { !$0.isLetter }.map(String.init)
        var found: [Double] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if halves.contains(token) { found.append(0.5); i += 1; continue }
            if quarters.contains(token) { found.append(0.25); i += 1; continue }
            if let d = doubles[token] { found.append(d); i += 1; continue }
            guard var value = wordValue(token) else { i += 1; continue }
            i += 1
            // "twenty five", "two hundred (and) fifty", "three thousand".
            if value >= 20, value < 100, value.truncatingRemainder(dividingBy: 10) == 0, i < tokens.count, let unit = units[tokens[i]], unit >= 1, unit <= 9 { value += unit; i += 1 }
            if i < tokens.count, hundreds.contains(tokens[i]) {
                value *= 100; i += 1
                if i < tokens.count, ["and", "och"].contains(tokens[i]), i + 1 < tokens.count, wordValue(tokens[i + 1]) != nil { i += 1 }
                if i < tokens.count, let rest = wordValue(tokens[i]), rest < 100 {
                    value += rest; i += 1
                    if rest >= 20, rest.truncatingRemainder(dividingBy: 10) == 0, i < tokens.count, let unit = units[tokens[i]], unit >= 1, unit <= 9 { value += unit; i += 1 }
                }
            }
            if i < tokens.count, thousands.contains(tokens[i]) { value *= 1000; i += 1 }
            // "one and a half", "en och en halv", "ett och ett halvt".
            if i + 2 < tokens.count, ["and", "och"].contains(tokens[i]), ["a", "en", "ett", "one"].contains(tokens[i + 1]), halves.contains(tokens[i + 2]) { value += 0.5; i += 3 }
            found.append(value)
        }
        return found
    }

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
    public static func shownWhileArriving(_ text: String, given: [String], extra: Extra = .none) -> String {
        var parts = sentences(text)
        var pending = ""
        // The last part is finished only when white space follows it: "2400." may go on as "2400.5".
        if let last = text.last, !last.isWhitespace, !parts.isEmpty { pending = parts.removeLast() }
        var shown = parts.filter { checked($0, given: given, extra: extra).removed.isEmpty }.joined()
        let lower = pending.lowercased()
        _ = lower
        if !pending.contains(where: \.isNumber), !has(pending, anyOf: money) { shown += pending }
        return shown
    }

    /// `pricesOnly`: for text that proposes an edit ("crop to 4:5"), whose numbers are the
    /// proposal itself; only a sentence about money with a figure goes.
    /// `extra`: what counts as given besides `given`, each kind only where it belongs (see `Extra`).
    public static func checked(_ text: String, given: [String], steps: Int = 0, pricesOnly: Bool = false, extra: Extra = .none) -> (text: String?, removed: [String]) {
        // What was given in digits, and what was given in words ("one and a half seconds" backs "1.5").
        var backed = Set(given.flatMap(numbers(in:))).union(given.flatMap(numbersInWords(in:)))
        // A share given as 0.5 may be said as 50 (percent).
        for n in backed where n > 0 && n <= 1 { backed.insert((n * 100).rounded()) }
        // 0, 1 and the numbers up to the count of the plan's steps are free: "2 steps", a numbered list of the steps.
        for n in 0...max(steps, 1) { backed.insert(Double(n)) }
        var kept: [String] = [], removed: [String] = []
        for sentence in sentences(text) {
            let stated = numbers(in: sentence)
            var allowed = backed
            // A sentence about money, time, a size on disk, quality or a service keeps only what the request or the editor state gave.
            if !has(sentence, anyOf: held) {
                allowed.formUnion(extra.sizes)
                let lower = sentence.lowercased()
                if ["megapixel", "megapixlar", "megapixels"].contains(where: { lower.contains($0) }) || has(sentence, anyOf: ["mp"]) { allowed.formUnion(extra.megapixels) }
                // The document's shape counts only written as that ratio; "4:3" for a 3:2 document has neither figure given.
                if let ratio = extra.ratio, lower.range(of: #"(?<![\d.,])\#(ratio.0)\s*[:∶]\s*\#(ratio.1)(?![\d.,])"#, options: .regularExpression) != nil {
                    allowed.insert(Double(ratio.0)); allowed.insert(Double(ratio.1))
                }
                // An operation's own figures count where the sentence names the operation or its subject.
                for operation in extra.operations where operation.names.contains(where: { name in
                    name.contains(" ") || name.contains("_") ? lower.contains(name) : has(sentence, anyOf: [name])
                }) { allowed.formUnion(operation.figures) }
            }
            let unbacked = stated.filter { n in !allowed.contains { abs($0 - n) <= max(0.005, abs(n) * 0.005) } }
            // Called a price only when the sentence carries a currency or the word.
            let about = has(sentence, anyOf: money) ? "price" : "number"
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
