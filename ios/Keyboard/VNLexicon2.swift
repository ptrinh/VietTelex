// VNLexicon2.swift — loader cho Resources/vnlexicon.bin (dữ liệu GENERATED bởi
// Scripts/gen-vnlexicon.py, đóng gói nhị phân — KHÔNG sửa tay).
// 7184 âm tiết tiếng Việt (hieuthi 7184 + tần suất OpenSubtitles),
// sort theo foldedKey rồi tần suất giảm dần. attr mỗi ký tự = quality<<3|tone
// (quality: 0 none, 1 â/ê/ô, 2 ơ/ư/ă, 3 đ; tone: 0 ngang 1 sắc 2 huyền 3 hỏi
// 4 ngã 5 nặng). Blob mmap từ bundle (.alwaysMapped) — pages clean/evictable,
// không còn base64 literal chiếm __TEXT.
//
// vnlexicon.bin layout (little-endian):
//   0  "VNL2" | 4 version u32=1 | 8 count u32 | 12 sectionCount u32=6
//   16 sectionCount × (offset u32, length u32) — offset tính từ đầu file
//   sections theo thứ tự: folded, display, attr, offsets, dispOffsets, freqs
import Foundation

enum VNLexicon2Data {
    static let count = 7184

    /// Toàn bộ file resource, memory-mapped — không copy vào dirty memory.
    static let blob: Data = {
        final class BundleToken {}
        guard let url = Bundle(for: BundleToken.self)
                .url(forResource: "vnlexicon", withExtension: "bin"),
              let d = try? Data(contentsOf: url, options: .alwaysMapped)
        else { fatalError("vnlexicon.bin missing from bundle") }
        precondition(d.count > 64, "vnlexicon.bin truncated")
        return d
    }()

