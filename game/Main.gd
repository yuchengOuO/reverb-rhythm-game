extends Node
## 主控：場景流程、UI、把各個系統接起來。
##
## 節點結構（全部由程式建立，方便直接看程式碼理解）：
##   Main
##   ├─ StageViewport (SubViewport)   ← 遊戲畫面畫在這裡
##   │   └─ Stage (Node2D) └─ Playfield
##   ├─ Surface (ColorRect + shader)  ← 把 StageViewport 貼到主視窗
##   ├─ WindowDirector                ← 控制真實視窗
##   └─ UI (CanvasLayer)              ← 選單 / 暫停 / 結算

const STAGE_MIN := Vector2i(480, 270)

var stage_vp: SubViewport
var stage_root: Node2D
var surface: ColorRect
var director: WindowDirector
var playfield: Playfield
var conductor: Conductor

var ui: CanvasLayer
var menu_root: Control
var select_root: Control
var settings_root: Control
var pause_root: Control
var result_root: Control
var song_box: VBoxContainer
var toast_label: Label

var state := "menu"
var current_chart_path := ""

var _font: Font
var _theme: Theme
var _rebind_lane := -1
var _rebind_btn: Button
var _result_grade: Label
var _result_score: Label
var _result_detail: Label


func _ready() -> void:
	_font = load("res://assets/fonts/NotoSansTC-Regular.otf")
	_theme = _make_theme()

	_build_stage()
	_build_ui()

	get_viewport().size_changed.connect(_on_viewport_resized)
	_on_viewport_resized()
	_apply_fullscreen()
	_set_state("menu")

	# 開發用：godot --path . -- --autoplay 會直接開始第一張譜面
	var args := OS.get_cmdline_user_args()
	# 開發用：-- --note=orb / --note=bar 臨時切換音符樣式（不寫入設定檔）
	for a in args:
		if a.begins_with("--note="):
			var v := a.substr(7)
			if v in ["bar", "orb"]:
				Settings.note_style = v
			break
	if "--autoplay" in args:
		_start_game(_default_chart())
	else:
		# 開發用：-- --screen=settings / --screen=select 直接跳到該畫面
		for a in args:
			if a.begins_with("--screen="):
				_set_state(a.substr(9))
				break
	# 開發用：-- --chart=assets/charts/xxx.json 指定譜面（不必改名搶排序）
	for a in args:
		if a.begins_with("--chart="):
			_start_game(a.substr(8))
			break


func _exit_tree() -> void:
	if director != null:
		director.reset()
	# 先把音訊停掉再讓節點樹收掉，否則引擎關機時會回報 AudioStream 洩漏
	if conductor != null:
		conductor.stop()
		conductor.player.stream = null
	# 註：引擎仍可能在關機時印出「1 resources still in use at exit」（AudioStreamMP3）。
	# 那是「音訊播放中直接結束程式」的已知引擎問題（godotengine/godot#76745），
	# 遊戲端已做到能做的清理，剩下的引用在引擎的音訊執行緒裡，不需再追。
	# 只出現在命令列直接執行時，不影響遊玩與判定。


# --------------------------------------------------------------------------
# 舞台（SubViewport + 顯示表面）
# --------------------------------------------------------------------------

func _build_stage() -> void:
	stage_vp = SubViewport.new()
	stage_vp.size = Vector2i(1280, 720)
	stage_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	stage_vp.transparent_bg = false
	stage_vp.disable_3d = true
	stage_vp.handle_input_locally = false
	add_child(stage_vp)

	stage_root = Node2D.new()
	stage_vp.add_child(stage_root)

	surface = ColorRect.new()
	surface.color = Color.BLACK
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.visible = false
	add_child(surface)
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	director = WindowDirector.new()
	add_child(director)
	director.setup(surface, stage_vp)


func _on_viewport_resized() -> void:
	if director != null and director.stage_locked:
		return
	var vp_size := get_viewport().get_visible_rect().size
	var sz := Vector2i(
		maxi(int(vp_size.x), STAGE_MIN.x),
		maxi(int(vp_size.y), STAGE_MIN.y)
	)
	stage_vp.size = sz
	if playfield != null:
		playfield.stage_size = Vector2(sz)


# --------------------------------------------------------------------------
# 流程
# --------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if state == "game" and Input.is_action_just_pressed("ui_cancel"):
		_set_pause(true)
	elif state == "paused" and Input.is_action_just_pressed("ui_cancel"):
		_set_pause(false)


