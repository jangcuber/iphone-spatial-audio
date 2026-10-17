# tools — 측정·시험 도구

아이폰 여러 대가 **얼마나 같은 시각에 소리를 내는지**를 마이크 하나로 재는 도구입니다.
보정 스크립트(`run/06`, `run/09`)가 내부에서 씁니다.

필요한 것: Python 3.10+, `pip3 install numpy` (테스트까지 하려면 `pip3 install -r requirements.txt`).
m4a 같은 녹음 파일을 바로 분석하려면 `brew install ffmpeg`.

```bash
cd tools
python3 -m pytest -q tests          # 23개 테스트 (가짜 기기·가짜 Snapcast 서버로 검증)
python3 -m spatial_tools demo slots --devices 7   # 합성 녹음으로 분석기 동작 보기
python3 -m spatial_tools --help
```

## 가장 쉬운 실행

더블클릭 스크립트는 저장소 맨 위 [README](../README.md)의 순서를 따르세요 (`run/01_setup.command` → `run/14_add_phone.command` → `run/10_atmos.command` → `run/06_desk_calib.command`).

## 구성

| 명령 | 하는 일 |
|---|---|
| `gen train` | 모든 출력에 같은 신호를 0.5초마다. 시험 A용. 기본 chime은 5음계 멜로디 |
| `gen slots` | 채널 k의 신호를 k번째 시간 슬롯에만. 마지막 슬롯은 비워 cycle 시작을 표시. 시험 B·7채널용. chime이면 채널마다 다른 음(C D E G A C D) |
| `gen identify` | 채널 k에서 그 채널의 벨 음이 k+1번. 배선/매핑을 귀로 확인 |
| `fanout` | 스케줄을 실시간 속도로 합성해 FIFO들에 **같은 frame을 같은 순간에** 써 넣음 (snapserver pipe 입력). 모노 채널은 L/R 복제 |
| `snap` | Snapcast 서버 제어: `status`, `solo`(한 대씩 순환), `assign`(기기별 스트림), `latency`, `rename` |
| `analyze` | 녹음 → 기기별 offset·drift·지터, 기기 쌍별 skew 분포(p95/최대), 시간창별 변화 |

신호 소리(`gen --voice`): 기본 **chime** = 작은 하강 chirp(12→3 kHz, 30 ms, 진폭 0.25) + 3 kHz 아래 벨 음.
측정은 chirp만 정합 필터로 찾고 벨 음은 대역이 달라 검출기에 -70 dB 이하로만 샌다. 합성 녹음에서 정확도는
예전 chirp와 같지만, 검출 SNR이 약 4 dB 낮아 잡음이 매우 큰 곳에서는 `--voice chirp`(예전 1.5–12 kHz, 진폭 0.5)가 유리하다.
예전 스케줄 JSON(tone 없음)은 그대로 예전 소리로 재생·분석된다.

분석 모델: `도착 = 공통지연 + 비율×소스시각 + 기기offset + 기기drift×시간`. 녹음 장치와 서버의 clock 차이는
비율에 흡수되고, 기기 간 차이만 남습니다. `--distance`로 마이크까지 거리를 주면 음속 지연을 빼서
**출력 시각** 기준 skew를 냅니다 (안 주면 마이크 위치에서 들리는 skew).

합성 녹음 검증 결과 (지터 60 µs, 반사음·잡음·탈락 포함): offset 오차는 통계 불확실성(±1σ) 수준인 수 µs~수십 µs,
drift 오차 < 0.5 ppm. 실제 정확도는 마이크·방 반사가 좌우하므로 결과의 `±1σ`와 `잔차σ`를 함께 보세요.

## 시험 A 절차 (아이폰 2대, 같은 스트림)

Mac에서:

```bash
brew install snapcast ffmpeg            # snapserver (Homebrew formula 이름은 설치 전에 확인)
cd tools
python3 -m spatial_tools gen train --minutes 35 --out ../recordings/test_a
snapserver -c config/snapserver_test_a.conf          # 터미널 1
python3 -m spatial_tools fanout ../recordings/test_a.schedule.json --out /tmp/snap_test_a:0   # 터미널 2
```

1. 두 아이폰에 snapclient를 설치합니다 (`run/14_add_phone.command`, 설정의 SERVER가 Mac IP). `python3 -m spatial_tools snap status`로 두 대가 보이는지,
   이름을 확인합니다 (필요하면 `snap rename --set 원래이름=P1`).
2. 폰 볼륨은 낮게 시작하고, 두 폰을 마이크에서 **같은 거리**(또는 거리를 줄자로 기록)에 둡니다.
3. 녹음을 시작합니다. 예: `ffmpeg -f avfoundation -i ":0" -ac 1 -ar 48000 ../recordings/rec_a.wav`
   (`ffmpeg -f avfoundation -list_devices true -i ""`로 마이크 번호 확인. 30분 이상)
4. solo 순환을 켭니다 (터미널 3): `python3 -m spatial_tools snap solo --clients P1,P2 --solo 20 --solo-step 5 --gap 3 --log ../recordings/solo_a.jsonl`
   - P1은 20초, P2는 25초씩 혼자 울립니다. 분석기는 이 **길이 차이로 기기를 구분**하므로 녹음과 순환을 켜는 순서는 상관없습니다.
5. 분석:

```bash
python3 -m spatial_tools analyze ../recordings/rec_a.wav --schedule ../recordings/test_a.schedule.json \
    --solo-order P1,P2 --solo 20 --solo-step 5 --window 102 --distance P1=1.00,P2=1.00 --json ../recordings/rep_a.json
```

`--window`는 solo 한 바퀴(20+3+25+3 = 51초)의 두 배 정도로 줍니다. 시험 A는 두 폰이 **번갈아** 울리므로 skew는
시간 모델로 이어 붙여 계산한 값입니다. 동시에 울리는 상태의 직접 측정은 시험 B(slots)에서 합니다.

## 시험 B 절차 (아이폰 2대, 서로 다른 채널)

```bash
python3 -m spatial_tools gen slots --channels L,R --minutes 35 --out ../recordings/test_b
snapserver -c config/snapserver_test_b.conf
python3 -m spatial_tools fanout ../recordings/test_b.schedule.json --out /tmp/snap_L:0 --out /tmp/snap_R:1
python3 -m spatial_tools snap assign --map P1=chL,P2=chR
# 녹음 후
python3 -m spatial_tools analyze ../recordings/rec_b.wav --schedule ../recordings/test_b.schedule.json --distance L=1.0,R=1.0
```

채널 이름(L, R)은 신호 기준이고, 어느 폰이 어느 채널인지는 `assign`이 정합니다. 기기 간 차이가 슬롯 간격의
절반(기본 125 ms)보다 크면 기기 구분이 틀어지므로 `--slot`을 늘립니다.
7대는 `gen slots --channels 7`과 `config/snapserver_7ch.conf`를 같은 방식으로 씁니다.

## 주의

- 측정 원본(`recordings/`, `*.wav`)은 용량 때문에 git에서 제외했습니다. 결과 요약과 JSON만 HANDOFF에 기록하세요.
- `snap solo`는 종료 시 원래 mute 상태로 되돌립니다. 비정상 종료 후에는 `snap status`로 확인하세요.
- `snap assign`의 그룹 분리는 Snapcast `Group.SetClients` 동작(빠진 클라이언트를 새 그룹으로)을 가정합니다.
  실제 서버 버전에서 처음 한 번 `snap status`로 결과를 확인하세요.
- 실제 기기·서버로는 아직 한 번도 실행하지 않았습니다. 첫 실행에서 나온 문제는 HANDOFF에 기록합니다.
