class_name Chart
extends RefCounted
## 譜面資料模型
##
## 一個 .json 檔就是一首歌的譜面。設計重點：
##   * 音符用「拍（beat）」儲存，不是秒。這樣改 BPM 或做 BPM 變化時，
##     音符會自動跟著音樂跑，不會整首歪掉。
##   * 支援多段 BPM（bpm_segments），段落之間以拍數銜接。
##   * 軌道位移（lanes）與視窗特效（windows）也是以拍為單位的事件。
##
## 檔案格式（實際譜面見 assets/charts/）：
## {
##   "format": "reverb-chart",
##   "version": 1,
##   "meta": { "title": "...", "artist": "...", "difficulty": "Normal",
##             "level": 8, "audio": "res://assets/audio/my_song.mp3" },
##   "timing": { "offset": 0.375,
##               "bpm_segments": [ { "beat": 0, "bpm": 120 } ] },
##   "notes":  [ { "beat": 8.0, "lane": 0, "len": 0.0 } ],
##   "lanes":  [ { "beat": 0, "lane": 0, "x": 0, "y": 0, "rot": 0,
##                 "scale": 1.0, "alpha": 1.0, "ease": "smooth" } ],
##   "windows":[ { "beat": 32, "type": "split",
##                 "axis": "vertical", "move": "mirror" },
##               { "beat": 40, "type": "resize", "w": 0.8, "h": 0.9,
##                 "anchor": "center", "duration": 0.5 } ],
##   "effects":[ { "beat": 48, "type": "flash", "duration": 0.35, "strength": 1.0 } ],
##   "settings":{ "note_style": "any", "note_scale": 1.0,
##                "borderless": true, "fullscreen": "allow",
##                "background": "res://assets/backgrounds/bg.jpg",
##                "background_dim": 0.45,
##                "window": { "width": 1280, "height": 720,
##                            "x": 0, "y": 0, "centered": true } }
## }
##
## settings 是「譜面自己的預設值」，可以整段省略。它讓譜面作者決定
## 這首歌的長相（例如整首只能用長條），玩家設定則在譜面沒指定時才生效。

const FORMAT := "reverb-chart"

var title := "Untitled"
var artist := ""
var difficulty := "Normal"
var level := 1
var audio_path := ""

## 第 0 拍在音檔中的秒數（音檔前面的空白 / 前奏長度）
var offset := 0.0

## [{ beat: float, bpm: float }]，依 beat 排序，第一個一定是 beat 0
var bpm_segments: Array = []

## [{ beat, lane, len, time, end_time }]
var notes: Array = []

## [{ beat, lane, x, y, rot, scale, ease, time }]
## x / y 的單位是「軌道寬度」，1.0 = 往右一根軌道
var lane_events: Array = []

## [{ beat, time, type, ... }]
var window_events: Array = []

## [{ beat, time, type, duration, strength }]
## 畫面特效事件（白閃 / 故障 / 反色 / 模糊 / 色散 / 掃描線 / 暗角 / 震動 / 縮放）。
## 由 EffectDirector 播放，跟視窗事件一樣以拍為單位。
var effect_events: Array = []

## --- 譜面層級設定（settings 區塊）---
## 音符樣式："any" = 依玩家設定／"bar" = 只能長條／"orb" = 只能圓球
var note_style := "any"
## 音符大小倍率（會再乘上玩家設定）
var note_scale := 1.0
## 進場時是否使用無邊框視窗
var borderless := true
## 是否允許這個譜面切換全螢幕："allow" / "block"
var fullscreen := "allow"
## 背景圖路徑（空字串 = 純黑）。只存路徑，圖片本身放在 assets/backgrounds/。
var background := ""
## 背景壓暗程度（0 = 原圖，1 = 全黑）。讓白色音符仍然是畫面最亮的東西。
var background_dim := 0.45
## 視窗初始狀態。寬或高 <= 0 表示「沿用玩家目前的視窗」。
var window_w := 0
var window_h := 0
var window_x := 0
var window_y := 0
## true = 開場自動置中（忽略 window_x / window_y）
var window_centered := true

## 歌曲長度（秒），載入時由最後一個音符推算
var duration := 0.0

var source_path := ""


func get_bpm() -> float:
	if bpm_segments.is_empty():
		return 120.0
	return float(bpm_segments[0].bpm)