func _start_game(path: String) -> void:
	var chart := Chart.from_file(path)
	if chart == null:
		_toast("譜面讀取失敗：" + path)
		return

	var stream := AudioLoader.load_stream(chart.audio_path)
	if stream == null:
		_toast("找不到音樂檔，將以無聲模式遊玩：" + chart.audio_path)

	_clear_game()
	current_chart_path = path

	conductor = Conductor.new()
	add_child(conductor)
	conductor.setup(stream, 2.6, Settings.offset_ms / 1000.0)

	playfield = Playfield.new()
	playfield.conductor = conductor
	playfield.stage_size = Vector2(stage_vp.size)
	stage_root.add_child(playfield)
	playfield.set_chart(chart)
	playfield.auto_play = "--autohit" in OS.get_cmdline_user_args()
	playfield.finished.connect(_on_song_finished)

	director.bind_chart(chart)
	director.start(conductor)
	conductor.start()

	_set_state("game")


func _clear_game() -> void:
	if playfield != null:
		playfield.queue_free()
		playfield = null
	if conductor != null:
		conductor.queue_free()
		conductor = null
	if director != null:
		director.reset()


func _set_pause(paused_now: bool) -> void:
	if paused_now:
		if state != "game":
			return
		conductor.set_paused(true)
		director.reset()
		_set_state("paused")
	else:
		if state != "paused":
			return
		conductor.set_paused(false)
		director.start(conductor)
		_set_state("game")


func _on_song_finished() -> void:
	if state != "game":
		return
	conductor.set_paused(true)
	director.reset()
	_fill_result()
	_set_state("result")


func _restart() -> void:
	if current_chart_path.is_empty():
		return
	_start_game(current_chart_path)


func _back_to_menu() -> void:
	_clear_game()
	_set_state("menu")


func _set_state(new_state: String) -> void:
	state = new_state
	menu_root.visible = new_state == "menu"
	select_root.visible = new_state == "select"
	settings_root.visible = new_state == "settings"
	pause_root.visible = new_state == "paused"
	result_root.visible = new_state == "result"

	var playing := new_state == "game" or new_state == "paused"
	surface.visible = playing
	stage_vp.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if playing else SubViewport.UPDATE_DISABLED
	)

	if new_state == "select":
		_refresh_song_list()


func _apply_fullscreen() -> void:
	if Settings.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


# --------------------------------------------------------------------------
# UI 建立
# --------------------------------------------------------------------------

func _build_ui() -> void:
	ui = CanvasLayer.new()
	ui.layer = 2
	add_child(ui)

	menu_root = _build_menu()
	ui.add_child(menu_root)

	select_root = _build_select()
	ui.add_child(select_root)

	settings_root = _build_settings()
	ui.add_child(settings_root)

	pause_root = _build_pause()
	ui.add_child(pause_root)

	result_root = _build_result()
	ui.add_child(result_root)

	toast_label = Label.new()
	toast_label.theme = _theme
	toast_label.add_theme_color_override("font_color", Color("ff6b6b"))
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	toast_label.offset_top = -60
	toast_label.offset_bottom = -28
	toast_label.visible = false
	ui.add_child(toast_label)


func _build_menu() -> Control:
	var root := _full_rect()
	root.theme = _theme
	root.add_child(_bg(Color("000000")))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	center.add_child(box)

	var title := Label.new()
	title.text = "殘 響"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 76)
	title.add_theme_color_override("font_color", Color("ffffff"))
	box.add_child(title)

	var sub := Label.new()
	sub.text = "R E V E R B    ·    4 K   R H Y T H M"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", Color("8c8c8c"))
	box.add_child(sub)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 40)
	box.add_child(gap)

	box.add_child(_button("開 始 遊 玩", func(): _start_game(_default_chart())))
	box.add_child(_button("選 擇 譜 面", func(): _set_state("select")))
	box.add_child(_button("設 定", func(): _set_state("settings")))
	box.add_child(_button("離 開", func(): get_tree().quit()))

	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 26)
	box.add_child(gap2)

	var hint := Label.new()
	hint.text = "D F J K 打擊　·　Esc 暫停　·　譜面可控制軌道與視窗"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color("5c5c5c"))
	box.add_child(hint)

	return root


func _build_select() -> Control:
	var p := _panel("選 擇 譜 面", Vector2(760, 560))
	var box: VBoxContainer = p.box

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(660, 380)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	song_box = VBoxContainer.new()
	song_box.add_theme_constant_override("separation", 8)
	song_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(song_box)

	var back := _button("返 回", func(): _set_state("menu"))
	box.add_child(back)

	return p.root


