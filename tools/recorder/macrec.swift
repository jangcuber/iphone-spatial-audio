// Mac 마이크 녹음기 (ffmpeg avfoundation이 샘플을 ~13% 잃고 시간축이 흔들리는 문제 대응, 2026-10-08)
// 사용법: macrec <출력.wav> <초> [장치UID]
// AVAudioRecorder로 48 kHz / mono / 16-bit PCM WAV. 끝나면 기록된 frame 수와 경과 시간을 출력한다.
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let seconds = Double(args[2]) else {
    FileHandle.standardError.write("사용법: macrec <출력.wav> <초>\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 48000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
]

let sema = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .audio) { ok in
    if !ok { FileHandle.standardError.write("마이크 권한 없음 (시스템 설정 > 개인정보 보호 > 마이크)\n".data(using: .utf8)!) }
    sema.signal()
}
sema.wait()

do {
    let rec = try AVAudioRecorder(url: url, settings: settings)
    guard rec.prepareToRecord() else { throw NSError(domain: "macrec", code: 1) }
    let t0 = Date()
    guard rec.record(forDuration: seconds) else { throw NSError(domain: "macrec", code: 2) }
    while rec.isRecording { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    let wall = Date().timeIntervalSince(t0)
    let f = try AVAudioFile(forReading: url)
    let got = Double(f.length) / f.fileFormat.sampleRate
    print(String(format: "macrec: %.3f s 녹음 (경과 %.3f s, %.0f Hz)", got, wall, f.fileFormat.sampleRate))
} catch {
    FileHandle.standardError.write("녹음 실패: \(error)\n".data(using: .utf8)!)
    exit(1)
}
