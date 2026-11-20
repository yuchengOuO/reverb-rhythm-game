class_name WindowDirector
extends Node
## 視窗特效導演
##
## 這是本作的第二個特色：譜面不只能移動軌道，還能移動「視窗本身」。
##
## 技術核心：
##   遊戲畫面其實是畫在一個 SubViewport 裡（固定解析度、獨立於視窗），
##   主視窗只是把這張貼圖顯示出來。所以我們可以：
##     * 把主視窗變窄 → 畫面被裁掉一半
##     * 開第二個原生視窗 → 顯示同一張貼圖的另一半
##     * 兩塊拼起來 = 一個被拆到兩個 OS 視窗的遊戲畫面
##   遊戲邏輯完全不用知道這件事，因為它只畫在那個 SubViewport 裡。
##
## 安全機制：
##   * Esc 暫停時一定會 reset()，把視窗還原。
##   * headless / 建立失敗時靜默略過，不影響遊戲本身。
##
## 無邊框：譜面可以在 settings.borderless 指定「進場就是無邊框」。
## 但無邊框視窗沒有標題列，玩家就完全動不了它，所以這裡另外提供
## Alt + 左鍵拖曳 = 移動、Alt + 滾輪 = 縮放。這不是「開關」，
## 而是無邊框狀態下必備的逃生口。

## 用 preload 而不是 class_name：class_name 需要編輯器掃描過一次才會註冊，
## 在純 headless（--script / --import 前）的環境會找不到符號。
const SPLIT_WINDOW := preload("res://game/SplitWindow.gd")

const CROP_SHADER := """
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D view_tex : filter_linear, repeat_disable;
uniform vec2 uv_offset = vec2(0.0, 0.0);
uniform vec2 uv_scale = vec2(1.0, 1.0);

// --- 畫面特效（由 EffectDirector 每幀寫入）---
uniform float fx_flash = 0.0;
uniform float fx_glitch = 0.0;
uniform float fx_invert = 0.0;
uniform float fx_blur = 0.0;
uniform float fx_chroma = 0.0;
uniform float fx_scanline = 0.0;
uniform float fx_vignette = 0.0;
uniform float fx_shake = 0.0;
uniform float fx_zoom = 1.0;
uniform float fx_seed = 0.0;
uniform vec2 fx_texel = vec2(0.000781, 0.001389);

float fx_hash(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

// 把「視窗座標」換成「舞台貼圖座標」，再取樣。
// 分割視窗時 uv_offset / uv_scale 只取舞台的一塊，特效仍然作用在整塊畫面上。
vec3 fx_sample(vec2 suv) {
	vec2 uv = uv_offset + clamp(suv, vec2(0.0), vec2(1.0)) * uv_scale;
	return texture(view_tex, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

void fragment() {
	vec2 suv = UV;

	// 鏡頭縮放（以畫面中心為基準）
	suv = (suv - 0.5) / max(fx_zoom, 0.2) + 0.5;

	// 畫面震動
	if (fx_shake > 0.001) {
		float st = TIME * 47.0;
		suv += vec2(sin(st) * 0.6 + sin(st * 2.3) * 0.4,
		            cos(st * 1.7) * 0.6 + cos(st * 3.1) * 0.4) * 0.010 * fx_shake;
	}

	// 故障：水平條塊隨機位移
	if (fx_glitch > 0.001) {
		float band = floor(suv.y * 28.0);
		float tick = floor(TIME * 20.0);
		float h = fx_hash(band * 1.7 + tick * 3.1 + fx_seed);
		float active = step(0.55, h);
		suv.x += (fx_hash(band + tick) - 0.5) * 0.09 * fx_glitch * active;
	}

	// 色散 / 故障的 RGB 分離
	float ca = fx_chroma * 0.006 + fx_glitch * 0.008;
	vec3 col;
	if (ca > 0.0001) {
		col.r = fx_sample(suv + vec2(ca, 0.0)).r;
		col.g = fx_sample(suv).g;
		col.b = fx_sample(suv - vec2(ca, 0.0)).b;
	} else {
		col = fx_sample(suv);
	}

	// 模糊：五點取樣
	if (fx_blur > 0.001) {
		vec2 px = fx_texel * 8.0 * fx_blur;
		vec3 b = col * 0.4;
		b += fx_sample(suv + vec2(px.x, 0.0)) * 0.15;
		b += fx_sample(suv - vec2(px.x, 0.0)) * 0.15;
		b += fx_sample(suv + vec2(0.0, px.y)) * 0.15;
		b += fx_sample(suv - vec2(0.0, px.y)) * 0.15;
		col = mix(col, b, clamp(fx_blur, 0.0, 1.0));
	}

	// 反色
	col = mix(col, vec3(1.0) - col, clamp(fx_invert, 0.0, 1.0));

	// 掃描線
	if (fx_scanline > 0.001) {
		float s = 0.5 + 0.5 * sin((UV.y * 900.0 + TIME * 90.0) * 1.7);
		col *= 1.0 - clamp(fx_scanline, 0.0, 1.0) * 0.45 * s;
	}

	// 暗角
	if (fx_vignette > 0.001) {
		float d = distance(UV, vec2(0.5)) * 1.4142;
		col *= 1.0 - clamp(fx_vignette, 0.0, 1.0) * smoothstep(0.30, 1.0, d);
	}

	// 閃光（最後疊，蓋掉其他效果）
	col = mix(col, vec3(1.0), clamp(fx_flash, 0.0, 1.0));

	COLOR = vec4(col, 1.0);
}
"""

