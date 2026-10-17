// Mac 시스템 소리 → 7채널(FL FR C SL SR HL HR) snapserver pipe (7단계 2026-10-08, 8단계 Atmos 2026-10-09)
//
// 입력 두 가지:
//  1) 기본: 가상 오디오 드라이버 없이 Core Audio process tap(macOS 14.2+)으로 Mac 전체 출력(스테레오)을 받는다.
//     tap이 켜진 동안 Mac 스피커는 조용하다(mutedWhenTapped). 스테레오는 넓게 펼쳐(upmix) 7채널로.
//  2) --device 이름: 다채널 가상 장치(SpatialPhones 12ch = BlackHole 7.1.4 빌드)의 입력을 받는다.
//     이 장치를 Mac 기본 출력으로 두면 Apple Music이 돌비 Atmos를 장치의 스피커 배치(7.1.4)로 렌더링해 내보낸다.
//     채널 이름(장치가 알려 주는 label)으로 7채널에 매핑하고, 지금 없는 폰의 채널은 가까운 폰에 섞는다.
//     L/R 말고 다른 채널이 전부 0이면(스테레오 앱·일반 곡) 1)과 같은 upmix로 자동 전환한다.
//     음량·음소거는 장치가 직접 적용하므로(BlackHole) 여기서는 Mac 볼륨을 따로 곱하지 않는다.
//
// 시계 문제: 입력은 Mac 출력/가상 장치 시계로, snapserver는 pipe를 자기 steady clock(= mach 시계)으로 읽는다.
// 두 시계는 수십 ppm 다르므로 그대로 쓰면 pipe가 점점 차거나 비어 전체가 함께 밀린다.
// → 받은 소리를 링 버퍼에 두고, 쓰기는 mach 시계 기준 정확히 48000 frame/s(fanout과 같은 방식),
//   링 버퍼 양이 목표(기본 100 ms)에 머물도록 리샘플 비율을 PI 제어로 아주 조금씩(최대 ±500 ppm) 바꾼다.
//
// 사용법: sysbridge --out /tmp/snap_7ch [--preset desk.json] [--active FL,FR,C,SL] [--ahead-ms 60]
//         [--fill-ms 100] [--no-mute] [--fixed-volume] [--seconds N] [--device SpatialPhones [--keep-output]]
//         Mac 볼륨 키 = 전체 음량(--fixed-volume이면 무시), 프리셋 파일을 고치면 재생 중 바로 반영
//         (ahead 기본 60 ms: pipe 용량보다 크면 write가 계속 막힘)
//         --device: 시작할 때 그 장치를 Mac 기본 출력으로 바꾸고 끝날 때 원래대로 (--keep-output이면 안 바꿈)
//         sysbridge --selftest [--skew-ppm 80] [--src-rate 44100] [--out 파일]   (장치 없이 제어·리샘플 확인)
//         sysbridge --selftest-map [--active FL,FR,C,SL]   (7.1.4 → 7채널 매핑·스테레오 자동 전환 확인)
import CoreAudio
import AudioToolbox
import Foundation

let NAMES = ["FL", "FR", "C", "SL", "SR", "HL", "HR"]
let OUT_RATE = 48000.0
let NCH = 7

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - 설정

struct Options {
    var out = "/tmp/snap_7ch"
    var preset: String? = nil
    var active: [String] = NAMES
    var aheadMs = 60.0     // 7채널 16 bit에서 macOS pipe 64 KiB ≈ 97 ms보다 작게
    var fillMs = 100.0
    var mute = true
    var followVolume = true
    var seconds: Double? = nil
    var selftest = false
    var selftestMap = false
    var skewPpm = 80.0
    var srcRate = 44100.0
    var device: String? = nil
    var keepOutput = false
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func next(_ flag: String) -> String {
        guard let v = it.next() else { fail("\(flag) 값이 없습니다") }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--out": o.out = next(a)
        case "--preset": o.preset = next(a)
        case "--active": o.active = next(a).split(separator: ",").map { String($0) }
        case "--ahead-ms": o.aheadMs = Double(next(a)) ?? o.aheadMs
        case "--fill-ms": o.fillMs = Double(next(a)) ?? o.fillMs
        case "--no-mute": o.mute = false
        case "--fixed-volume": o.followVolume = false
        case "--seconds": o.seconds = Double(next(a))
        case "--selftest": o.selftest = true
        case "--selftest-map": o.selftestMap = true
        case "--skew-ppm": o.skewPpm = Double(next(a)) ?? o.skewPpm
        case "--src-rate": o.srcRate = Double(next(a)) ?? o.srcRate
        case "--device": o.device = next(a)
        case "--keep-output": o.keepOutput = true
        default: fail("알 수 없는 옵션: \(a)")
        }
    }
    for n in o.active where !NAMES.contains(n) { fail("채널 이름은 \(NAMES): \(n)") }
    return o
}

/// 청취 위치 프리셋: 채널별 지연(ms, 0 이상)과 음량(dB). calib가 만든 JSON
/// {"delay_ms": {"FL": 0.42, ...}, "gain_db": {"FL": -1.5, ...}}
struct Preset {
    var delaySamples = [Int](repeating: 0, count: NCH)
    var gain = [Float](repeating: 1, count: NCH)
    var text = "없음"

