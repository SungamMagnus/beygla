import Foundation

/// Minimal MSB-first bit reader over a byte buffer.
struct BitReader {
    let bytes: [UInt8]
    var pos: Int  // in bits

    init(_ d: Data, bitOffset: Int = 0) {
        bytes = [UInt8](d)
        pos = bitOffset
    }

    mutating func read(_ n: Int) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0 ..< n {
            let byteIndex = pos >> 3
            guard byteIndex < bytes.count else { return v }
            let bit = (bytes[byteIndex] >> (7 - UInt8(pos & 7))) & 1
            v = (v << 1) | UInt32(bit)
            pos += 1
        }
        return v
    }
}

/// Minimal MSB-first bit writer.
struct BitWriter {
    private var bits: [UInt8] = []

    mutating func write(_ value: UInt32, _ n: Int) {
        guard n > 0 else { return }
        for i in stride(from: n - 1, through: 0, by: -1) {
            bits.append(UInt8((value >> UInt32(i)) & 1))
        }
    }

    /// Zero-pad to a byte boundary and emit.
    func data() -> Data {
        var padded = bits
        while padded.count % 8 != 0 { padded.append(0) }
        var out = Data(capacity: padded.count / 8)
        var i = 0
        while i < padded.count {
            var b: UInt8 = 0
            for j in 0 ..< 8 { b = (b << 1) | padded[i + j] }
            out.append(b)
            i += 8
        }
        return out
    }
}

public extension MPEG4 {
    /// Parsed just far enough to synthesise a skip frame.
    struct VOLInfo {
        public let timeIncrementResolution: Int
        public let timeIncrementBits: Int
    }

    /// Read `vop_time_increment_resolution` out of the Video Object Layer header.
    ///
    /// Everything before it has to be walked bit by bit because the header is
    /// not byte-aligned and several fields are conditional.
    static func parseVOL(_ payload: Data) -> VOLInfo? {
        // VOL start codes are 0x00000120 ... 0x0000012F.
        var volOffset: Int? = nil
        let bytes = [UInt8](payload)
        if bytes.count >= 4 {
            for i in 0 ..< (bytes.count - 4) {
                if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1,
                   bytes[i + 3] >= 0x20, bytes[i + 3] <= 0x2F {
                    volOffset = i + 4
                    break
                }
            }
        }
        guard let start = volOffset else { return nil }

        var br = BitReader(payload, bitOffset: start * 8)
        _ = br.read(1)                       // random_accessible_vol
        _ = br.read(8)                       // video_object_type_indication
        var verid: UInt32 = 1
        if br.read(1) == 1 {                 // is_object_layer_identifier
            verid = br.read(4)               // video_object_layer_verid
            _ = br.read(3)                   // video_object_layer_priority
        }
        let aspect = br.read(4)              // aspect_ratio_info
        if aspect == 0xF {                   // extended PAR
            _ = br.read(8); _ = br.read(8)
        }
        if br.read(1) == 1 {                 // vol_control_parameters
            _ = br.read(2)                   // chroma_format
            _ = br.read(1)                   // low_delay
            if br.read(1) == 1 {             // vbv_parameters
                _ = br.read(15); _ = br.read(1)   // first_half_bit_rate
                _ = br.read(15); _ = br.read(1)   // latter_half_bit_rate
                _ = br.read(15); _ = br.read(1)   // first_half_vbv_buffer_size
                _ = br.read(3)                    // latter_half_vbv_buffer_size
                _ = br.read(11); _ = br.read(1)   // first_half_vbv_occupancy
                _ = br.read(15); _ = br.read(1)   // latter_half_vbv_occupancy
            }
        }
        let shape = br.read(2)               // video_object_layer_shape
        if shape == 3 && verid != 1 { _ = br.read(4) }
        _ = br.read(1)                       // marker_bit
        let resolution = Int(br.read(16))    // vop_time_increment_resolution
        guard resolution > 0 else { return nil }

        let bits = resolution > 1 ? Int(ceil(log2(Double(resolution)))) : 1
        return VOLInfo(timeIncrementResolution: resolution, timeIncrementBits: max(1, bits))
    }

    /// Build a P-VOP with `vop_coded = 0`.
    ///
    /// This is the only legal way to say "this frame is exactly the previous
    /// one" in MPEG-4 Part 2. It matters because the obvious alternative — a
    /// zero-length AVI chunk — makes the decoder emit no frame at all, and the
    /// output then comes up short. Both forms leave an identically sized hole in
    /// the presentation timeline, which the CFR decode pass refills, but a real
    /// skip VOP keeps the intermediate AVI playable in other tools.
    static func makeSkipVOP(_ vol: VOLInfo) -> Data {
        var w = BitWriter()
        w.write(0x0000_01B6, 32)             // vop_start_code
        w.write(1, 2)                        // vop_coding_type = P
        w.write(0, 1)                        // modulo_time_base terminator
        w.write(1, 1)                        // marker_bit
        w.write(0, vol.timeIncrementBits)    // vop_time_increment
        w.write(1, 1)                        // marker_bit
        w.write(0, 1)                        // vop_coded = 0
        return w.data()
    }
}