## 拍 → 秒（不含 offset）
func time_of_beat(beat: float) -> float:
	var n := bpm_segments.size()
	if n == 0:
		return beat * 0.5
	var acc := 0.0
	for i in n:
		var seg: Dictionary = bpm_segments[i]
		var bpm: float = maxf(float(seg.bpm), 1.0)
		var next_beat := INF
		if i + 1 < n:
			next_beat = float(bpm_segments[i + 1].beat)
		if beat <= next_beat:
			return acc + (beat - float(seg.beat)) * 60.0 / bpm
		acc += (next_beat - float(seg.beat)) * 60.0 / bpm
	return acc


## 秒 → 拍（不含 offset）
func beat_of_time(t: float) -> float:
	var n := bpm_segments.size()
	if n == 0:
		return t * 2.0
	var t0 := 0.0
	for i in n:
		var seg: Dictionary = bpm_segments[i]
		var bpm: float = maxf(float(seg.bpm), 1.0)
		var span := INF
		if i + 1 < n:
			span = (float(bpm_segments[i + 1].beat) - float(seg.beat)) * 60.0 / bpm
		if t <= t0 + span:
			return float(seg.beat) + (t - t0) * bpm / 60.0
		t0 += span
	var last: Dictionary = bpm_segments[n - 1]
	return float(last.beat) + (t - t0) * float(last.bpm) / 60.0


## 音檔時間 → 拍（含 offset）
func beat_at_song_time(t: float) -> float:
	return beat_of_time(t - offset)


func beat_to_song_time(beat: float) -> float:
	return offset + time_of_beat(beat)


# --------------------------------------------------------------------------
# 載入
# --------------------------------------------------------------------------

