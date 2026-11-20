#!/usr/bin/env python3
"""把 osu!mania 4K 譜面（.osu）轉成《殘響》的譜面格式（reverb-chart）。

用法：
    python tools/osu_to_chart.py <檔案.osu> [--out 輸出路徑.json]
                                 [--audio res://assets/audio/xxx.mp3]
                                 [--level 14] [--difficulty "LN Tech"]

為什麼需要這支工具：
    osu 用「毫秒」記錄音符，本作則用「拍」，而且允許中途換 BPM。
    直接把毫秒換成秒會讓之後改 BPM 的譜面整首歪掉，所以這裡會：

      1. 讀 [TimingPoints] 的 uninherited 段，建立「時間 → 拍」的分段映射。
      2. 自動挑一個 offset，讓絕大多數音符落在乾淨的 1/8 或 1/3 格線上
         （osu 的 timing point 常常沒有對在真正的重拍上）。
      3. 把 hold（type & 128）的尾端時間換算成長度 len（單位：拍）。

支援：osu!mania 4K（Mode: 3, CircleSize: 4）。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from typing import Iterable

LANE_COUNT = 4


# ---------------------------------------------------------------------------
# .osu 解析
# ---------------------------------------------------------------------------

def read_sections(path: str) -> dict[str, list[str]]:
    """把 .osu 拆成 {區塊名稱: [原始行]}。

    .osu 是 UTF-8（通常帶 BOM），換行可能是 CRLF，這裡都一併處理掉。
    """
    with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        text = f.read()
    sections: dict[str, list[str]] = {}
    current = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, [])
            continue
        if current:
            sections[current].append(line)
    return sections


def parse_key_values(lines: Iterable[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in lines:
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        out[key.strip()] = value.strip()
    return out


def parse_timing_points(lines: Iterable[str]) -> list[dict]:
    """回傳所有 uninherited（真正的 BPM）時間點，依時間排序。"""
    points = []
    for line in lines:
        parts = line.split(",")
        if len(parts) < 2:
            continue
        try:
            time_ms = float(parts[0])
            beat_len = float(parts[1])
        except ValueError:
            continue
        # 舊格式只有 2 欄，視為 uninherited；新格式第 7 欄才是旗標
        uninherited = True
        if len(parts) >= 7:
            uninherited = parts[6].strip() != "0"
        if not uninherited or beat_len <= 0:
            continue
        points.append({"time": time_ms / 1000.0, "beat_len": beat_len / 1000.0})
    points.sort(key=lambda p: p["time"])
    if not points:
        raise SystemExit("這個譜面沒有任何 BPM 時間點（[TimingPoints] 是空的）。")
    return points


def parse_hit_objects(lines: Iterable[str], keys: int) -> list[dict]:
    """回傳 [{time, end, lane}]，time / end 單位是秒。"""
    notes = []
    for line in lines:
        parts = line.split(",")
        if len(parts) < 4:
            continue
        try:
            x = float(parts[0])
            time_ms = float(parts[2])
            kind = int(parts[3])
        except ValueError:
            continue
        if not (kind & 1 or kind & 128):
            continue  # 跳過 spinner / 其他型別
        lane = int(x * keys / 512.0)
        lane = max(0, min(LANE_COUNT - 1, lane))
        end_ms = time_ms
        if kind & 128 and len(parts) > 5:
            try:
                end_ms = float(parts[5].split(":")[0])
            except ValueError:
                end_ms = time_ms
        notes.append({
            "time": time_ms / 1000.0,
            "end": max(end_ms, time_ms) / 1000.0,
            "lane": lane,
        })
    notes.sort(key=lambda n: (n["time"], n["lane"]))
    return notes


# ---------------------------------------------------------------------------
# 時間 ↔ 拍
# ---------------------------------------------------------------------------

class BeatMap:
    """依 BPM 時間點把「秒」換成「拍」。

    offset（第 0 拍的秒數）是可以平移的：osu 的 timing point 常常落在
    重拍前 1/4 拍或 1/8 拍，直接拿它當第 0 拍，譜面在編輯器裡就會全部
    卡在 .75 這種難看的格線上。
    """

    def __init__(self, points: list[dict], shift_beats: float = 0.0):
        self.points = points
        self.beat_len0 = points[0]["beat_len"]
        self.offset = points[0]["time"] + shift_beats * self.beat_len0
        # 每個時間點對應的拍數（以 self.offset 為第 0 拍）
        self.beats: list[float] = []
        acc = (points[0]["time"] - self.offset) / self.beat_len0
        self.beats.append(acc)
        for i in range(1, len(points)):
            prev = points[i - 1]
            acc += (points[i]["time"] - prev["time"]) / prev["beat_len"]
            self.beats.append(acc)

    def beat_at(self, t: float) -> float:
        idx = 0
        for i, p in enumerate(self.points):
            if p["time"] <= t:
                idx = i
            else:
                break
        return self.beats[idx] + (t - self.points[idx]["time"]) / self.points[idx]["beat_len"]

    def bpm_segments(self) -> list[dict]:
        """輸出譜面的 bpm_segments。BPM 都一樣時只留一段，譜面比較乾淨。"""
        bpms = [60.0 / p["beat_len"] for p in self.points]
        if max(bpms) - min(bpms) < 0.01:
            return [{"beat": 0, "bpm": round(bpms[0], 3)}]
        segs = []
        for i, p in enumerate(self.points):
            segs.append({"beat": round(self.beats[i], 4), "bpm": round(bpms[i], 3)})
        if segs[0]["beat"] > 0:
            segs.insert(0, {"beat": 0, "bpm": segs[0]["bpm"]})
        return segs


## 允許吸附的拍子分母。osu 記錄時間只到 1 毫秒，換算成拍之後會出現
## 15.9983 這種「差 0.5 毫秒」的數字；只要落在 0.012 拍（約 3ms）內，
## 就吸附到最近的常用格線，譜面在編輯器裡才會是乾淨的 16.0。
SNAP_DENOMS = (1, 2, 3, 4, 6, 8, 12, 16, 24, 32)


def snap_beat(beat: float, tolerance: float = 0.012) -> float:
    best = beat
    best_d = tolerance
    for d in SNAP_DENOMS:
        cand = round(beat * d) / d
        diff = abs(cand - beat)
        if diff < best_d:
            best_d = diff
            best = cand
    return round(best, 4)


def pick_shift(points: list[dict], notes: list[dict]) -> float:
    """挑一個讓音符最貼格線的 offset 位移（單位：拍，1/16 拍為一級）。

    評分方式：
      1. 量化誤差總和（越小越好）—— 同時考慮 1/8 與 1/3 格線，
         因為很多譜面會混用三連音。
      2. 落在整拍上的音符數量（越多越好）—— 用來打破平手，
         例如 offset 差 1/4 拍時誤差一樣，但其中一個會讓音符全在整拍上。
      3. 位移量（越小越好）—— 盡量貼近原本的 timing point。
    """
    best = None
    for k in range(-8, 9):
        shift = k / 16.0
        bm = BeatMap(points, shift)
        err = 0.0
        whole = 0
        for n in notes:
            b = bm.beat_at(n["time"])
            e8 = abs(b * 8.0 - round(b * 8.0)) / 8.0
            e3 = abs(b * 3.0 - round(b * 3.0)) / 3.0
            err += min(e8, e3)
            if abs(b - round(b)) < 0.02:
                whole += 1
        score = (round(err, 4), -whole, abs(k))
        if best is None or score < best[0]:
            best = (score, shift)
    return best[1]


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def convert(args) -> dict:
    sections = read_sections(args.osu)
    general = parse_key_values(sections.get("General", []))
    meta = parse_key_values(sections.get("Metadata", []))
    diff = parse_key_values(sections.get("Difficulty", []))

    mode = int(general.get("Mode", "0"))
    if mode != 3:
        raise SystemExit(f"這不是 osu!mania 譜面（Mode: {mode}）。本作只支援 4K mania。")
    keys = int(float(diff.get("CircleSize", "4") or 4))
    if keys != LANE_COUNT:
        raise SystemExit(
            f"這個譜面是 {keys}K，本作只有 4 軌，無法直接轉換。"
        )

    points = parse_timing_points(sections.get("TimingPoints", []))
    notes = parse_hit_objects(sections.get("HitObjects", []), keys)
    if not notes:
        raise SystemExit("譜面裡沒有任何音符。")

    shift = pick_shift(points, notes)
    bm = BeatMap(points, shift)

    # 同一個時間、同一軌出現兩顆 → 遊戲裡會變成「一顆打不到」的幽靈音符
    seen: set[tuple[float, int]] = set()
    out_notes = []
    dupes = 0
    for n in notes:
        beat = snap_beat(bm.beat_at(n["time"]))
        end_beat = snap_beat(bm.beat_at(n["end"]))
        length = round(end_beat - beat, 4)
        key = (round(beat, 3), n["lane"])
        if key in seen:
            dupes += 1
            continue
        seen.add(key)
        out_notes.append({
            "beat": beat,
            "lane": n["lane"],
            "len": max(length, 0.0),
        })
    out_notes.sort(key=lambda x: (x["beat"], x["lane"]))

    # 難度：用「2 秒窗內最多打了幾顆」估，再換成 1–20 的等級
    peak = 0
    j = 0
    for i in range(len(notes)):
        while notes[i]["time"] - notes[j]["time"] > 2.0:
            j += 1
        peak = max(peak, i - j + 1)
    peak_nps = peak / 2.0

    title = meta.get("TitleUnicode") or meta.get("Title") or "Untitled"
    artist = meta.get("ArtistUnicode") or meta.get("Artist") or ""
    version = meta.get("Version") or "Normal"
    level = args.level if args.level else max(1, min(20, round(peak_nps * 2.2)))

    audio = args.audio or ("res://assets/audio/" + general.get("AudioFilename", "audio.mp3"))

    chart = {
        "format": "reverb-chart",
        "version": 1,
        "meta": {
            "title": title,
            "artist": artist,
            "difficulty": args.difficulty or version,
            "level": level,
            "audio": audio,
        },
        "timing": {
            "offset": round(bm.offset, 4),
            "bpm_segments": bm.bpm_segments(),
        },
        # 譜面層級的預設值：音符樣式不限、大小 1.0、無邊框、允許全螢幕
        "settings": {
            "note_style": "any",
            "note_scale": 1.0,
            "borderless": True,
            "fullscreen": "allow",
        },
        "notes": out_notes,
        "lanes": [],
        "windows": [],
    }

    print(f"  標題      {title} — {version}")
    print(f"  音符      {len(out_notes)} 顆（長條 {sum(1 for n in out_notes if n['len'] > 0)}）")
    if dupes:
        print(f"  略過重複  {dupes} 顆（同拍同軌）")
    print(f"  BPM       {chart['timing']['bpm_segments'][0]['bpm']}"
          f"{'（含變化，共 %d 段）' % len(chart['timing']['bpm_segments']) if len(chart['timing']['bpm_segments']) > 1 else ''}")
    print(f"  Offset    {chart['timing']['offset']:.4f}s（位移 {shift:+.4f} 拍）")
    print(f"  最高密度  {peak_nps:.1f} 顆/秒 → 等級 {level}")
    print(f"  長度      {out_notes[-1]['beat'] * 60.0 / chart['timing']['bpm_segments'][0]['bpm'] + chart['timing']['offset']:.1f} 秒")
    return chart


def main() -> None:
    ap = argparse.ArgumentParser(description="osu!mania 4K → 殘響譜面")
    ap.add_argument("osu", help="來源 .osu 檔")
    ap.add_argument("--out", help="輸出 .json 路徑（預設放在 assets/charts/）")
    ap.add_argument("--audio", help="音檔路徑（預設沿用 .osu 裡的 AudioFilename）")
    ap.add_argument("--level", type=int, help="難度等級 1–20（預設自動估算）")
    ap.add_argument("--difficulty", help="難度名稱（預設沿用 .osu 的 Version）")
    args = ap.parse_args()

    print(f"轉換 {os.path.basename(args.osu)} …")
    chart = convert(args)

    out = args.out
    if not out:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        name = (chart["meta"]["title"] or "chart").replace("/", "_").replace("\\", "_")
        out = os.path.join(root, "assets", "charts", name + " (osu).json")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(chart, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"已寫入 {out}")


if __name__ == "__main__":
    sys.exit(main())
