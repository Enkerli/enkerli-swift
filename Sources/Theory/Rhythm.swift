//
//  Rhythm.swift
//  Theory
//
//  Rhythm as a mask of onsets, which is a different object from a melody.
//
//  Ported from `packages/theory/src/rhythm.ts` in music-suite, itself ported
//  from Serpe (rhythm_pattern_explorer): Björklund's Euclidean algorithm,
//  Barlow indispensability and the transforms over it, and the codecs. Held to
//  `packages/theory/vectors/rhythm.json` — seven groups of cases described
//  there as "verified by differential testing against the original WebApp JS
//  (all E(k,n) for n≤24 with offsets, Barlow tables, transforms)", which makes
//  this the fourth language in that contract after TypeScript, Lua and C++.
//
//  **First step = leftmost = LSB, and hex/octal digit strings are
//  little-endian.** Tresillo is `10010010`, which is `0x94` and decimal 73, not
//  `0x49`. This is stated in the suite's CONVENTIONS.md, it is in the vectors,
//  and it is the single thing a port into a new language silently inverts — so
//  the codec tests exist mostly to catch exactly that.
//
//  What is deliberately NOT here: UPI notation. `parseUPI` is where Serpe's
//  identity lives, it has a grammar rather than an algorithm, and it belongs in
//  the plug-in rather than in shared theory. See MelGen's PORTING.md §5.
//
//  This is a mask, not a line. A `MelodyPattern` carries durations inside the
//  token; a rhythm carries which of n slots are struck and says nothing about
//  how long anything sounds. The thing that joins them is `Carrier`'s
//  `applyRhythm`, which performs a line's pitch material on a rhythm's grid.
//

import Foundation

/// Björklund's Euclidean algorithm, and the family around it.
public enum EuclideanRhythm {

    /// The maximally even distribution of `beats` onsets over `steps` slots,
    /// normalised to start on its first onset, then rotated right by `offset`.
    ///
    /// The normalisation matters and is easy to leave out: Björklund's raw
    /// output for E(3,8) starts on a rest, and every notation that names this
    /// pattern — `E(3,8)`, `0x94`, `10010010` — means the rotation that starts
    /// on an onset.
    public static func pattern(beats: Int, steps: Int, offset: Int = 0) -> [Bool] {
        guard steps > 0 else { return [] }
        let beats = min(beats, steps)
        guard beats > 0 else { return Array(repeating: false, count: steps) }

        var counts: [Int] = []
        var remainders: [Int] = [beats]
        var divisor = steps - beats
        var level = 0

        repeat {
            counts.append(divisor / remainders[level])
            remainders.append(divisor % remainders[level])
            divisor = remainders[level]
            level += 1
        } while remainders[level] > 1
        counts.append(divisor)

        // The recursion in the original is `build(l)` over two sentinel levels;
        // written iteratively here it would need its own stack, so it stays
        // recursive and stays readable. Depth is the number of remainder levels,
        // which is logarithmic in `steps`.
        var pattern: [Bool] = []
        func build(_ l: Int) {
            if l == -1 {
                pattern.append(false)
            } else if l == -2 {
                pattern.append(true)
            } else {
                for _ in 0..<counts[l] { build(l - 1) }
                if remainders[l] != 0 { build(l - 2) }
            }
        }
        build(level)

        while pattern.count < steps { pattern.append(false) }

        if let first = pattern.firstIndex(of: true), first > 0 {
            pattern = Array(pattern[first...]) + Array(pattern[..<first])
        }

        if offset != 0 {
            let shift = ((offset % steps) + steps) % steps
            var rotated = Array(repeating: false, count: steps)
            for i in 0..<steps {
                rotated[i] = pattern[((i - shift) % steps + steps) % steps]
            }
            pattern = rotated
        }
        return pattern
    }

    /// E(steps − beats, steps): the onsets the Euclidean rhythm left alone.
    ///
    /// Not the same as inverting the mask, which is what makes it worth having
    /// a name — the complement is itself maximally even.
    public static func complement(beats: Int, steps: Int, offset: Int = 0) -> [Bool] {
        pattern(beats: steps - beats, steps: steps, offset: offset)
    }
}

/// Clarence Barlow's indispensability: how much a position in a meter is the
/// one you would keep if you could keep only one.
public enum Barlow {