func _refresh_song_list() -> void:
	for c in song_box.get_children():
		c.queue_free()

	var paths := Chart.scan_charts()
	if paths.is_empty():
		var l := Label.new()
		l.text = "找不到譜面。請把 .json 放到 assets/charts/ 或 user://charts/"
		song_box.add_child(l)
		return

	for path in paths:
		var chart := Chart.from_file(path)
		if chart == null:
			continue
		var label := "%s  ·  %s Lv.%d  ·  BPM %d" % [
			chart.title, chart.difficulty, chart.level, int(chart.get_bpm())
		]
		var captured := path
		var b := _button(label, func(): _start_game(captured), 640.0)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		song_box.add_child(b)


func _build_settings() -> Control:
	var p := _panel("設 定", Vector2(780, 620))
	var box: VBoxContainer = p.box

	var key_title := Label.new()
	key_title.text = "按鍵設定（點一下再按想要的鍵）"
	key_title.add_theme_color_override("font_color", Color("9e9e9e"))
	box.add_child(key_title)

	var key_row := HBoxContainer.new()
	key_row.add_theme_constant_override("separation", 10)
	for lane in 4:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 6)
		var lab := Label.new()
		lab.text = "軌道 %d" % (lane + 1)
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lab.add_theme_font_size_override("font_size", 13)
		col.add_child(lab)
		var b := Button.new()
		b.text = Settings.key_label(lane)
		b.custom_minimum_size = Vector2(150, 52)
		b.add_theme_font_size_override("font_size", 22)
		b.pressed.connect(func(): _begin_rebind(lane, b))
		col.add_child(b)
		key_row.add_child(col)
	box.add_child(key_row)

	box.add_child(_gap(14))

	# 音畫偏移
	var off_row := HBoxContainer.new()
	var off_lab := Label.new()
	off_lab.text = "音畫偏移"
	off_lab.custom_minimum_size.x = 110
	off_row.add_child(off_lab)
	var off_slider := HSlider.new()
	off_slider.min_value = -200
	off_slider.max_value = 200
	off_slider.step = 1
	off_slider.value = Settings.offset_ms
	off_slider.custom_minimum_size = Vector2(380, 28)
	off_row.add_child(off_slider)
	var off_val := Label.new()
	off_val.text = "%+d ms" % int(Settings.offset_ms)
	off_val.custom_minimum_size.x = 90
	off_row.add_child(off_val)
	off_slider.value_changed.connect(func(v: float):
		Settings.offset_ms = v
		off_val.text = "%+d ms" % int(v)
		Settings.save_settings()
	)
	box.add_child(off_row)

	# 流速
	var spd_row := HBoxContainer.new()
	var spd_lab := Label.new()
	spd_lab.text = "音符流速"
	spd_lab.custom_minimum_size.x = 110
	spd_row.add_child(spd_lab)
	var spd_slider := HSlider.new()
	spd_slider.min_value = 0.5
	spd_slider.max_value = 2.0
	spd_slider.step = 0.05
	spd_slider.value = Settings.scroll_speed
	spd_slider.custom_minimum_size = Vector2(380, 28)
	spd_row.add_child(spd_slider)
	var spd_val := Label.new()
	spd_val.text = "%.2fx" % Settings.scroll_speed
	spd_val.custom_minimum_size.x = 90
	spd_row.add_child(spd_val)
	spd_slider.value_changed.connect(func(v: float):
		Settings.scroll_speed = v
		spd_val.text = "%.2fx" % v
		Settings.save_settings()
	)
	box.add_child(spd_row)

	# 音符樣式
	var style_row := HBoxContainer.new()
	style_row.add_theme_constant_override("separation", 10)
	var style_lab := Label.new()
	style_lab.text = "音符樣式"
	style_lab.custom_minimum_size.x = 110
	style_row.add_child(style_lab)

	var style_btns: Array[Button] = []
	for opt in [["bar", "長條"], ["orb", "圓球"]]:
		var b := Button.new()
		b.text = opt[1]
		b.custom_minimum_size = Vector2(120, 36)
		b.theme = _theme
		b.toggle_mode = true
		b.button_pressed = Settings.note_style == opt[0]
		var key: String = opt[0]
		b.pressed.connect(func():
			Settings.note_style = key
			Settings.save_settings()
			for i in style_btns.size():
				var sel: bool = ["bar", "orb"][i] == key
				style_btns[i].button_pressed = sel
				_style_note_btn(style_btns[i], sel)
		)
		_style_note_btn(b, Settings.note_style == opt[0])
		style_btns.append(b)
		style_row.add_child(b)

	var style_hint := Label.new()
	style_hint.text = "預設長條；圓球是原本的樣式。"
	style_hint.add_theme_font_size_override("font_size", 12)
	style_hint.add_theme_color_override("font_color", Color("8c8c8c"))
	style_row.add_child(style_hint)
	box.add_child(style_row)

	box.add_child(_gap(6))

	var wfx := CheckBox.new()
	wfx.text = "允許譜面控制視窗（移動 / 縮放 / 分割）"
	wfx.button_pressed = Settings.window_fx
	wfx.toggled.connect(func(on: bool):
		Settings.window_fx = on
		Settings.save_settings()
	)
	box.add_child(wfx)

	var fs := CheckBox.new()
	fs.text = "全螢幕"
	fs.button_pressed = Settings.fullscreen
	fs.toggled.connect(func(on: bool):
		Settings.fullscreen = on
		Settings.save_settings()
		_apply_fullscreen()
	)
	box.add_child(fs)

	box.add_child(_gap(10))

	var note := Label.new()
	note.text = "提示：覺得音符比音樂早，就把偏移往正的方向調；每 10ms 一格慢慢試。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", Color("8c8c8c"))
	box.add_child(note)

	box.add_child(_button("返 回", func(): _set_state("menu")))

	return p.root


