// 영상 싱크용 전체 지연 재기 (2026-10-09)
//
// 가상 장치(SpatialPhones)로 짧은 벨 소리 4번을 내고 Mac 내장 마이크로 폰 소리를 녹음해서
// "앱이 장치에 소리를 넘긴 시각 → 폰 소리가 Mac 앞에 도착한 시각"을 잰다.
// 두 시각 모두 Core Audio IOProc의 host time(mach 시계)이라 같은 시계로 바로 뺄 수 있다.
// 이 값이 장치가 앱에 알려야 할 출력 지연(kAudioDevicePropertyLatency)이다. 브라우저·QuickTime은
// 이 값만큼 화면을 늦춰 소리와 맞춘다 (블루투스 이어폰·AirPlay와 같은 방식).
//
// 사용법: avlatency [--device SpatialPhones] [--mic 이름] [--gain-db -12] [--set] [--out 결과.json]
//         avlatency --get                    (장치가 지금 알리는 출력 지연만 보기)
//         avlatency --set-ms 1180            (재지 않고 값만 넣기)
//  --set: 잰 값을 장치의 출력 지연으로 넣는다 (지연을 바꿀 수 있게 고친 드라이버일 때만)
import CoreAudio
import Accelerate
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

var devName = "SpatialPhones", micName: String? = nil, gainDb = -12.0, doSet = false, outPath: String? = nil
var onlyGet = false, setMs: Double? = nil, dumpPath: String? = nil
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--device": devName = it.next() ?? devName
    case "--mic": micName = it.next()
    case "--gain-db": gainDb = Double(it.next() ?? "") ?? gainDb
    case "--set": doSet = true
    case "--out": outPath = it.next()
    case "--get": onlyGet = true
    case "--dump": dumpPath = it.next()
    case "--set-ms": setMs = Double(it.next() ?? "")
    default: fail("알 수 없는 옵션: \(a)")
    }
}

// MARK: - Core Audio

