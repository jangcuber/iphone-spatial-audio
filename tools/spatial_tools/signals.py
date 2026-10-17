"""측정용 테스트 신호.

두 가지 배치를 지원한다.

* 반복열(train): 모든 출력에 같은 chirp를 period 간격으로 넣는다.
  시험 A(같은 스트림 2대)에 사용. 기기 구분은 Snapcast mute 순환(solo)으로 한다.
* 슬롯(slots): 채널 k의 chirp를 cycle 안의 k번째 슬롯에만 넣는다.
  마지막 슬롯 하나는 비워 cycle의 시작을 표시한다. 시험 B(독립 채널)와
  7채널 식별·skew 측정에 사용. 마이크 하나로 기기를 구분할 수 있다.

소리(voice):

* chime(기본): 짧은 하강 chirp(12→3 kHz, 낮은 음량) = 벨을 치는 "팅" 소리 +
  3 kHz 아래에만 성분이 있는 벨/마림바 음(5음계). 검출은 chirp만 템플릿으로 쓰고,
  벨 음은 대역이 겹치지 않아 정합 필터에 거의 걸리지 않는다. train은 짧은 멜로디,
  slots는 채널마다 다른 음이라 귀로도 채널을 구분할 수 있다.
* chirp: 예전 신호(1.5–12 kHz 상승 chirp만). 옛 스케줄 JSON은 tone이 없어 이 소리로 재생된다.

모든 이벤트의 "소스 시각"은 파일 첫 sample 기준 초 단위로 정확히 계산된다.
분석기는 녹음에서 찾은 도착 시각을 이 소스 시각에 맞춰 기기별 offset/drift를 구한다.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field

import numpy as np

DEFAULT_RATE = 48_000
CHANNEL_NAMES_7 = ["FL", "FR", "C", "SL", "SR", "HL", "HR"]


@dataclass(frozen=True)
class ChirpSpec:
    f0: float = 1_500.0      # Hz. 아이폰 내장 스피커가 잘 내는 대역
    f1: float = 12_000.0     # Hz
    duration: float = 0.020  # s
    fade: float = 0.002      # s, 양 끝 cosine fade
    amplitude: float = 0.5   # 0~1, 기본 -6 dBFS (볼륨은 폰/서버에서 낮게 시작)


# chime용 측정 chirp: 위에서 아래로 쓸어 내려 벨을 치는 소리처럼 들리게, 음량은 낮게
STRIKE = ChirpSpec(f0=12_000.0, f1=3_000.0, duration=0.030, fade=0.003, amplitude=0.25)

# C장조 5음계 (C5 D5 E5 G5 A5 C6 D6). 7채널이면 채널마다 한 음
PENTATONIC = (523.25, 587.33, 659.26, 783.99, 880.00, 1046.50, 1174.66)
MELODY = (0, 2, 3, 5, 4, 3, 2, 1)   # train: C E G C6 A G E D 반복 (0.5 s 간격이면 4 s 한 마디)


@dataclass(frozen=True)
class ToneSpec:
    """측정 chirp에 얹는 벨 음. 검출 템플릿에는 들어가지 않는다."""
    notes: tuple = PENTATONIC
    melody: tuple = MELODY
    amplitude: float = 0.30      # 기음 진폭 (chirp 0.25보다 크게: 귀에는 벨 음이 주로 들림)
    attack: float = 0.004        # s, 부드러운 시작
    decay: float = 0.15          # s, 기음 감쇠 시상수
    length: float = 0.45         # s, 이 길이에서 끝을 fade로 닫음
    max_hz: float = 2_200.0      # 이 주파수 이상 배음은 넣지 않음 (chirp 대역 3 kHz와 분리)


def tone(freq: float, spec: ToneSpec = ToneSpec(), rate: int = DEFAULT_RATE) -> np.ndarray:
    """벨/마림바 비슷한 음: 기음 + 약한 2배음(빨리 감쇠), 지수 감쇠, 부드러운 attack."""
    n = int(round(spec.length * rate))
    t = np.arange(n) / rate
    x = np.zeros(n)
    for mult, gain, tau in ((1.0, 1.0, spec.decay), (2.0, 0.3, spec.decay * 0.4), (3.0, 0.1, spec.decay * 0.25)):
        f = freq * mult
        if f < spec.max_hz:
            x += gain * np.sin(2 * np.pi * f * t) * np.exp(-t / tau)
    na = max(1, int(round(spec.attack * rate)))
    x[:na] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(na) / na)
    nr = int(0.05 * rate)
    x[-nr:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(nr) / nr)
    return spec.amplitude * x


def voices(sched: "Schedule") -> tuple[list[np.ndarray], np.ndarray]:
    """이벤트마다 실제로 재생되는 파형: (파형 목록, 이벤트별 파형 index)."""
    c = chirp(ChirpSpec(**sched.chirp), sched.rate)
    if not sched.tone:
        return [c], np.zeros(len(sched.events), dtype=np.int64)
    spec = ToneSpec(**{k: tuple(v) if isinstance(v, list) else v for k, v in sched.tone.items()})
    waves = []
    for f in spec.notes:
        w = tone(f, spec, sched.rate)
        w[:len(c)] += c
        waves.append(w)
    if sched.mode == "slots":
        idx = [ch % len(spec.notes) for ch, _ in sched.events]
    else:
        idx = [spec.melody[i % len(spec.melody)] % len(spec.notes) for i in range(len(sched.events))]
    return waves, np.array(idx, dtype=np.int64)


def chirp(spec: ChirpSpec = ChirpSpec(), rate: int = DEFAULT_RATE) -> np.ndarray:
    """선형 chirp. 대역폭이 넓을수록 도착 시각 분해능이 좋아진다 (~1/대역폭)."""
    n = int(round(spec.duration * rate))
    t = np.arange(n) / rate
    k = (spec.f1 - spec.f0) / spec.duration
    x = np.sin(2 * np.pi * (spec.f0 * t + 0.5 * k * t * t))
    nf = max(1, int(round(spec.fade * rate)))
    w = np.ones(n)
    ramp = 0.5 - 0.5 * np.cos(np.pi * np.arange(nf) / nf)
    w[:nf] = ramp
    w[-nf:] = ramp[::-1]
    return spec.amplitude * x * w


@dataclass
class Schedule:
    """신호 파일에 들어간 이벤트 목록과 배치 정보 (JSON으로 저장해 분석기에 넘긴다)."""
    mode: str                      # "train" | "slots"
    rate: int
    channels: list[str]
    period: float                  # train: chirp 간격 / slots: cycle 길이
    slot: float | None = None      # slots 전용: 슬롯 간격
    lead_in: float = 1.0           # 첫 이벤트 전 무음 (s)
    duration: float = 0.0
    chirp: dict = field(default_factory=dict)      # 검출 템플릿 (분석기는 이것만 씀)
    # (channel index, source time s). train에서는 channel=-1 (모든 출력 동일)
    events: list[tuple[int, float]] = field(default_factory=list)
    tone: dict | None = None                        # chime 벨 음 (None = chirp만 재생)

    def to_json(self) -> dict:
        d = asdict(self)
        d["events"] = [list(e) for e in self.events]
        return d

    @staticmethod
    def from_json(d: dict) -> "Schedule":
        s = Schedule(**{k: v for k, v in d.items() if k != "events"})
        s.events = [(int(c), float(t)) for c, t in d.get("events", [])]
        return s


def _place(buf: np.ndarray, start: int, x: np.ndarray) -> None:
    end = min(len(buf), start + len(x))
    if start < end:
        buf[start:end] += x[: end - start]


def make_train(duration: float, period: float = 0.5, n_out: int = 2,
               spec: ChirpSpec = ChirpSpec(), rate: int = DEFAULT_RATE,
               lead_in: float = 1.0, tone_spec: ToneSpec | None = None) -> tuple[np.ndarray, Schedule]:
    """모든 출력 채널에 동일한 신호 반복열. 시험 A용. tone_spec을 주면 chime."""
    events = []
    t = lead_in
    while t + spec.duration < duration:
        events.append((-1, int(round(t * rate)) / rate))  # 정수 sample 위치로 고정된 정확한 소스 시각
        t += period
    sched = Schedule("train", rate, [f"out{i}" for i in range(n_out)], period,
                     None, lead_in, duration, asdict(spec), events,
                     asdict(tone_spec) if tone_spec else None)
    mono = ScheduleRenderer(sched).block(0, int(round(duration * rate)))[:, 0]
    return np.repeat(mono[:, None], n_out, axis=1), sched


def make_slots(duration: float, channels: list[str], slot: float = 0.25,
               spec: ChirpSpec = ChirpSpec(), rate: int = DEFAULT_RATE,
               lead_in: float = 1.0, tone_spec: ToneSpec | None = None,
               active: list[int] | None = None, render: bool = True):
    """채널별 시간 슬롯. cycle = (울리는 채널 수 + 1 빈 슬롯) × slot. 시험 B / 7채널용.

    active: 이벤트를 넣을 채널 index (기본 전부). 7채널 스트림을 폰 일부만으로 잴 때 빈 채널은 슬롯도 두지 않는다.
    render=False: 전체 PCM 대신 ScheduleRenderer를 돌려준다 (7채널 수 분이면 수백 MB).
    """
    act = list(range(len(channels))) if active is None else list(active)
    if slot < spec.duration + 0.05:
        raise ValueError("slot은 chirp 길이 + 반사음 여유(50 ms)보다 길어야 합니다")
    cycle = (len(act) + 1) * slot
    events = []
    base = lead_in
    while base + cycle <= duration:
        for j, k in enumerate(act):
            events.append((k, int(round((base + j * slot) * rate)) / rate))
        base += cycle
    sched = Schedule("slots", rate, list(channels), cycle, slot, lead_in, duration,
                     asdict(spec), events, asdict(tone_spec) if tone_spec else None)
    r = ScheduleRenderer(sched)
    return (r.block(0, int(round(duration * rate))) if render else r), sched


def make_identify(channels: list[str], rate: int = DEFAULT_RATE, gap: float = 0.6,
                  spec: ToneSpec = ToneSpec()) -> np.ndarray:
    """채널 식별용: 채널 k에서 그 채널의 벨 음이 (k+1)번. 귀로 배선/매핑 확인."""
    n = len(channels)
    segs = []
    for k in range(n):
        note = tone(spec.notes[k % len(spec.notes)], spec, rate)
        block = np.zeros((int((gap * 2 + (k + 1) * 0.3 + spec.length) * rate), n))
        pos = int(gap * rate)
        for _ in range(k + 1):
            _place(block[:, k], pos, note)
            pos += int(0.3 * rate)
        segs.append(block)
    return np.concatenate(segs, axis=0)


class ScheduleRenderer:
    """스케줄로부터 필요한 구간만 즉석에서 합성한다 (긴 7채널 WAV를 만들지 않기 위해).

    출력 채널 수: slots = 채널 수, train = 1 (모노; 재생 단계에서 L/R 복제).
    """

    def __init__(self, sched: Schedule):
        self.sched = sched
        self.rate = sched.rate
        self.frames = int(round(sched.duration * sched.rate))
        self.channels = len(sched.channels) if sched.mode == "slots" else 1
        self.shape = (self.frames, self.channels)
        self._waves, self._vidx = voices(sched)
        self._starts = np.array([int(round(t * sched.rate)) for _, t in sched.events], dtype=np.int64)
        self._chans = np.array([max(c, 0) for c, _ in sched.events], dtype=np.int64)

    def __len__(self) -> int:
        return self.frames

    def block(self, start: int, end: int) -> np.ndarray:
        out = np.zeros((end - start, self.channels))
        m = max(len(w) for w in self._waves)
        lo = np.searchsorted(self._starts, start - m, side="right")
        hi = np.searchsorted(self._starts, end, side="left")
        for st, ch, vi in zip(self._starts[lo:hi], self._chans[lo:hi], self._vidx[lo:hi]):
            w = self._waves[vi]
            a = max(start, st)
            b = min(end, st + len(w))
            if a < b:
                out[a - start:b - start, ch] += w[a - st:b - st]
        return out
