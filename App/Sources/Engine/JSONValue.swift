import Foundation

/// stream-json 里任意形状的 JSON。用枚举而不是 `[String: Any]`，是为了能跨 actor 传递（Sendable），
/// 也能原样再编码给网页层渲染。
enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(any: Any) {
        switch any {
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            // JSONSerialization 把 true/false 也装进 NSNumber，只能按 CFType 区分。
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(any:)))
        case let d as [String: Any]:
            self = .object(d.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    static func parse(_ data: Data) -> JSONValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(any: obj)
    }

    static func parse(_ line: String) -> JSONValue? {
        parse(Data(line.utf8))
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    subscript(key: String) -> JSONValue? { object?[key] }
    subscript(index: Int) -> JSONValue? {
        guard let a = array, a.indices.contains(index) else { return nil }
        return a[index]
    }

    func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o): return o.mapValues { $0.toAny() }
        }
    }

    func serialized(pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert([.prettyPrinted, .sortedKeys]) }
        guard let data = try? JSONSerialization.data(withJSONObject: toAny(), options: options),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    /// 对象里第一个字符串值，用于给不认识的工具挑一个能显示的摘要。
    var firstStringValue: String? {
        guard let o = object else { return nil }
        for key in o.keys.sorted() { if let s = o[key]?.string, !s.isEmpty { return s } }
        return nil
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别的 JSON 值")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