var enabled := true

## 目前是不是無邊框模式（決定 Alt 手動控制要不要生效）
var borderless := false

## 分割視窗時，舞台尺寸會被鎖住（否則畫面會隨著視窗縮小而重排）
var stage_locked := false

var _surface: ColorRect
var _stage_vp: SubViewport
var _conductor: Conductor
var _chart: Chart
var _main_mat: ShaderMaterial

var _events: Array = []
var _next := 0
var _active := false
## 譜面的初始視窗只套用一次；暫停恢復時不能再把玩家拉回原位
var _initial_applied := false

var _base_pos := Vector2i.ZERO
var _base_size := Vector2i.ZERO
var _win_pos := Vector2i.ZERO
var _win_size := Vector2i.ZERO
## 視窗中心的浮點座標。
##
## 縮放時每一幀都要「移動半個差值」，但 Vector2i 的除法會把 0.5 px 截掉，
## 一秒的動畫累積下來中心會偏掉十幾 px（實測 60 幀漂 13px）。
## 所以中心另外用浮點數保存，每幀從它推算位置，不從上一次的位置累加。
var _center_f := Vector2.ZERO

## 分割視窗（固定兩塊）
var _split_total := Vector2i.ZERO
var _split_axis := "v"      ## "v" = 垂直線分割（左右） / "h" = 水平線分割（上下）
var _split_mode := "mirror" ## "mirror" = 以中線對稱（相反方向） / "same" = 同方向
var _extra_pos := Vector2i.ZERO
## 剛用程式搬過視窗的冷卻幀數（避免把 OS 的延遲誤判成玩家拖曳）
var _poll_grace := 0
var _extra: Array[Window] = []
var _extra_mats: Array[ShaderMaterial] = []
var _tweens: Array = []
var _shake_time := 0.0
var _shake_strength := 0.0

# Alt 手動控制（只在無邊框時生效）
var _dragging := false
var _drag_from := Vector2i.ZERO
var _drag_mouse := Vector2i.ZERO


func setup(surface: ColorRect, stage_vp: SubViewport) -> void:
	_surface = surface
	_stage_vp = stage_vp
	_main_mat = _make_material(Vector2.ZERO, Vector2.ONE)
	if _surface != null:
		_surface.material = _main_mat
	refresh_texel()


func bind_chart(chart: Chart) -> void:
	_chart = chart
	_events = chart.window_events.duplicate()
	_next = 0
	_initial_applied = false


func start(conductor: Conductor) -> void:
	_conductor = conductor
	_next = 0
	_active = true
	# 若被最大化 / 全螢幕，先回到視窗模式，否則無法移動或縮放
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# 譜面指定的初始視窗（大小 / 位置）只套用一次。
	# 暫停恢復時 start() 會再被呼叫一次，那時不能再把玩家拖過的視窗拉回去。
	var applied := Vector2i.ZERO
	if not _initial_applied:
		_initial_applied = true
		applied = _apply_initial_window()
	# 用「繪圖區」尺寸而不是 window_get_size()，避免把標題列算進去。
	# 剛設定完大小的那一幀 viewport 可能還沒更新，所以優先用譜面指定的尺寸。
	_win_size = applied if applied != Vector2i.ZERO else get_viewport().size
	_win_pos = DisplayServer.window_get_position()
	_base_pos = _win_pos
	_base_size = _win_size
	_center_f = Vector2(_win_pos) + Vector2(_win_size) / 2.0
	# 譜面指定的無邊框
	borderless = _chart != null and _chart.borderless
	if borderless and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	# 略過已經過去的的事件（例如從暫停恢復）
	var now: float = conductor.song_time if conductor != null else 0.0
	while _next < _events.size() and float(_events[_next].time) < now:
		_next += 1