    init() {}
    init(path: String) {
        guard let p = Preset(tryPath: path) else { fail("프리셋을 읽지 못했습니다: \(path)") }
        self = p
    }
    /// 읽기 실패(쓰는 중인 파일 등)면 nil
    init?(tryPath path: String) {
        guard let d = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let delays = j["delay_ms"] as? [String: Double] ?? [:]
        let gains = j["gain_db"] as? [String: Double] ?? [:]
        var parts: [String] = []
        for (k, n) in NAMES.enumerated() {
            let ms = max(0, delays[n] ?? 0)
            delaySamples[k] = Int((ms * OUT_RATE / 1000).rounded())
            gain[k] = Float(pow(10, (gains[n] ?? 0) / 20))
            if delays[n] != nil || gains[n] != nil {
                parts.append(String(format: "%@ %+.2f ms %+.1f dB", n, ms, gains[n] ?? 0))
            }
        }
        text = parts.joined(separator: ", ")
    }
}

// MARK: - 입력 채널 이름 → 7채널 매핑

/// Core Audio 채널 label(AudioChannelLabel)의 짧은 이름 (상태 줄용)
func labelName(_ l: UInt32) -> String {
    switch l {
    case 1: return "L"; case 2: return "R"; case 3: return "C"; case 4: return "LFE"
    case 5: return "Ls"; case 6: return "Rs"; case 7: return "Lc"; case 8: return "Rc"; case 9: return "Cs"
    case 10: return "Lsd"; case 11: return "Rsd"; case 12: return "Ts"
    case 13: return "Vhl"; case 14: return "Vhc"; case 15: return "Vhr"
    case 16: return "Tbl"; case 17: return "Tbc"; case 18: return "Tbr"
    case 33: return "Rls"; case 34: return "Rrs"; case 35: return "Lw"; case 36: return "Rw"; case 37: return "LFE2"
    case 49: return "Ltm"; case 50: return "Ctm"; case 51: return "Rtm"
    case 52: return "Ltr"; case 53: return "Ctr"; case 54: return "Rtr"; case 55: return "Lss"; case 56: return "Rss"
    default: return "#\(l)"
    }
}

/// 입력 채널이 원래 가야 할 7채널(FL0 FR1 C2 SL3 SR4 HL5 HR6)과 비율. LFE는 폰이 못 내는 저음이라 버린다.
func baseTargets(_ l: UInt32) -> [(Int, Float)] {
    let h: Float = 0.7071
    switch l {
    case 1, 7, 35: return [(0, 1)]                      // L, 왼쪽 가운데, 왼쪽 와이드
    case 2, 8, 36: return [(1, 1)]
    case 3: return [(2, 1)]
    case 5, 10, 33, 55: return [(3, 1)]                 // 왼쪽 서라운드 / 뒤 서라운드
    case 6, 11, 34, 56: return [(4, 1)]
    case 9: return [(3, h), (4, h)]                     // 뒤 가운데
    case 13, 16, 49, 52: return [(5, 1)]                // 왼쪽 천장 (앞·가운데·뒤)
    case 15, 18, 51, 54: return [(6, 1)]
    case 12, 14, 17, 50, 53: return [(5, h), (6, h)]    // 천장 가운데
    default: return []                                  // LFE(4, 37) 등
    }
}

/// 폰이 없는 채널을 보낼 곳: 같은 쪽 앞 폰, 앞이 없으면 가운데 (−3 dB씩)
let FALLBACK: [[Int]] = [[2], [2], [0, 1], [0], [1], [0], [1]]

func resolve(_ o: Int, _ active: [Bool], _ seen: Set<Int> = []) -> [(Int, Float)] {
    if active[o] { return [(o, 1)] }
    var r: [(Int, Float)] = []
    for t in FALLBACK[o] where !seen.contains(t) {
        for (u, g) in resolve(t, active, seen.union([o])) { r.append((u, g * 0.7071)) }
    }
    return r
}

/// 입력 label 목록 → 출력 7채널별 [(입력 index, gain)]. 같은 출력에 입력이 여럿이면 1/√n로 줄인다.
func buildMatrix(labels: [UInt32], active: [Bool]) -> [[(Int, Float)]] {
    var perOut = [[(Int, Float)]](repeating: [], count: NCH)
    for (c, l) in labels.enumerated() { for (o, g) in baseTargets(l) { perOut[o].append((c, g)) } }
    for o in 0..<NCH where perOut[o].count > 1 {
        let s = 1 / Float(perOut[o].count).squareRoot()
        perOut[o] = perOut[o].map { ($0.0, $0.1 * s) }
    }
    var m = [[Float]](repeating: [Float](repeating: 0, count: labels.count), count: NCH)
    for o in 0..<NCH { for (c, g) in perOut[o] { for (u, gu) in resolve(o, active) { m[u][c] += g * gu } } }
    return m.map { row in row.enumerated().compactMap { $0.element != 0 ? ($0.offset, $0.element) : nil } }
}

func matrixText(_ m: [[(Int, Float)]], labels: [UInt32]) -> String {
    NAMES.enumerated().map { o, n in
        let src = m[o].map { String(format: "%@×%.2f", labelName(labels[$0.0]), $0.1) }
        return "\(n) ← " + (src.isEmpty ? "(없음)" : src.joined(separator: " + "))
    }.joined(separator: "\n  ")
}

