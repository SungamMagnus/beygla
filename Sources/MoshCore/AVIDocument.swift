import Foundation

/// One video frame as it sits in the AVI's `movi` list: the raw compressed
/// chunk payload plus its decoded picture type.
public struct AVIFrame {
    public var payload: Data
    public var type: MPEG4.VOPType?

    public init(payload: Data) {
        self.payload = payload
        self.type = MPEG4.vopType(of: payload)
    }

    public var isKey: Bool { type == .i }
    public var isDelta: Bool { type == .p || type == .s }
}

public enum AVIError: Error, LocalizedError {
    case noMoviList
    case noStreamHeader
    case noVideoStream
    case containsBFrames

    public var errorDescription: String? {
        switch self {
        case .noMoviList: return "AVI has no movi list"
        case .noStreamHeader: return "AVI has no stream header"
        case .noVideoStream: return "AVI has no video stream"
        case .containsBFrames:
            return "Stream contains B-frames; re-encode with -bf 0 before moshing"
        }
    }
}

/// A video-only MPEG-4 AVI opened for frame surgery.
///
/// The pipeline deliberately keeps audio out of the AVI: the moshed video is
/// muxed back against the untouched original audio at the end, so sync survives
/// whatever we do to the picture.
public final class AVIDocument {
    public private(set) var header: [RIFFNode]      // children of LIST hdrl
    public private(set) var trailing: [RIFFNode]    // anything after movi except idx1
    public var frames: [AVIFrame]
    public let videoChunkID: FourCC
    public let width: Int
    public let height: Int
    public let frameRate: Double

    private static let avihFlagHasIndex: UInt32 = 0x0010

    public init(data: Data) throws {
        let root = try RIFF.parse(data)
        guard let hdrl = root.firstList(type: "hdrl") else { throw AVIError.noStreamHeader }
        guard let movi = root.firstList(type: "movi") else { throw AVIError.noMoviList }

        header = hdrl

        // Pull geometry and rate out of avih / strh.
        let avih = hdrl.compactMap { $0.firstChunk(id: "avih") }.first
        width = avih.map { Int(readU32($0, $0.startIndex + 32)) } ?? 0
        height = avih.map { Int(readU32($0, $0.startIndex + 36)) } ?? 0

        var rate = 30.0
        var foundVideo = false
        for strl in root.allLists(type: "strl") {
            guard let strh = strl.compactMap({ $0.firstChunk(id: "strh") }).first,
                  let fcc = FourCC(strh) else { continue }
            if fcc == FourCC("vids") {
                let scale = Double(readU32(strh, strh.startIndex + 20))
                let r = Double(readU32(strh, strh.startIndex + 24))
                if scale > 0 && r > 0 { rate = r / scale }
                foundVideo = true
            }
        }
        guard foundVideo else { throw AVIError.noVideoStream }
        frameRate = rate

        // Flatten the movi list (some muxers wrap runs of chunks in `rec ` lists)
        // and keep only the video chunks.
        var collected: [AVIFrame] = []
        var chunkID: FourCC? = nil
        func walk(_ nodes: [RIFFNode]) {
            for n in nodes {
                switch n {
                case .list(_, _, let kids): walk(kids)
                case .chunk(let id, let payload):
                    let s = id.description
                    guard s.count == 4 else { continue }
                    let suffix = String(s.dropFirst(2))
                    if suffix == "dc" || suffix == "db" {
                        if chunkID == nil { chunkID = id }
                        collected.append(AVIFrame(payload: payload))
                    }
                }
            }
        }
        walk(movi)

        frames = collected
        videoChunkID = chunkID ?? "00dc"
        trailing = []
    }

    public var frameCount: Int { frames.count }

    /// A synthesised `vop_coded = 0` P-VOP for this stream — the "repeat the
    /// last picture" frame used by freeze and stutter. Derived from the VOL
    /// header carried by the first keyframe.
    public private(set) lazy var skipFrame: AVIFrame = {
        for f in frames where f.isKey {
            if let vol = MPEG4.parseVOL(f.payload) {
                return AVIFrame(payload: MPEG4.makeSkipVOP(vol))
            }
        }
        // No usable VOL: fall back to an empty chunk, which leaves the same
        // gap in the presentation timeline even if it is less well-formed.
        return AVIFrame(payload: Data())
    }()

    public var keyframeIndices: [Int] {
        frames.enumerated().compactMap { $0.element.isKey ? $0.offset : nil }
    }

    public var hasBFrames: Bool { frames.contains { $0.type == .b } }

    /// Serialise back to a playable AVI, rebuilding `idx1` and patching the
    /// frame counts in `avih` / `strh` so players and ffmpeg agree with what is
    /// actually in `movi`.
    public func serialize() -> Data {
        let count = frames.count

        let patchedHeader = header.map { patchCounts(in: $0, totalFrames: UInt32(count)) }

        let moviChildren: [RIFFNode] = frames.map { .chunk(id: videoChunkID, payload: $0.payload) }
        let moviNode = RIFFNode.list(id: "LIST", type: "movi", children: moviChildren)

        // idx1 offsets are measured from the `movi` FourCC, so the first chunk
        // header sits at offset 4.
        var idx = Data()
        idx.reserveCapacity(count * 16)
        var offset = 4
        for f in frames {
            idx.append(videoChunkID.data)
            appendU32(&idx, f.isKey ? 0x0000_0010 : 0)
            appendU32(&idx, UInt32(offset))
            appendU32(&idx, UInt32(f.payload.count))
            offset += 8 + f.payload.count + (f.payload.count & 1)
        }
        let idxNode = RIFFNode.chunk(id: "idx1", payload: idx)

        let hdrlNode = RIFFNode.list(id: "LIST", type: "hdrl", children: patchedHeader)
        let root = RIFFNode.list(id: "RIFF", type: "AVI ", children: [hdrlNode, moviNode, idxNode])

        var out = Data()
        out.reserveCapacity(root.encodedSize)
        RIFF.serialize(root, into: &out)
        return out
    }

    /// Rewrite `dwTotalFrames` in avih and `dwLength` in the video strh.
    private func patchCounts(in node: RIFFNode, totalFrames: UInt32) -> RIFFNode {
        switch node {
        case .chunk(let id, var payload):
            if id == FourCC("avih"), payload.count >= 20 {
                var d = Data(payload)
                writeU32(&d, at: 16, totalFrames)
                var flags = readU32(d, d.startIndex + 12)
                flags |= Self.avihFlagHasIndex
                writeU32(&d, at: 12, flags)
                payload = d
            }
            return .chunk(id: id, payload: payload)
        case .list(let id, let type, let kids):
            var patched: [RIFFNode] = []
            var isVideoStream = false
            for k in kids {
                if case .chunk(let cid, let p) = k, cid == FourCC("strh"),
                   let fcc = FourCC(p), fcc == FourCC("vids") {
                    isVideoStream = true
                }
                patched.append(k)
            }
            if type == FourCC("strl") && isVideoStream {
                patched = patched.map { k in
                    if case .chunk(let cid, let p) = k, cid == FourCC("strh"), p.count >= 36 {
                        var d = Data(p)
                        writeU32(&d, at: 32, totalFrames)
                        return .chunk(id: cid, payload: d)
                    }
                    return patchCounts(in: k, totalFrames: totalFrames)
                }
                return .list(id: id, type: type, children: patched)
            }
            return .list(id: id, type: type, children: patched.map { patchCounts(in: $0, totalFrames: totalFrames) })
        }
    }
}