## 套用譜面的初始視窗大小／位置，回傳實際使用的尺寸（沒有指定時回傳 ZERO）。
## 寬或高 <= 0 代表「沿用玩家目前的視窗」，只改位置也可以。
func _apply_initial_window() -> Vector2i:
	if _chart == null or DisplayServer.get_name() == "headless":
		return Vector2i.ZERO
	if _chart.window_w <= 0 or _chart.window_h <= 0:
		return Vector2i.ZERO
	var size := Vector2i(
		clampi(_chart.window_w, 320, 7680),
		clampi(_chart.window_h, 240, 4320)
	)
	DisplayServer.window_set_size(size)
	var pos := Vector2i.ZERO
	if _chart.window_centered:
		# 用目前這顆螢幕的「可用區域」（扣掉工作列），否則視窗底部會被工作列蓋住
		var usable := DisplayServer.screen_get_usable_rect(
			DisplayServer.window_get_current_screen()
		)
		pos = usable.position + (usable.size - size) / 2
	else:
		pos = Vector2i(_chart.window_x, _chart.window_y)
	DisplayServer.window_set_position(pos)
	return size


func stop() -> void:
	_active = false


func reset() -> void:
	_active = false
	_dragging = false
	_close_extras()
	_set_main_uv(Vector2.ZERO, Vector2.ONE)
	stage_locked = false
	_tweens.clear()
	_shake_time = 0.0
	borderless = false
	_split_total = Vector2i.ZERO
	_split_axis = "v"
	_split_mode = "mirror"
	_poll_grace = 0
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, false)
	if _base_size != Vector2i.ZERO:
		DisplayServer.window_set_size(_base_size)
		DisplayServer.window_set_position(_base_pos)
	_win_pos = _base_pos
	_win_size = _base_size
	_center_f = Vector2(_base_pos) + Vector2(_base_size) / 2.0


func _process(delta: float) -> void:
	if not _active:
		return
	_update_tweens(delta)
	_update_shake(delta)
	_fire_events()
	_poll_external_move()


## 玩家用標題列（或系統快捷鍵）搬動主視窗時，分割視窗也要跟著走。
## 只在「沒有任何動畫在跑」時偵測，否則會和 tween 互相打架。
func _poll_external_move() -> void:
	if _extra.is_empty() or DisplayServer.get_name() == "headless":
		return
	if _poll_grace > 0:
		_poll_grace -= 1
		return
	if not _tweens.is_empty() or _shake_time > 0.0:
		return
	var actual := DisplayServer.window_get_position()
	if actual == _win_pos:
		return
	var d := actual - _win_pos
	# 1px 以內的差異是 DPI 取整，不要讓另一塊跟著抖
	if absi(d.x) + absi(d.y) <= 1:
		_win_pos = actual
		_center_f = Vector2(actual) + Vector2(_win_size) / 2.0
		return
	_place_main(actual)
	_follow_main(d)


func _fire_events() -> void:
	if _conductor == null:
		return
	var now := _conductor.song_time
	while _next < _events.size():
		var ev: Dictionary = _events[_next]
		if float(ev.get("time", 0.0)) > now:
			break
		_next += 1
		_apply(ev)


# --------------------------------------------------------------------------
# 事件實作
# --------------------------------------------------------------------------