func _build_pause() -> Control:
	var root := _full_rect()
	root.theme = _theme
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 320)
	panel.add_theme_stylebox_override("panel", _sb(Color("0a0a0a"), Color("2b2b2b"), 1))
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 36)
	margin.add_theme_constant_override("margin_right", 36)
	margin.add_theme_constant_override("margin_top", 28)
	margin.add_theme_constant_override("margin_bottom", 28)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	var t := Label.new()
	t.text = "暫 停"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 30)
	box.add_child(t)

	box.add_child(_button("繼 續", func(): _set_pause(false)))
	box.add_child(_button("重 新 開 始", func(): _restart()))
	box.add_child(_button("回 主 選 單", func(): _back_to_menu()))

	return root


func _build_result() -> Control:
	var root := _full_rect()
	root.theme = _theme
	root.add_child(_bg(Color("000000")))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	_result_grade = Label.new()
	_result_grade.text = "S"
	_result_grade.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_grade.add_theme_font_size_override("font_size", 96)
	_result_grade.add_theme_color_override("font_color", Color("ffffff"))
	box.add_child(_result_grade)

	_result_score = Label.new()
	_result_score.text = "0"
	_result_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_score.add_theme_font_size_override("font_size", 40)
	box.add_child(_result_score)

	_result_detail = Label.new()
	_result_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_detail.add_theme_font_size_override("font_size", 15)
	_result_detail.add_theme_color_override("font_color", Color("9a9a9a"))
	box.add_child(_result_detail)

	box.add_child(_gap(24))
	box.add_child(_button("再 來 一 次", func(): _restart()))
	box.add_child(_button("回 主 選 單", func(): _back_to_menu()))

	return root


func _fill_result() -> void:
	if playfield == null:
		return
	_result_grade.text = playfield.grade_letter()
	_result_score.text = "%d" % playfield.score
	_result_detail.text = "ACC %.2f%%    MAX COMBO %d\nPERFECT %d    GREAT %d    GOOD %d    MISS %d" % [
		playfield.accuracy() * 100.0,
		playfield.max_combo,
		playfield.counts["PERFECT"],
		playfield.counts["GREAT"],
		playfield.counts["GOOD"],
		playfield.counts["MISS"],
	]
	# 開發用：自動測試時把結果印到 console，方便用 headless 驗證判定是否正確
	if "--autoplay" in OS.get_cmdline_user_args():
		print("[AUTOTEST] grade=%s score=%d acc=%.4f max_combo=%d P=%d G=%d D=%d M=%d" % [
			playfield.grade_letter(),
			playfield.score,
			playfield.accuracy(),
			playfield.max_combo,
			playfield.counts["PERFECT"],
			playfield.counts["GREAT"],
			playfield.counts["GOOD"],
			playfield.counts["MISS"],
		])


# --------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------

func _default_chart() -> String:
	var paths := Chart.scan_charts()
	if paths.is_empty():
		return ""
	return paths[0]


func _begin_rebind(lane: int, btn: Button) -> void:
	_rebind_lane = lane
	_rebind_btn = btn
	btn.text = "按下按鍵…"


func _end_rebind() -> void:
	if _rebind_btn != null and _rebind_lane >= 0:
		_rebind_btn.text = Settings.key_label(_rebind_lane)
	_rebind_lane = -1
	_rebind_btn = null


func _input(event: InputEvent) -> void:
	if _rebind_lane < 0:
		return
	if event is InputEventKey:
		var ke := event as InputEventKey
		if not ke.pressed or ke.echo:
			return
		if ke.physical_keycode == KEY_ESCAPE:
			_end_rebind()
		else:
			Settings.set_key(_rebind_lane, ke.physical_keycode)
			_end_rebind()
		get_viewport().set_input_as_handled()