    /// Indispensability of one position, 0…1, with the downbeat at 1.
    ///
    /// Serpe's enhanced method rather than the bare textbook one: the downbeat
    /// is 1, the last step is 0.75 because a pickup is the second thing you
    /// would keep, and everything between comes from the meter's own prime
    /// stratification with a gcd fallback for positions the stratification does
    /// not reach.
    public static func indispensability(ofPosition position: Int, length: Int) -> Double {
        guard length > 0 else { return 0 }
        if position == 0 { return 1 }
        if position == length - 1 { return 0.75 }   // anacrustic pickup

        let stratification = primeFactors(length).sorted()
        var total = 0.0
        for (level, prime) in stratification.enumerated() {
            let levelSize = Double(length) / pow(Double(prime), Double(level + 1))
            // Float remainder, deliberately, and this is the one line of the
            // port that had to be argued about rather than transcribed.
            //
            // `levelSize` is a real number in the TypeScript — for length 12 the
            // third level is 12/27 = 0.444… — and JavaScript's `%` is a float
            // operation, so the test is "is this position an exact multiple of a
            // fractional level size", which for a fractional level size is true
            // of nothing but position 0, which never reaches here. Rounding it
            // to an Int first changes the answer at every level whose size is
            // not whole, and at 0.444… it truncates to zero and traps. The
            // vectors caught it on the first run, which is what they are for.
            if levelSize > 0,
               Double(position).truncatingRemainder(dividingBy: levelSize) == 0 {
                total += 1 / pow(Double(prime), Double(level + 1))
            }
        }

        if total == 0 {
            let level = length / greatestCommonDivisor(position, length)
            total = 1
            for prime in primeFactors(level) { total *= 1 / Double(prime) }
        }
        return min(total, 1)
    }

    /// The table for a whole meter.
    public static func table(length: Int) -> [Double] {
        (0..<max(0, length)).map { indispensability(ofPosition: $0, length: length) }
    }

    /// Mean of (1 − normalised indispensability) over a set of onsets.
    ///
    /// 0 means every onset is on the grid's strong points; towards 1 means the
    /// line is avoiding them. This is `@enkerli/theory`'s single-number measure
    /// and is *not* Serpe's six-way syncopation readout, which lives in the
    /// plug-in — two different things with one word between them.
    public static func syncopation(onsets: [Int], stepCount: Int) -> Double {
        guard !onsets.isEmpty, stepCount > 0 else { return 0 }
        let table = table(length: stepCount)
        guard let peak = table.max(), peak > 0 else { return 0 }
        let total = onsets.reduce(0.0) { sum, position in
            guard position >= 0, position < table.count else { return sum }
            return sum + (1 - table[position] / peak)
        }
        return total / Double(onsets.count)
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    static func primeFactors(_ n: Int) -> [Int] {
        var factors: [Int] = []
        var n = n, divisor = 2
        while n > 1 {
            while n % divisor == 0 { factors.append(divisor); n /= divisor }
            divisor += 1
            // Without this the loop is O(n) on a prime, which for a 4096-step
            // meter is 4096 iterations of nothing. The remainder is prime.
            if divisor * divisor > n, n > 1 { factors.append(n); break }
        }
        return factors
    }
}

/// Moving a pattern to a different onset count by indispensability.
public enum BarlowTransform {

    public enum Kind: String, Sendable {
        case none, dilution, concentration
        case wolrabDilution = "wolrab-dilution"
        case wolrabConcentration = "wolrab-concentration"
    }

    public struct Options: Sendable {
        /// Reverse the indispensability logic — keep what the meter says to drop.
        public var wolrab: Bool
        /// Keep the position-0 onset while diluting.
        public var preserveDownbeat: Bool
        /// Floor below which a position is not removed.
        public var minimumIndispensability: Double
        /// Deprioritize weak beats while concentrating.
        public var avoidWeakBeats: Bool

        public init(wolrab: Bool = false,
                    preserveDownbeat: Bool = true,
                    minimumIndispensability: Double? = nil,
                    avoidWeakBeats: Bool = false) {
            self.wolrab = wolrab
            self.preserveDownbeat = preserveDownbeat
            // The two directions have different defaults in the TypeScript — 0
            // for dilution and 0.1 for concentration — which is not a mistake:
            // a concentration floor stops the transform reaching for positions
            // nothing in the meter recommends. `nil` here means "whichever
            // direction we end up going", so the two agree by construction
            // rather than by both remembering.
            self.minimumIndispensability = minimumIndispensability ?? .nan
            self.avoidWeakBeats = avoidWeakBeats
        }

        func floor(default value: Double) -> Double {
            minimumIndispensability.isNaN ? value : minimumIndispensability
        }
    }

    public struct Position: Hashable, Sendable {
        public let position: Int
        public let indispensability: Double

        public init(position: Int, indispensability: Double) {
            self.position = position
            self.indispensability = indispensability
        }
    }

    public struct Result: Sendable {
        public let pattern: [Bool]
        public let originalPattern: [Bool]
        public let transformation: Kind
        public let targetOnsets: Int
        public let currentOnsets: Int
        public let removedPositions: [Position]
        public let addedPositions: [Position]

