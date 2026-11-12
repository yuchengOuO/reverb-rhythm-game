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
##   * Settings.window_fx = false 時全部略過。
##   * headless / 建立失敗時靜默略過，不影響遊戲本身。

## 用 preload 而不是 class_name：class_name 需要編輯器掃描過一次才會註冊，
## 在純 headless（--script / --import 前）的環境會找不到符號。
const SPLIT_WINDOW := preload("res://game/SplitWindow.gd")

const CROP_SHADER := """
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D view_tex : filter_linear, repeat_disable;
uniform vec2 uv_offset = vec2(0.0, 0.0);
uniform vec2 uv_scale = vec2(1.0, 1.0);

void fragment() {
	vec2 uv = uv_offset + UV * uv_scale;
	COLOR = texture(view_tex, clamp(uv, vec2(0.0), vec2(1.0)));
}
"""

var enabled := true

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

var _base_pos := Vector2i.ZERO
var _base_size := Vector2i.ZERO
var _win_pos := Vector2i.ZERO
var _win_size := Vector2i.ZERO
var _split_restore := Vector2i.ZERO
var _extra: Array[Window] = []
var _tweens: Array = []
var _shake_time := 0.0
var _shake_strength := 0.0


func setup(surface: ColorRect, stage_vp: SubViewport) -> void:
	_surface = surface
	_stage_vp = stage_vp
	_main_mat = _make_material(Vector2.ZERO, Vector2.ONE)
	if _surface != null:
		_surface.material = _main_mat


func bind_chart(chart: Chart) -> void:
	_chart = chart
	_events = chart.window_events.duplicate()
	_next = 0


func start(conductor: Conductor) -> void:
	_conductor = conductor
	_next = 0
	_active = true
	_win_pos = DisplayServer.window_get_position()
	# 用「繪圖區」尺寸而不是 window_get_size()，避免把標題列算進去
	_win_size = get_viewport().size
	_base_pos = _win_pos
	_base_size = _win_size
	# 若被最大化 / 全螢幕，先回到視窗模式，否則無法移動或縮放
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# 略過已經過去的的事件（例如從暫停恢復）
	var now: float = conductor.song_time if conductor != null else 0.0
	while _next < _events.size() and float(_events[_next].time) < now:
		_next += 1


func stop() -> void:
	_active = false


func reset() -> void:
	_active = false
	_close_extras()
	_set_main_uv(Vector2.ZERO, Vector2.ONE)
	stage_locked = false
	_tweens.clear()
	_shake_time = 0.0
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, false)
	if _base_size != Vector2i.ZERO:
		DisplayServer.window_set_size(_base_size)
		DisplayServer.window_set_position(_base_pos)
	_win_pos = _base_pos
	_win_size = _base_size
	_split_restore = Vector2i.ZERO


func _process(delta: float) -> void:
	if not _active:
		return
	_update_tweens(delta)
	_update_shake(delta)
	_fire_events()


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
	if not Settings.window_fx or DisplayServer.get_name() == "headless":
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
			var target_size := Vector2i(
				int(_base_size.x * float(ev.get("w", 1.0))),
				int(_base_size.y * float(ev.get("h", 1.0)))
			)
			target_size.x = maxi(target_size.x, 320)
			target_size.y = maxi(target_size.y, 240)
			_tween("size", target_size, float(ev.get("duration", 0.5)))
		"shake":
			_shake_time = float(ev.get("duration", 0.4))
			_shake_strength = float(ev.get("strength", 10.0))
		"split":
			_split(int(ev.get("count", 2)))
		"merge":
			_merge()
		"recenter":
			# 回到「目前這顆螢幕」的正中央。用可用區域（扣掉工作列）計算，
			# 否則視窗底部會被工作列蓋住。
			var usable := DisplayServer.screen_get_usable_rect(
				DisplayServer.window_get_current_screen()
			)
			var cur: Vector2i = get_viewport().size
			var centered := Vector2i(
				usable.position.x + (usable.size.x - cur.x) / 2,
				usable.position.y + (usable.size.y - cur.y) / 2
			)
			_tween("pos", centered, float(ev.get("duration", 0.45)))
		"ontop":
			DisplayServer.window_set_flag(
				DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, bool(ev.get("on", true))
			)
		"borderless":
			DisplayServer.window_set_flag(
				DisplayServer.WINDOW_FLAG_BORDERLESS, bool(ev.get("on", true))
			)