func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
}
func get<T>(_ o: AudioObjectID, _ s: AudioObjectPropertySelector, _ v0: T, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var a = addr(s, sc); var v = v0; var n = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(o, &a, 0, nil, &n, &v) == noErr ? v : nil
}
func name(_ d: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName); var s: Unmanaged<CFString>?; var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &n, &s) == noErr, let v = s else { return "?" }
    return v.takeRetainedValue() as String
}
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var n: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n)
    var d = [AudioObjectID](repeating: 0, count: Int(n) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &d)
    return d
}
func channels(_ d: AudioObjectID, _ sc: AudioObjectPropertyScope) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, sc); var n: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &n) == noErr, n > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(n), alignment: 16); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(d, &a, 0, nil, &n, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
/// 장치 지연 + 첫 스트림 지연 (frame)
func latencyFrames(_ d: AudioObjectID, _ sc: AudioObjectPropertyScope) -> UInt32 {
    var l = get(d, kAudioDevicePropertyLatency, UInt32(0), sc) ?? 0
    var a = addr(kAudioDevicePropertyStreams, sc); var n: UInt32 = 0
    if AudioObjectGetPropertyDataSize(d, &a, 0, nil, &n) == noErr, n >= 4 {
        var s = [AudioObjectID](repeating: 0, count: Int(n) / 4)
        AudioObjectGetPropertyData(d, &a, 0, nil, &n, &s)
        l += get(s[0], kAudioStreamPropertyLatency, UInt32(0)) ?? 0
    }
    return l
}
func setOutputLatency(_ d: AudioObjectID, frames: UInt32) -> OSStatus {
    var a = addr(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(d, &a, &settable) == noErr, settable.boolValue else { return kAudioHardwareUnsupportedOperationError }
    var v = frames
    return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &v)
}

let all = devices()
guard let dev = all.first(where: { name($0).localizedCaseInsensitiveContains(devName) && channels($0, kAudioObjectPropertyScopeOutput) > 0 })
else { fail("'\(devName)' 출력 장치가 없습니다") }
let devRate = get(dev, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 48000
func showLatency() {
    let f = latencyFrames(dev, kAudioObjectPropertyScopeOutput)
    print(String(format: "%@가 앱에 알리는 출력 지연: %.0f ms (%d frame)", name(dev), Double(f) / devRate * 1000, f))
}
if onlyGet { showLatency(); exit(0) }
if let ms = setMs {
    let e = setOutputLatency(dev, frames: UInt32((ms / 1000 * devRate).rounded()))
    if e != noErr { fail("출력 지연 넣기 실패(\(e)) — 지연을 바꿀 수 있게 고친 드라이버가 아닙니다") }
    showLatency(); exit(0)
}

let mic: AudioObjectID = {
    if let m = micName {
        guard let d = all.first(where: { name($0).localizedCaseInsensitiveContains(m) && channels($0, kAudioObjectPropertyScopeInput) > 0 }) else { fail("마이크 '\(m)' 없음") }
        return d
    }
    guard let d = all.first(where: { get($0, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
                                     && channels($0, kAudioObjectPropertyScopeInput) > 0 }) else { fail("내장 마이크가 없습니다") }
    return d
}()
let micRate = get(mic, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 48000
let micCh = channels(mic, kAudioObjectPropertyScopeInput)
let devOutCh = channels(dev, kAudioObjectPropertyScopeOutput)
let micLatMs = Double(latencyFrames(mic, kAudioObjectPropertyScopeInput)) / micRate * 1000
print(String(format: "출력: %@ (%.0f Hz, %d채널)  마이크: %@ (%.0f Hz, %d채널, 입력 지연 %.1f ms)",
             name(dev), devRate, devOutCh, name(mic), micRate, micCh, micLatMs))
showLatency()

// MARK: - 신호: 부드러운 짧은 chirp(위치 잡기용) + 벨 꼬리, 4번, 간격을 서로 다르게 (어느 소리인지 헷갈리지 않게)

let chirpLen = Int(0.04 * devRate)
let chirp: [Float] = (0..<chirpLen).map { i in
    let t = Double(i) / devRate, T = Double(chirpLen) / devRate
    let f0 = 900.0, f1 = 3600.0
    let ph = 2 * Double.pi * (f0 * t + (f1 - f0) * t * t / (2 * T))
    return Float(sin(ph) * 0.5 * (1 - cos(2 * Double.pi * t / T)))
}
func chime() -> [Float] {
    let n = Int(0.5 * devRate)
    var s = [Float](repeating: 0, count: n)
    for i in 0..<chirpLen { s[i] = 0.7 * chirp[i] }
    for i in 0..<n {   // E6 벨 (배음 3개, 지수 감쇠)
        let t = Double(i) / devRate
        let a = (1 - exp(-t / 0.004)) * exp(-t / 0.12)
        s[i] += Float(a * (0.5 * sin(2 * .pi * 1318.5 * t) + 0.2 * sin(2 * .pi * 2637 * t) + 0.08 * sin(2 * .pi * 3955.5 * t)))
    }
    return s
}
let gaps = [1.3, 1.7, 1.1]           // 소리 사이 간격(s)
let lead = 0.3
var onsets = [Int(lead * devRate)]
for g in gaps { onsets.append(onsets.last! + Int(g * devRate)) }
let tailSec = 3.0                    // 마지막 소리 뒤 녹음 (지연 최대 약 2.5 s까지)
let total = onsets.last! + Int(tailSec * devRate)
var sig = [Float](repeating: 0, count: total)
let ch1 = chime(), g = Float(pow(10, gainDb / 20))
for o in onsets { for i in 0..<ch1.count where o + i < total { sig[o + i] += g * ch1[i] } }

// MARK: - 재생·녹음 (IOProc 두 개, 각 콜백의 host time 기록)

final class Rec { var frames = [Float](); var stamps = [(Int, UInt64)](); var outStamps = [(Int, UInt64)](); var outPos = 0 }
let rec = Rec()
let lock = NSLock()
rec.frames.reserveCapacity(Int(micRate) * 15)

var outProc: AudioDeviceIOProcID?
var inProc: AudioDeviceIOProcID?
let q = DispatchQueue(label: "io")
var e = AudioDeviceCreateIOProcIDWithBlock(&outProc, dev, q) { _, _, _, outData, outTime in
    let abl = UnsafeMutableAudioBufferListPointer(outData)
    guard let b0 = abl.first, let p = b0.mData?.assumingMemoryBound(to: Float.self) else { return }
    let nch = Int(b0.mNumberChannels), n = Int(b0.mDataByteSize) / 4 / max(1, nch)
    lock.lock()
    let pos = rec.outPos
    if pos < total { rec.outStamps.append((pos, outTime.pointee.mHostTime)) }
    rec.outPos += n
    lock.unlock()
    for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    for i in 0..<n where pos + i < total {
        let v = sig[pos + i]
        p[i * nch] = v                          // L
        if nch > 1 { p[i * nch + 1] = v }       // R → sysbridge가 FL·FR·C로 (가운데 소리)
    }
}
if e != noErr { fail("출력 IOProc 실패 \(e)") }
e = AudioDeviceCreateIOProcIDWithBlock(&inProc, mic, q) { _, inData, inTime, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    guard let b0 = abl.first, let p = b0.mData?.assumingMemoryBound(to: Float.self) else { return }
    let nch = Int(b0.mNumberChannels), n = Int(b0.mDataByteSize) / 4 / max(1, nch)
    lock.lock()
    rec.stamps.append((rec.frames.count, inTime.pointee.mHostTime))
    for i in 0..<n { rec.frames.append(p[i * nch]) }
    lock.unlock()
}
if e != noErr { fail("마이크 IOProc 실패 \(e)") }

var tb = mach_timebase_info(); mach_timebase_info(&tb)
func hostSec(_ h: UInt64) -> Double { Double(h) * Double(tb.numer) / Double(tb.denom) / 1e9 }

print("재생·녹음 \(String(format: "%.0f", Double(total) / devRate)) 초…")
guard AudioDeviceStart(mic, inProc) == noErr else { fail("마이크 시작 실패 (터미널 마이크 권한?)") }
Thread.sleep(forTimeInterval: 0.3)
guard AudioDeviceStart(dev, outProc) == noErr else { fail("출력 시작 실패") }
while true { lock.lock(); let d = rec.outPos >= total; lock.unlock(); if d { break }; Thread.sleep(forTimeInterval: 0.05) }
AudioDeviceStop(dev, outProc)
AudioDeviceStop(mic, inProc)
AudioDeviceDestroyIOProcID(dev, outProc!); AudioDeviceDestroyIOProcID(mic, inProc!)

// MARK: - 분석

/// stamps(시작 frame, host)로 frame 위치 → host 초 (가까운 두 콜백 사이 보간)
func timeOf(_ k: Double, _ st: [(Int, UInt64)], _ rate: Double) -> Double {
    guard let j = st.lastIndex(where: { Double($0.0) <= k }) else { return hostSec(st[0].1) + (k - Double(st[0].0)) / rate }
    if j + 1 < st.count {
        let (a, ha) = st[j], (b, hb) = st[j + 1]
        return hostSec(ha) + (k - Double(a)) / Double(b - a) * (hostSec(hb) - hostSec(ha))
    }
    return hostSec(st[j].1) + (k - Double(st[j].0)) / rate
}
let x = rec.frames
if x.count < Int(micRate) * 2 { fail("녹음이 너무 짧습니다 (\(x.count) frame) — 마이크 권한을 확인하세요") }
let peak = x.map { abs($0) }.max() ?? 0
print(String(format: "녹음 최대 %.1f dBFS", peak > 0 ? 20 * log10(peak) : -120))
if peak == 0 { fail("녹음이 전부 0입니다 — 마이크 권한이 없습니다 (시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 터미널 허용)") }
// 마이크 rate의 chirp 템플릿으로 상관 (vDSP_conv), 포락선
let tl = Int(0.04 * micRate)
let tpl: [Float] = (0..<tl).map { i in chirp[min(chirpLen - 1, Int(Double(i) * devRate / micRate))] }
let nc = x.count - tl
var corr = [Float](repeating: 0, count: nc)
vDSP_conv(x, 1, tpl, 1, &corr, 1, vDSP_Length(nc), vDSP_Length(tl))
let env = corr.map { abs($0) }
// 지연 L 후보마다 4개 소리 위치의 상관 합 → 최대 (간격이 서로 달라 다른 소리와 헷갈리지 않음)
let outT = onsets.map { timeOf(Double($0), rec.outStamps, devRate) }
let micT0 = timeOf(0, rec.stamps, micRate)
if let d = dumpPath {   // 원본(분석 확인용): float32 녹음 + 시각
    x.withUnsafeBytes { try? Data($0).write(to: URL(fileURLWithPath: d + ".f32")) }
    let j: [String: Any] = ["mic_rate": micRate, "dev_rate": devRate, "mic_t0": micT0, "out_onsets_t": outT, "mic_latency_ms": micLatMs,
                            "mic_stamps": rec.stamps.map { [Double($0.0), hostSec($0.1)] }, "out_stamps": rec.outStamps.map { [Double($0.0), hostSec($0.1)] },
                            "chirp": chirp.map { Double($0) }]
    try? JSONSerialization.data(withJSONObject: j).write(to: URL(fileURLWithPath: d + ".raw.json"))
}
func idx(_ t: Double) -> Int { Int(((t - micT0) * micRate).rounded()) }
var best = (score: Float(0), L: 0.0)
let step = 1.0 / micRate * 4
var L = 0.0
while L < 2.6 {
    var s: Float = 0
    for t in outT { let k = idx(t + L); if k >= 0 && k < env.count { s += env[k] } }
    if s > best.score { best = (s, L) }
    L += step
}
// 각 소리별로 ±10 ms에서 다시 정확히
var each = [Double](), snr = [Double]()
let noise = { () -> Float in let s = env.sorted(); return s[s.count / 2] }()
for t in outT {
    let c = idx(t + best.L), w = Int(0.01 * micRate)
    var bi = c, bv: Float = 0
    for k in max(0, c - w)..<min(env.count, c + w) where env[k] > bv { bv = env[k]; bi = k }
    // 직접음(먼저 오는 소리): 최대값의 50%를 처음 넘는 곳 (방 반사가 더 클 때 대비)
    var first = bi
    for k in max(0, bi - w)...bi where env[k] >= 0.5 * bv { first = k; break }
    each.append(micT0 + Double(first) / micRate - t)
    snr.append(bv > 0 ? Double(20 * log10(bv / max(noise, 1e-9))) : -120)
}
let srt = each.sorted(), med = srt[srt.count / 2]
let spread = (srt.last! - srt.first!) * 1000
let ok = spread < 5 && (snr.min() ?? 0) > 15
let totalMs = med * 1000 - micLatMs
print(String(format: "소리별 지연: %@ ms (차이 %.1f ms), 신호/잡음 %@ dB",
             each.map { String(format: "%.1f", $0 * 1000 - micLatMs) }.joined(separator: " "), spread,
             snr.map { String(format: "%.0f", $0) }.joined(separator: " ")))
print(String(format: "전체 지연(장치에 소리 넘김 → Mac 앞 폰 소리): %.1f ms  %@", totalMs, ok ? "OK" : "불확실 (소리가 작거나 잡음이 큼)"))

if let p = outPath {
    let j: [String: Any] = ["total_latency_ms": totalMs, "each_ms": each.map { $0 * 1000 - micLatMs }, "spread_ms": spread,
                            "snr_db": snr, "ok": ok, "device": name(dev), "mic": name(mic), "mic_latency_ms": micLatMs,
                            "reported_before_ms": Double(latencyFrames(dev, kAudioObjectPropertyScopeOutput)) / devRate * 1000,
                            "date": ISO8601DateFormatter().string(from: Date())]
    try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: p))
}
if doSet {
    guard ok else { print("결과가 불확실해서 장치 지연은 바꾸지 않았습니다"); exit(2) }
    let e = setOutputLatency(dev, frames: UInt32((totalMs / 1000 * devRate).rounded()))
    if e != noErr { print("장치에 지연 넣기 실패(\(e)) — 지연을 바꿀 수 있게 고친 드라이버를 설치해야 합니다"); exit(3) }
    showLatency()
}
exit(ok ? 0 : 2)