func _toast(msg: String) -> void:
	toast_label.text = msg
	toast_label.visible = true
	var timer := get_tree().create_timer(3.5)
	timer.timeout.connect(func(): toast_label.visible = false)


func _full_rect() -> Control:
	var c := Control.new()
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c


func _bg(color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return r


func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _button(text: String, cb: Callable, min_w := 320.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 50)
	b.add_theme_font_size_override("font_size", 19)
	b.theme = _theme
	b.pressed.connect(cb)
	return b


## 二選一按鈕（長條 / 圓球）的選中樣式。
## 只用 toggle_mode 的話，Godot 的預設 pressed 樣式在純黑主題上幾乎看不出差別。
func _style_note_btn(b: Button, on: bool) -> void:
	var border := Color("ffffff") if on else Color("282828")
	var bg := Color("1f1f1f") if on else Color("0e0e0e")
	var fg := Color("ffffff") if on else Color("9a9a9a")
	b.add_theme_stylebox_override("normal", _sb(bg, border, 1))
	b.add_theme_stylebox_override("hover", _sb(Color("1b1b1b"), Color("6a6a6a"), 1))
	b.add_theme_stylebox_override("pressed", _sb(bg, border, 1))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_pressed_color", fg)
	b.add_theme_color_override("font_hover_color", Color("ffffff"))


func _panel(title: String, min_size: Vector2) -> Dictionary:
	var root := _full_rect()
	root.theme = _theme
	root.add_child(_bg(Color("000000")))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = min_size
	panel.add_theme_stylebox_override("panel", _sb(Color("0a0a0a"), Color("2b2b2b"), 1))
	panel.theme = _theme
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 34)
	margin.add_theme_constant_override("margin_right", 34)
	margin.add_theme_constant_override("margin_top", 26)
	margin.add_theme_constant_override("margin_bottom", 26)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 30)
	box.add_child(label)

	return {"root": root, "box": box}


func _make_theme() -> Theme:
	var th := Theme.new()
	th.default_font = _font
	th.default_font_size = 17
	th.set_stylebox("normal", "Button", _sb(Color("0e0e0e"), Color("282828"), 1))
	th.set_stylebox("hover", "Button", _sb(Color("1b1b1b"), Color("ffffff"), 1))
	th.set_stylebox("pressed", "Button", _sb(Color("090909"), Color("ffffff"), 2))
	th.set_stylebox("disabled", "Button", _sb(Color("090909"), Color("1e1e1e"), 1))
	th.set_stylebox("focus", "Button", _sb(Color(0, 0, 0, 0), Color("ffffff"), 1))
	th.set_color("font_color", "Button", Color("e8e8e8"))
	th.set_color("font_hover_color", "Button", Color.WHITE)
	th.set_color("font_pressed_color", "Button", Color.WHITE)
	th.set_color("font_focus_color", "Button", Color.WHITE)
	th.set_color("font_color", "Label", Color("d2d2d2"))
	th.set_color("font_color", "CheckBox", Color("d2d2d2"))
	th.set_stylebox("panel", "PanelContainer", _sb(Color("0a0a0a"), Color("2b2b2b"), 1))

	# 滑桿：預設主題是藍色的，在黑底白光的主題裡會很突兀，改成白色
	th.set_stylebox("slider", "HSlider", _bar(Color("1c1c1c"), 3))
	th.set_stylebox("grabber_area", "HSlider", _bar(Color("ffffff"), 3))
	th.set_stylebox("grabber_area_highlight", "HSlider", _bar(Color("ffffff"), 3))
	th.set_icon("grabber", "HSlider", _circle_tex(16, Color.WHITE))
	th.set_icon("grabber_highlight", "HSlider", _circle_tex(18, Color.WHITE))
	th.set_icon("grabber_disabled", "HSlider", _circle_tex(16, Color(0.35, 0.35, 0.35)))
	return th


func _bar(bg: Color, half_h: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(half_h)
	sb.content_margin_top = half_h
	sb.content_margin_bottom = half_h
	sb.anti_aliasing = true
	return sb


## 程式畫一個白色圓點當滑桿握把（不需要外部素材）
func _circle_tex(size: int, col: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(size, size) * 0.5
	var r := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / r
			var a := clampf(1.0 - smoothstep(0.74, 1.0, d), 0.0, 1.0)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	return ImageTexture.create_from_image(img)


func _sb(bg: Color, border: Color, bw: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	sb.anti_aliasing = true
	return sb