// MARK: - 링 버퍼 (N채널 float, 입력 콜백 → 쓰기 스레드)

final class Ring {
    let nch: Int
    private var buf: [Float]
    private let cap: Int          // frame 단위
    private var w = 0             // 누적 쓴 frame
    private var r = 0             // 누적 읽은(버린) frame
    private var lock = os_unfair_lock()
    private(set) var overflows = 0
    // 진단: 콜백 수·최대 간격·한 번에 온 frame 수 (stats 줄에서 출력 후 초기화)
    var cbCount = 0, cbMaxGap = 0.0, cbMaxFrames = 0, cbMinFrames = Int.max
    private var cbLast = 0.0

    init(frames: Int, channels: Int) { cap = frames; nch = channels; buf = [Float](repeating: 0, count: frames * channels) }

    /// Core Audio 버퍼 목록(interleaved 하나 또는 채널별 여러 개). 채널이 모자라면(모노) 첫 채널로 채운다.
    func push(_ abl: UnsafeMutableAudioBufferListPointer) {
        var frames = Int.max
        for b in abl { frames = min(frames, Int(b.mDataByteSize) / 4 / max(1, Int(b.mNumberChannels))) }
        guard frames != Int.max, frames > 0 else { return }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        note(frames)
        for i in 0..<frames {
            let j = (w % cap) * nch
            var c = 0
            for b in abl {
                let ch = max(1, Int(b.mNumberChannels))
                if let p = b.mData?.assumingMemoryBound(to: Float.self) {
                    for k in 0..<ch where c + k < nch { buf[j + c + k] = p[i * ch + k] }
                }
                c += ch
            }
            while c < nch { buf[j + c] = buf[j]; c += 1 }
            w += 1
        }
        if w - r > cap { overflows += 1; r = w - cap / 2 }
    }

    /// interleaved nch채널 (자체 시험용)
    func push(interleaved p: UnsafePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        note(frames)
        for i in 0..<frames {
            let j = (w % cap) * nch
            for c in 0..<nch { buf[j + c] = p[i * nch + c] }
            w += 1
        }
        if w - r > cap { overflows += 1; r = w - cap / 2 }
    }

    private func note(_ frames: Int) {
        let now = monotonic()
        if cbLast > 0 { cbMaxGap = max(cbMaxGap, now - cbLast) }
        cbLast = now; cbCount += 1; cbMaxFrames = max(cbMaxFrames, frames); cbMinFrames = min(cbMinFrames, frames)
    }

    var available: Int { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return w - r }

    /// 읽기 위치 r 기준 상대 frame k의 채널 c. 호출자가 available 안쪽만 묻는다.
    @inline(__always) func peek(_ k: Int, _ c: Int) -> Float { buf[((r + k) % cap) * nch + c] }
    func withLock<T>(_ f: () -> T) -> T { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return f() }
    func availableUnlocked() -> Int { w - r }
    func dropUnlocked(_ n: Int) { r += min(n, w - r) }
    func resetUnlocked() { r = w }
}

// MARK: - 리샘플 + 매핑/업믹스 + 프리셋

final class Bridge {
    let ring: Ring
    let srcRate: Double
    let fillTarget: Double       // 소스 frame
    var frac = 0.0               // 링 읽기 위치의 소수부
    var ratio: Double            // 출력 1 frame당 소스 frame
    var integ = 0.0
    var fillAvg: Double
    var started = false
    var underruns = 0
    var minAvail = Int.max
    var ppm: Double { (ratio / (srcRate / OUT_RATE) - 1) * 1e6 }
    private(set) var preset: Preset
    let activeMask: [Bool]
    var master: Float = 1        // 전체 음량 목표 (Mac 볼륨을 따라감)
    var masterNow: Float = 1     // 실제 적용값 (딸깍 소리 없게 천천히 따라감)
    // 프리셋 지연용 채널별 지연선
    var hist: [[Float]]
    var histPos = 0
    var peak: Float = 0
    var ambPrev = [Float](repeating: 0, count: 600)   // 서라운드 성분 12.5 ms 지연선 (600 frame @48k)
    var ambPos = 0
    // 다채널 입력
    let labels: [UInt32]
    let matrix: [[(Int, Float)]]
    let li: Int, ri: Int         // 업믹스에 쓸 L, R 입력 index
    let others: [Int]            // L/R 말고 다른 입력 (하나라도 0이 아니면 다채널 모드)
    var quietFrames = Int.max / 2
    let stereoHold = Int(OUT_RATE * 1.5)   // 다른 채널이 1.5 s 동안 0이면 스테레오 모드로
    var mix: Float = 0           // 0 = 스테레오 업믹스, 1 = 다채널 매핑 (약 40 ms에 걸쳐 바뀜)
    private(set) var discrete = false
    var inPeak: [Float]

