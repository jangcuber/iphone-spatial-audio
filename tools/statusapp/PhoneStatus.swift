// 폰 스피커 앱 — 폰 7대 + 마이크 폰 상태(Wi-Fi, 서버 연결, 배터리)를 15초마다 보여 주고 켜기/끄기 버튼을 둔다.
//  - 상태는 run/19_phone_status.command(STATUS_TSV=1)를 돌려 읽음: 조회만, 소리 없음
//  - 켜기/끄기는 기존 켜기.command / 끄기.command를 창 없이 이 앱 안에서 돌리고 진행 상황을 앱에 보여 준다.
//    가상 장치 입력(마이크) 권한은 띄운 앱 기준이라, 이 앱이 처음 켤 때 마이크 권한을 한 번 받는다
//    (권한 없이 띄우면 입력이 전부 0 = 폰 무음). 켜기.command는 터미널 밖이면 터미널로 다시 열기 때문에
//    TERM_PROGRAM=Apple_Terminal을 넘겨 여기서 그대로 돌게 한다.
//  - 빌드: run/20_phone_app.command → 프로젝트 폴더의 "폰 스피커.app"
import SwiftUI
import AppKit
import AVFoundation

struct Phone: Identifiable {
    let name, channel, ip, wifi, server, battery, charge, ios: String
    var id: String { name }
    var ok: Bool { wifi == "O" && (server == "O" || server == "-") }
}

@MainActor
final class Model: ObservableObject {
    @Published var phones: [Phone] = []
    @Published var time = "-"
    @Published var macIP = ""
    @Published var speakersOn = false
    @Published var busy = false
    @Published var note = ""
    @Published var running: String? = nil   // 켜기/끄기 진행 중이면 그 이름
    @Published var log: [String] = []
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let script = root.appendingPathComponent("run/19_phone_status.command").path
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script]
            var env = ProcessInfo.processInfo.environment
            env["STATUS_TSV"] = "1"
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            var text = ""
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                text = String(decoding: data, as: UTF8.self)
            } catch {}
            let result = text
            await MainActor.run { self.parse(result) }
        }
    }

    private func parse(_ text: String) {
        busy = false
        var rows: [Phone] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "#", f.count >= 5 {
                time = f[1]; macIP = f[2]; speakersOn = f[4] == "켜짐"
            } else if f.count >= 8 {
                rows.append(Phone(name: f[0], channel: f[1], ip: f[2], wifi: f[3], server: f[4],
                                  battery: f[5], charge: f[6], ios: f[7]))
            }
        }
        if rows.isEmpty { note = "상태를 못 읽었어요 (run/19_phone_status.command를 더블클릭해 보세요)" }
        else { phones = rows; note = "" }
    }

    func run(_ command: String) {
        guard running == nil else { return }
        running = command; log = []; note = ""
        if command.hasPrefix("켜기") {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in
                        self.running = nil
                        if ok { self.run(command) }
                        else { self.note = "마이크 권한이 없어서 켜지 않았어요 (켜도 폰이 조용해요)" }
                    }
                }
                return
            default:
                running = nil
                note = "마이크 권한이 꺼져 있어요: 시스템 설정 > 개인정보 보호 및 보안 > 마이크 > 폰 스피커를 켜 주세요"
                return
            }
        }
        let path = root.appendingPathComponent(command).path
        let dir = root.path
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [path]
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            var env = ProcessInfo.processInfo.environment
            env["TERM_PROGRAM"] = "Apple_Terminal"
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice   // 스크립트 끝의 '엔터' 대기는 바로 넘어감
            out.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; return }   // 끝(EOF)
                let lines = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
                    .filter { !$0.contains("이 창은 닫아도") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if !lines.isEmpty { Task { @MainActor in self.log.append(contentsOf: lines) } }
            }
            do { try p.run(); p.waitUntilExit() } catch {}
            out.fileHandleForReading.readabilityHandler = nil
            await MainActor.run {
                self.running = nil
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.refresh() }
            }
        }
    }
}

struct ContentView: View {
    @StateObject var m = Model()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(m.speakersOn ? Color.green : Color.secondary.opacity(0.4)).frame(width: 12, height: 12)
                Text(m.speakersOn ? "폰 스피커 켜짐" : "폰 스피커 꺼짐").font(.title3.bold())
                Spacer()
                if let r = m.running {
                    ProgressView().controlSize(.small)
                    Text(r.hasPrefix("켜기") ? "켜는 중..." : "끄는 중...").foregroundStyle(.secondary)
                }
                Button("켜기") { m.run("켜기.command") }.keyboardShortcut("o").disabled(m.speakersOn || m.running != nil)
                Button("끄기") { m.run("끄기.command") }.keyboardShortcut("x").disabled(!m.speakersOn || m.running != nil)
            }
            Table(m.phones) {
                TableColumn("폰") { p in
                    HStack(spacing: 6) {
                        Circle().fill(p.ok ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(p.name == "mic" ? "마이크" : p.name)
                    }
                }.width(90)
                TableColumn("채널", value: \.channel).width(40)
                TableColumn("Wi-Fi") { p in Text(p.wifi == "O" ? "응답" : "없음").foregroundStyle(p.wifi == "O" ? .primary : Color.red) }.width(50)
                TableColumn("서버") { p in Text(serverText(p.server)) }.width(70)
                TableColumn("배터리") { p in batteryView(p) }.width(80)
                TableColumn("충전", value: \.charge).width(80)
                TableColumn("IP", value: \.ip).width(110)
                TableColumn("iOS", value: \.ios).width(55)
            }
            .frame(minHeight: 270)
            HStack {
                Text(m.busy ? "확인 중..." : "마지막 확인 \(m.time) · 15초마다 자동").foregroundStyle(.secondary)
                Spacer()
                Button("지금 확인") { m.refresh() }.disabled(m.busy)
            }.font(.callout)
            if !m.note.isEmpty { Text(m.note).font(.callout).foregroundStyle(.secondary) }
            if !m.log.isEmpty {
                Text(m.log.suffix(4).joined(separator: "\n")).font(.callout.monospaced())
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Wi-Fi 없음: 폰 화면을 눌러 깨우고, 그래도 안 되면 그 폰에서 Dopamine 앱 > Jailbreak")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 620)
        .onAppear { m.start() }
    }

    func serverText(_ s: String) -> String {
        switch s {
        case "O": return "연결"
        case "X": return "끊김"
        case "-": return "-"
        case "?": return "모름"
        default: return s.hasSuffix("(꺼짐)") ? "앱 꺼짐" : s
        }
    }

    @ViewBuilder func batteryView(_ p: Phone) -> some View {
        let v = Int(p.battery.replacingOccurrences(of: "%", with: ""))
        if let v {
            HStack(spacing: 4) {
                Image(systemName: p.charge == "충전 중" ? "battery.100.bolt"
                      : v > 60 ? "battery.75" : v > 25 ? "battery.50" : "battery.25")
                    .foregroundStyle(v <= 20 ? Color.red : Color.primary)
                Text("\(v)%")
            }
        } else { Text(p.battery) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
struct PhoneStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("폰 스피커") { ContentView() }
            .windowResizability(.contentSize)
    }
}