static func from_file(path: String) -> Chart:
	if not FileAccess.file_exists(path):
		push_error("找不到譜面：" + path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("無法開啟譜面：" + path)
		return null
	var text := f.get_as_text()
	f.close()
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("譜面 JSON 格式錯誤：" + path)
		return null
	var chart := from_dict(data)
	chart.source_path = path
	return chart


static func from_dict(data: Dictionary) -> Chart:
	var chart := Chart.new()

	var meta: Dictionary = data.get("meta", {})
	chart.title = str(meta.get("title", "Untitled"))
	chart.artist = str(meta.get("artist", ""))
	chart.difficulty = str(meta.get("difficulty", "Normal"))
	chart.level = int(meta.get("level", 1))
	chart.audio_path = str(meta.get("audio", ""))

	var timing: Dictionary = data.get("timing", {})
	chart.offset = float(timing.get("offset", 0.0))
	chart._parse_bpm(timing.get("bpm_segments", []))

	# --- 譜面設定（可省略）---
	var cfg = data.get("settings", {})
	if typeof(cfg) == TYPE_DICTIONARY:
		var style := str(cfg.get("note_style", "any"))
		chart.note_style = style if style in ["any", "bar", "orb"] else "any"
		chart.note_scale = clampf(float(cfg.get("note_scale", 1.0)), 0.4, 2.5)
		chart.borderless = bool(cfg.get("borderless", true))
		var fs := str(cfg.get("fullscreen", "allow"))
		chart.fullscreen = fs if fs in ["allow", "block"] else "allow"
		# 背景：只接受字串路徑；空字串 / 缺欄位 = 純黑
		var bg = cfg.get("background", "")
		chart.background = str(bg) if typeof(bg) == TYPE_STRING else ""
		chart.background_dim = clampf(float(cfg.get("background_dim", 0.45)), 0.0, 1.0)
		# 視窗初始狀態（可省略）
		var win = cfg.get("window", {})
		if typeof(win) == TYPE_DICTIONARY:
			chart.window_w = maxi(int(win.get("width", 0)), 0)
			chart.window_h = maxi(int(win.get("height", 0)), 0)
			chart.window_x = int(win.get("x", 0))
			chart.window_y = int(win.get("y", 0))
			chart.window_centered = bool(win.get("centered", true))

	# --- 音符 ---
	for raw in data.get("notes", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var beat := float(raw.get("beat", 0.0))
		var lane := int(raw.get("lane", 0))
		if lane < 0 or lane > 3:
			continue
		var length := maxf(float(raw.get("len", 0.0)), 0.0)
		chart.notes.append({
			"beat": beat,
			"lane": lane,
			"len": length,
			"time": chart.beat_to_song_time(beat),
			"end_time": chart.beat_to_song_time(beat + length),
		})
	chart.notes.sort_custom(func(a, b): return float(a.time) < float(b.time))

	# --- 軌道關鍵影格 ---
	for raw in data.get("lanes", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var lane := int(raw.get("lane", 0))
		if lane < 0 or lane > 3:
			continue
		var beat := float(raw.get("beat", 0.0))
		chart.lane_events.append({
			"beat": beat,
			"lane": lane,
			"x": float(raw.get("x", 0.0)),
			"y": float(raw.get("y", 0.0)),
			"rot": float(raw.get("rot", 0.0)),
			"scale": float(raw.get("scale", 1.0)),
			# 單軌透明度：這一軌的底色、判定球與「這一軌的音符」一起變淡
			"alpha": clampf(float(raw.get("alpha", 1.0)), 0.0, 1.0),
			"ease": str(raw.get("ease", "smooth")),
			"time": chart.beat_to_song_time(beat),
		})
	chart.lane_events.sort_custom(func(a, b): return float(a.time) < float(b.time))

	# --- 視窗事件 ---
	for raw in data.get("windows", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		# 舊譜面可能還有「全螢幕開關」事件，這個事件已經移除，直接忽略。
		if str(raw.get("type", "")) == "fullscreen":
			continue
		var ev: Dictionary = raw.duplicate(true)
		var beat := float(raw.get("beat", 0.0))
		ev["beat"] = beat
		ev["time"] = chart.beat_to_song_time(beat)
		chart.window_events.append(ev)
	chart.window_events.sort_custom(func(a, b): return float(a.time) < float(b.time))

	# --- 特效事件 ---
	for raw in data.get("effects", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var fx: Dictionary = raw.duplicate(true)
		var fx_beat := float(raw.get("beat", 0.0))
		fx["beat"] = fx_beat
		fx["time"] = chart.beat_to_song_time(fx_beat)
		fx["type"] = str(raw.get("type", "flash"))
		fx["duration"] = maxf(float(raw.get("duration", 0.35)), 0.05)
		fx["strength"] = clampf(float(raw.get("strength", 1.0)), 0.0, 1.0)
		chart.effect_events.append(fx)
	chart.effect_events.sort_custom(func(a, b): return float(a.time) < float(b.time))

	# --- 長度 ---
	chart.duration = chart.content_end_time()

	return chart


## 譜面「全部內容都結束」的秒數（歌曲時間）。
##
## 結算判定要用：最後一顆音符的尾端、最後一個軌道關鍵影格、
## 最後一個視窗事件（含動畫長度）、最後一個特效（含持續時間）。
## 注意：軌道關鍵影格沒有「結束」的概念（狀態會一直保持），
## 所以只取它的發生時間。
func content_end_time() -> float:
	var last := 0.0
	for n in notes:
		last = maxf(last, float(n.end_time))
	for ev in lane_events:
		last = maxf(last, float(ev.time))
	for ev in window_events:
		last = maxf(last, float(ev.time) + maxf(float(ev.get("duration", 0.0)), 0.0))
	for ev in effect_events:
		last = maxf(last, float(ev.time) + maxf(float(ev.get("duration", 0.0)), 0.0))
	return last


func _parse_bpm(raw_segments) -> void:
	bpm_segments.clear()
	if raw_segments is Array:
		for raw in raw_segments:
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var bpm := float(raw.get("bpm", 120.0))
			if bpm <= 0.0:
				continue
			bpm_segments.append({
				"beat": float(raw.get("beat", 0.0)),
				"bpm": bpm,
			})
	if bpm_segments.is_empty():
		bpm_segments.append({"beat": 0.0, "bpm": 120.0})
	bpm_segments.sort_custom(func(a, b): return float(a.beat) < float(b.beat))
	# 保證第 0 拍有 BPM，否則前面的拍數沒有速度可用
	if float(bpm_segments[0].beat) > 0.0:
		bpm_segments.push_front({"beat": 0.0, "bpm": float(bpm_segments[0].bpm)})


# --------------------------------------------------------------------------
# 掃描可用譜面
# --------------------------------------------------------------------------

static func scan_charts() -> Array[String]:
	var out: Array[String] = []
	for dir in ["res://assets/charts", "user://charts"]:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for f in d.get_files():
			if f.to_lower().ends_with(".json"):
				out.append(dir.path_join(f))
	out.sort()
	return out
