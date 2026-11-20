class_name SplitWindow
extends Window
## 分割視窗的其中一塊。
##
## 它是一個「真正的 OS 視窗」，不是內嵌在遊戲裡的面板，所以本來就可以
## 被作業系統搬動。問題是：無邊框視窗沒有標題列可以拖、也沒有邊角可以拉，
## 玩家根本沒有辦法控制它。所以這裡自己實作三個手勢：
##
##   左鍵拖曳 → 移動視窗
##   滾輪     → 以視窗中心為基準縮放
##   雙擊     → 還原成譜面安排的大小與位置
##
## 內容是同一張舞台貼圖的一塊裁切（見 WindowDirector 的 CROP_SHADER），
## 所以放大視窗 = 放大那一塊畫面，縮小 = 看得更少但更精細。

const MIN_SIZE := Vector2i(180, 120)
const MAX_SIZE := Vector2i(3840, 2160)
const ZOOM_STEP := 1.07

## 譜面安排的位置與大小（雙擊還原用）
var home_size := Vector2i(640, 720)
var home_pos := Vector2i.ZERO

## 位置被改變時通知 WindowDirector，讓另一塊跟著動。
## 簽名：func(new_pos: Vector2i)
var on_moved: Callable = Callable()

var _dragging := false
var _grab := Vector2i.ZERO
var _hint: Label
var _hint_life := 4.0


func _ready() -> void:
	title = "REVERB"
	borderless = true
	unresizable = true
	always_on_top = true
	transparent = false

	_hint = Label.new()
	_hint.text = "拖曳移動　·　滾輪縮放　·　雙擊還原"
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_override("font", load("res://assets/fonts/NotoSansTC-Regular.otf"))
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hint.add_theme_constant_override("outline_size", 4)
	add_child(_hint)
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.offset_top = -38
	_hint.offset_bottom = -12


func _process(delta: float) -> void:
	if _hint == null or _hint_life <= 0.0:
		return
	_hint_life -= delta
	if _hint_life <= 0.0:
		_hint.visible = false
	elif _hint_life < 0.8:
		_hint.modulate.a = _hint_life / 0.8


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					_restore_home()
				else:
					_dragging = true
					# 用「游標 - 視窗位置」當抓取偏移，而不是累加 event.relative。
					# 視窗被搬動時 relative 會跟著座標系改變，累加會越拖越歪。
					_grab = DisplayServer.mouse_get_position() - position
			else:
				_dragging = false
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scale_by(ZOOM_STEP)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scale_by(1.0 / ZOOM_STEP)
	elif event is InputEventMouseMotion and _dragging:
		position = DisplayServer.mouse_get_position() - _grab
		_notify_moved()


func _scale_by(f: float) -> void:
	var center := position + Vector2i(size.x / 2, size.y / 2)
	var ns := Vector2i(
		clampi(int(round(float(size.x) * f)), MIN_SIZE.x, MAX_SIZE.x),
		clampi(int(round(float(size.y) * f)), MIN_SIZE.y, MAX_SIZE.y)
	)
	size = ns
	# 以中心為基準，視窗才不會一邊放大一邊往右下角跑
	position = center - Vector2i(ns.x / 2, ns.y / 2)
	_show_hint()
	_notify_moved()


func _restore_home() -> void:
	size = home_size
	position = home_pos
	_show_hint()
	_notify_moved()


## 告訴 WindowDirector 我跑到哪了，讓另一塊依「相同 / 相反方向」跟著動。
func _notify_moved() -> void:
	if on_moved.is_valid():
		on_moved.call(position)


func _show_hint() -> void:
	if _hint == null:
		return
	_hint.visible = true
	_hint.modulate.a = 1.0
	_hint_life = 2.4