    init(srcRate: Double, labels: [UInt32] = [1, 2], fillMs: Double, preset: Preset, active: [String]) {
        self.srcRate = srcRate
        self.labels = labels
        ring = Ring(frames: Int(srcRate * 2), channels: labels.count)
        fillTarget = srcRate * fillMs / 1000
        ratio = srcRate / OUT_RATE
        fillAvg = fillTarget
        self.preset = preset
        activeMask = NAMES.map { active.contains($0) }
        matrix = buildMatrix(labels: labels, active: activeMask)
        let l = labels.firstIndex(of: 1) ?? 0, r = labels.firstIndex(of: 2) ?? min(1, labels.count - 1)
        li = l; ri = r
        others = labels.indices.filter { $0 != l && $0 != r }
        inPeak = [Float](repeating: 0, count: labels.count)
        hist = []
        setPreset(preset)
    }

    /// 프리셋 교체 (재생 중 파일이 바뀌었을 때). 지연선은 새로 만든다 (바뀌는 순간 짧게 끊길 수 있음).
    func setPreset(_ p: Preset) {
        ring.withLock {
            preset = p
            let maxD = (p.delaySamples.max() ?? 0) + 1
            hist = [[Float]](repeating: [Float](repeating: 0, count: maxD), count: NCH)
        }
    }

    /// 4점 Hermite 보간
    @inline(__always) func hermite(_ x0: Float, _ x1: Float, _ x2: Float, _ x3: Float, _ t: Float) -> Float {
        let c0 = x1, c1 = 0.5 * (x2 - x0)
        let c2 = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3
        let c3 = 0.5 * (x3 - x0) + 1.5 * (x1 - x2)
        return ((c3 * t + c2) * t + c1) * t + c0
    }

    /// 스테레오 → 7채널. 지금 있는 폰만 소리(activeMask), 없는 채널은 0.
    /// FL/FR = L/R, C = (L+R)/2·0.7, 서라운드·높이 = 차 성분(L−R)/2를 12.5 ms 늦춰 (SR·HR은 부호 반대).
    @inline(__always) func upmix(_ l: Float, _ r: Float, into o: inout [Float]) {
        let side = 0.5 * (l - r)
        let amb = ambPrev[ambPos]
        ambPrev[ambPos] = side
        ambPos = (ambPos + 1) % ambPrev.count
        o[0] = l; o[1] = r; o[2] = 0.35 * (l + r)
        o[3] = 0.8 * amb; o[4] = -0.8 * amb
        o[5] = 0.5 * amb; o[6] = -0.5 * amb
    }

    /// 출력 n frame을 만들어 Int16 7채널 interleaved로 out에 덧붙인다.
    func render(_ n: Int, dt: Double, into out: inout [Int16]) {
        // 1) 제어: 링 양을 목표에 맞춘다 (dt = 이번 회차 실제 경과 초)
        let avail = Double(ring.available)
        if started { minAvail = min(minAvail, Int(avail)) }
        if !started {
            if avail >= fillTarget { started = true; fillAvg = avail }
        } else {
            let a = min(1.0, dt / 2.0)                 // 약 2 s 평균
            fillAvg += a * (avail - fillAvg)
            let err = (fillAvg - fillTarget) / srcRate // 초. +면 링이 넘침 → 소스를 더 빨리 소비
            integ += err * dt
            integ = max(-0.5, min(0.5, integ))
            let corr = max(-500e-6, min(500e-6, 0.05 * err + 6e-4 * integ))   // ζ≈1, 시정수 약 40 s
            ratio = srcRate / OUT_RATE * (1 + corr)
        }
        let nin = labels.count
        var inp = [Float](repeating: 0, count: nin)
        var up = [Float](repeating: 0, count: NCH)
        var frame = [Float](repeating: 0, count: NCH)
        out.reserveCapacity(out.count + n * NCH)
        ring.withLock {
            for _ in 0..<n {
                for c in 0..<nin { inp[c] = 0 }
                if started {
                    if ring.availableUnlocked() < 4 {
                        underruns += 1; started = false; frac = 0; ring.resetUnlocked()
                    } else {
                        let t = Float(frac)
                        for c in 0..<nin {
                            inp[c] = hermite(ring.peek(0, c), ring.peek(1, c), ring.peek(2, c), ring.peek(3, c), t)
                            inPeak[c] = max(inPeak[c], abs(inp[c]))
                        }
                        frac += ratio
                        let whole = Int(frac); frac -= Double(whole)
                        ring.dropUnlocked(whole)
                    }
                }
                // 다채널/스테레오 판정: L/R 말고 다른 채널에 소리가 있으면 다채널 매핑
                var any = false
                for c in others where inp[c] != 0 { any = true; break }
                quietFrames = any ? 0 : quietFrames + 1
                discrete = quietFrames < stereoHold
                mix += ((discrete ? 1 : 0) - mix) * 0.0005
                upmix(inp[li], inp[ri], into: &up)
                for o in 0..<NCH {
                    var d: Float = 0
                    for (c, g) in matrix[o] { d += g * inp[c] }
                    frame[o] = mix * d + (1 - mix) * up[o]
                }
                masterNow += (master - masterNow) * 0.0005      // 약 40 ms에 걸쳐
                for c in 0..<NCH {
                    var v = activeMask[c] ? frame[c] * preset.gain[c] * masterNow : 0
                    let d = preset.delaySamples[c]
                    if d > 0 {
                        let h = hist[c].count
                        hist[c][histPos % h] = v
                        v = hist[c][(histPos - d + h * 4) % h]
                    }
                    peak = max(peak, abs(v))
                    out.append(Int16(max(-32767, min(32767, (v * 32767).rounded()))))
                }
                histPos += 1
            }
        }
    }
}