    private static func u32(at off: Int) -> Int {
        Int(UInt32(littleEndian: blob.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)
        }))
    }

    /// (offset, length) của section thứ `i` theo header.
    private static func section(_ i: Int) -> (base: Int, len: Int) {
        (u32(at: 16 + i * 8), u32(at: 16 + i * 8 + 4))
    }

    // Section bases — offset byte tuyệt đối trong `blob`. Validate 1 lần.
    static let sections: (folded: Int, foldedLen: Int, display: Int,
                          displayLen: Int, attr: Int, freqs: Int) = {
        precondition(blob.prefix(4).elementsEqual("VNL2".utf8), "bad magic")
        precondition(u32(at: 4) == 1, "bad version")
        precondition(u32(at: 8) == count, "count mismatch")
        precondition(u32(at: 12) == 6, "section count mismatch")
        let f = section(0), d = section(1), a = section(2)
        let o = section(3), oo = section(4), q = section(5)
        precondition(a.len == f.len, "attr/folded length mismatch")
        precondition(o.len == (count + 1) * 4 && oo.len == (count + 1) * 4)
        precondition(q.len == count)
        precondition(q.base + q.len <= blob.count, "sections exceed file")
        return (f.base, f.len, d.base, d.len, a.base, q.base)
    }()

    /// Offsets vào folded/attr (count+1 phần tử) — giải mã một lần, hot path.
    static let offsets: [UInt32] = u32Array(section: 3)
    /// Offsets vào display (count+1 phần tử).
    static let dispOffsets: [UInt32] = u32Array(section: 4)

    private static func u32Array(section i: Int) -> [UInt32] {
        let (base, len) = section(i)
        return blob.withUnsafeBytes { raw in
            (0..<(len / 4)).map {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + $0 * 4,
                                                       as: UInt32.self))
            }
        }
    }

    // MARK: accessors — index như blob cũ (0-based trong từng section)

    static func foldedSlice(_ lo: Int, _ hi: Int) -> Data {
        blob[sections.folded + lo ..< sections.folded + hi]
    }
    static func displaySlice(_ lo: Int, _ hi: Int) -> Data {
        blob[sections.display + lo ..< sections.display + hi]
    }
    static func attr(_ i: Int) -> UInt8 { blob[sections.attr + i] }
    static func freq(_ id: Int) -> UInt8 { blob[sections.freqs + id] }

    static let firstCharTop: [Character: [Int]] = [
        "a": [44, 66, 11, 0, 26, 27, 1, 45, 2, 49, 28, 15, 6, 46, 3, 29, 30, 16, 4, 53, 17, 50, 61, 31, 12, 35, 18, 51, 67, 19, 52, 5],
        "b": [238, 210, 101, 132, 70, 267, 142, 310, 133, 268, 156, 143, 166, 115, 180, 269, 292, 134, 252, 239, 102, 71, 157, 103, 76, 192, 229, 388, 84, 105, 104, 322],
        "c": [883, 980, 836, 884, 703, 932, 497, 433, 878, 653, 933, 422, 1010, 427, 452, 794, 804, 648, 945, 438, 591, 1011, 968, 575, 520, 431, 514, 691, 1018, 805, 885, 873],
        "d": [1306, 1054, 1404, 1667, 1217, 1236, 1140, 1201, 1266, 1218, 1366, 1645, 1646, 1202, 1592, 1685, 1383, 1406, 1405, 1534, 1076, 1535, 1161, 1301, 1237, 1292, 1141, 1572, 1473, 1472, 1343, 1256],
        "e": [1728, 1718, 1719, 1745, 1729, 1726, 1740, 1732, 1741, 1742, 1720, 1724, 1733, 1747, 1730, 1721, 1731, 1748, 1750, 1746, 1743, 1744, 1749, 1722, 1737, 1723, 1725, 1738, 1734, 1739, 1727, 1735],
        "g": [1852, 1939, 1800, 1933, 2005, 1985, 1762, 1856, 1962, 1883, 1971, 1953, 1869, 1779, 1857, 1751, 1954, 1858, 1816, 1974, 1898, 1897, 1859, 1865, 2050, 1788, 1845, 1844, 1914, 1915, 1884, 1909],
        "h": [2240, 2101, 2323, 2154, 2155, 2196, 2224, 2084, 2073, 2115, 2300, 2291, 2232, 2126, 2316, 2213, 2347, 2301, 2270, 2260, 2302, 2074, 2225, 2457, 2324, 2277, 2208, 2162, 2370, 2264, 2423, 2255],
        "i": [2462, 2480, 2473, 2471, 2475, 2464, 2463, 2465, 2468, 2481, 2476, 2469, 2466, 2467, 2478, 2474, 2479, 2482, 2472, 2477, 2470],
        "k": [2721, 2628, 2532, 2704, 2483, 2797, 2523, 2660, 2485, 2484, 2803, 2802, 2717, 2841, 2798, 2831, 2536, 2629, 2733, 2640, 2528, 2817, 2821, 2697, 2679, 2763, 2685, 2514, 2529, 2669, 2842, 2807],
        "l": [2847, 2867, 2859, 2970, 3101, 3199, 2868, 2941, 2880, 3243, 3102, 3279, 2951, 3052, 2933, 3132, 3016, 3145, 3200, 3072, 3198, 2982, 2853, 3030, 2921, 2848, 3248, 3172, 2860, 3183, 3041, 3040],
        "m": [3530, 3582, 3285, 3450, 3368, 3483, 3377, 3484, 3353, 3354, 3369, 3370, 3328, 3459, 3355, 3338, 3567, 3371, 3451, 3297, 3543, 3359, 3485, 3291, 3329, 3360, 3356, 3486, 3286, 3605, 3549, 3515],
        "n": [3991, 3691, 4372, 4348, 3670, 4287, 4256, 4288, 3839, 3734, 4423, 4021, 3809, 3714, 4161, 4089, 3801, 4169, 3802, 3746, 3629, 4051, 3992, 3692, 4052, 4110, 4373, 4095, 3893, 4153, 4075, 4183],
        "o": [4537, 4470, 4527, 4511, 4528, 4512, 4538, 4471, 4472, 4473, 4474, 4539, 4529, 4520, 4504, 4475, 4540, 4530, 4521, 4476, 4513, 4505, 4531, 4550, 4477, 4485, 4493, 4494, 4514, 4478, 4541, 4515],
        "p": [4613, 4750, 4766, 4656, 4628, 4803, 4694, 4720, 4686, 4653, 4775, 4603, 4617, 4710, 4629, 4690, 4795, 4699, 4776, 4630, 4767, 4691, 4768, 4752, 4751, 4631, 4668, 4632, 4618, 4657, 4769, 4777],
        "q": [4862, 4863, 4882, 4920, 4883, 4982, 4876, 4971, 4936, 4864, 4977, 4965, 4906, 4937, 4972, 4884, 4885, 4886, 4865, 4973, 4929, 4897, 4896, 4978, 4974, 4979, 4945, 4975, 4887, 4861, 4921, 4922],
        "r": [5164, 4990, 5053, 5029, 5137, 5278, 5165, 5166, 5116, 5030, 4996, 5167, 5281, 5246, 5195, 5031, 5196, 5138, 5220, 4997, 5017, 5062, 5213, 5070, 5276, 5071, 5072, 5059, 5208, 5221, 5044, 5184],
        "s": [5377, 5347, 5517, 5364, 5497, 5358, 5440, 5410, 5431, 5441, 5333, 5553, 5353, 5319, 5518, 5334, 5300, 5537, 5405, 5298, 5484, 5519, 5572, 5583, 5442, 5443, 5320, 5528, 5365, 5321, 5466, 5299],
        "t": [6158, 5592, 5811, 5812, 6378, 5932, 5847, 5803, 5792, 6159, 5971, 6456, 6201, 6095, 5653, 6099, 6428, 5702, 6285, 5663, 5836, 5605, 5776, 5855, 6116, 5677, 6457, 6074, 6336, 5981, 5933, 5767],
        "u": [6561, 6617, 6562, 6563, 6605, 6633, 6597, 6590, 6581, 6598, 6634, 6632, 6627, 6599, 6571, 6635, 6587, 6600, 6626, 6629, 6618, 6582, 6612, 6631, 6572, 6564, 6588, 6585, 6565, 6619, 6637, 6601],
        "v": [6642, 6812, 6714, 6724, 6698, 6767, 6757, 6664, 6850, 6680, 6868, 6790, 6758, 6654, 6859, 6770, 6665, 6725, 6726, 6835, 6791, 6706, 6851, 6836, 6813, 6778, 6771, 6666, 6860, 6681, 6752, 6890],
        "x": [7016, 6969, 6957, 7146, 6951, 6907, 6901, 7092, 6948, 7119, 7104, 6991, 7120, 6988, 6935, 7021, 6952, 7135, 7136, 7112, 7160, 7147, 7105, 6902, 6916, 7106, 7044, 7061, 7001, 6903, 7078, 6958],
        "y": [7167, 7180, 7168, 7175, 7181, 7172, 7176, 7173, 7182, 7179, 7169, 7170, 7183, 7171, 7177, 7178, 7174],
    ]
}