func _apply(ev: Dictionary) -> void:
	if DisplayServer.get_name() == "headless":
		return
	match str(ev.get("type", "")):
		"move":
			var screen := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
			var target := _win_pos
			if bool(ev.get("absolute", false)):
				target = Vector2i(int(ev.get("x", 0.0)), int(ev.get("y", 0.0)))
			else:
				target += Vector2i(
					int(float(ev.get("dx", 0.0)) * screen.x),
					int(float(ev.get("dy", 0.0)) * screen.y)
				)
			_tween("pos", target, float(ev.get("duration", 0.45)))
		"resize":
			if stage_locked:
				return
			# 玩家可能自己拖過視窗，先同步 OS 的實際位置 / 大小，
			# 否則第一次縮放會以「上一個動畫結束的位置」為中心，畫面會跳一下。
			_sync_from_os()
			var target_size := Vector2i(
				int(_base_size.x * float(ev.get("w", 1.0))),
				int(_base_size.y * float(ev.get("h", 1.0)))
			)
			target_size.x = maxi(target_size.x, 320)
			target_size.y = maxi(target_size.y, 240)
			_tween(
				"size", target_size, float(ev.get("duration", 0.5)),
				_normalize_anchor(str(ev.get("anchor", "center")))
			)
		"shake":
			_shake_time = float(ev.get("duration", 0.4))
			_shake_strength = float(ev.get("strength", 10.0))
		"split":
			_split(
				_normalize_axis(str(ev.get("axis", "vertical"))),
				_normalize_split_mode(str(ev.get("move", "mirror")))
			)
		"merge":
			_merge()
		"recenter":
			# 回到「目前這顆螢幕」的正中央。用可用區域（扣掉工作列）計算，
			# 否則視窗底部會被工作列蓋住。
			var usable := DisplayServer.screen_get_usable_rect(
				DisplayServer.window_get_current_screen()
			)
			var dur := float(ev.get("duration", 0.45))
			if not _extra.is_empty() and _split_total != Vector2i.ZERO:
				# 分割中：要讓「合併後」的完整矩形回到螢幕中央，
				# 不是只把左半 / 上半那一塊擺到中央。
				var origin := usable.position + (usable.size - _split_total) / 2
				_tween_pair(origin, origin + _split_offset(), dur)
			else:
				var cur: Vector2i = get_viewport().size
				var centered := Vector2i(
					usable.position.x + (usable.size.x - cur.x) / 2,
					usable.position.y + (usable.size.y - cur.y) / 2
				)
				_tween("pos", centered, dur)
		"ontop":
			DisplayServer.window_set_flag(
				DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, bool(ev.get("on", true))
			)
		"borderless":
			DisplayServer.window_set_flag(
				DisplayServer.WINDOW_FLAG_BORDERLESS, bool(ev.get("on", true))
			)
			borderless = bool(ev.get("on", true))


# --------------------------------------------------------------------------
# 無邊框時的逃生口：Alt + 左鍵拖曳移動、Alt + 滾輪縮放
# --------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not borderless or DisplayServer.get_name() == "headless":
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.alt_pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed:
				_drag_from = DisplayServer.window_get_position()
				_drag_mouse = DisplayServer.mouse_get_position()
			get_viewport().set_input_as_handled()
			return
		if mb.alt_pressed and mb.pressed and mb.button_index in [
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN
		]:
			var factor := 1.06 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.06
			_manual_resize(factor)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseMotion and _dragging:
		# 以「按下瞬間的視窗位置 + 滑鼠位移」計算，而不是逐幀累加，
		# 這樣即使某一幀漏掉事件，視窗也不會慢慢跟滑鼠脫節。
		var target := _drag_from + (DisplayServer.mouse_get_position() - _drag_mouse)
		var d := target - _win_pos
		_place_main(target)
		_follow_main(d)
		get_viewport().set_input_as_handled()


## 以畫面中心為基準縮放（Alt + 滾輪）。
func _manual_resize(factor: float) -> void:
	var cur: Vector2i = get_viewport().size
	var target := Vector2i(
		clampi(int(cur.x * factor), 320, 3840),
		clampi(int(cur.y * factor), 240, 2160)
	)
	_tweens.clear()
	# 用 OS 的實際位置 / 大小當基準（玩家可能自己拖過）
	_sync_from_os()
	_set_size_anchored(target, "center")


## 把 OS 目前的視窗位置 / 大小讀回來（玩家可能自己拖過、或用系統快捷鍵改過）。
func _sync_from_os() -> void:
	if DisplayServer.get_name() == "headless":
		return
	_win_pos = DisplayServer.window_get_position()
	_win_size = get_viewport().size
	_center_f = Vector2(_win_pos) + Vector2(_win_size) / 2.0