// MARK: - pipe 쓰기 (fanout.py와 같은 규칙: O_RDWR로 열고 4 KB 조각)

func openFifo(_ path: String) -> Int32 {
    var st = stat()
    if stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFIFO { return open(path, O_RDWR) }
    return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
}

func writeAll(_ fd: Int32, _ samples: [Int16]) {
    samples.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, min(4096, raw.count - off))
            if n < 0 { if errno == EINTR { continue }; fail("pipe 쓰기 실패: errno \(errno)") }
            off += n
        }
    }
}

func monotonic() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_UPTIME_RAW, &ts)   // mach_absolute_time과 같은 시계 (snapserver steady_clock)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
}

func dbText(_ v: Float) -> String { v > 0 ? String(format: "%.0f", 20 * log10(v)) : "-" }

/// 쓰기 루프: 실시간 + ahead만큼 앞서, 5 ms마다 모자란 만큼 만든다.
func writerLoop(_ b: Bridge, fd: Int32?, aheadMs: Double, seconds: Double?, clock: () -> Double,
                sleep: (Double) -> Void, tick: ((Double) -> Void)? = nil, stats: Bool = true) {
    let t0 = clock()
    var written = 0
    var last = t0
    var lastStat = t0
    var buf: [Int16] = []
    var maxN = 0
    var lastMode: Bool? = nil
    while true {
        let now = clock()
        if let s = seconds, now - t0 >= s { break }
        tick?(now)
        let target = Int(((now - t0) + aheadMs / 1000) * OUT_RATE)
        // 20 ms씩 만들고 쓴다. 한 번에 크게 만들면(pipe가 차서 write가 오래 막힌 뒤) 링을 한꺼번에 비워
        // 끊김이 난다 (2026-10-08 실측: ahead 150 ms > 7채널 pipe 용량 약 97 ms → 1회 222 ms, 초당 1회 끊김).
        var n = target - written
        if n > 0 { maxN = max(maxN, n) }
        while n > 0 {
            let m = min(n, Int(OUT_RATE / 50))
            let t = clock()
            buf.removeAll(keepingCapacity: true)
            b.render(m, dt: t - last, into: &buf)
            last = t
            if let fd = fd { writeAll(fd, buf) }
            written += m
            n -= m
        }
        if stats && b.labels.count > 2 && b.discrete != lastMode {
            lastMode = b.discrete
            print(b.discrete ? "입력: 다채널(Atmos 등) → 채널별로 폰에" : "입력: 스테레오 → 넓게 펼쳐서 폰에")
        }
        if stats && now - lastStat >= 10 {
            lastStat = now
            let db = b.peak > 0 ? 20 * log10(b.peak) : -120
            print(String(format: "%6.0f s  링 %5.1f ms (목표 %.0f)  보정 %+6.1f ppm  최대 %5.1f dBFS  끊김 %d  넘침 %d",
                         now - t0, b.fillAvg / b.srcRate * 1000, b.fillTarget / b.srcRate * 1000, b.ppm, db,
                         b.underruns, b.ring.overflows))
            b.ring.withLock {
                print(String(format: "        콜백 %d회 최대간격 %.1f ms, frame %d~%d, 최소 링 %.1f ms, 1회 최대 출력 %d",
                             b.ring.cbCount, b.ring.cbMaxGap * 1000, b.ring.cbMinFrames == Int.max ? 0 : b.ring.cbMinFrames,
                             b.ring.cbMaxFrames, b.minAvail == Int.max ? -1 : Double(b.minAvail) / b.srcRate * 1000, maxN))
                b.ring.cbCount = 0; b.ring.cbMaxGap = 0; b.ring.cbMaxFrames = 0; b.ring.cbMinFrames = Int.max
                if b.labels.count > 2 {
                    print("        입력 최대 dBFS: " + b.labels.enumerated().map { "\(labelName($0.element)) \(dbText(b.inPeak[$0.offset]))" }
                        .joined(separator: "  ") + (b.discrete ? "  [다채널]" : "  [스테레오]"))
                    for c in b.inPeak.indices { b.inPeak[c] = 0 }
                }
            }
            b.minAvail = Int.max; maxN = 0
            fflush(stdout)
            b.peak = 0
        }
        sleep(0.005)
    }
}

// MARK: - 자체 시험: 가짜 시계로 소스가 skew만큼 빠르거나 느릴 때 링이 목표에 수렴하는지

