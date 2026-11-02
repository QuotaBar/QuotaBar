import CryptoKit
import XCTest
@testable import QuotaCore

/// Codex archives rollouts as zstd. The fixtures were written by the zstd
/// 1.5.7 CLI, one per kind of frame the decoder has to read; each is checked
/// against the size and SHA-256 of what was compressed.
final class ZstdTests: XCTestCase {
    private struct Fixture {
        let size: Int
        let sha256: String
        let base64: String

        var data: Data { Data(base64Encoded: base64, options: .ignoreUnknownCharacters)! }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testEveryKindOfFrameDecodesToWhatWasCompressed() throws {
        for (name, fixture) in Self.fixtures.sorted(by: { $0.key < $1.key }) {
            let plain = try Zstd.decompress(fixture.data)
            XCTAssertEqual(plain.count, fixture.size, name)
            XCTAssertEqual(Self.sha256(plain), fixture.sha256, name)
        }
    }

    func testOutputComesABlockAtATime() throws {
        var stream = Zstd.Stream(Self.fixtures["sliding"]!.data)
        var pieces: [Int] = []
        while let piece = try stream.next() { pieces.append(piece.count) }
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0 > 0 && $0 <= Zstd.blockMax }, "\(pieces)")
        XCTAssertEqual(pieces.reduce(0, +), Self.fixtures["sliding"]!.size)
    }

    func testATruncatedArchiveThrows() {
        let sealed = Self.fixtures["sliding"]!.data
        for length in stride(from: 1, to: sealed.count, by: 97) {
            XCTAssertThrowsError(try Zstd.decompress(sealed.prefix(length)), "cut at \(length)")
        }
    }

    /// Damage anywhere may decode to garbage or throw, but must never trap.
    func testDamagedBytesNeverCrash() {
        for (name, step) in [("compressed", 11), ("sliding", 691)] {
            let sealed = [UInt8](Self.fixtures[name]!.data)
            for position in stride(from: 4, to: sealed.count, by: step) {
                for flip: UInt8 in [0x01, 0xFF] {
                    var damaged = sealed
                    damaged[position] ^= flip
                    _ = try? Zstd.decompress(Data(damaged))
                }
            }
        }
    }

    func testAFrameNeedingADictionaryIsRefused() {
        // Magic, a one-byte dictionary id, a 1KB window, dictionary 7.
        let frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x01, 0x00, 0x07])
        XCTAssertThrowsError(try Zstd.decompress(frame))
    }

    func testSomethingElseIsNotTakenForZstd() {
        XCTAssertThrowsError(try Zstd.decompress(Data("{\"type\":\"session_meta\"}\n".utf8)))
    }

    /// `QUOTABAR_ZSTD_CORPUS=~/.codex/sessions swift test --filter ZstdTests`:
    /// every archive under the folder, against the zstd CLI's own output.
    func testCorpusMatchesTheZstdCLI() throws {
        guard let folder = ProcessInfo.processInfo.environment["QUOTABAR_ZSTD_CORPUS"] else {
            throw XCTSkip("set QUOTABAR_ZSTD_CORPUS to a folder of .zst files")
        }
        guard let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { throw XCTSkip("the zstd CLI is not installed") }
        let files = FileManager.default.enumerator(atPath: folder)?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".zst") }
            .map { URL(fileURLWithPath: folder).appendingPathComponent($0) } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            var stream = Zstd.Stream(try Data(contentsOf: file, options: .alwaysMapped))
            var ours = SHA256()
            while let piece = try stream.next() { ours.update(data: piece) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: zstd)
            process.arguments = ["-dc", file.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            var theirs = SHA256()
            while case let chunk = pipe.fileHandleForReading.readData(ofLength: 1 << 20), !chunk.isEmpty {
                theirs.update(data: chunk)
            }
            process.waitUntilExit()
            XCTAssertEqual(
                ours.finalize().description, theirs.finalize().description, file.lastPathComponent)
        }
    }

    private static let fixtures: [String: Fixture] = [
        // Huffman literals and FSE sequences, level 19, with a checksum
        "compressed": Fixture(size: 7087, sha256: "3c90cad1d0bfeadf59edc084dd13fcb969ec76843669909aae89874915ad6a59", base64: """
            KLUv/WSvGnUrAAaqbx1gbw4jH9GPBvuTmZbTWHQYYG5KkhWRngljMBEYB34AaQBaAInePANRPdPhApmmB/vxWgIymSYCVY0D
            REXSREGSBgKBGFQDkSgBD1ZQTYvmqaDIIZIaFAVRgQyzbZ4rC1RFEuIQSSaSImpQEfSQqkM1maLGIQExEA8Ck3gkyOWZIFBC
            ikDTpQo0TsBwd4O/a3iCQwHnZaD5wBR5KgqKNKoAJvt+je1WEHnXbH1f817qaPoE2ZWVcz1f6/O8XlzW7ti8q7/XuIoaFPU0
            TSfvg6gQ0USxVplWE2l5/rq2DbR4Ig22k+jttKqyRdSIJOpRzNdrq0GmzGEVAnJIkolAgRIESgJRBUIu/LymAXzv2Fgzb5a5
            sjG72X5jc9yVt5YqW4x4ybnP2PpY3XfXLzZezo71KVuuv7AtW36djdydjaOoqK/YFiOj58pPbMrYj9iSLefhDf6wIfq6K3O2
            GdNn1w7dM5eZc4ebt5jms/zVdMZvmKrN7jtfr7mzJ8s77lPOe87Pa51rd3/z8RrzLod3ff3Kv2uLvZqPce6l4nrNtho3GcPe
            XPqZTVUX+zFb6uUN/rJhM9Nn2C53vV2dKa4HgaioMSKbqSlJQSnDAVEQhSBkuJWyA1IxEAEJMASDwAYRo5QxhCASjIpEggQF
            Cl0MTaN6ojMwuzEdMY2SWl4dJPvykjKkO29Lhv4Un4zH3qSp3azZnJDZyd8iv3heIBYVNPaxgrWqc0ilQ3hdZsq23KgkacDQ
            0dMJ28ydxUC90NRC2Q02SFNtP8fAvuWzW73jjXV85J8g4Gmupu3rpBS+s5ke7/lsFW2eotbqJBxmCB+yS6o3xF42xtMGWccW
            2WPIfx1BqNaiAF3Qa9r6cxTCMYSKqjlc0Qa2cewrPFRgPllaIsfcs6tK86sMYe5zp7VLZqYAMhGy4TwhvPOhCrSFbaVX5Lgs
            +y4dsf0sg7KRjI8XJ4JERXFONa2h6sI25KCfeFXF56Bqax8ng9bdEPnRqSCty/KXlXHBiimuXbpYofUBQCZiYUbegpzY8vs+
            q1xeM7HdEt0I9t6DzVcgZeoGjiNXPG2ElQ77RHIy4K52NQ9wkaTOdf5Oicyyqs/lf/GYA/82l38F4xO/zFOfeNV8toSee+9l
            x53f6hHx3AsSm0SL7KiClNxAsBQicztBeHcp4S18SrKUc4pAExESh1rQzhdD/BNsLiPLkw+F9NaeFsiJWP/JHiccaRD5BpbH
            bUnTE9GWVAMbllIRxJohOJwXO47whsvWR1wRJyFHk0hOnpBnulm/TC7QoSovIxlfiuG/6Imf4+eucLS5UBqHjT6SF5tyl4NS
            1l7Zhwi0yUpUvLSH+bHiSR5ULlLRRlDgtydlLX8aC5Aw3SlJIw+T44euwONpLSC57LKiiwHZKuG4lyALK9Q6ujJ5l2gIptS5
            OCWD/XbYlnJP1vJyP85zptVoG76wuckEEVN5FCIVB+vXffyzMR/lqCVQnSlGrmRlFrhqd03MrffThbiH0x9bcvdC/p3wPCRz
            fPhOToyBeSsVnIPcRF65MPs/wXWQ1pOGYbmt0WSIdxAqhOQoVvSne+ptM5HUkjRdwouDkVnPLnleceJDRfAomX4qvilujFG8
            zyvJ908nPuCouY9QH9bv4D3EfnA6J6klCnv1sGQ8ebOqyBYoSuoOVPP6KmOgUEZn0wFj0rjXgOF44Xgpk/QxtDg8qPJrY64T
            pRbVbtQwUqV7SRVS7OgVgiTid2nEcYs0DuBgyDUrnYqUnwxs8CKCBM3nCognKI4vPyeipwCyCpnN0v6Jbf5CH/oiCYTXx63S
            udZf1kEge9Le6v9siKx+Ldg7+AiK4ikiPX6e+jTPQxWcJ+j6
            """),
        // random bytes zstd keeps as a raw block
        "raw": Fixture(size: 300, sha256: "9d02d194519426054d96efdb81ac8e5b2137e2662d74b71c9b8951b80393a004", base64: """
            KLUv/WQsAGEJAB6anaOpJtXe29pjmxJcIZ9bxKP+Dvt6EeUM+n+hrNlREmlFe/zGppIkw7/7Rm8tUJMk62DvheCgQxG4ru/Z
            QFtWWe54CDsBNdIa7r4eMI0UAsA89OdDn2CBKx4X++Wbr4zYt1uz0YpyvW/KnAZ0R9OS1pCfvJpi8vcDsJfehiStBjV7XTpN
            6ZvQ4zv9Tpi0/4rBUL96oqpJExJUICrDfWWgRwe3xzAd8IC4jexZjdWWBwW3M+M42Nu2bd9MI5vL5CHm6nfF81SP6dWG+Mwl
            OqM7NlZfvvIotGKsQYJJXdXOjT84UPa4u1yi9zfCbDDfzzGA0U1W5j8WZJ2T5xbmXGiiDpLg5DgYl5gFxLTd/a0ZEcWbEdE6
            WlvSpO+53W8ObQ4ZvIGhlJY7lKW7+6+idhM=
            """),
        // 300KB of zeros: RLE blocks
        "rle": Fixture(size: 300000, sha256: "886715e4051e827f4fe215df3053af3f85ad0d352db2c829c7487af6d78efe30", base64: """
            KLUv/aTgkwQAVAAAEAAAAQD7/znAAgIAEAADnwQALSjeJg==
            """),
        // 175KB in an 8KB window, many blocks: reused tables, repeat offsets, the window sliding
        "sliding": Fixture(size: 178520, sha256: "ea3f24013086ec11092a57e375bde34211be5d0fcb5bc8689ebea720ee7fe5bb", base64: """
            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
            """),
        // two frames with a skippable frame between them
        "concatenated": Fixture(size: 47, sha256: "8fc7a6b234cd86d7d1e14fc8274c7ea824966d05f86bcb113f9b79e381dff95b", base64: """
            KLUv/SQMYQAAZmlyc3QgZnJhbWUKDsLHKlMqTRgFAAAAaGVsbG8otS/9ICMZAQBzZWNvbmQgZnJhbWUgYWZ0ZXIgYSBza2lw
            cGFibGUgb25lCg==
            """),
    ]
}
