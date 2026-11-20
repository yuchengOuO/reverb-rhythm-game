class_name EffectDirector
extends Node
## 譜面特效導演
##
## 譜面除了控制軌道與視窗，還可以「對畫面本身動手」。
## 特效加在「舞台貼圖 → 視窗」這一層的合成 shader 上（WindowDirector 的材質），
## 所以：
##   * 分割視窗時每一塊都會同步出現同樣的特效
##   * 不需要額外的全螢幕節點，也沒有螢幕擷取（screen texture）的相容性問題
##
## 支援的效果（type）：
##   flash     白色閃光
##   glitch    故障（水平條塊位移 + RGB 分離）
##   invert    反色
##   blur      模糊
##   chroma    色散
##   scanline  掃描線
##   vignette  暗角收縮
##   shake     畫面震動
##   zoom      鏡頭縮放
##
## 每個事件都是 { beat, type, duration, strength }；
## strength 0~1（zoom 例外：0.08 = 放大 8%）。

## 每種特效的預設值與包絡。
## attack / release 是「佔總長度的比例」，不是秒：越短越像硬切，越長越柔。
## release = 1.0 代表「整段持續衰減」（閃光就是這種：一閃即退）。
##
## 這裡的 attack 是「淡入要多久」，不是「延遲多久」——
## 事件會**提前** attack × duration 秒開始播（見 _event_start），
## 所以譜面標記的那一拍剛好是效果最強的瞬間，淡入不會讓它看起來慢半拍。
const KIND_DEFAULTS := {
	"flash":    {"duration": 0.35, "strength": 1.0, "attack": 0.02, "release": 1.0},
	"glitch":   {"duration": 0.55, "strength": 1.0, "attack": 0.06, "release": 0.45},
	"invert":   {"duration": 0.30, "strength": 1.0, "attack": 0.25, "release": 0.55},
	"blur":     {"duration": 0.60, "strength": 0.9, "attack": 0.15, "release": 0.45},
	"chroma":   {"duration": 0.50, "strength": 1.0, "attack": 0.08, "release": 0.45},
	"scanline": {"duration": 0.90, "strength": 0.9, "attack": 0.12, "release": 0.40},
	"vignette": {"duration": 0.90, "strength": 1.0, "attack": 0.20, "release": 0.45},
	"shake":    {"duration": 0.35, "strength": 1.0, "attack": 0.02, "release": 0.60},
	"zoom":     {"duration": 0.40, "strength": 0.08, "attack": 0.05, "release": 0.50},
}

## 目前同時在跑的效果 [{type, start, duration, strength}]
var _active: Array = []
var _events: Array = []
var _next := 0
var _running := false
var _conductor: Conductor
var _director: WindowDirector
var _seed := 0.0


## 這個事件「實際開始播」的時間。
##
## 譜面標記的 beat 是**效果最強的那一瞬間**，不是淡入的起點：
## 淡入要花 attack × duration 秒，所以實際起點往前推同樣的時間。
## 這樣「我標在第 32 拍」就真的會在第 32 拍看到滿強度的特效，
## 同時保留 attack 的柔和進場。
func _event_start(ev: Dictionary) -> float:
	var kind := str(ev.get("type", "flash"))
	var d: Dictionary = KIND_DEFAULTS.get(kind, KIND_DEFAULTS["flash"])
	var dur := maxf(float(ev.get("duration", 0.35)), 0.05)
	return float(ev.get("time", 0.0)) - float(d.attack) * dur


func setup(director: WindowDirector) -> void:
	_director = director
	_seed = randf() * 100.0
	_reset_uniforms()


func bind_chart(chart: Chart) -> void:
	# deep copy：下面會往每個事件塞 _start，不能改到 chart 自己的資料
	_events = chart.effect_events.duplicate(true)
	for ev in _events:
		ev["_start"] = _event_start(ev)
	# 提前量依特效種類而不同（暗角 0.18s、閃光 0.007s），
	# 排序後 _next 才能單純往前推進，不會漏掉「時間較晚但提前量較大」的事件。
	_events.sort_custom(func(a, b): return float(a["_start"]) < float(b["_start"]))
	_next = 0