func selftest(_ o: Options) -> Never {
    let b = Bridge(srcRate: o.srcRate, fillMs: o.fillMs, preset: o.preset.map { Preset(path: $0) } ?? Preset(), active: o.active)
    var vt = 0.0
    var srcPos = 0.0
    let srcTrue = o.srcRate * (1 + o.skewPpm * 1e-6)
    let blk = 512
    var phase = 0.0
    var chunk = [Float](repeating: 0, count: blk * 2)
    var samples: [(Double, Double, Double)] = []
    let dump: Int32? = o.out == Options().out ? nil : openFifo(o.out)   // --out 파일이면 출력 저장(음질 확인용)
    writerLoop(b, fd: dump, aheadMs: o.aheadMs, seconds: dump == nil ? 600 : 20, clock: { vt }, sleep: { vt += $0 },
               tick: { now in
                   // 소스(tap)는 자기 시계로 512 frame씩 도착
                   while srcPos + Double(blk) <= now * srcTrue {
                       for i in 0..<blk {
                           let v = Float(0.5 * sin(phase)); phase += 2 * .pi * 1000 / o.srcRate
                           chunk[2 * i] = v; chunk[2 * i + 1] = v
                       }
                       chunk.withUnsafeBufferPointer { b.ring.push(interleaved: $0.baseAddress!, frames: blk) }
                       srcPos += Double(blk)
                   }
                   if Int(now * 200) % 2000 == 0 { samples.append((now, b.fillAvg / o.srcRate * 1000, b.ppm)) }
               }, stats: false)
    for (t, f, p) in samples where Int(t) % 60 == 0 { print(String(format: "t=%4.0f s  링 %6.1f ms  보정 %+7.1f ppm", t, f, p)) }
    let ok = abs(b.ppm - o.skewPpm) < 2 && abs(b.fillAvg / o.srcRate * 1000 - o.fillMs) < 5 && b.underruns == 0 && b.ring.overflows == 0
    print(String(format: "selftest: 소스 skew %+.1f ppm → 보정 %+.1f ppm, 링 %.1f ms, 끊김 %d, 넘침 %d → %@",
                 o.skewPpm, b.ppm, b.fillAvg / o.srcRate * 1000, b.underruns, b.ring.overflows, ok ? "PASS" : "FAIL"))
    exit(ok ? 0 : 1)
}

/// 7.1.4 입력에서 채널 하나씩 소리를 넣어 어느 출력으로 가는지, 스테레오만 오면 업믹스로 바뀌는지 확인
func selftestMap(_ o: Options) -> Never {
    let labels: [UInt32] = [1, 2, 3, 4, 5, 6, 33, 34, 13, 15, 52, 54]   // SpatialPhones 12ch 배치
    let active = NAMES.map { o.active.contains($0) }
    let m = buildMatrix(labels: labels, active: active)
    print("소리 내는 폰: \(o.active.joined(separator: ","))\n  " + matrixText(m, labels: labels))
    var ok = true
    func check(_ name: String, _ c: Bool) { print("  \(c ? "PASS" : "FAIL")  \(name)"); ok = ok && c }

    /// 입력 채널 ch(nil이면 L/R만)에 0.5 s 사인을 넣고 출력 채널별 RMS와 판정 모드를 돌려준다
    func run(_ ch: Int?) -> ([Float], Bool) {
        let b = Bridge(srcRate: OUT_RATE, labels: labels, fillMs: 20, preset: Preset(), active: o.active)
        let n = 24000, nin = labels.count
        var src = [Float](repeating: 0, count: n * nin)
        for i in 0..<n {
            let v = Float(0.5 * sin(2 * .pi * 440 * Double(i) / OUT_RATE))
            if let c = ch { src[i * nin + c] = v } else { src[i * nin] = v; src[i * nin + 1] = v }
        }
        src.withUnsafeBufferPointer { b.ring.push(interleaved: $0.baseAddress!, frames: n) }
        var out: [Int16] = []
        b.render(n - 2400, dt: 0.01, into: &out)
        var rms = [Float](repeating: 0, count: NCH)
        let skip = 4800                                   // 모드 전환·업믹스 지연선이 자리 잡은 뒤
        for i in skip..<(out.count / NCH) { for c in 0..<NCH { let v = Float(out[i * NCH + c]) / 32767; rms[c] += v * v } }
        return (rms.map { ($0 / Float(out.count / NCH - skip)).squareRoot() }, b.discrete)
    }
    let on: Float = 0.05
    for (ch, label) in labels.enumerated() {
        let (rms, disc) = run(ch)
        let got = NAMES.indices.filter { rms[$0] > on }.map { NAMES[$0] }
        let want = NAMES.indices.filter { m[$0].contains { $0.0 == ch } }.map { NAMES[$0] }
        // L이나 R 하나만 오면 스테레오 소리로 보고 업믹스 (원래 채널은 그대로 포함)
        let pass = ch < 2 ? !disc && want.allSatisfy(got.contains) : disc && got == want
        check("\(labelName(label)) → \(got.isEmpty ? "(없음)" : got.joined(separator: ","))\(ch < 2 ? " (스테레오 업믹스)" : "")", pass)
    }
    let (rms, disc) = run(nil)
    check(String(format: "L/R만 → 스테레오 업믹스 (C %.2f, 판정 %@)", rms[2], disc ? "다채널" : "스테레오"), !disc && (!active[2] || rms[2] > on))
    print("selftest-map: \(ok ? "PASS" : "FAIL")")
    exit(ok ? 0 : 1)
}

// MARK: - Core Audio 공통

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = initial
    var size = UInt32(MemoryLayout<T>.size)
    let err = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
    if err != noErr { fail("Core Audio 속성 \(sel) 읽기 실패: \(err)") }
    return v
}

