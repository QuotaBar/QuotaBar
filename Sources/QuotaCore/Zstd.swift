import Foundation

// MARK: - Zstandard, decode only

/// Codex compresses a rollout it is done with into `rollout-….jsonl.zst` and
/// deletes the plain file, about a week after the session — on a Mac that has
/// used Codex for a while, most of the tree. macOS has no zstd of its own
/// (neither Compression nor the system libarchive reads it), so this is a
/// decoder written from RFC 8878: frames, raw, RLE and compressed blocks,
/// Huffman literals and FSE sequences. No dictionaries, which Codex does not
/// use, and the content checksum is skipped rather than checked.
///
/// Output comes a block at a time, never more than 128KB, and only the frame's
/// window is kept behind it (2MB in Codex's files), so a 200MB rollout is never
/// in memory whole. Malformed input throws; every index into the output is
/// checked before it is written.
enum Zstd {
    struct Corrupt: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Largest output of one block, whatever the window.
    static let blockMax = 1 << 17
    /// libzstd's own default ceiling: a frame asking for a larger window is
    /// refused rather than allocated.
    static let windowMax = 1 << 27

    /// Everything at once, for tests and small inputs.
    static func decompress(_ data: Data) throws -> Data {
        var stream = Stream(data)
        var out = Data()
        while let piece = try stream.next() { out.append(piece) }
        return out
    }

    /// The decompressed bytes of every frame in `input`, in pieces.
    struct Stream {
        private let input: Data
        private var cursor = 0
        private var frame: Frame?

        init(_ input: Data) {
            self.input = input
        }

        /// The next piece of output, never empty; nil after the last frame.
        mutating func next() throws -> Data? {
            while true {
                guard let frame else {
                    guard cursor < input.count else { return nil }
                    self.frame = try readFrameHeader()
                    continue
                }
                let header = try integer(3)
                let isLast = header & 1 == 1
                let size = header >> 3
                guard size <= Zstd.blockMax else { throw Corrupt("block larger than 128KB") }
                frame.makeRoom()
                let start = frame.end
                switch (header >> 1) & 3 {
                case 0: frame.appendRaw(try take(size))
                case 1:
                    let byte = try take(1)
                    frame.appendRepeated(byte[byte.startIndex], count: size)
                case 2: try frame.decodeCompressed([UInt8](try take(size)))
                default: throw Corrupt("reserved block type")
                }
                if isLast {
                    if frame.hasChecksum { _ = try take(4) }
                    self.frame = nil
                }
                if frame.end > start { return Data(frame.window[start..<frame.end]) }
            }
        }

        /// A frame's header, or nil for a skippable frame, which is passed over.
        private mutating func readFrameHeader() throws -> Frame? {
            let magic = try integer(4)
            if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
                _ = try take(try integer(4))
                return nil
            }
            guard magic == 0xFD2F_B528 else { throw Corrupt("not a zstd frame") }
            let descriptor = try integer(1)
            guard descriptor & 0x08 == 0 else { throw Corrupt("reserved frame header bit") }
            let singleSegment = descriptor & 0x20 != 0
            var windowSize = 0
            if !singleSegment {
                let byte = try integer(1)
                let log = 10 + (byte >> 3)
                guard log <= 31 else { throw Corrupt("window too large") }
                windowSize = (1 << log) + ((1 << log) >> 3) * (byte & 7)
            }
            guard try integer([0, 1, 2, 4][descriptor & 3]) == 0 else {
                throw Corrupt("frame needs a dictionary")
            }
            var contentSize: Int
            switch descriptor >> 6 {
            case 0: contentSize = singleSegment ? try integer(1) : 0
            case 1: contentSize = try integer(2) + 256
            case 2: contentSize = try integer(4)
            default:
                // Only a single-segment frame's size is used, as its window,
                // and anything past four bytes is over the ceiling anyway.
                contentSize = try integer(4)
                if try integer(4) != 0 { contentSize = Int.max }
            }
            if singleSegment { windowSize = contentSize }
            guard windowSize <= Zstd.windowMax else { throw Corrupt("window too large") }
            return Frame(windowSize: windowSize, hasChecksum: descriptor & 0x04 != 0)
        }

