//
//  RhythmCodecs.swift
//  Theory
//
//  Writing a rhythm down as a number, in the one order the suite uses.
//
//  **First step = leftmost = LSB.** Step k contributes 2^k, so the decimal
//  value is an ordinary integer read the ordinary way — and hex and octal
//  *digit strings* are little-endian, because the first step's nibble is the
//  leftmost digit. Tresillo is `10010010` = `0x94` = `o111` = 73.
//
//      pattern      hex   octal  decimal
//      1000         1     1      1
//      1011         D     51     13
//      10111010     D5    531    93
//      10010010     94    111    73    (E(3,8), onsets 0, 3, 6)
//
//  So `0x94` and `73` are the same pattern in two transcriptions — `0x94` read
//  low-digit-first is 9 + 4·16 = 73 — and not equal as raw numbers. The suite
//  reversed this convention once, on 2026-06-10, and reverted it twelve days
//  later; CONVENTIONS.md carries the scar. Reading the digits the other way
//  round gives `0x49`, which is a real pattern and the wrong one, which is why
//  `packages/upi/vectors/upi.json` carries both side by side.
//
//  Trailing high bits vanish in a bare numeral: `d73` is seven steps, not
//  eight, because 73 needs seven bits and nothing says the pattern had a rest
//  at the end. Every decoder here therefore takes an explicit step count, and
//  UPI's `:n` suffix is the notation for it.
//

import Foundation

/// A rhythm as a mask of onsets, and the four ways to write one down.
public enum RhythmCodec {

    // MARK: - Binary

    /// First step leftmost, which is also the order a person reads it in.
    public static func binaryString(_ pattern: [Bool]) -> String {
        pattern.map { $0 ? "1" : "0" }.joined()
    }

    public static func pattern(binary: String) -> [Bool]? {
        guard !binary.contains(where: { $0 != "0" && $0 != "1" }) else { return nil }
        return binary.map { $0 == "1" }
    }

    // MARK: - Decimal

    /// Step k contributes 2^k.
    ///
    /// `UInt64` rather than `Int` because a 64-step pattern is a perfectly
    /// ordinary thing to want and `2^63` is where an `Int` stops being able to
    /// hold one. Patterns longer than 64 steps have no numeral form here; they
    /// have a bit-string, which is the honest answer.
    public static func decimal(_ pattern: [Bool]) -> UInt64? {
        guard pattern.count <= 64 else { return nil }
        var value: UInt64 = 0
        for (i, on) in pattern.enumerated() where on { value |= (1 << UInt64(i)) }
        return value
    }

    public static func pattern(decimal value: UInt64, steps: Int) -> [Bool]? {
        guard steps >= 0, steps <= 64 else { return nil }
        guard steps == 64 || value < (UInt64(1) << UInt64(steps)) else { return nil }
        return (0..<steps).map { (value >> UInt64($0)) & 1 == 1 }
    }

    // MARK: - Hex and octal, digits little-endian

    public static func hexString(_ pattern: [Bool]) -> String? {
        guard let value = decimal(pattern) else { return nil }
        return String(String(value, radix: 16, uppercase: true).reversed())
    }

    public static func pattern(hex: String, steps: Int) -> [Bool]? {
        let cleaned = hex.hasPrefix("0x") || hex.hasPrefix("0X")
            ? String(hex.dropFirst(2)) : hex
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isHexDigit }),
              let value = UInt64(String(cleaned.reversed()), radix: 16)
        else { return nil }
        return pattern(decimal: value, steps: steps)
    }

    public static func octalString(_ pattern: [Bool]) -> String? {
        guard let value = decimal(pattern) else { return nil }
        return String(String(value, radix: 8).reversed())
    }

    public static func pattern(octal: String, steps: Int) -> [Bool]? {
        let cleaned = octal.hasPrefix("0o") || octal.hasPrefix("0O")
            ? String(octal.dropFirst(2)) : octal
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ $0.isNumber && $0 != "8" && $0 != "9" }),
              let value = UInt64(String(cleaned.reversed()), radix: 8)
        else { return nil }
        return pattern(decimal: value, steps: steps)
    }

    // MARK: - Reading one

    /// Which slots are struck.
    public static func onsets(_ pattern: [Bool]) -> [Int] {
        pattern.enumerated().compactMap { $0.element ? $0.offset : nil }
    }

    /// The gaps between successive onsets, wrapping the last back to the first.
    ///
    /// Wrapping is what makes this a *cycle* rather than a list: E(3,8)'s
    /// intervals are 3, 3, 2 and the 2 only exists because the last onset's gap
    /// closes round to step 0. A line's intervals would not wrap.
    public static func interOnsetIntervals(_ pattern: [Bool]) -> [Int] {
        let onsets = onsets(pattern)
        guard onsets.count > 1 else { return onsets.isEmpty ? [] : [pattern.count] }
        return onsets.indices.map { i in
            let next = onsets[(i + 1) % onsets.count]
            return i == onsets.count - 1 ? pattern.count - onsets[i] + next : next - onsets[i]
        }
    }
}