/// 크기가 정해지지 않은 속성(배열·구조체 목록)을 바이트로 읽는다
func propData(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt8]? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
    var d = [UInt8](repeating: 0, count: Int(size))
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &d) == noErr else { return nil }
    return Array(d.prefix(Int(size)))
}

func deviceName(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "?" }
    return n.takeRetainedValue() as String
}

func allDevices() -> [AudioObjectID] {
    guard let d = propData(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) else { return [] }
    return d.withUnsafeBytes { Array($0.bindMemory(to: AudioObjectID.self)) }
}

func channelCount(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    guard var d = propData(dev, kAudioDevicePropertyStreamConfiguration, scope: scope) else { return 0 }
    return d.withUnsafeMutableBytes { raw in
        UnsafeMutableAudioBufferListPointer(raw.baseAddress!.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// 장치가 알려 주는 출력 스피커 배치(채널 label 목록). Audio MIDI 설정의 '스피커 구성'과 같은 값.
func channelLabels(_ dev: AudioObjectID, count: Int) -> [UInt32] {
    let fallback = (0..<count).map { UInt32($0) + 1 }
    guard var d = propData(dev, kAudioDevicePropertyPreferredChannelLayout, scope: kAudioDevicePropertyScopeOutput) else { return fallback }
    var labels: [UInt32] = d.withUnsafeMutableBytes { raw in
        let acl = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
        if acl.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
            let n = Int(acl.pointee.mNumberChannelDescriptions)
            return withUnsafeMutablePointer(to: &acl.pointee.mChannelDescriptions) {
                $0.withMemoryRebound(to: AudioChannelDescription.self, capacity: n) { p in (0..<n).map { p[$0].mChannelLabel } }
            }
        }
        // 태그로 온 배치는 채널 설명으로 풀어서
        var tag = acl.pointee.mChannelLayoutTag
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size) == noErr else { return [] }
        var e = [UInt8](repeating: 0, count: Int(size))
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, 4, &tag, &size, &e) == noErr else { return [] }
        return e.withUnsafeMutableBytes { r in
            let a = r.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            let n = Int(a.pointee.mNumberChannelDescriptions)
            return withUnsafeMutablePointer(to: &a.pointee.mChannelDescriptions) {
                $0.withMemoryRebound(to: AudioChannelDescription.self, capacity: n) { p in (0..<n).map { p[$0].mChannelLabel } }
            }
        }
    }
    if labels.count < count { labels += fallback[labels.count...] }
    return Array(labels.prefix(count))
}

func defaultOutput() -> AudioObjectID {
    prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
}

func setDefaultOutput(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var d = dev
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioObjectID>.size), &d) == noErr
}

/// 지금 기본 출력 장치의 볼륨(0~1)과 음소거. tap이 Mac 스피커를 꺼도 볼륨 키는 이 값을 바꾼다.
func macVolume() -> (Float, Bool)? {
    var dev = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return nil }
    var vol: Float32 = 1
    size = UInt32(MemoryLayout<Float32>.size)
    a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &vol) == noErr else { return nil }
    var mute: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &mute) != noErr { mute = 0 }
    return (vol, mute != 0)
}

func fileMtime(_ path: String) -> Double? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
}

protocol Source: AnyObject {
    var rate: Double { get }
    var labels: [UInt32] { get }
    func start(_ ring: Ring)
    func stop()
}

// MARK: - 입력 1: Core Audio process tap (스테레오)

final class Tap: Source {
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    let rate: Double
    let labels: [UInt32] = [1, 2]

    init(mute: Bool) {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "sysbridge"
        desc.isPrivate = true
        desc.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        if err != noErr { fail("process tap 생성 실패(\(err)). 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 터미널을 허용하세요") }

        let outDev: AudioObjectID = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
        let outUID: CFString = prop(outDev, kAudioDevicePropertyDeviceUID, "" as CFString)
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "sysbridge",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        if err != noErr { fail("aggregate 장치 생성 실패: \(err)") }
        let fmt: AudioStreamBasicDescription = prop(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        rate = fmt.mSampleRate
        let interleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        print(String(format: "tap 형식: %.0f Hz, %d채널, %@, %d bit float=%@", fmt.mSampleRate, fmt.mChannelsPerFrame,
                     interleaved ? "interleaved" : "non-interleaved", fmt.mBitsPerChannel,
                     fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "yes" : "no"))
        if fmt.mFormatFlags & kAudioFormatFlagIsFloat == 0 || fmt.mBitsPerChannel != 32 { fail("float32가 아닌 tap 형식은 아직 지원하지 않습니다") }
    }

    func start(_ ring: Ring) {
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, _, _ in
            ring.push(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)))
        }
        if err != noErr { fail("IOProc 생성 실패: \(err)") }
        let e2 = AudioDeviceStart(aggID, procID)
        if e2 != noErr { fail("tap 시작 실패: \(e2)") }
    }

    func stop() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }
}

// MARK: - 입력 2: 다채널 가상 장치(loopback)의 입력

final class DeviceInput: Source {
    let dev: AudioObjectID
    let rate: Double
    let labels: [UInt32]
    var procID: AudioDeviceIOProcID?
    var restoreTo: AudioObjectID? = nil