## 移動主視窗（不動分割出來的那一塊）。所有移動都走這裡，
## 才會同步更新 _center_f，下一次縮放的中心才不會用到舊值。
func _place_main(p: Vector2i) -> void:
	_win_pos = p
	DisplayServer.window_set_position(p)
	_center_f = Vector2(p) + Vector2(_win_size) / 2.0
	# 剛搬完的幾幀先不要偵測「玩家是不是自己搬了視窗」，
	# 否則 OS 還沒套用新位置時會被誤判成外部拖曳，兩塊會互相推擠。
	_poll_grace = 3


## 以「視窗中心」為基準縮放。
##
## 只呼叫 window_set_size() 時，作業系統固定左上角：放大只會往右下長、
## 縮小只會往左上收，看起來就像「只有一邊在拉伸」。
## 譜面的 resize 事件要的是左右 / 上下同時伸縮，所以這裡同時改位置，
## 讓視窗中心留在原點。
##
## anchor 可以讓譜面刻意「只往一邊縮放」：
##   center     = 中心不動（預設）
##   topleft    = 左上角不動（往右下伸縮）
##   topright   = 右上角不動（往左下伸縮）
##   bottomleft = 左下角不動（往右上伸縮）
##   bottomright= 右下角不動（往左上伸縮）
## UI 是左上原點，所以「右上 / 右下」不動時，位置要跟著往左補。
##
## 這裡刻意用浮點數算「左上角該在哪」再四捨五入，而不是每幀
## `pos += (舊大小 - 新大小) / 2`：Vector2i 的除法會把 0.5 px 截掉，
## 一次 60 幀的縮放動畫會累積出十幾 px 的偏移（實測 13px）。
func _set_size_anchored(target: Vector2i, anchor := "center") -> void:
	var w0 := float(_win_size.x)
	var h0 := float(_win_size.y)
	var w1 := float(target.x)
	var h1 := float(target.y)
	var exact := Vector2(_win_pos)
	match anchor:
		"topleft":
			pass
		"topright":
			exact.x = float(_win_pos.x) + (w0 - w1)
		"bottomleft":
			exact.y = float(_win_pos.y) + (h0 - h1)
		"bottomright":
			exact = Vector2(
				float(_win_pos.x) + (w0 - w1), float(_win_pos.y) + (h0 - h1)
			)
		_:
			exact = _center_f - Vector2(w1, h1) * 0.5
	_win_size = target
	DisplayServer.window_set_size(target)
	_win_pos = Vector2i(exact.round())
	DisplayServer.window_set_position(_win_pos)
	# 中心保留浮點精度：下一幀從這裡推算，不會從四捨五入後的位置重新累積誤差
	_center_f = exact + Vector2(w1, h1) * 0.5


func _normalize_anchor(anchor: String) -> String:
	if anchor in ["topleft", "topright", "bottomleft", "bottomright"]:
		return anchor
	return "center"


func _tween(kind: String, target: Vector2i, duration: float, anchor := "center") -> void:
	if duration <= 0.01:
		if kind == "pos":
			var d := target - _win_pos
			_place_main(target)
			_follow_main(d)
		else:
			_set_size_anchored(target, anchor)
		return
	var from := _win_pos if kind == "pos" else _win_size
	_tweens.append({
		"kind": kind,
		"from": from,
		"to": target,
		"t": 0.0,
		"dur": duration,
		"anchor": anchor,
	})


## 主視窗與分割視窗「一起」移動到指定位置（分割中按 recenter 用）。
func _tween_pair(to_main: Vector2i, to_extra: Vector2i, duration: float) -> void:
	if duration <= 0.01:
		_place_main(to_main)
		_place_extra(to_extra)
		return
	_tweens.append({
		"kind": "pair",
		"from": _win_pos,
		"to": to_main,
		"efrom": _extra_pos,
		"eto": to_extra,
		"t": 0.0,
		"dur": duration,
		"anchor": "center",
	})


