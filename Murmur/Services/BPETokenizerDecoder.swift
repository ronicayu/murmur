import Foundation

/// Decodes token IDs produced by the ONNX model back to text strings.
///
/// Supports the HuggingFace BPE tokenizer format used by Cohere Transcribe:
/// - SentencePiece word-boundary marker (▁ → space)
/// - ByteFallback tokens (<0xNN> → raw byte, accumulated and decoded as UTF-8)
/// - Special token filtering (pad, bos, eos, language tags, etc.)
///
/// Only decoding (token IDs → text) is implemented. Encoding is not needed.
final class BPETokenizerDecoder {

    // MARK: - Constants

    /// The SentencePiece word-boundary marker (U+2581 LOWER ONE EIGHTH BLOCK).
    private static let sentencePieceMarker: Character = "▁"

    // MARK: - State

    /// Vocabulary indexed by token ID. Index 0 corresponds to token ID 0.
    private let idToToken: [String]

    /// IDs of tokens that carry no textual content and should be stripped
    /// when `skipSpecialTokens` is true (pad, bos, eos, language tags, etc.).
    private let specialTokenIds: Set<Int>

    // MARK: - Initialisation

    /// Loads the tokenizer from a HuggingFace `tokenizer.json` file.
    ///
    /// - Parameter tokenizerJSONPath: Absolute URL to `tokenizer.json`.
    /// - Throws: If the file cannot be read or the JSON structure is unexpected.
    init(tokenizerJSONPath: URL) throws {
        let data = try Data(contentsOf: tokenizerJSONPath)

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = root["model"] as? [String: Any],
            let vocabDict = model["vocab"] as? [String: Int]
        else {
            throw BPETokenizerError.invalidFormat("model.vocab not found or wrong type")
        }

        // Build a flat array indexed by token ID.
        // vocabDict is {token_string: id}; IDs are 0..<vocabSize (dense).
        let vocabSize = vocabDict.count
        var tokens = [String](repeating: "", count: vocabSize)
        for (token, id) in vocabDict {
            guard id >= 0 && id < vocabSize else {
                throw BPETokenizerError.invalidFormat("Token ID \(id) out of bounds for vocab size \(vocabSize)")
            }
            tokens[id] = token
        }
        self.idToToken = tokens

        // Collect special token IDs from `added_tokens` entries marked special: true.
        var specialIds = Set<Int>()
        if let addedTokens = root["added_tokens"] as? [[String: Any]] {
            for entry in addedTokens {
                if entry["special"] as? Bool == true,
                   let id = entry["id"] as? Int {
                    specialIds.insert(id)
                }
            }
        }
        self.specialTokenIds = specialIds
    }

    // MARK: - Decoding

    /// Converts an array of token IDs to a human-readable string.
    ///
    /// Applies the standard BPE decode pipeline:
    /// 1. Optionally strips special tokens.
    /// 2. Resolves ByteFallback tokens (`<0xNN>`) to raw bytes.
    /// 3. Replaces SentencePiece word-boundary markers (▁) with spaces.
    /// 4. Strips a leading space produced by the first word-initial token.
    ///
    /// - Parameters:
    ///   - tokenIds: Token IDs from the ONNX model (greedy decode output).
    ///   - skipSpecialTokens: When true (default), special tokens are omitted.
    /// - Returns: Decoded text string.
    func decode(_ tokenIds: [Int32], skipSpecialTokens: Bool = true) -> String {
        // Step 1 — resolve each ID to its raw token string, skipping as requested.
        var rawBytes = [UInt8]()
        rawBytes.reserveCapacity(tokenIds.count * 4)

        var pendingBytes = [UInt8]()

        // Flush accumulated byte-fallback bytes as UTF-8, then reset.
        func flushBytes(into output: inout [UInt8]) {
            output.append(contentsOf: pendingBytes)
            pendingBytes.removeAll(keepingCapacity: true)
        }

        for rawId in tokenIds {
            let id = Int(rawId)

            // Ignore out-of-range IDs defensively.
            guard id >= 0 && id < idToToken.count else { continue }

            // Skip special tokens if requested.
            if skipSpecialTokens && specialTokenIds.contains(id) { continue }

            let token = idToToken[id]

            // ByteFallback: token of the form <0xNN>
            if let byte = parseByteFallback(token) {
                pendingBytes.append(byte)
                continue
            }

            // Not a byte token — flush any pending bytes first.
            flushBytes(into: &rawBytes)

            // Replace the SentencePiece word-boundary marker with a space byte.
            // We work in UTF-8 so we can append the result byte-by-byte.
            let replaced = token.replacingOccurrences(
                of: String(BPETokenizerDecoder.sentencePieceMarker),
                with: " "
            )
            rawBytes.append(contentsOf: replaced.utf8)
        }

        // Flush any trailing byte-fallback accumulation.
        flushBytes(into: &rawBytes)

        // Decode the full byte stream as UTF-8 (lossily to handle partial sequences).
        var result = String(bytes: rawBytes, encoding: .utf8)
            ?? String(decoding: rawBytes, as: UTF8.self)

        // Strip leading whitespace that the word-initial ▁ on the first token produces.
        // Use trimming to handle any Unicode whitespace variant.
        while result.first?.isWhitespace == true {
            result.removeFirst()
        }

        return result
    }

    // MARK: - Private Helpers

    /// Returns the byte value if `token` matches the ByteFallback pattern `<0xNN>`,
    /// otherwise returns nil.
    ///
    /// The pattern is always exactly 6 characters: `<`, `0`, `x`, two hex digits, `>`.
    private func parseByteFallback(_ token: String) -> UInt8? {
        // Fast path: check length before allocating.
        guard token.count == 6 else { return nil }

        let scalars = token.unicodeScalars
        var it = scalars.makeIterator()

        guard
            it.next()?.value == UInt32(("<" as UnicodeScalar).value),
            it.next()?.value == UInt32(("0" as UnicodeScalar).value),
            it.next()?.value == UInt32(("x" as UnicodeScalar).value)
        else { return nil }

        // Extract the two hex digits.
        guard
            let hi = it.next().flatMap({ hexValue($0) }),
            let lo = it.next().flatMap({ hexValue($0) }),
            it.next()?.value == UInt32((">" as UnicodeScalar).value)
        else { return nil }

        return UInt8((hi << 4) | lo)
    }

    /// Maps a Unicode scalar to its hexadecimal digit value (0–15),
    /// or nil if it is not a valid hex digit.
    private func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)        // '0'–'9'
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)   // 'A'–'F'
        case 0x61...0x66: return UInt8(scalar.value - 0x61 + 10)   // 'a'–'f'
        default: return nil
        }
    }
}

// MARK: - Errors

enum BPETokenizerError: Error, LocalizedError {
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let message):
            return "BPETokenizerDecoder: invalid tokenizer.json — \(message)"
        }
    }
}
