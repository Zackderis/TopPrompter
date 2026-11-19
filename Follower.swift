import Foundation

/// Tracks where you are in the script from live speech-recognition transcripts.
struct ScriptWord {
    let norm: String
    let range: NSRange
}

final class Follower {
    private(set) var words: [ScriptWord] = []
    /// Index of the next word you are expected to say.
    var cursor = 0
    /// What the last feed() decided, for the voice log.
    private(set) var lastNote = ""

    func load(_ text: String) {
        words = Follower.spokenWords(in: text)
        cursor = min(cursor, words.count)
    }

    private static let wordRE = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}'’]*")

    static func tokenize(_ s: String) -> [ScriptWord] {
        let ns = s as NSString
        return wordRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            ScriptWord(norm: norm(ns.substring(with: $0.range)), range: $0.range)
        }
    }

    /// Notes you don't read aloud: anything in [brackets] or (parentheses), and take labels like "Z01".
    private static let directionRE = try! NSRegularExpression(
        pattern: "\\[[^\\]]*\\]|\\([^)]*\\)|(?m)^\\s*[A-Z]{1,3}\\d{1,3}[A-Z]?\\s*$")

    /// Script words you're expected to say (directions removed), with their positions in the full text.
    static func spokenWords(in s: String) -> [ScriptWord] {
        let ns = s as NSString
        let skip = directionRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).map(\.range)
        return tokenize(s).filter { w in !skip.contains { NSLocationInRange(w.range.location, $0) } }
    }

    static func norm(_ w: String) -> String {
        w.lowercased().replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let short = min(a.count, b.count)
        if short >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) && abs(a.count - b.count) <= 3 { return true } // lead/leads
        if short >= 5 && levenshtein(a, b) <= 1 { return true }
        if short >= 8 && levenshtein(a, b) <= 2 { return true }
        return false
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Feed the latest (partial) transcript. Returns true if the cursor moved forward.
    @discardableResult
    func feed(_ transcript: String) -> Bool {
        let spoken = Follower.tokenize(transcript).map(\.norm)
        guard let last = spoken.last, !words.isEmpty else { lastNote = "no words"; return false }
        let tail = Array(spoken.suffix(5))
        let lo = max(0, cursor - 4)
        let hi = min(words.count - 1, cursor + 30)
        guard lo <= hi else { return false }

        var best = -1
        var bestScore = 0.0
        for j in lo...hi where Follower.similar(words[j].norm, last) {
            var s = 1.0
            var k = 1
            while k < tail.count, j - k >= 0 {
                if Follower.similar(words[j - k].norm, tail[tail.count - 1 - k]) { s += 1 } else { break }
                k += 1
            }
            if j > cursor { s -= Double(j - cursor) * 0.03 }   // prefer nearby
            if j < cursor - 1 { s -= 0.1 }                     // slight penalty for going back
            if s > bestScore + 0.001 { bestScore = s; best = j }
        }
        guard best >= 0 else { lastNote = "'\(last)' not found near word \(cursor)"; return false }

        let ahead = best - cursor
        // The very next word needs just itself. Skipping 1–3 words needs 2 in a row (or one long,
        // distinctive word). Bigger jumps (you skipped a line) need 3 words in a row.
        let accept: Bool
        if ahead <= 0 { accept = bestScore >= 0.85 }
        else if ahead <= 3 { accept = bestScore >= 1.8 || (last.count >= 6 && bestScore >= 0.85) }
        else { accept = bestScore >= 2.4 }
        guard accept, best + 1 > cursor else {
            lastNote = accept ? "'\(last)' = word \(best) (already there)"
                              : String(format: "'%@' = word %d, %d ahead, score %.2f too weak", last, best, ahead, bestScore)
            return false
        }
        lastNote = String(format: "'%@' → word %d (%d ahead, score %.2f)", last, best, ahead, bestScore)
        cursor = best + 1
        return true
    }
}
