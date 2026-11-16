#if GLIMMER_PSD   // Config/Features.xcconfig
import Foundation

/// The "descriptor" structure Photoshop files use for settings (fill colours, text, smart
/// objects), read as the specification lays it out in its Actions section. Untrusted like
/// the rest of the file: depth, item counts and every length are bounded.
struct PSDItem: Equatable {
    let key: String
    let value: PSDValue
}

indirect enum PSDValue: Equatable {
    case object(classID: String, items: [PSDItem])
    case list([PSDValue])
    case double(Double)
    case unitFloat(unit: String, value: Double)
    case string(String)
    case enumerated(type: String, value: String)
    case integer(Int)
    case boolean(Bool)
    case raw(Data)
    case other(String)   // a type that is skipped whole: reference, class, alias

    var items: [PSDItem] { if case .object(_, let items) = self { items } else { [] } }
    subscript(key: String) -> PSDValue? { items.first { $0.key == key }?.value }
    var number: Double? {
        switch self {
        case .double(let d): d
        case .unitFloat(_, let d): d
        case .integer(let i): Double(i)
        default: nil
        }
    }

    /// Every value in the tree, this one first, depth first.
    var all: [PSDValue] {
        switch self {
        case .object(_, let items): [self] + items.flatMap { $0.value.all }
        case .list(let values): [self] + values.flatMap(\.all)
        default: [self]
        }
    }
}

enum PSDDescriptor {
    static let maxDepth = 24
    static let maxItems = 20_000

    /// A descriptor at the cursor: the name, the class and its items.
    static func read(_ r: inout PSDBytes, depth: Int = 0, budget: inout Int) throws -> PSDValue {
        guard depth <= maxDepth else { throw PSDFile.Problem("This Photoshop file nests its settings deeper than Glimmer reads.") }
        _ = try unicode(&r)
        let classID = try id(&r)
        let count = Int(try r.u32())
        guard count <= budget else { throw PSDFile.Problem("This Photoshop file's settings are damaged.") }
        budget -= count
        var items: [PSDItem] = []
        for _ in 0..<count {
            let key = try id(&r)
            items.append(PSDItem(key: key, value: try value(&r, type: try r.ascii(4), depth: depth + 1, budget: &budget)))
        }
        return .object(classID: classID, items: items)
    }

    static func read(_ data: Data) throws -> PSDValue {
        var r = PSDBytes(data)
        var budget = maxItems
        return try read(&r, budget: &budget)
    }

    /// "4 bytes (length), followed either by string or (if length is zero) 4-byte ID".
    static func id(_ r: inout PSDBytes) throws -> String {
        let length = Int(try r.u32())
        return try r.ascii(length == 0 ? 4 : length)
    }

    /// A count of UTF-16 code units, then the units. A trailing null, when the count includes one, is dropped.
    static func unicode(_ r: inout PSDBytes) throws -> String {
        let count = Int(try r.u32())
        guard count <= r.remaining / 2 else { throw PSDFile.Problem("This Photoshop file is cut short or damaged.") }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try r.u16()) }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    static func double(_ r: inout PSDBytes) throws -> Double {
        let bits = UInt64(try r.u32()) << 32 | UInt64(try r.u32())
        return Double(bitPattern: bits)
    }

    private static func value(_ r: inout PSDBytes, type: String, depth: Int, budget: inout Int) throws -> PSDValue {
        switch type {
        case "Objc", "GlbO":
            return try read(&r, depth: depth, budget: &budget)
        case "VlLs":
            let count = Int(try r.u32())
            guard count <= budget, depth < maxDepth else { throw PSDFile.Problem("This Photoshop file's settings are damaged.") }
            budget -= count
            var values: [PSDValue] = []
            for _ in 0..<count { values.append(try value(&r, type: try r.ascii(4), depth: depth + 1, budget: &budget)) }
            return .list(values)
        case "doub":
            return .double(try double(&r))
        case "UntF":
            let unit = try r.ascii(4)
            return .unitFloat(unit: unit, value: try double(&r))
        case "TEXT":
            return .string(try unicode(&r))
        case "enum":
            let type = try id(&r)
            return .enumerated(type: type, value: try id(&r))
        case "long":
            return .integer(Int(try r.i32()))
        case "comp":
            let high = try r.u32(), low = try r.u32()
            return .integer(Int(truncatingIfNeeded: Int64(bitPattern: UInt64(high) << 32 | UInt64(low))))
        case "bool":
            return .boolean(try r.u8() != 0)
        case "tdta":
            return .raw(try r.slice(Int(try r.u32())).rest)
        case "type", "GlbC":
            _ = try unicode(&r); _ = try id(&r)
            return .other(type)
        case "alis":
            try r.skip(Int(try r.u32()))
            return .other(type)
        case "obj ":
            // A reference: its items are read only to get past them.
            let count = Int(try r.u32())
            guard count <= budget else { throw PSDFile.Problem("This Photoshop file's settings are damaged.") }
            budget -= count
            for _ in 0..<count {
                switch try r.ascii(4) {
                case "prop": _ = try unicode(&r); _ = try id(&r); _ = try id(&r)
                case "Clss": _ = try unicode(&r); _ = try id(&r)
                case "Enmr": _ = try unicode(&r); _ = try id(&r); _ = try id(&r); _ = try id(&r)
                case "rele": _ = try unicode(&r); _ = try id(&r); try r.skip(4)
                default: throw PSDFile.Problem("This Photoshop file has settings in a form Glimmer doesn't read.")   // identifier, index, name: the specification gives no layout
                }
            }
            return .other(type)
        default:
            throw PSDFile.Problem("This Photoshop file has settings in a form Glimmer doesn't read.")
        }
    }
}

/// Paths as Photoshop files store them: 26-byte records, points as fixed-point shares of the
/// image's height and width (vertical first), "8 bits before the binary point and 24 bits after".
enum PSDPath {
    /// The subpaths in a vector mask's records, in document pixels.
    static func subpaths(_ data: Data, width: Int, height: Int) -> [Subpath] {
        var r = PSDBytes(data)
        var result: [Subpath] = []
        var expecting = 0
        func point(_ r: inout PSDBytes) throws -> SIMD2<Double> {
            let y = Double(try r.i32()) / 16_777_216, x = Double(try r.i32()) / 16_777_216
            return SIMD2(x * Double(width), y * Double(height))
        }
        while r.remaining >= 26, result.count < 10_000 {
            guard var record = try? r.slice(26), let selector = try? record.u16() else { break }
            switch selector {
            case 0, 3:
                expecting = Int((try? record.u16()) ?? 0)
                result.append(Subpath(anchors: [], isClosed: selector == 0))
            case 1, 2, 4, 5:
                guard expecting > 0, !result.isEmpty, let before = try? point(&record), let anchor = try? point(&record), let after = try? point(&record),
                      [before, anchor, after].allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                expecting -= 1
                result[result.count - 1].anchors.append(PathAnchor(anchor, handleIn: before, handleOut: after))
            default:
                continue   // fill rule, clipboard and initial fill records carry no points
            }
        }
        return result.filter { $0.anchors.count >= 2 }
    }
}
#endif