func start(conductor: Conductor) -> void:
	_conductor = conductor
	_next = 0
	_active.clear()
	_running = true
	# 從暫停恢復時，跳過「已經播完」的事件；還在跑的要接回來
	# （只比 _start 的話，剛好在淡入段暫停再繼續，那個特效就會被吃掉）
	var now: float = conductor.song_time if conductor != null else 0.0
	while _next < _events.size():
		var ev: Dictionary = _events[_next]
		var dur := maxf(float(ev.get("duration", 0.35)), 0.05)
		if float(ev["_start"]) + dur >= now:
			break
		_next += 1
	_reset_uniforms()


func stop() -> void:
	_running = false
	_active.clear()
	_reset_uniforms()


## 暫停 / 回選單時把畫面恢復乾淨
func reset() -> void:
	stop()


func _process(_delta: float) -> void:
	if not _running or _conductor == null or _director == null:
		return
	var now := _conductor.song_time

	# 1) 啟動到期的事件
	while _next < _events.size() and float(_events[_next]["_start"]) <= now:
		var ev: Dictionary = _events[_next]
		_next += 1
		_active.append({
			"type": str(ev.get("type", "flash")),
			"start": float(ev["_start"]),
			"duration": maxf(float(ev.get("duration", 0.35)), 0.05),
			"strength": clampf(float(ev.get("strength", 1.0)), 0.0, 1.0),
		})

	# 2) 推進 / 移除；同一種特效取最大值（疊加會爆掉）
	var acc := {}
	for i in range(_active.size() - 1, -1, -1):
		var fx: Dictionary = _active[i]
		var p := (now - float(fx.start)) / float(fx.duration)
		if p >= 1.0:
			_active.remove_at(i)
			continue
		var kind := str(fx.type)
		var amp := float(fx.strength) * _envelope(kind, maxf(p, 0.0))
		acc[kind] = maxf(float(acc.get(kind, 0.0)), amp)

	# 3) 寫進 shader
	_director.set_effect_params({
		"fx_flash": float(acc.get("flash", 0.0)),
		"fx_glitch": float(acc.get("glitch", 0.0)),
		"fx_invert": float(acc.get("invert", 0.0)),
		"fx_blur": float(acc.get("blur", 0.0)),
		"fx_chroma": float(acc.get("chroma", 0.0)),
		"fx_scanline": float(acc.get("scanline", 0.0)),
		"fx_vignette": float(acc.get("vignette", 0.0)),
		"fx_shake": float(acc.get("shake", 0.0)),
		"fx_zoom": 1.0 + float(acc.get("zoom", 0.0)),
		"fx_seed": _seed,
	})


## 0 → 1 → 0 的包絡。p 是 0~1 的進度。
func _envelope(kind: String, p: float) -> float:
	var d: Dictionary = KIND_DEFAULTS.get(kind, KIND_DEFAULTS["flash"])
	var atk: float = maxf(float(d.attack), 0.001)
	var rel: float = maxf(float(d.release), 0.001)
	var a := clampf(p / atk, 0.0, 1.0)
	var r := clampf((1.0 - p) / rel, 0.0, 1.0)
	return minf(a, r)


func _reset_uniforms() -> void:
	if _director == null:
		return
	_director.set_effect_params({
		"fx_flash": 0.0,
		"fx_glitch": 0.0,
		"fx_invert": 0.0,
		"fx_blur": 0.0,
		"fx_chroma": 0.0,
		"fx_scanline": 0.0,
		"fx_vignette": 0.0,
		"fx_shake": 0.0,
		"fx_zoom": 1.0,
		"fx_seed": _seed,
	})
