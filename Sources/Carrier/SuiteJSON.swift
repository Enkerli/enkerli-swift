//
//  SuiteJSON.swift
//  Carrier
//
//  A JSON value that remembers the order its keys arrived in.
//
//  Foundation can parse and print JSON perfectly well, and this exists for one
//  reason it cannot serve: **the suite protocol commits byte-exact SysEx frames
//  as its cross-language contract**, and those bytes contain a JSON payload
//  whose key order is whatever `JSON.stringify` produced. A dictionary throws
//  that away, so a message decoded from the wire and re-encoded would come back
//  with different bytes — and a C++ or Swift implementation could never be
//  diffed against the committed vectors.
//
//  So objects here are an *array of pairs*. Serialization preserves the order;
//  equality ignores it, because two messages differing only in key order are the
//  same message. Those two sentences are the whole design.
//
//  Numbers are `Double` with an integral check on the way out, which is exactly
//  what JavaScript does — `JSON.stringify(2741)` is `2741`, not `2741.0`. Any
//  other choice would fail the vectors on the first mask.
//

import Foundation

public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    /// Ordered, deliberately. See the file comment.
    case object([(key: String, value: JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            // Order-insensitive: the wire order is a serialization detail, not
            // part of what a message means.
            guard a.count == b.count else { return false }
            let right = Dictionary(uniqueKeysWithValues: b.map { ($0.key, $0.value) })
            for (key, value) in a {
                guard let other = right[key], other == value else { return false }
            }
            return true
        default: return false
        }
    }

    // MARK: - Reading

    public subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var isObject: Bool { if case .object = self { return true }; return false }

    /// An integer, only when the number really is one. `2.5` is not an integer
    /// and neither is a string that looks like one — the protocol's validators
    /// say "integer required" and mean it.
    public var intValue: Int? {
        guard case .number(let value) = self,
              value.rounded() == value,
              value.magnitude < 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }

    // MARK: - Writing

    public func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    public func serializedData() -> Data { Data(serialized().utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value): out += Self.format(value)
        case .string(let value): Self.writeString(value, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(pair.key, into: &out)
                out += ":"
                pair.value.write(into: &out)
            }
            out += "}"
        }
    }

    /// JavaScript's number printing: integral values lose the fraction.
    static func format(_ value: Double) -> String {
        if value.rounded() == value && value.magnitude < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    /// JSON string escaping, matching `JSON.stringify`: the seven named escapes,
    /// `\u00XX` for the other control characters, and **raw UTF-8 for everything
    /// else**. That last part is load-bearing — the vectors include `E♭`, and
    /// escaping it as `♭` would produce a different frame.
    static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        out += "\""
    }

    // MARK: - Parsing

    public static func parse(_ data: Data) -> JSONValue? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> JSONValue? {
        var scanner = Scanner(Array(text.unicodeScalars))
        guard let value = scanner.value() else { return nil }
        scanner.skipWhitespace()
        return scanner.atEnd ? value : nil
    }

    /// A small recursive-descent parser.
    ///
    /// Hand-written rather than `JSONSerialization` because that returns a
    /// dictionary, and a dictionary has already lost the thing this type exists
    /// to keep. It is also the only way to be sure what a malformed frame does:
    /// every failure here is `nil`, never a throw and never a partial value.
    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }
        private var current: Unicode.Scalar? { atEnd ? nil : scalars[index] }

        mutating func skipWhitespace() {
            while let scalar = current,
                  scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                index += 1
            }
        }

        mutating func literal(_ text: String) -> Bool {
            let wanted = Array(text.unicodeScalars)
            guard index + wanted.count <= scalars.count else { return false }
            for (offset, scalar) in wanted.enumerated() where scalars[index + offset] != scalar {
                return false
            }
            index += wanted.count
            return true
        }

        mutating func value() -> JSONValue? {
            skipWhitespace()
            guard let scalar = current else { return nil }
            switch scalar {
            case "{": return object()
            case "[": return array()
            case "\"": return string().map(JSONValue.string)
            case "t": return literal("true") ? .bool(true) : nil
            case "f": return literal("false") ? .bool(false) : nil
            case "n": return literal("null") ? .null : nil
            default: return number()
            }
        }

        mutating func object() -> JSONValue? {
            index += 1                       // {
            var pairs: [(key: String, value: JSONValue)] = []
            skipWhitespace()
            if current == "}" { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard let key = string() else { return nil }
                skipWhitespace()
                guard current == ":" else { return nil }
                index += 1
                guard let value = value() else { return nil }
                pairs.append((key, value))
                skipWhitespace()
                if current == "," { index += 1; continue }
                if current == "}" { index += 1; return .object(pairs) }
                return nil
            }
        }

        mutating func array() -> JSONValue? {
            index += 1                       // [
            var items: [JSONValue] = []
            skipWhitespace()
            if current == "]" { index += 1; return .array(items) }
            while true {
                guard let item = value() else { return nil }
                items.append(item)
                skipWhitespace()
                if current == "," { index += 1; continue }
                if current == "]" { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func string() -> String? {
            guard current == "\"" else { return nil }
            index += 1
            var out = String.UnicodeScalarView()
            while let scalar = current {
                index += 1
                if scalar == "\"" { return String(out) }
                if scalar != "\\" { out.append(scalar); continue }
                guard let escape = current else { return nil }
                index += 1
                switch escape {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    guard let first = hex4() else { return nil }
                    // A surrogate pair is two escapes and one scalar. Getting
                    // this wrong turns an emoji into two replacement characters,
                    // silently.
                    if first >= 0xD800 && first <= 0xDBFF {
                        guard current == "\\" else { return nil }
                        index += 1
                        guard current == "u" else { return nil }
                        index += 1
                        guard let second = hex4(),
                              second >= 0xDC00, second <= 0xDFFF else { return nil }
                        let combined = 0x10000
                            + ((first - 0xD800) << 10)
                            + (second - 0xDC00)
                        guard let scalar = Unicode.Scalar(UInt32(combined)) else { return nil }
                        out.append(scalar)
                    } else {
                        guard let scalar = Unicode.Scalar(UInt32(first)) else { return nil }
                        out.append(scalar)
                    }
                default: return nil
                }
            }
            return nil
        }

        mutating func hex4() -> Int? {
            var value = 0
            for _ in 0..<4 {
                guard let scalar = current,
                      let digit = Character(scalar).hexDigitValue else { return nil }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        mutating func number() -> JSONValue? {
            let start = index
            if current == "-" { index += 1 }
            while let scalar = current,
                  (scalar >= "0" && scalar <= "9") || scalar == "." || scalar == "e"
                    || scalar == "E" || scalar == "+" || scalar == "-" {
                index += 1
            }
            guard start < index,
                  let value = Double(String(String.UnicodeScalarView(scalars[start..<index]))) else {
                return nil
            }
            return .number(value)
        }
    }
}
