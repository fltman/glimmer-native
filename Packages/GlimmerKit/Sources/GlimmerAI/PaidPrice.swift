import Foundation

/// What Glimmer knows about the price of a paid operation before it runs
/// (the-apps/SIBLINGS.md, "Okänt pris").
///
/// `allowPaid` does not mean "whatever it costs": a paid operation whose price is not known
/// is refused unless the call also says `allowUnknownPrice`, and in the window the person
/// ticks once per service that it states no price in advance.
///
/// The register is empty, and that is its content: no picture service Glimmer talks to states
/// the price of one picture job in a form Glimmer reads. OpenRouter's answer carries the charge
/// afterwards (`usage.cost`); the others' answers carry none. A price goes in here only with
/// its source and its date, never as an estimate.
public enum PaidPrice {
    public struct Known: Sendable, Equatable {
        public let amount: Double
        public let currency: String
        /// Where the figure was read (the service's own list or answer).
        public let source: String
        public let asOf: Date
    }

    /// The price of running `op` once on `service`, when the service has stated it. Nil: not known.
    public static func known(op: String, service: String) -> Known? { nil }

    /// Whether every paid operation on `service` has a stated price.
    public static func knownInAdvance(service: String) -> Bool { false }

    public static let reason = "unknown_price"
    public static let consentParameter = "allowUnknownPrice"
}