func _tween(kind: String, target: Vector2i, duration: float) -> void:
	if duration <= 0.01:
		if kind == "pos":
			_win_pos = target
			DisplayServer.window_set_position(target)
		else:
			_win_size = target
			DisplayServer.window_set_size(target)
		return
	var from := _win_pos if kind == "pos" else _win_size
	_tweens.append({
		"kind": kind,
		"from": from,
		"to": target,
		"t": 0.0,
		"dur": duration,
	})


func _update_tweens(delta: float) -> void:
	for i in range(_tweens.size() - 1, -1, -1):
		var tw: Dictionary = _tweens[i]
		tw.t = float(tw.t) + delta
		var f := clampf(float(tw.t) / maxf(float(tw.dur), 0.0001), 0.0, 1.0)
		var e := f * f * (3.0 - 2.0 * f)
		var v := Vector2(tw.from).lerp(Vector2(tw.to), e)
		if str(tw.kind) == "pos":
			_win_pos = Vector2i(v)
			DisplayServer.window_set_position(_win_pos)
		else:
			_win_size = Vector2i(v)
			DisplayServer.window_set_size(_win_size)
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
# 分割視窗
# --------------------------------------------------------------------------

func _split(count: int) -> void:
	count = clampi(count, 2, 3)
	if not _extra.is_empty():
		_merge()

	var cur_size: Vector2i = get_viewport().size
	var cur_pos := DisplayServer.window_get_position()
	_split_restore = cur_size
	stage_locked = true

	var slice_w := maxi(int(cur_size.x / count), 200)
	DisplayServer.window_set_size(Vector2i(slice_w, cur_size.y))
	_win_size = Vector2i(slice_w, cur_size.y)
	_set_main_uv(Vector2.ZERO, Vector2(1.0 / float(count), 1.0))

	for i in range(1, count):
		var w := _create_window(
			Vector2i(slice_w, cur_size.y),
			Vector2i(cur_pos.x + slice_w * i, cur_pos.y),
			Vector2(float(i) / float(count), 0.0),
			Vector2(1.0 / float(count), 1.0)
		)
		if w != null:
			_extra.append(w)


func _merge() -> void:
	_close_extras()
	_set_main_uv(Vector2.ZERO, Vector2.ONE)
	if _split_restore != Vector2i.ZERO:
		DisplayServer.window_set_size(_split_restore)
		_win_size = _split_restore
	_split_restore = Vector2i.ZERO
	stage_locked = false


func _create_window(sz: Vector2i, pos: Vector2i, uv_off: Vector2, uv_scale: Vector2) -> Window:
	# SplitWindow 自己處理「拖曳移動 / 滾輪縮放 / 雙擊還原」，
	# 因為無邊框視窗沒有標題列可以拖，玩家否則完全無法控制它。
	var win: Window = SPLIT_WINDOW.new()
	win.home_size = sz
	win.home_pos = pos
	win.visible = false
	add_child(win)
	win.size = sz

	var cr := ColorRect.new()
	cr.color = Color.BLACK
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cr.material = _make_material(uv_off, uv_scale)
	win.add_child(cr)
	cr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	win.visible = true
	win.size = sz
	win.position = pos
	return win


func _close_extras() -> void:
	for w in _extra:
		if is_instance_valid(w):
			w.queue_free()
	_extra.clear()


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
