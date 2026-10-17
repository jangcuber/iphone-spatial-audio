// 탈옥 아이폰 마이크 녹음기 (청취 위치 측정용, 2026-10-08): MacBook을 옮기지 않고 폰을 귀 자리에 둔다.
// 사용법: iosrec <출력.wav> <초>
// AVAudioSession mode=measurement(자동 음량·잡음 처리 끔), 48 kHz / mono / 16-bit PCM WAV.
// 빌드: tools/recorder/build_iosrec.sh (ldid 서명, 마이크 TCC 권한 entitlement)
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let seconds = Double(args[2]) else {
    FileHandle.standardError.write("사용법: iosrec <출력.wav> <초>\n".data(using: .utf8)!)
    exit(2)
}
let session = AVAudioSession.sharedInstance()
do {
    try session.setCategory(.record, mode: .measurement)
    try session.setPreferredSampleRate(48000)
    try session.setActive(true)
} catch {
    FileHandle.standardError.write("AVAudioSession 실패: \(error)\n".data(using: .utf8)!)
    exit(1)
}
let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 48000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]
do {
    let url = URL(fileURLWithPath: args[1])
    let rec = try AVAudioRecorder(url: url, settings: settings)
    guard rec.prepareToRecord() else { throw NSError(domain: "iosrec", code: 1) }
    let t0 = Date()
    guard rec.record(forDuration: seconds) else { throw NSError(domain: "iosrec", code: 2) }
    while rec.isRecording { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    let wall = Date().timeIntervalSince(t0)
    let f = try AVAudioFile(forReading: url)
    print(String(format: "iosrec: %.3f s 녹음 (경과 %.3f s, %.0f Hz, 세션 %.0f Hz)",
                 Double(f.length) / f.fileFormat.sampleRate, wall, f.fileFormat.sampleRate, session.sampleRate))
} catch {
    FileHandle.standardError.write("녹음 실패: \(error)\n".data(using: .utf8)!)
    exit(1)
}