        private mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= input.count - cursor else { throw Corrupt("truncated") }
            let start = input.startIndex + cursor
            cursor += count
            return input[start..<(start + count)]
        }

        /// `count` bytes, little-endian; at most four.
        private mutating func integer(_ count: Int) throws -> Int {
            let bytes = try take(count)
            return bytes.reversed().reduce(0) { $0 << 8 | Int($1) }
        }
    }

    // MARK: Frame

    /// What one frame carries from block to block: the window, the repeat
    /// offsets, and the tables a later block may say to reuse.
    final class Frame {
        let windowSize: Int
        let hasChecksum: Bool
        /// `window[0..<end]` is the output kept so far: at least the last
        /// `windowSize` bytes, once that many exist.
        private(set) var window: [UInt8] = []
        private(set) var end = 0
        private var repeats = (1, 4, 8)
        private var huffman: Huffman?
        private var literalLengths: FSE?
        private var offsets: FSE?
        private var matchLengths: FSE?

        init(windowSize: Int, hasChecksum: Bool) {
            self.windowSize = windowSize
            self.hasChecksum = hasChecksum
        }

        /// Ensures a whole block fits after `end`: grows the buffer up to
        /// twice the window, then slides the window back to the front, so the
        /// copy happens once per window's worth of output.
        func makeRoom() {
            guard end + Zstd.blockMax > window.count else { return }
            let full = 2 * windowSize + Zstd.blockMax
            if window.count < full {
                let grown = min(full, max(2 * window.count, end + Zstd.blockMax))
                window.append(contentsOf: repeatElement(0, count: grown - window.count))
            }
            guard end + Zstd.blockMax > window.count else { return }
            let keep = min(end, windowSize)
            let dropped = end - keep
            window.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                memmove(base, base + dropped, keep)
            }
            end = keep
        }

        func appendRaw(_ bytes: Data) {
            window.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                bytes.copyBytes(to: base + end, count: bytes.count)
            }
            end += bytes.count
        }

        func appendRepeated(_ byte: UInt8, count: Int) {
            for index in end..<(end + count) { window[index] = byte }
            end += count
        }

        func decodeCompressed(_ block: [UInt8]) throws {
            var at = 0
            let literals = try readLiterals(block, &at)

            guard at < block.count else { throw Corrupt("missing sequences header") }
            var count = Int(block[at])
            at += 1
            if count >= 128 {
                if count < 255 {
                    guard at < block.count else { throw Corrupt("truncated sequences header") }
                    count = (count - 128) << 8 + Int(block[at])
                    at += 1
                } else {
                    guard at + 1 < block.count else { throw Corrupt("truncated sequences header") }
                    count = Int(block[at]) + Int(block[at + 1]) << 8 + 0x7F00
                    at += 2
                }
            }
            guard count > 0 else {
                try copyLiterals(literals, from: 0, blockStart: end)
                return
            }

            guard at < block.count else { throw Corrupt("missing compression modes") }
            let modes = Int(block[at])
            at += 1
            guard modes & 3 == 0 else { throw Corrupt("reserved compression mode bits") }
            literalLengths = try table(modes >> 6, .literalLength, block, &at, previous: literalLengths)
            offsets = try table((modes >> 4) & 3, .offset, block, &at, previous: offsets)
            matchLengths = try table((modes >> 2) & 3, .matchLength, block, &at, previous: matchLengths)
            try execute(count: count, bits: BackwardBits(block, at..<block.count), literals: literals)
        }

        // MARK: Literals

        private func readLiterals(_ block: [UInt8], _ at: inout Int) throws -> [UInt8] {
            guard at < block.count else { throw Corrupt("missing literals header") }
            let first = Int(block[at])
            let type = first & 3
            let format = (first >> 2) & 3

            if type < 2 {
                let headerSize = [1, 2, 1, 3][format]
                guard block.count - at >= headerSize else { throw Corrupt("truncated literals header") }
                let size: Int
                switch headerSize {
                case 1: size = first >> 3
                case 2: size = first >> 4 + Int(block[at + 1]) << 4
                default: size = first >> 4 + Int(block[at + 1]) << 4 + Int(block[at + 2]) << 12
                }
                at += headerSize
                guard size <= Zstd.blockMax else { throw Corrupt("literals larger than a block") }
                if type == 0 {
                    guard block.count - at >= size else { throw Corrupt("truncated raw literals") }
                    defer { at += size }
                    return Array(block[at..<(at + size)])
                }
                guard at < block.count else { throw Corrupt("truncated RLE literals") }
                defer { at += 1 }
                return [UInt8](repeating: block[at], count: size)
            }

            let headerSize = [3, 3, 4, 5][format]
            let width = [10, 10, 14, 18][format]
            guard block.count - at >= headerSize else { throw Corrupt("truncated literals header") }
            var header = 0
            for index in 0..<headerSize { header |= Int(block[at + index]) << (8 * index) }
            at += headerSize
            let regenerated = (header >> 4) & ((1 << width) - 1)
            let compressed = (header >> (4 + width)) & ((1 << width) - 1)
            guard regenerated <= Zstd.blockMax, block.count - at >= compressed else {
                throw Corrupt("literals larger than their block")
            }
            let streamsEnd = at + compressed
            if type == 2 { huffman = try Huffman.read(block, &at, end: streamsEnd) }
            guard let huffman else { throw Corrupt("treeless literals with no earlier table") }

            var out = [UInt8](repeating: 0, count: regenerated)
            if format == 0 {
                try huffman.decode(block, at..<streamsEnd, into: &out, 0..<regenerated)
            } else {
                guard streamsEnd - at >= 6 else { throw Corrupt("truncated jump table") }
                let sizes = (0..<3).map { Int(block[at + 2 * $0]) | Int(block[at + 2 * $0 + 1]) << 8 }
                var start = at + 6
                guard sizes.reduce(0, +) <= streamsEnd - start else { throw Corrupt("streams overrun literals") }
                let segment = (regenerated + 3) / 4
                guard 3 * segment <= regenerated else { throw Corrupt("too few literals for four streams") }
                for stream in 0..<4 {
                    let size = stream < 3 ? sizes[stream] : streamsEnd - start
                    let slots = (stream * segment)..<(stream < 3 ? (stream + 1) * segment : regenerated)
                    try huffman.decode(block, start..<(start + size), into: &out, slots)
                    start += size
                }
            }
            at = streamsEnd
            return out
        }

        // MARK: Sequences

        private func table(
            _ mode: Int, _ kind: SequenceKind, _ block: [UInt8], _ at: inout Int, previous: FSE?) throws -> FSE
        {
            switch mode {
            case 0:
                return kind.predefined
            case 1:
                guard at < block.count else { throw Corrupt("truncated RLE table") }
                let symbol = block[at]
                at += 1
                guard Int(symbol) <= kind.maxSymbol else { throw Corrupt("RLE symbol out of range") }
                return FSE(repeating: symbol)
            case 2:
                return try FSE.read(block, &at, end: block.count, maxLog: kind.maxLog, maxSymbol: kind.maxSymbol)
            default:
                guard let previous else { throw Corrupt("repeated table with no earlier one") }
                return previous
            }
        }

        private func execute(count: Int, bits initial: BackwardBits, literals: [UInt8]) throws {
            guard let ll = literalLengths, let of = offsets, let ml = matchLengths else {
                throw Corrupt("missing sequence tables")
            }
            var bits = initial
            var llState = bits.read(ll.log)
            var ofState = bits.read(of.log)
            var mlState = bits.read(ml.log)
            var (r1, r2, r3) = repeats
            var literal = 0
            let blockStart = end
            var end = self.end

            try window.withUnsafeMutableBufferPointer { out in
                try literals.withUnsafeBufferPointer { source in
                    guard let base = out.baseAddress else { throw Corrupt("no output buffer") }
                    for index in 0..<count {
                        let ofCode = Int(of.entries[ofState].symbol)
                        let llCode = Int(ll.entries[llState].symbol)
                        let mlCode = Int(ml.entries[mlState].symbol)
                        guard ofCode <= 31 else { throw Corrupt("offset code out of range") }
                        var offset = 1 << ofCode + bits.read(ofCode)
                        let matchLength = Zstd.matchBase[mlCode] + bits.read(Zstd.matchExtra[mlCode])
                        let literalLength = Zstd.literalBase[llCode] + bits.read(Zstd.literalExtra[llCode])
                        if index + 1 < count {
                            llState = ll.next(llState, &bits)
                            mlState = ml.next(mlState, &bits)
                            ofState = of.next(ofState, &bits)
                        }

                        if offset > 3 {
                            offset -= 3
                            (r1, r2, r3) = (offset, r1, r2)
                        } else {
                            // Values 1-3 name a recent offset; with no
                            // literals before the match they shift by one,
                            // the last meaning the most recent less one.
                            switch offset - 1 + (literalLength == 0 ? 1 : 0) {
                            case 0: offset = r1
                            case 1: offset = r2; (r1, r2) = (offset, r1)
                            case 2: offset = r3; (r1, r2, r3) = (offset, r1, r2)
                            default: offset = r1 - 1; (r1, r2, r3) = (offset, r1, r2)
                            }
                        }

                        guard literalLength <= literals.count - literal,
                              end - blockStart + literalLength + matchLength <= Zstd.blockMax
                        else { throw Corrupt("sequence overruns its block") }
                        if literalLength > 0, let from = source.baseAddress {
                            memcpy(base + end, from + literal, literalLength)
                        }
                        end += literalLength
                        literal += literalLength

                        guard offset >= 1, offset <= end else { throw Corrupt("offset outside the window") }
                        let from = end - offset
                        if offset >= matchLength {
                            memcpy(base + end, base + from, matchLength)
                        } else {
                            // Overlapping: the match repeats bytes it is
                            // itself writing, so it must go forward a byte
                            // at a time.
                            for step in 0..<matchLength { base[end + step] = base[from + step] }
                        }
                        end += matchLength
                    }
                }
            }
            guard bits.position == 0 else { throw Corrupt("sequence bitstream not consumed exactly") }
            self.end = end
            repeats = (r1, r2, r3)
            try copyLiterals(literals, from: literal, blockStart: blockStart)
        }

        /// The literals no sequence used, which close the block.
        private func copyLiterals(_ literals: [UInt8], from literal: Int, blockStart: Int) throws {
            let rest = literals.count - literal
            guard end - blockStart + rest <= Zstd.blockMax else { throw Corrupt("literals overrun their block") }
            for index in 0..<rest { window[end + index] = literals[literal + index] }
            end += rest
        }
    }

    // MARK: Bitstreams

    /// FSE and Huffman streams are read from their last bit to their first.
    /// The top set bit of the last byte only marks where the stream starts;
    /// reads that run past the beginning get zeros, and `position` goes
    /// negative so the caller can tell.
    struct BackwardBits {
        private let bytes: [UInt8]
        private let start: Int
        private(set) var position: Int

        init(_ bytes: [UInt8], _ range: Range<Int>) throws {
            guard !range.isEmpty, range.upperBound <= bytes.count, bytes[range.upperBound - 1] != 0 else {
                throw Corrupt("empty or unterminated bitstream")
            }
            self.bytes = bytes
            start = range.lowerBound
            let last = Int(bytes[range.upperBound - 1])
            position = (range.count - 1) * 8 + (Int.bitWidth - 1 - last.leadingZeroBitCount)
        }

        /// The next `count` bits, at most 32, as an integer.
        @inline(__always)
        mutating func read(_ count: Int) -> Int {
            guard count > 0 else { return 0 }
            position -= count
            var low = position
            var width = count
            if low < 0 {
                width += low
                if width <= 0 { return 0 }
                low = 0
            }
            let first = start + low >> 3
            var index = start + (low + width - 1) >> 3
            var word: UInt64 = 0
            while index >= first {
                word = word << 8 | UInt64(bytes[index])
                index -= 1
            }
            let value = Int(truncatingIfNeeded: (word >> UInt64(low & 7)) & ((1 << UInt64(width)) - 1))
            return position < 0 ? value << -position : value
        }
    }

    /// Table descriptions are read forward, low bit first. Reads past `end`
    /// get zeros; the caller checks `bit` afterwards.
    struct ForwardBits {
        private let bytes: [UInt8]
        private let start: Int
        private let end: Int
        private(set) var bit = 0

        init(_ bytes: [UInt8], from start: Int, to end: Int) {
            self.bytes = bytes
            self.start = start
            self.end = end
        }

        var exhausted: Bool { bit > (end - start) * 8 }
        var bytesUsed: Int { (bit + 7) / 8 }

        mutating func read(_ count: Int) -> Int {
            var value = 0
            for offset in 0..<count {
                let at = bit + offset
                let index = start + at >> 3
                if index < end { value |= Int(bytes[index] >> UInt8(at & 7) & 1) << offset }
            }
            bit += count
            return value
        }

        mutating func rewind(_ count: Int) {
            bit -= count
        }
    }

    // MARK: FSE

    struct FSE {
        struct Entry {
            let symbol: UInt8
            let bits: UInt8
            let base: UInt16
        }

        let log: Int
        let entries: [Entry]

        @inline(__always)
        func next(_ state: Int, _ bits: inout BackwardBits) -> Int {
            let entry = entries[state]
            return Int(entry.base) + bits.read(Int(entry.bits))
        }

        init(repeating symbol: UInt8) {
            log = 0
            entries = [Entry(symbol: symbol, bits: 0, base: 0)]
        }

        /// The decoding table for normalized counts summing to `1 << log`,
        /// -1 meaning "less than one".
        init(counts: [Int], log: Int) throws {
            let size = 1 << log
            guard counts.reduce(0, { $0 + abs($1) }) == size, counts.count <= 256 else {
                throw Corrupt("FSE counts do not fill the table")
            }
            var symbols = [UInt8](repeating: 0, count: size)
            var next = [Int](repeating: 0, count: counts.count)
            var high = size
            for (symbol, count) in counts.enumerated() where count == -1 {
                high -= 1
                symbols[high] = UInt8(symbol)
                next[symbol] = 1
            }
            let step = size >> 1 + size >> 3 + 3
            let mask = size - 1
            var position = 0
            for (symbol, count) in counts.enumerated() where count > 0 {
                next[symbol] = count
                for _ in 0..<count {
                    symbols[position] = UInt8(symbol)
                    repeat { position = (position + step) & mask } while position >= high
                }
            }
            guard position == 0 else { throw Corrupt("FSE table spread did not close") }
            entries = symbols.map { symbol in
                let state = next[Int(symbol)]
                next[Int(symbol)] += 1
                let bits = log - (Int.bitWidth - 1 - state.leadingZeroBitCount)
                return Entry(symbol: symbol, bits: UInt8(bits), base: UInt16(state << bits - size))
            }
            self.log = log
        }

        /// A table description at `block[at...]`; `at` is left after it.
        static func read(_ block: [UInt8], _ at: inout Int, end: Int, maxLog: Int, maxSymbol: Int) throws -> FSE {
            var reader = ForwardBits(block, from: at, to: end)
            let log = reader.read(4) + 5
            guard log <= maxLog else { throw Corrupt("FSE accuracy too high") }
            var remaining = 1 << log
            var counts: [Int] = []
            while remaining > 0 {
                guard counts.count <= maxSymbol else { throw Corrupt("FSE symbol out of range") }
                let bits = Int.bitWidth - (remaining + 1).leadingZeroBitCount
                var value = reader.read(bits)
                let lowerMask = 1 << (bits - 1) - 1
                let threshold = 1 << bits - 1 - (remaining + 1)
                if value & lowerMask < threshold {
                    reader.rewind(1)
                    value &= lowerMask
                } else if value > lowerMask {
                    value -= threshold
                }
                let count = value - 1
                remaining -= abs(count)
                counts.append(count)
                if count == 0 {
                    while true {
                        let zeros = reader.read(2)
                        guard counts.count + zeros <= maxSymbol + 1 else { throw Corrupt("FSE symbol out of range") }
                        counts.append(contentsOf: repeatElement(0, count: zeros))
                        if zeros < 3 { break }
                    }
                }
            }
            guard remaining == 0, !reader.exhausted else { throw Corrupt("bad FSE table description") }
            at += reader.bytesUsed
            return try FSE(counts: counts, log: log)
        }

        /// Huffman weights: two states taking turns over one stream until
        /// it runs out.
        func decodeWeights(_ block: [UInt8], _ range: Range<Int>) throws -> [Int] {
            var bits = try BackwardBits(block, range)
            var one = bits.read(log)
            var two = bits.read(log)
            var weights: [Int] = []
            while weights.count < 255 {
                weights.append(Int(entries[one].symbol))
                one = next(one, &bits)
                if bits.position < 0 {
                    weights.append(Int(entries[two].symbol))
                    return weights
                }
                weights.append(Int(entries[two].symbol))
                two = next(two, &bits)
                if bits.position < 0 {
                    weights.append(Int(entries[one].symbol))
                    return weights
                }
            }
            throw Corrupt("too many Huffman weights")
        }
    }

    // MARK: Huffman

    struct Huffman {
        let maxBits: Int
        /// Indexed by the next `maxBits` bits: the symbol, and in the high
        /// byte how many of those bits its code uses.
        let table: [UInt16]

        /// Weights as listed; the last symbol's is implied by the others.
        init(weights listed: [Int]) throws {
            guard listed.count <= 255 else { throw Corrupt("too many Huffman weights") }
            var total = 0
            for weight in listed where weight > 0 {
                guard weight <= 12 else { throw Corrupt("Huffman weight too large") }
                total += 1 << (weight - 1)
            }
            guard total > 0 else { throw Corrupt("no Huffman weights") }
            let maxBits = Int.bitWidth - total.leadingZeroBitCount
            guard maxBits <= 12 else { throw Corrupt("Huffman codes too long") }
            let leftOver = 1 << maxBits - total
            guard leftOver & (leftOver - 1) == 0 else { throw Corrupt("Huffman weights do not complete") }
            let weights = listed + [Int.bitWidth - leftOver.leadingZeroBitCount]
            let lengths = weights.map { $0 > 0 ? maxBits + 1 - $0 : 0 }

            var perLength = [Int](repeating: 0, count: maxBits + 1)
            for length in lengths where length > 0 { perLength[length] += 1 }
            // Longest codes first, from the bottom of the table.
            var next = [Int](repeating: 0, count: maxBits + 1)
            var position = 0
            for length in stride(from: maxBits, through: 1, by: -1) {
                next[length] = position
                position += perLength[length] << (maxBits - length)
            }
            guard position == 1 << maxBits else { throw Corrupt("Huffman table does not fill") }
            var table = [UInt16](repeating: 0, count: 1 << maxBits)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let span = 1 << (maxBits - length)
                let entry = UInt16(symbol) | UInt16(length) << 8
                for index in next[length]..<(next[length] + span) { table[index] = entry }
                next[length] += span
            }
            self.maxBits = maxBits
            self.table = table
        }

        /// A tree description at `block[at...]`; `at` is left after it.
        static func read(_ block: [UInt8], _ at: inout Int, end: Int) throws -> Huffman {
            guard at < end else { throw Corrupt("missing Huffman header") }
            let header = Int(block[at])
            at += 1
            if header >= 128 {
                let count = header - 127
                let size = (count + 1) / 2
                guard end - at >= size else { throw Corrupt("truncated Huffman weights") }
                let weights = (0..<count).map { index in
                    let byte = Int(block[at + index / 2])
                    return index % 2 == 0 ? byte >> 4 : byte & 15
                }
                at += size
                return try Huffman(weights: weights)
            }
            guard header > 0, end - at >= header else { throw Corrupt("truncated Huffman weights") }
            let streamEnd = at + header
            var tableEnd = at
            let fse = try FSE.read(block, &tableEnd, end: streamEnd, maxLog: 6, maxSymbol: 12)
            let weights = try fse.decodeWeights(block, tableEnd..<streamEnd)
            at = streamEnd
            return try Huffman(weights: weights)
        }

        func decode(_ block: [UInt8], _ range: Range<Int>, into out: inout [UInt8], _ slots: Range<Int>) throws {
            var bits = try BackwardBits(block, range)
            let mask = 1 << maxBits - 1
            var state = bits.read(maxBits)
            for slot in slots {
                let entry = table[state]
                out[slot] = UInt8(truncatingIfNeeded: entry)
                let length = Int(entry >> 8)
                state = (state << length | bits.read(length)) & mask
            }
            guard bits.position == -maxBits else { throw Corrupt("literal stream not consumed exactly") }
        }
    }

    // MARK: Sequence codes

    struct SequenceKind {
        let maxLog: Int
        let maxSymbol: Int
        let predefined: FSE

        // Fixed counts that fill their tables exactly, so these cannot throw.
        static let literalLength = SequenceKind(maxLog: 9, maxSymbol: 35, predefined: try! FSE(counts: [
            4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2,
            2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
        ], log: 6))
        static let matchLength = SequenceKind(maxLog: 9, maxSymbol: 52, predefined: try! FSE(counts: [
            1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
            -1, -1, -1, -1, -1,
        ], log: 6))
        static let offset = SequenceKind(maxLog: 8, maxSymbol: 31, predefined: try! FSE(counts: [
            1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            -1, -1, -1, -1, -1,
        ], log: 5))
    }

    static let literalBase: [Int] = Array(0..<16) + [
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
        8192, 16384, 32768, 65536,
    ]
    static let literalExtra: [Int] = Array(repeating: 0, count: 16) + [
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    ]
    static let matchBase: [Int] = Array(3..<35) + [
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
        4099, 8195, 16387, 32771, 65539,
    ]
    static let matchExtra: [Int] = Array(repeating: 0, count: 32) + [
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    ]
}