func _update_tweens(delta: float) -> void:
	for i in range(_tweens.size() - 1, -1, -1):
		var tw: Dictionary = _tweens[i]
		tw.t = float(tw.t) + delta
		var f := clampf(float(tw.t) / maxf(float(tw.dur), 0.0001), 0.0, 1.0)
		var e := f * f * (3.0 - 2.0 * f)
		var v := Vector2(tw.from).lerp(Vector2(tw.to), e)
		match str(tw.kind):
			"pos":
				var target := Vector2i(v)
				var d := target - _win_pos
				_place_main(target)
				# 分割中：另一塊依「相同 / 相反方向」跟著走
				_follow_main(d)
			"pair":
				_place_main(Vector2i(v))
				_place_extra(Vector2i(Vector2(tw.efrom).lerp(Vector2(tw.eto), e)))
			_:
				# 縮放預設以中心為基準；事件可用 anchor 指定只往某一邊伸縮
				_set_size_anchored(Vector2i(v), str(tw.get("anchor", "center")))
		if f >= 1.0:
			_tweens.remove_at(i)


func _update_shake(delta: float) -> void:
	if _shake_time <= 0.0:
		return
	_shake_time -= delta
	if _shake_time <= 0.0:
		DisplayServer.window_set_position(_win_pos)
		return
	var off := Vector2i(
		randi_range(-1, 1) * int(_shake_strength),
		randi_range(-1, 1) * int(_shake_strength)
	)
	DisplayServer.window_set_position(_win_pos + off)


# --------------------------------------------------------------------------
# 分割視窗（固定兩塊）
# --------------------------------------------------------------------------
#
# 只會分成「兩塊」，但可以選：
#   axis = vertical   垂直線切開 → 左 / 右兩塊
#   axis = horizontal 水平線切開 → 上 / 下兩塊
#
# 兩塊是同一張舞台貼圖的兩個 UV 區塊，所以遊戲邏輯完全不用知道。
# 移動時另一塊會跟著走：
#   move = mirror（預設）以分割線為鏡射軸 → 相反方向
#   move = same   兩塊朝同一個方向平移
# 鏡射只反轉「垂直於分割線」的那個軸，另一個軸同向 ——
# 左右分的時候上下仍然一起動，畫面才不會錯位。

func _normalize_axis(axis: String) -> String:
	var a := axis.strip_edges().to_lower()
	if a in ["h", "horizontal", "horiz", "水平"]:
		return "h"
	return "v"


func _normalize_split_mode(mode: String) -> String:
	var m := mode.strip_edges().to_lower()
	if m in ["same", "same_dir", "同向", "相同", "same_direction"]:
		return "same"
	return "mirror"


## 第二塊相對主視窗的位移（也等於「合併後大小的一半」）。
func _split_offset() -> Vector2i:
	if _split_axis == "h":
		return Vector2i(0, maxi(_split_total.y / 2, 120))
	return Vector2i(maxi(_split_total.x / 2, 160), 0)


func _split_uv_scale() -> Vector2:
	return Vector2(1.0, 0.5) if _split_axis == "h" else Vector2(0.5, 1.0)


func _split_uv_offset() -> Vector2:
	return Vector2(0.0, 0.5) if _split_axis == "h" else Vector2(0.5, 0.0)


func _split(axis: String, mode: String) -> void:
	var base: Vector2i = _split_total if _split_total != Vector2i.ZERO else get_viewport().size
	var origin := _win_pos
	if not _extra.is_empty():
		# 已經在分割中（例如中途換方向）：沿用原本的完整大小重新切。
		# 不要先 _merge() —— window_set_size() 還沒生效時讀到的大小會是舊的。
		origin = _pair_origin()
		_close_split()

	_split_axis = axis
	_split_mode = mode
	_split_total = base
	stage_locked = true

	var half := _split_offset()
	var slice: Vector2i = base - half
	# 主視窗 = 左半 / 上半
	_win_size = slice
	DisplayServer.window_set_size(slice)
	_place_main(origin)
	_set_main_uv(Vector2.ZERO, _split_uv_scale())

	# 第二塊 = 右半 / 下半
	var w := _create_window(slice, origin + half, _split_uv_offset(), _split_uv_scale())
	if w != null:
		_extra.append(w)
		_extra_pos = origin + half


func _close_split() -> void:
	_close_extras()
	_split_total = Vector2i.ZERO
	stage_locked = false


## 兩塊合起來的 bounding box 左上角（重新分割時當基準）。
func _pair_origin() -> Vector2i:
	return Rect2i(_win_pos, _win_size).merge(Rect2i(_extra_pos, _win_size)).position


## 兩塊合起來的中心（合併時讓視窗長回這個中心）。
func _pair_center() -> Vector2:
	var m := Rect2i(_win_pos, _win_size).merge(Rect2i(_extra_pos, _win_size))
	return Vector2(m.position) + Vector2(m.size) / 2.0


