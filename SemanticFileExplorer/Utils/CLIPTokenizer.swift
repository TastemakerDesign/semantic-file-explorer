import Foundation

nonisolated final class CLIPTokenizer {
    static let contextLength = 77

    private static let bosToken = "<|startoftext|>"
    private static let eosToken = "<|endoftext|>"
    private static let preTokenizePattern =
        #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|\p{L}+|\p{N}|[^\s\p{L}\p{N}]+"#
    private static let specialPattern = #"<\|startoftext\|>|<\|endoftext\|>"#

    private let vocab: [String: Int32]
    private let ranks: [String: Int]
    private let byteTable: [Character]
    private let suffix: String
    private let unknownID: Int32
    private let preTokenize: NSRegularExpression
    private let special: NSRegularExpression

    private var cache: [String: [Int32]] = [:]

    let bosTokenID: Int32
    let eosTokenID: Int32

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Int],
              let merges = model["merges"] as? [Any] else {
            throw CLIPError.malformedTokenizer
        }
        self.vocab = vocab.mapValues(Int32.init)
        self.suffix = model["end_of_word_suffix"] as? String ?? "</w>"
        self.byteTable = Self.makeByteTable()
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, merge) in merges.enumerated() {
            if let pair = merge as? String {
                ranks[pair] = rank
            } else if let parts = merge as? [String], parts.count == 2 {
                ranks["\(parts[0]) \(parts[1])"] = rank
            }
        }
        self.ranks = ranks
        let added = root["added_tokens"] as? [[String: Any]] ?? []
        func id(of content: String) -> Int32? {
            if let match = added.first(where: { $0["content"] as? String == content }),
               let id = match["id"] as? Int {
                return Int32(id)
            }
            return vocab[content].map(Int32.init)
        }
        guard let bos = id(of: Self.bosToken), let eos = id(of: Self.eosToken) else {
            throw CLIPError.malformedTokenizer
        }
        self.bosTokenID = bos
        self.eosTokenID = eos
        let unknown = model["unk_token"] as? String ?? Self.eosToken
        self.unknownID = id(of: unknown) ?? eos
        self.preTokenize = try NSRegularExpression(pattern: Self.preTokenizePattern)
        self.special = try NSRegularExpression(pattern: Self.specialPattern)
    }

    func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = [bosTokenID]
        for chunk in splitOnSpecialTokens(text) {
            switch chunk {
            case Self.bosToken:
                ids.append(bosTokenID)
            case Self.eosToken:
                ids.append(eosTokenID)
            default:
                let normalized = chunk
                    .precomposedStringWithCanonicalMapping
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .lowercased()
                for word in words(in: normalized) {
                    ids.append(contentsOf: encodeWord(word))
                }
            }
        }
        ids.append(eosTokenID)
        if ids.count > Self.contextLength {
            ids = Array(ids.prefix(Self.contextLength))
            ids[Self.contextLength - 1] = eosTokenID
        } else {
            ids.append(contentsOf: repeatElement(0, count: Self.contextLength - ids.count))
        }
        return ids
    }

    private func splitOnSpecialTokens(_ text: String) -> [String] {
        let full = NSRange(text.startIndex..., in: text)
        let matches = special.matches(in: text, range: full)
        guard !matches.isEmpty else {
            return [text]
        }
        var chunks: [String] = []
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else {
                continue
            }
            if cursor < range.lowerBound {
                chunks.append(String(text[cursor..<range.lowerBound]))
            }
            chunks.append(String(text[range]))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            chunks.append(String(text[cursor...]))
        }
        return chunks
    }

    private func words(in text: String) -> [String] {
        let full = NSRange(text.startIndex..., in: text)
        return preTokenize.matches(in: text, range: full).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private func encodeWord(_ word: String) -> [Int32] {
        if let cached = cache[word] {
            return cached
        }
        let ids = mergeSymbols(in: encodeBytes(of: word)).map { vocab[$0] ?? unknownID }
        cache[word] = ids
        return ids
    }

    private func encodeBytes(of word: String) -> String {
        String(word.utf8.map { byteTable[Int($0)] })
    }

    private func mergeSymbols(in word: String) -> [String] {
        guard !word.isEmpty else {
            return []
        }
        var symbols = word.map(String.init)
        symbols[symbols.count - 1] += suffix
        while symbols.count > 1 {
            var best = Int.max
            var at = -1
            for i in 0..<(symbols.count - 1) {
                if let rank = ranks["\(symbols[i]) \(symbols[i + 1])"], rank < best {
                    best = rank
                    at = i
                }
            }
            guard at >= 0 else {
                break
        }
            symbols.replaceSubrange(at...(at + 1), with: [symbols[at] + symbols[at + 1]])
        }
        return symbols
    }

    private static func makeByteTable() -> [Character] {
        let printable = Set<UInt8>(
            Array(0x21...0x7e) + Array(0xa1...0xac) + Array(0xae...0xff)
        )
        var table: [Character] = []
        table.reserveCapacity(256)
        var next = 0
        for byte in 0...255 {
            if printable.contains(UInt8(byte)) {
                table.append(Character(UnicodeScalar(UInt8(byte))))
            } else {
                table.append(Character(UnicodeScalar(0x100 + next)!))
                next += 1
            }
        }
        return table
    }
}