    init(nameLike: String, makeDefault: Bool) {
        let devs = allDevices()
        guard let d = devs.first(where: { deviceName($0).localizedCaseInsensitiveContains(nameLike) && channelCount($0, kAudioDevicePropertyScopeInput) > 0 }) else {
            fail("'\(nameLike)' 장치가 없습니다. run/10_atmos.command가 설치하는 가상 장치입니다. 지금 장치: "
                 + devs.map(deviceName).joined(separator: ", "))
        }
        dev = d
        rate = prop(d, kAudioDevicePropertyNominalSampleRate, Float64(0))
        let nin = channelCount(d, kAudioDevicePropertyScopeInput)
        labels = channelLabels(d, count: nin)
        print(String(format: "입력 장치: %@ (%.0f Hz, %d채널, 배치 %@)", deviceName(d), rate, nin,
                     labels.map(labelName).joined(separator: " ")))
        if makeDefault {
            var prev = defaultOutput()
            if prev == d {   // 지난번에 원래대로 못 돌린 경우 → 내장 스피커로
                prev = devs.first(where: {
                    prop($0, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
                        && channelCount($0, kAudioDevicePropertyScopeOutput) > 0 }) ?? prev
            }
            if setDefaultOutput(d) {
                restoreTo = prev
                print("Mac 소리 출력 → \(deviceName(d)) (끝나면 \(deviceName(prev))로 돌아갑니다)")
            } else { print("기본 출력 바꾸기 실패 — 시스템 설정 > 사운드 > 출력에서 \(deviceName(d))를 고르세요") }
        }
    }

    func start(_ ring: Ring) {
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, inData, _, _, _ in
            ring.push(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)))
        }
        if err != noErr { fail("IOProc 생성 실패: \(err)") }
        let e2 = AudioDeviceStart(dev, procID)
        if e2 != noErr { fail("장치 시작 실패: \(e2)") }
    }

    func stop() {
        if let p = procID { AudioDeviceStop(dev, p); AudioDeviceDestroyIOProcID(dev, p); procID = nil }
        if let r = restoreTo, setDefaultOutput(r) { restoreTo = nil }
    }
}

// MARK: - main

var opt = parseOptions()
if opt.selftest { selftest(opt) }
if opt.selftestMap { selftestMap(opt) }

setvbuf(stdout, nil, _IOLBF, 0)
let preset = opt.preset.map { Preset(path: $0) } ?? Preset()
let source: Source
if let name = opt.device {
    source = DeviceInput(nameLike: name, makeDefault: !opt.keepOutput)
    opt.followVolume = false        // 장치(BlackHole)가 볼륨·음소거를 직접 적용
} else {
    source = Tap(mute: opt.mute)
}
let bridge = Bridge(srcRate: source.rate, labels: source.labels, fillMs: opt.fillMs, preset: preset, active: opt.active)
if source.labels.count > 2 { print("채널 매핑 (다채널일 때):\n  " + matrixText(bridge.matrix, labels: source.labels)) }
signal(SIGPIPE, SIG_IGN)
let fd = openFifo(opt.out)
if fd < 0 { source.stop(); fail("출력을 열 수 없습니다: \(opt.out)") }
var signalSources: [DispatchSourceSignal] = []
for s in [SIGINT, SIGTERM, SIGHUP] {
    signal(s, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
    src.setEventHandler { source.stop(); print("\nsysbridge 종료 (Mac 스피커 소리 복구)"); exit(0) }
    src.resume()
    signalSources.append(src)
}
source.start(bridge.ring)
print("Mac 소리 → \(opt.out) (7채널 48 kHz, 소리 내는 채널 \(opt.active.joined(separator: ",")), 프리셋: \(preset.text))")
if opt.device != nil { print("전체 음량 = Mac 볼륨 키. 멈추려면 Ctrl-C") }
else { print(opt.mute ? "Mac 스피커는 꺼집니다. 멈추려면 Ctrl-C" : "Mac 스피커도 같이 납니다. 멈추려면 Ctrl-C") }
Thread.detachNewThread {
    // 0.25 s마다: Mac 볼륨·음소거를 전체 음량으로, 프리셋 파일이 바뀌면 다시 읽기(폰별 음량 조절)
    var lastPoll = 0.0, lastVol: Float = -1, lastMute = false
    var presetMtime = opt.preset.flatMap { fileMtime($0) }
    writerLoop(bridge, fd: fd, aheadMs: opt.aheadMs, seconds: opt.seconds, clock: monotonic,
               sleep: { Thread.sleep(forTimeInterval: $0) }, tick: { now in
        guard now - lastPoll >= 0.25 else { return }
        lastPoll = now
        if opt.followVolume, let (v, m) = macVolume(), v != lastVol || m != lastMute {
            lastVol = v; lastMute = m
            bridge.master = m ? 0 : v * v
            print(m ? "Mac 볼륨: 음소거" : String(format: "Mac 볼륨: %.0f%% (%.1f dB)", v * 100, v > 0 ? 40 * log10(v) : -120))
        }
        if let path = opt.preset, let mt = fileMtime(path), mt != presetMtime, let p = Preset(tryPath: path) {
            presetMtime = mt
            bridge.setPreset(p)
            print("프리셋 다시 읽음: \(p.text)")
        }
    })
    source.stop()
    exit(0)
}
dispatchMain()
