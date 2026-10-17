"""검출 시각 → 기기별 offset / drift / pairwise skew.

모델 (녹음 시간축 기준):

    a = alpha + beta * s + d_k + g_k * (s - s_mid)

* a      : 녹음에서 검출한 도착 시각
* s      : 신호 파일 안의 소스 시각 (Schedule)
* alpha  : 공통 지연 (Snapcast 버퍼 + 출력 + 녹음 시작 시점 차이)
* beta   : 녹음 장치 clock / 소스 clock 비율 (1 근처)
* d_k    : 기준 기기 대비 기기 k의 고정 offset  ← 우리가 원하는 skew
* g_k    : 기준 기기 대비 기울기  ← 시간이 갈수록 벌어지는 drift

슬롯 모드에서는 같은 cycle 안 기기 쌍의 (a - 예측)를 직접 빼서 이벤트별 skew 분포를,
반복열(solo) 모드에서는 시간창별 평균 offset 차이로 skew 분포를 낸다.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .detect import Detection
from .signals import Schedule

SPEED_OF_SOUND = 343.0  # m/s, 약 20 °C


@dataclass
class Match:
    det_time: float
    src_time: float
    device: int
    strength: float


@dataclass
class Report:
    mode: str
    devices: list[str]
    reference: str
    n_detections: int
    n_matched: int
    n_expected: int
    recorder_ppm: float
    common_latency_s: float
    offsets_ms: dict[str, float]
    drift_ppm: dict[str, float]
    offsets_se_ms: dict[str, float]   # 표준오차 (통계적 불확실성, 1σ)
    drift_se_ppm: dict[str, float]
    jitter_us: dict[str, float]
    counts: dict[str, int]
    pairwise: dict[str, dict] = field(default_factory=dict)
    timeline: list[dict] = field(default_factory=list)
    distance_corrected: bool = False
    notes: list[str] = field(default_factory=list)


# ---------------------------------------------------------------- 매칭

def _labels_for(sched: Schedule, solo_order: list[str] | None):
    """이벤트별 기기 index. train 모드는 solo 순환 정보가 있어야 라벨을 붙일 수 있다."""
    if sched.mode == "slots":
        return [c for c, _ in sched.events], list(sched.channels)
    if not solo_order:
        raise ValueError("train(같은 스트림) 녹음은 --solo-order 로 solo 순서를 알려줘야 기기를 구분할 수 있습니다")
    return None, list(solo_order)


def _initial_alpha(det: np.ndarray, src: np.ndarray, tol: float, window: float) -> float:
    """처음 window 초 안에서 매칭 수가 가장 많은 공통 지연 alpha를 찾는다."""
    d0 = det[det < det[0] + window]
    s0 = src[src < src[0] + window + 5.0]
    best, best_n = 0.0, -1
    for a in d0[:8]:
        for s in s0:
            alpha = a - s
            pred = s0 + alpha
            idx = np.searchsorted(d0, pred)
            n = 0
            for p, i in zip(pred, idx):
                for j in (i - 1, i):
                    if 0 <= j < len(d0) and abs(d0[j] - p) < tol:
                        n += 1
                        break
            if n > best_n:
                best, best_n = alpha, n
    return best


def match(dets: list[Detection], sched: Schedule, tol: float) -> list[tuple[int, int]]:
    """(detection index, event index) 쌍. 짧은 구간에서 시작해 창을 넓혀 가며 clock 비율을 추정한다."""
    if not dets or not sched.events:
        return []
    det = np.array([d.time for d in dets])
    src = np.array([t for _, t in sched.events])
    alpha = _initial_alpha(det, src, tol, window=min(60.0, sched.period * 40))
    beta = 1.0
    pairs: list[tuple[int, int]] = []
    horizon = src[0] + min(60.0, sched.period * 40)
    while True:
        sel = np.flatnonzero(src <= horizon)
        pred = alpha + beta * src[sel]
        idx = np.searchsorted(det, pred)
        pairs = []
        used = set()
        for e, p, i in zip(sel, pred, idx):
            best = None
            for j in (i - 1, i):
                if 0 <= j < len(det) and abs(det[j] - p) < tol and j not in used:
                    if best is None or abs(det[j] - p) < abs(det[best] - p):
                        best = j
            if best is not None:
                used.add(best)
                pairs.append((best, int(e)))
        if len(pairs) >= 2:
            a = det[[p[0] for p in pairs]]
            s = src[[p[1] for p in pairs]]
            if np.ptp(s) > 0:
                beta, alpha = np.polyfit(s, a, 1)
        if horizon >= src[-1]:
            break
        horizon = src[0] + (horizon - src[0]) * 2
    return pairs


# ---------------------------------------------------------------- 적합

def _segments_by_gap(src_times: np.ndarray, period: float, gap_factor: float) -> np.ndarray:
    seg = np.zeros(len(src_times), dtype=int)
    if len(src_times):
        seg[1:] = np.cumsum(np.diff(src_times) > period * gap_factor)
    return seg


def _label_solo_segments(s: np.ndarray, period: float, names: list[str], solo: float,
                         step: float, gap_factor: float, notes: list[str]) -> np.ndarray:
    """solo 구간 길이로 기기를 알아낸다. 기기 k의 solo 길이 = solo + k*step (snap solo와 같은 규칙).

    녹음 시작/끝에 잘린 첫·마지막 구간, 길이가 맞지 않는 구간(두 대가 동시에 울린 구간 등)은 버린다.
    """
    seg = _segments_by_gap(s, period, gap_factor)
    dev = np.full(len(s), -1, dtype=int)
    expected = np.array([solo + k * step for k in range(len(names))])
    tol = max(1.5 * period, 0.3 * step) if len(names) > 1 else 1.5 * period
    nseg = int(seg.max()) + 1 if len(seg) else 0
    used = dropped = 0
    per_dev = [0] * len(names)
    for g in range(nseg):
        m = seg == g
        if g in (0, nseg - 1):
            dropped += 1
            continue
        dur = s[m].max() - s[m].min() + period
        k = int(np.argmin(np.abs(expected - dur)))
        if abs(expected[k] - dur) <= tol:
            dev[m] = k
            used += 1
            per_dev[k] += 1
        else:
            dropped += 1
    notes.append(f"solo 구간 {nseg}개 중 {used}개 사용 (길이로 기기 판별: "
                 + ", ".join(f"{n}={e:g}s×{c}" for n, e, c in zip(names, expected, per_dev))
                 + f"), {dropped}개 제외(처음·끝·길이 불일치)")
    if min(per_dev) < 2:
        notes.append("solo 구간이 기기당 2회 미만이라 drift 추정 신뢰도가 낮습니다")
    return dev


def analyze(dets: list[Detection], sched: Schedule, *, solo_order: list[str] | None = None,
            solo: float = 20.0, solo_step: float = 5.0, reference: str | None = None, distances: dict[str, float] | None = None,
            window: float = 60.0, tol: float | None = None, gap_factor: float = 1.5,
            outlier_mad: float = 6.0) -> Report:
    ev_labels, names = _labels_for(sched, solo_order)
    if tol is None:
        tol = (sched.slot if sched.mode == "slots" else sched.period) * 0.4
    pairs = match(dets, sched, tol)
    if len(pairs) < 4:
        raise ValueError(f"매칭된 이벤트가 {len(pairs)}개뿐입니다. 녹음 레벨/신호 파일/모드를 확인하세요")

    a = np.array([dets[i].time for i, _ in pairs])
    s = np.array([sched.events[e][1] for _, e in pairs])
    notes: list[str] = []

    if sched.mode == "slots":
        dev = np.array([ev_labels[e] for _, e in pairs])
    else:
        dev = _label_solo_segments(s, sched.period, names, solo, solo_step, gap_factor, notes)
        ok = dev >= 0
        a, s, dev = a[ok], s[ok], dev[ok]
        if len(a) < 4:
            raise ValueError("solo 구간을 기기에 배정하지 못했습니다. --solo/--solo-step 값이 snap solo 설정과 같은지 확인하세요")

    present = sorted(set(dev.tolist()))
    ref = names.index(reference) if reference else present[0]
    if ref not in present:
        raise ValueError(f"기준 기기 {names[ref]} 의 이벤트가 없습니다")

    s_mid = float(np.median(s))

    def _fit(ref):
        keep = np.ones(len(a), dtype=bool)
        for _ in range(3):
            cols = [np.ones(len(a)), s]
            others = [k for k in present if k != ref]
            for k in others:
                cols.append((dev == k).astype(float))
            for k in others:
                cols.append((dev == k) * (s - s_mid))
            X = np.stack(cols, axis=1)
            coef, *_ = np.linalg.lstsq(X[keep], a[keep], rcond=None)
            resid = a - X @ coef
            mad = np.median(np.abs(resid[keep] - np.median(resid[keep]))) * 1.4826 + 1e-9
            new_keep = np.abs(resid) < max(outlier_mad * mad, 20e-6)
            if (new_keep == keep).all():
                break
            keep = new_keep
        return coef, resid, keep, X

    coef, resid, keep, X = _fit(ref)
    # 기준 기기의 표본이 이상치로 거의 다 빠지면(크게 울려 검출이 흔들림 등) 나머지 offset이 통째로 엉뚱해진다
    # (2026-10-09 7대: FL 1개만 남아 다른 6대가 −658/−780 ms). 기준을 지정 안 했으면 남은 표본이 가장 많은 기기로 다시.
    kept = {k: int((keep & (dev == k)).sum()) for k in present}
    if reference is None and kept[ref] < 0.5 * max(kept.values()):
        old = names[ref]
        ref = max(present, key=lambda k: kept[k])
        coef, resid, keep, X = _fit(ref)
        notes.append(f"기준 {old}의 표본이 이상치로 대부분 빠져 기준을 {names[ref]}(으)로 바꿈")
    if (~keep).sum():
        notes.append(f"이상치 {int((~keep).sum())}개 제외 (|잔차| > {outlier_mad}×MAD)")

    alpha, beta = coef[0], coef[1]
    others = [k for k in present if k != ref]
    Xk = X[keep]
    dof = max(1, Xk.shape[0] - Xk.shape[1])
    sigma2 = float(np.sum(resid[keep] ** 2) / dof)
    cov = sigma2 * np.linalg.pinv(Xk.T @ Xk)
    se = np.sqrt(np.clip(np.diag(cov), 0, None))
    off = {names[ref]: 0.0}
    drift = {names[ref]: 0.0}
    off_se = {names[ref]: 0.0}
    drift_se = {names[ref]: 0.0}
    for j, k in enumerate(others):
        off[names[k]] = coef[2 + j]
        off_se[names[k]] = se[2 + j] * 1e3
        drift[names[k]] = coef[2 + len(others) + j] / beta * 1e6
        drift_se[names[k]] = se[2 + len(others) + j] / beta * 1e6

    corrected = False
    if distances:
        missing = [n for n in off if n not in distances]
        if missing:
            notes.append(f"거리 정보 없음 → 거리 보정 생략: {missing}")
        else:
            corrected = True
            base = distances[names[ref]]
            for n in off:
                off[n] -= (distances[n] - base) / SPEED_OF_SOUND * beta
            notes.append("offset은 거리 차이(음속 343 m/s)를 뺀 '출력 시각' 기준")

    jitter = {}
    counts = {}
    for k in present:
        m = keep & (dev == k)
        counts[names[k]] = int(m.sum())
        jitter[names[k]] = float(np.std(resid[m]) * 1e6) if m.sum() > 1 else float("nan")

    # 기기별 '보정된 도착 오차' = 공통 모델(alpha, beta)만 뺀 값 → offset+drift+jitter 포함
    dist_term = np.zeros(len(a))
    if corrected:
        base = distances[names[ref]]
        for k in present:
            dist_term[dev == k] = (distances[names[k]] - base) / SPEED_OF_SOUND * beta
    e = a - (alpha + beta * s) - dist_term

    pairwise: dict[str, dict] = {}
    timeline: list[dict] = []
    if sched.mode == "slots":
        cyc = np.floor((s - sched.lead_in) / sched.period + 1e-9).astype(int)
        for i, ki in enumerate(present):
            for kj in present[i + 1:]:
                mi = keep & (dev == ki)
                mj = keep & (dev == kj)
                ci = dict(zip(cyc[mi], e[mi]))
                cj = dict(zip(cyc[mj], e[mj]))
                common = sorted(set(ci) & set(cj))
                if not common:
                    continue
                v = np.array([cj[c] - ci[c] for c in common]) * 1e3
                pairwise[f"{names[ki]}-{names[kj]}"] = _stats(v, "cycle")
        unit = "cycle"
    else:
        unit = "window"
    # 시간창별 평균 오차 (모드 공통) → drift 확인용 타임라인 + solo 모드의 skew 분포
    t0, t1 = s.min(), s.max()
    edges = np.arange(t0, t1 + window, window)
    for w0, w1 in zip(edges[:-1], edges[1:]):
        row = {"t_start_s": round(float(w0), 3)}
        for k in present:
            m = keep & (dev == k) & (s >= w0) & (s < w1)
            if m.sum():
                row[names[k]] = round(float(np.mean(e[m]) * 1e3), 4)
        timeline.append(row)
    if sched.mode != "slots":
        for i, ki in enumerate(present):
            for kj in present[i + 1:]:
                ni, nj = names[ki], names[kj]
                v = [r[nj] - r[ni] for r in timeline if ni in r and nj in r]
                if v:
                    pairwise[f"{ni}-{nj}"] = _stats(np.array(v), unit)
        if not pairwise:
            notes.append("같은 시간창에 두 기기 solo가 모두 들어간 창이 없어 창별 skew 대신 전체 적합 offset만 유효합니다. --window를 solo 순환 주기보다 길게 주세요")

    expected = len(sched.events)
    return Report(
        mode=sched.mode, devices=[names[k] for k in present], reference=names[ref],
        n_detections=len(dets), n_matched=int(keep.sum()), n_expected=expected,
        recorder_ppm=(beta - 1) * 1e6, common_latency_s=float(alpha),
        offsets_ms={k: v * 1e3 for k, v in off.items()}, drift_ppm=drift,
        offsets_se_ms=off_se, drift_se_ppm=drift_se,
        jitter_us=jitter, counts=counts, pairwise=pairwise, timeline=timeline,
        distance_corrected=corrected, notes=notes,
    )


def _stats(v_ms: np.ndarray, unit: str) -> dict:
    av = np.abs(v_ms)
    return {
        "n": int(len(v_ms)), "unit": unit,
        "mean_ms": float(np.mean(v_ms)), "median_ms": float(np.median(v_ms)),
        "std_ms": float(np.std(v_ms)),
        "abs_p95_ms": float(np.percentile(av, 95)), "abs_max_ms": float(av.max()),
    }


def format_report(r: Report) -> str:
    L = []
    L.append(f"모드: {r.mode}   기준 기기: {r.reference}   거리 보정: {'예' if r.distance_corrected else '아니오'}")
    L.append(f"검출 {r.n_detections} / 매칭 {r.n_matched} / 신호 이벤트 {r.n_expected}")
    L.append(f"녹음 clock 대비 기준 기기 재생 속도: {r.recorder_ppm:+.1f} ppm   공통 지연(녹음 기준): {r.common_latency_s:.4f} s")
    L.append("")
    L.append(f"{'기기':<8}{'이벤트':>7}{'offset(ms)':>12}{'±1σ(µs)':>9}{'drift(ppm)':>12}{'±1σ':>7}{'잔차σ(µs)':>11}")
    for d in r.devices:
        L.append(f"{d:<8}{r.counts[d]:>7}{r.offsets_ms[d]:>+12.4f}{r.offsets_se_ms[d] * 1e3:>9.1f}"
                 f"{r.drift_ppm[d]:>+12.2f}{r.drift_se_ppm[d]:>7.2f}{r.jitter_us[d]:>11.1f}")
    L.append("  offset: 기준 기기보다 늦으면 +.  drift: 기준 기기 대비 재생 속도 차이 (+면 점점 늦어짐)")
    L.append("  잔차σ: 이벤트마다 흔들리는 정도(지터). ±1σ는 통계 불확실성이며 마이크/방 반사 오차는 포함하지 않음")
    if r.pairwise:
        L.append("")
        L.append(f"{'쌍':<10}{'단위':>8}{'n':>6}{'평균(ms)':>11}{'|p95|(ms)':>11}{'|max|(ms)':>11}{'σ(ms)':>9}")
        for k, v in r.pairwise.items():
            L.append(f"{k:<10}{v['unit']:>8}{v['n']:>6}{v['mean_ms']:>11.4f}{v['abs_p95_ms']:>11.4f}{v['abs_max_ms']:>11.4f}{v['std_ms']:>9.4f}")
    if r.timeline and len(r.timeline) > 1:
        L.append("")
        L.append("시간창별 평균 오차(ms) — 처음 / 중간 / 끝:")
        for row in (r.timeline[0], r.timeline[len(r.timeline) // 2], r.timeline[-1]):
            L.append("  " + "  ".join(f"{k}={v}" for k, v in row.items()))
    for n in r.notes:
        L.append(f"※ {n}")
    return "\n".join(L)