        public init(pattern: [Bool], originalPattern: [Bool], transformation: Kind,
                    targetOnsets: Int, currentOnsets: Int,
                    removedPositions: [Position] = [], addedPositions: [Position] = []) {
            self.pattern = pattern
            self.originalPattern = originalPattern
            self.transformation = transformation
            self.targetOnsets = targetOnsets
            self.currentOnsets = currentOnsets
            self.removedPositions = removedPositions
            self.addedPositions = addedPositions
        }
    }

    public static func apply(_ pattern: [Bool],
                             targetOnsets: Int,
                             options: Options = Options()) -> Result {
        let current = pattern.filter { $0 }.count
        guard targetOnsets != current else {
            return Result(pattern: pattern, originalPattern: pattern,
                          transformation: .none, targetOnsets: targetOnsets,
                          currentOnsets: current)
        }
        let table = Barlow.table(length: pattern.count)
        return targetOnsets < current
            ? dilute(pattern, to: targetOnsets, table: table, options: options)
            : concentrate(pattern, to: targetOnsets, table: table, options: options)
    }

    private static func dilute(_ pattern: [Bool], to target: Int,
                               table: [Double], options: Options) -> Result {
        let current = pattern.filter { $0 }.count
        let toRemove = current - target
        let floor = options.floor(default: 0)

        // A total order, not the TypeScript's comparator: `Array.sort` is stable
        // and Swift's is not, so a comparator that returns "equal" for two
        // positions with the same indispensability would give a different answer
        // here on a different run. Position breaks the tie, which is the order
        // a stable sort of an index-ordered array produces anyway.
        var onsets = pattern.enumerated().filter { $0.element }
            .map { Position(position: $0.offset, indispensability: table[$0.offset]) }
        onsets.sort { a, b in
            if options.preserveDownbeat, !options.wolrab {
                if a.position == 0, b.position != 0 { return false }
                if b.position == 0, a.position != 0 { return true }
            }
            if a.indispensability != b.indispensability {
                return options.wolrab
                    ? a.indispensability > b.indispensability
                    : a.indispensability < b.indispensability
            }
            return a.position < b.position
        }

        var result = pattern
        var removed: [Position] = []
        for candidate in onsets.prefix(max(0, min(toRemove, onsets.count))) {
            let allowed = options.wolrab
                || candidate.indispensability >= floor
                || !options.preserveDownbeat
                || candidate.position != 0
            if allowed {
                result[candidate.position] = false
                removed.append(candidate)
            }
        }
        return Result(pattern: result, originalPattern: pattern,
                      transformation: options.wolrab ? .wolrabDilution : .dilution,
                      targetOnsets: target,
                      currentOnsets: result.filter { $0 }.count,
                      removedPositions: removed)
    }

    private static func concentrate(_ pattern: [Bool], to target: Int,
                                    table: [Double], options: Options) -> Result {
        let stepCount = pattern.count
        let current = pattern.filter { $0 }.count
        let toAdd = target - current
        let floor = options.floor(default: 0.1)

        func isWeak(_ position: Int) -> Bool {
            let quarter = stepCount / 4, eighth = stepCount / 8
            let onQuarter = quarter > 0 && position % quarter == 0
            let onEighth = eighth > 0 && position % eighth == 0
            return !(onQuarter || onEighth)
        }

        var empties = pattern.enumerated().filter { !$0.element }
            .map { (Position(position: $0.offset, indispensability: table[$0.offset]),
                    isWeak($0.offset)) }
        empties.sort { a, b in
            if options.avoidWeakBeats {
                if a.1, !b.1 { return false }
                if b.1, !a.1 { return true }
            }
            if a.0.indispensability != b.0.indispensability {
                return options.wolrab
                    ? a.0.indispensability < b.0.indispensability
                    : a.0.indispensability > b.0.indispensability
            }
            return a.0.position < b.0.position
        }

        var result = pattern
        var added: [Position] = []
        for (candidate, _) in empties where added.count < toAdd {
            if candidate.indispensability >= floor {
                result[candidate.position] = true
                added.append(candidate)
            }
        }
        // Second pass without the floor: the target is a promise, and a meter
        // whose empty positions are all below it would otherwise silently
        // return fewer onsets than asked for.
        if added.count < toAdd {
            for (candidate, _) in empties where added.count < toAdd {
                guard !result[candidate.position] else { continue }
                result[candidate.position] = true
                added.append(candidate)
            }
        }
        return Result(pattern: result, originalPattern: pattern,
                      transformation: options.wolrab ? .wolrabConcentration : .concentration,
                      targetOnsets: target,
                      currentOnsets: result.filter { $0 }.count,
                      addedPositions: added)
    }
}