func _merge() -> void:
	if _extra.is_empty():
		return
	var size := _split_total
	var center := _pair_center()
	_close_split()
	_set_main_uv(Vector2.ZERO, Vector2.ONE)
	if size == Vector2i.ZERO:
		return
	DisplayServer.window_set_size(size)
	_win_size = size
	# 從兩塊的中心長回去，而不是從左半的左上角往右下長
	_place_main(Vector2i((center - Vector2(size) / 2.0).round()))


## 主視窗移動 d 之後，讓另一塊跟著動。
func _follow_main(d: Vector2i) -> void:
	if _extra.is_empty() or d == Vector2i.ZERO:
		return
	_place_extra(_extra_pos + _pair_delta(d))


## 分割視窗被拖動 / 縮放時，主視窗跟著動。
## 這裡只動主視窗、不再回頭動分割視窗，否則會互相觸發。
func _on_extra_moved(new_pos: Vector2i) -> void:
	var d := new_pos - _extra_pos
	if d == Vector2i.ZERO:
		return
	_extra_pos = new_pos
	_place_main(_win_pos + _pair_delta(d))


## 依「相同 / 相反方向」換算另一塊要移動多少。
func _pair_delta(d: Vector2i) -> Vector2i:
	if _split_mode == "same":
		return d
	# 鏡射：只反轉垂直於分割線的那個軸
	if _split_axis == "h":
		return Vector2i(d.x, -d.y)
	return Vector2i(-d.x, d.y)


func _place_extra(p: Vector2i) -> void:
	_extra_pos = p
	if _extra.is_empty():
		return
	var w: Window = _extra[0]
	if is_instance_valid(w):
		w.position = p


func _create_window(sz: Vector2i, pos: Vector2i, uv_off: Vector2, uv_scale: Vector2) -> Window:
	# SplitWindow 自己處理「拖曳移動 / 滾輪縮放 / 雙擊還原」，
	# 因為無邊框視窗沒有標題列可以拖，玩家否則完全無法控制它。
	var win: Window = SPLIT_WINDOW.new()
	win.home_size = sz
	win.home_pos = pos
	win.on_moved = _on_extra_moved
	win.visible = false
	add_child(win)
	win.size = sz

	var cr := ColorRect.new()
	cr.color = Color.BLACK
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := _make_material(uv_off, uv_scale)
	cr.material = mat
	win.add_child(cr)
	cr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_extra_mats.append(mat)

	win.visible = true
	win.size = sz
	win.position = pos
	return win


func _close_extras() -> void:
	for w in _extra:
		if is_instance_valid(w):
			w.queue_free()
	_extra.clear()
	_extra_mats.clear()


## 主視窗與所有分割視窗的材質（特效要同時套用到每一塊）
func all_materials() -> Array:
	var out: Array = []
	if _main_mat != null:
		out.append(_main_mat)
	for m in _extra_mats:
		if m != null:
			out.append(m)
	return out


## 特效參數：一次寫進所有材質，分割視窗才不會只有主視窗有特效。
func set_effect_params(params: Dictionary) -> void:
	for mat in all_materials():
		for key in params:
			mat.set_shader_parameter(key, params[key])


## 視窗大小改變時更新取樣間距（模糊用）
func refresh_texel() -> void:
	# 關閉遊戲時 size_changed 還會再觸發一次，這時候節點已經離開場景樹，
	# get_viewport() 會是 null（只影響關機時的 log，但很吵）。
	if not is_inside_tree():
		return
	var sz: Vector2i = get_viewport().size
	for mat in all_materials():
		mat.set_shader_parameter("fx_texel", Vector2(
			1.0 / maxf(float(sz.x), 1.0), 1.0 / maxf(float(sz.y), 1.0)
		))


func _set_main_uv(off: Vector2, scale: Vector2) -> void:
	if _main_mat == null:
		return
	_main_mat.set_shader_parameter("uv_offset", off)
	_main_mat.set_shader_parameter("uv_scale", scale)


func _make_material(uv_off: Vector2, uv_scale: Vector2) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = CROP_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("view_tex", _stage_vp.get_texture())
	mat.set_shader_parameter("uv_offset", uv_off)
	mat.set_shader_parameter("uv_scale", uv_scale)
	return mat
