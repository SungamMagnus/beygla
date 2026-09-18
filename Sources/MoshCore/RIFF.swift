import Foundation

/// Four-character code, stored in file order (little-endian containers still
/// write these as plain ASCII).
public struct FourCC: Hashable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var bytes: (UInt8, UInt8, UInt8, UInt8)

    public init(_ s: String) {
        var b: [UInt8] = Array(s.utf8.prefix(4))
        while b.count < 4 { b.append(0x20) }
        bytes = (b[0], b[1], b[2], b[3])
    }

    public init(stringLiteral value: String) { self.init(value) }

    public init?(_ d: Data) {
        guard d.count >= 4 else { return nil }
        let a = [UInt8](d.prefix(4))
        bytes = (a[0], a[1], a[2], a[3])
    }

    public var data: Data { Data([bytes.0, bytes.1, bytes.2, bytes.3]) }
    public var description: String { String(decoding: [bytes.0, bytes.1, bytes.2, bytes.3], as: UTF8.self) }

    public static func == (l: FourCC, r: FourCC) -> Bool { l.bytes == r.bytes }
    public func hash(into h: inout Hasher) {
        h.combine(bytes.0); h.combine(bytes.1); h.combine(bytes.2); h.combine(bytes.3)
    }
}

public enum RIFFError: Error, LocalizedError {
    case truncated(at: Int)
    case notRIFF
    case missing(String)

    public var errorDescription: String? {
        switch self {
        case .truncated(let at): return "RIFF data truncated at byte \(at)"
        case .notRIFF: return "File is not a RIFF container"
        case .missing(let what): return "RIFF container is missing \(what)"
        }
    }
}

/// A node in a RIFF tree. Either a leaf chunk carrying bytes, or a LIST/RIFF
/// node carrying children.
public indirect enum RIFFNode {
    case chunk(id: FourCC, payload: Data)
    case list(id: FourCC, type: FourCC, children: [RIFFNode])

    public var id: FourCC {
        switch self {
        case .chunk(let id, _): return id
        case .list(let id, _, _): return id
        }
    }

    /// Byte length this node occupies in the file, including its own header
    /// and any trailing pad byte.
    public var encodedSize: Int {
        switch self {
        case .chunk(_, let p):
            return 8 + p.count + (p.count & 1)
        case .list(_, _, let kids):
            let body = kids.reduce(4) { $0 + $1.encodedSize }
            return 8 + body + (body & 1)
        }
    }

    public func firstList(type: FourCC) -> [RIFFNode]? {
        switch self {
        case .chunk: return nil
        case .list(_, let t, let kids):
            if t == type { return kids }
            for k in kids { if let found = k.firstList(type: type) { return found } }
            return nil
        }
    }

    public func firstChunk(id wanted: FourCC) -> Data? {
        switch self {
        case .chunk(let id, let p): return id == wanted ? p : nil
        case .list(_, _, let kids):
            for k in kids { if let found = k.firstChunk(id: wanted) { return found } }
            return nil
        }
    }

    public func allLists(type: FourCC) -> [[RIFFNode]] {
        switch self {
        case .chunk: return []
        case .list(_, let t, let kids):
            var out: [[RIFFNode]] = t == type ? [kids] : []
            for k in kids { out.append(contentsOf: k.allLists(type: type)) }
            return out
        }
    }
}

public enum RIFF {
    /// FourCCs whose payload is itself a list of chunks.
    static let containerIDs: Set<FourCC> = ["RIFF", "LIST"]

    public static func parse(_ data: Data) throws -> RIFFNode {
        var cursor = data.startIndex
        guard let node = try parseNode(data, &cursor) else { throw RIFFError.notRIFF }
        guard case .list(let id, _, _) = node, id == FourCC("RIFF") else { throw RIFFError.notRIFF }
        return node
    }

    private static func parseNode(_ data: Data, _ cursor: inout Data.Index) throws -> RIFFNode? {
        guard cursor + 8 <= data.endIndex else { return nil }
        guard let id = FourCC(data[cursor ..< cursor + 4]) else { return nil }
        let size = Int(readU32(data, cursor + 4))
        let bodyStart = cursor + 8
        // Some muxers write a size that overruns the file (streamed writes that
        // were never patched up). Clamp instead of failing; the movi payload is
        // still recoverable.
        let bodyEnd = min(bodyStart + size, data.endIndex)

        if containerIDs.contains(id) {
            guard bodyStart + 4 <= data.endIndex else { throw RIFFError.truncated(at: bodyStart) }
            guard let type = FourCC(data[bodyStart ..< bodyStart + 4]) else {
                throw RIFFError.truncated(at: bodyStart)
            }
            var inner = bodyStart + 4
            var kids: [RIFFNode] = []
            while inner + 8 <= bodyEnd {
                guard let child = try parseNode(data, &inner) else { break }
                kids.append(child)
            }
            cursor = bodyEnd + (size & 1)
            return .list(id: id, type: type, children: kids)
        } else {
            let payload = data[bodyStart ..< bodyEnd]
            cursor = bodyEnd + (size & 1)
            return .chunk(id: id, payload: Data(payload))
        }
    }

    public static func serialize(_ node: RIFFNode, into out: inout Data) {
        switch node {
        case .chunk(let id, let payload):
            out.append(id.data)
            appendU32(&out, UInt32(payload.count))
            out.append(payload)
            if payload.count & 1 == 1 { out.append(0) }
        case .list(let id, let type, let children):
            let body = children.reduce(4) { $0 + $1.encodedSize }
            out.append(id.data)
            appendU32(&out, UInt32(body))
            out.append(type.data)
            for c in children { serialize(c, into: &out) }
            if body & 1 == 1 { out.append(0) }
        }
    }
}

@inline(__always)
func readU32(_ d: Data, _ at: Data.Index) -> UInt32 {
    guard at + 4 <= d.endIndex else { return 0 }
    return UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
}

@inline(__always)
func appendU32(_ d: inout Data, _ v: UInt32) {
    d.append(UInt8(v & 0xff))
    d.append(UInt8((v >> 8) & 0xff))
    d.append(UInt8((v >> 16) & 0xff))
    d.append(UInt8((v >> 24) & 0xff))
}

@inline(__always)
func writeU32(_ d: inout Data, at: Int, _ v: UInt32) {
    guard at + 4 <= d.count else { return }
    d[d.startIndex + at] = UInt8(v & 0xff)
    d[d.startIndex + at + 1] = UInt8((v >> 8) & 0xff)
    d[d.startIndex + at + 2] = UInt8((v >> 16) & 0xff)
    d[d.startIndex + at + 3] = UInt8((v >> 24) & 0xff)
}
