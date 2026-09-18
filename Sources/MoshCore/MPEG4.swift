import Foundation

/// MPEG-4 Part 2 (ASP) bitstream picking, just enough of it to tell frame
/// types apart. Datamoshing lives or dies on this classification: an I-VOP
/// carries a whole picture, a P-VOP carries only motion vectors and residuals,
/// and the whole craft is about feeding P-VOPs to pixels they were never meant
/// to describe.
public enum MPEG4 {
    public enum VOPType: UInt8, CustomStringConvertible {
        case i = 0, p = 1, b = 2, s = 3

        public var description: String {
            switch self {
            case .i: return "I"
            case .p: return "P"
            case .b: return "B"
            case .s: return "S"
            }
        }
    }

    /// Start codes we care about.
    static let vopStart: [UInt8] = [0x00, 0x00, 0x01, 0xB6]
    static let vosStart: [UInt8] = [0x00, 0x00, 0x01, 0xB0]
    static let govStart: [UInt8] = [0x00, 0x00, 0x01, 0xB3]

    /// Classify one AVI video chunk payload.
    ///
    /// Returns nil when the payload holds no VOP header at all — that happens
    /// for AVI "drop frames" (zero-length chunks) which repeat the previous
    /// picture and must be passed through untouched.
    public static func vopType(of payload: Data) -> VOPType? {
        guard let idx = find(vopStart, in: payload), idx + 4 < payload.endIndex else { return nil }
        let b = payload[idx + 4]
        return VOPType(rawValue: (b >> 6) & 0x03)
    }

    /// True when the chunk carries a sequence/GOV header. ffmpeg emits these
    /// immediately before every I-VOP, so their presence marks a "hard" restart
    /// point that a decoder can seek to.
    public static func hasSequenceHeader(_ payload: Data) -> Bool {
        find(vosStart, in: payload) != nil || find(govStart, in: payload) != nil
    }

    /// Strip any leading VOS/VO/VOL/GOV headers, leaving the bare VOP. Used when
    /// a keyframe's picture data is discarded but its headers must not be, or
    /// when duplicating a frame that should not re-announce the sequence.
    public static func strippingHeaders(_ payload: Data) -> Data {
        guard let idx = find(vopStart, in: payload) else { return payload }
        return Data(payload[idx...])
    }

    static func find(_ pattern: [UInt8], in data: Data, from: Data.Index? = nil) -> Data.Index? {
        guard !data.isEmpty, pattern.count <= data.count else { return nil }
        let start = from ?? data.startIndex
        guard start < data.endIndex else { return nil }
        let last = data.endIndex - pattern.count
        guard start <= last else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data.Index? in
            let base = raw.bindMemory(to: UInt8.self)
            let off = start - data.startIndex
            let lastOff = last - data.startIndex
            var i = off
            while i <= lastOff {
                if base[i] == pattern[0] {
                    var match = true
                    for j in 1 ..< pattern.count where base[i + j] != pattern[j] {
                        match = false
                        break
                    }
                    if match { return data.startIndex + i }
                }
                i += 1
            }
            return nil
        }
    }
}
