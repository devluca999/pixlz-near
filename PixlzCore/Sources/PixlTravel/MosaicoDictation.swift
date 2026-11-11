import Foundation
import PixlzCore

/// Dictation from a Mosaico (D22): its clip arrives in parts as
/// `{"dictation":{"id","session","part","data"(base64)}}`, then `{"dictation":{"id","session","done":true,"parts"}}`.
/// The audio is IMA ADPCM, 16 kHz mono, low nibble first (mosaico/pixl_trip/pt_adpcm.c).
public struct MosaicoDictation {
    public struct Clip: Sendable { public let id: String; public let session: String; public let samples: [Int16] }
    public static let sampleRate = 16000.0
    /// 30 s of ADPCM at most, plus slack.
    static let maxBytes = 260_000

    private var parts: [String: [Int: Data]] = [:]
    private var sessions: [String: String] = [:]
    public init() {}

    /// Feed a frame. Returns the finished clip when its last part is in.
    public mutating func receive(_ body: Data) -> Clip? {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let d = o["dictation"] as? [String: Any], let id = d["id"] as? String, let session = d["session"] as? String else { return nil }
        sessions[id] = session
        if let part = (d["part"] as? NSNumber)?.intValue, let b64 = d["data"] as? String, let data = Data(base64Encoded: b64) {
            var p = parts[id] ?? [:]
            p[part] = data
            if p.values.reduce(0, { $0 + $1.count }) <= Self.maxBytes { parts[id] = p }
            return nil
        }
        guard d["done"] as? Bool == true, let n = (d["parts"] as? NSNumber)?.intValue, let p = parts.removeValue(forKey: id) else { return nil }
        sessions[id] = nil
        guard p.count == n, (0..<n).allSatisfy({ p[$0] != nil }) else { return nil }   // a part went missing
        let bytes = (0..<n).reduce(into: Data()) { $0.append(p[$1]!) }
        return Clip(id: id, session: session, samples: Self.decode(bytes))
    }

    /// `{"dictation":{"id"}}` frames: is this one?
    public static func isDictation(_ body: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["dictation"] != nil
    }

    static let steps: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88,
        97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
        4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
        18500, 20350, 22385, 24623, 27086, 29794, 32767]
    static let indexTable: [Int32] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    public static func decode(_ bytes: Data) -> [Int16] {
        var predictor: Int32 = 0, index: Int32 = 0
        var out: [Int16] = []
        out.reserveCapacity(bytes.count * 2)
        func step(_ code: UInt8) -> Int16 {
            let st = steps[Int(index)]
            var diff = st >> 3
            if code & 4 != 0 { diff += st }
            if code & 2 != 0 { diff += st >> 1 }
            if code & 1 != 0 { diff += st >> 2 }
            predictor += code & 8 != 0 ? -diff : diff
            predictor = min(32767, max(-32768, predictor))
            index = min(88, max(0, index + indexTable[Int(code & 15)]))
            return Int16(predictor)
        }
        for b in bytes {
            out.append(step(b & 15))
            out.append(step(b >> 4))
        }
        return out
    }

    /// `{"transcript":{"id","session","text"}}`, or with `error` instead of text.
    public static func transcriptBody(id: String, session: String, text: String?, error: String? = nil) -> Data {
        var t: [String: Any] = ["id": id, "session": session]
        if let text { t["text"] = MosaicoFeed.ascii(text, 400) }
        if let error { t["error"] = MosaicoFeed.ascii(error, 79) }
        return (try? JSONSerialization.data(withJSONObject: ["transcript": t], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
