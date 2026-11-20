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
var effects: EffectDirector
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
var menu_chart_label: Label

var state := "menu"
var current_chart_path := ""
## 目前譜面的背景偏好 key（Settings 用它記住「這個譜面」選了哪張圖）
var _chart_key := ""
## 目前載入的背景貼圖（純黑時為 null）
var _bg_tex: Texture2D = null
var _bg_black_btn: Button
var _bg_auto_btn: Button
var _bg_custom_btn: Button
var _bg_label: Label
var _bg_preview: TextureRect
var _bg_dialog: FileDialog
## 譜面禁止全螢幕時，我們會暫時退出全螢幕；離開遊戲後要還原玩家的設定
var _fullscreen_forced := false

var _font: Font
var _theme: Theme
var _rebind_lane := -1
var _rebind_btn: Button
## 開發參數（--note / --scale）有沒有蓋掉設定值。
## 有的話就不要把設定寫回檔案，否則測試用的數值會被存成玩家的偏好。
var _dev_override := false
var _result_score: Label
var _result_detail: Label
## 結算畫面的評價階梯：[{letter, panel, letter_label, note, need}]
var _grade_rows: Array = []


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
				_dev_override = true
			break
	# 開發用：-- --scale=1.4 臨時指定音符大小（不寫入設定檔）
	for a in args:
		if a.begins_with("--scale="):
			Settings.note_scale = clampf(float(a.substr(8)), 0.6, 1.8)
			_dev_override = true
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

	# 特效：寫進 director 的合成材質，所以分割視窗時每一塊都有
	effects = EffectDirector.new()
	add_child(effects)
	effects.setup(director)


## 這個譜面的版面尺寸（UI 的座標系）。
##
## 以「開場時的視窗大小」為準：譜面若指定了初始視窗（settings.window），
## 就用那個大小排版，否則沿用玩家目前的視窗。
## 之後的 resize 事件不會再改它 —— 視窗變小是裁切、變大是露出更多背景，
## 音符、判定點、HUD 一律保持原本的比例。
func _layout_size(ch: Chart) -> Vector2:
	if ch != null and ch.window_w > 0 and ch.window_h > 0:
		return Vector2(
			clampi(ch.window_w, 320, 7680),
			clampi(ch.window_h, 240, 4320)
		)
	return Vector2(stage_vp.size)


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
		# 只更新「繪圖區」大小，不動版面尺寸：
		# 視窗縮放只是裁掉 / 露出更多外圍，音符與判定點的比例不變。
		playfield.view_size = Vector2(sz)
	if director != null:
		director.refresh_texel()


# --------------------------------------------------------------------------
# 流程
# --------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if state == "game" and Input.is_action_just_pressed("ui_cancel"):
		_set_pause(true)
	elif state == "paused" and Input.is_action_just_pressed("ui_cancel"):
		_set_pause(false)


func _start_game(path: String) -> void:
	if path.is_empty():
		_toast("找不到譜面。請把 .json 放進 assets/charts/")
		return
	var chart := Chart.from_file(path)
	if chart == null:
		_toast("譜面讀取失敗：" + path)
		return

	var stream := AudioLoader.load_stream(chart.audio_path)
	if stream == null:
		_toast("找不到音樂檔，將以無聲模式遊玩：" + chart.audio_path)

	_clear_game()
	current_chart_path = path
	_chart_key = Settings.chart_key(path)
	# 記住這次玩的譜面，「開始遊玩」下次就直接進這首
	# （用開發參數跑測試時不寫檔，免得把測試值存成玩家偏好）
	if Settings.last_chart != path and not _dev_override:
		Settings.last_chart = path
		Settings.save_settings()

	# 譜面可以禁止全螢幕（settings.fullscreen = "block"）
	if chart.fullscreen == "block" and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		_fullscreen_forced = true
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	conductor = Conductor.new()
	add_child(conductor)
	conductor.setup(stream, 2.6, Settings.offset_ms / 1000.0)

	playfield = Playfield.new()
	playfield.conductor = conductor
	# 版面尺寸在開場就固定，之後的 resize 事件只裁切 / 露出外圍，不改變 UI 比例
	playfield.stage_size = _layout_size(chart)
	playfield.view_size = Vector2(stage_vp.size)
	stage_root.add_child(playfield)
	playfield.set_chart(chart)
	playfield.auto_play = "--autohit" in OS.get_cmdline_user_args()
	playfield.finished.connect(_on_song_finished)
	_apply_background()

	director.bind_chart(chart)
	director.start(conductor)
	effects.bind_chart(chart)
	effects.start(conductor)
	conductor.start()

	_set_state("game")


func _clear_game() -> void:
	if playfield != null:
		playfield.queue_free()
		playfield = null
	_bg_tex = null
	_chart_key = ""
	if conductor != null:
		conductor.queue_free()
		conductor = null
	if director != null:
		director.reset()
	if effects != null:
		effects.reset()
	if _fullscreen_forced:
		_fullscreen_forced = false
		_apply_fullscreen()


func _set_pause(paused_now: bool) -> void:
	if paused_now:
		if state != "game":
			return
		conductor.set_paused(true)
		director.reset()
		effects.reset()
		_set_state("paused")
	else:
		if state != "paused":
			return
		conductor.set_paused(false)
		director.start(conductor)
		effects.start(conductor)
		_set_state("game")


# --------------------------------------------------------------------------
# 背景（譜面預設 / 玩家自訂）
# --------------------------------------------------------------------------

## 依「玩家對這個譜面的選擇」重新載入背景。
##   auto   → 譜面 settings.background（沒設定就是純黑）
##   black  → 純黑
##   custom → 玩家自己選的圖（會複製到 user://backgrounds/）
func _apply_background() -> void:
	if playfield == null or playfield.chart == null:
		return
	var chart: Chart = playfield.chart
	var mode := Settings.background_mode(_chart_key)
	var path := ""
	if mode == "custom":
		path = Settings.background_path(_chart_key)
		if path.is_empty():
			mode = "auto"
			path = chart.background
	elif mode == "auto":
		path = chart.background

	var tex: Texture2D = null
	if not path.is_empty():
		tex = ImageLoader.load_texture(path)
	# 自訂圖失效（換電腦、檔案被刪）→ 退回譜面預設，不要突然變全黑
	var fallback := false
	if tex == null and mode == "custom" and not chart.background.is_empty():
		tex = ImageLoader.load_texture(chart.background)
		fallback = tex != null
	_bg_tex = tex
	playfield.set_background(tex, chart.background_dim)
	_refresh_bg_ui(mode, fallback)


## 更新暫停選單的按鈕狀態；譜面沒有預設背景時隱藏「譜面預設」。
## mode 是目前「設定上」的模式；fallback = 自訂圖讀不到、暫時顯示譜面預設。
func _refresh_bg_ui(mode: String, fallback := false) -> void:
	if _bg_black_btn == null:
		return
	var chart: Chart = playfield.chart if playfield != null else null
	var has_chart_bg := chart != null and not chart.background.is_empty()

	_bg_auto_btn.visible = has_chart_bg
	_bg_auto_btn.disabled = not has_chart_bg
	# 譜面沒有背景時，auto 的實際結果就是純黑 → 把「純黑」標成選中
	_style_note_btn(_bg_black_btn, mode == "black" or (mode == "auto" and not has_chart_bg))
	_style_note_btn(_bg_auto_btn, mode == "auto" and has_chart_bg)
	_style_note_btn(_bg_custom_btn, mode == "custom")
	if _bg_preview != null:
		_bg_preview.texture = _bg_tex
		_bg_preview.visible = _bg_tex != null
	# 已經有自訂圖時，按鈕代表「切回去／換一張」，不是每次都開檔案對話框
	var has_custom := not Settings.background_path(_chart_key).is_empty()
	if mode == "custom":
		_bg_custom_btn.text = "更換照片…"
		_bg_custom_btn.tooltip_text = "重新選一張圖"
	elif has_custom:
		_bg_custom_btn.text = "自訂照片"
		_bg_custom_btn.tooltip_text = "切回上次選的照片（再按一次可換圖）"
	else:
		_bg_custom_btn.text = "自訂照片…"
		_bg_custom_btn.tooltip_text = "選一張自己的圖（依譜面記住）"

	if _bg_label != null:
		if mode == "custom" and fallback:
			_bg_label.text = "自訂圖讀取失敗，目前顯示譜面預設"
		elif mode == "custom" and _bg_tex == null:
			_bg_label.text = "自訂圖讀取失敗，目前顯示純黑"
		elif _bg_tex != null:
			_bg_label.text = "背景：%s（這首譜面會記住）" % (
				"自訂照片" if mode == "custom" else "譜面預設"
			)
		else:
			_bg_label.text = "背景：純黑（這首譜面會記住）"


func _set_bg_mode(mode: String) -> void:
	if _chart_key.is_empty():
		return
	# 保留玩家原本選的自訂圖路徑，只改模式；切回「自訂」時不用重選一次
	Settings.set_background(_chart_key, mode, Settings.background_path(_chart_key))
	_apply_background()


func _pick_custom_bg() -> void:
	if playfield == null:
		return
	# 已經選過自訂圖、只是暫時切到純黑／譜面預設時，直接切回那張圖，
	# 不用再開一次檔案對話框。想換圖的話（目前就在「自訂」模式）才開對話框。
	var existing := Settings.background_path(_chart_key)
	if Settings.background_mode(_chart_key) != "custom" \
			and not existing.is_empty() and FileAccess.file_exists(existing):
		_set_bg_mode("custom")
		return
	if _bg_dialog == null:
		_bg_dialog = FileDialog.new()
		_bg_dialog.title = "選擇背景圖片"
		_bg_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_bg_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_bg_dialog.use_native_dialog = true
		_bg_dialog.add_filter("*.png,*.jpg,*.jpeg,*.webp,*.bmp", "圖片")
		_bg_dialog.file_selected.connect(_on_bg_file_selected)
		add_child(_bg_dialog)
	_bg_dialog.popup_centered_ratio(0.6)


func _on_bg_file_selected(src_path: String) -> void:
	var dest := ImageLoader.import_custom(src_path, _chart_key)
	if dest.is_empty():
		_toast("讀不到這張圖片，請改用 png / jpg / webp")
		return
	Settings.set_background(_chart_key, "custom", dest)
	_apply_background()
	_toast("背景已更換（這首譜面會記住）")


func _on_song_finished() -> void:
	if state != "game":
		return
	# 音樂淡出（譜面先結束時，音檔可能還有一大段）
	if conductor != null:
		conductor.fade_out(0.9)
	director.reset()
	effects.reset()
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
	elif new_state == "menu":
		_refresh_menu_hint()


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

	# 「開始遊玩」會直接進上次那首，所以在按鈕下面寫清楚是哪一首。
	menu_chart_label = Label.new()
	menu_chart_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_chart_label.add_theme_font_size_override("font_size", 12)
	menu_chart_label.add_theme_color_override("font_color", Color("7a7a7a"))
	box.add_child(menu_chart_label)

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
	var p := _panel("設 定", Vector2(780, 620), true)
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
	style_hint.text = "預設長條；譜面也可以自己鎖定樣式。"
	style_hint.add_theme_font_size_override("font_size", 12)
	style_hint.add_theme_color_override("font_color", Color("8c8c8c"))
	style_row.add_child(style_hint)
	box.add_child(style_row)

	# 音符大小
	var size_row := HBoxContainer.new()
	var size_lab := Label.new()
	size_lab.text = "音符大小"
	size_lab.custom_minimum_size.x = 110
	size_row.add_child(size_lab)
	var size_slider := HSlider.new()
	size_slider.min_value = 0.6
	size_slider.max_value = 1.8
	size_slider.step = 0.05
	size_slider.value = Settings.note_scale
	size_slider.custom_minimum_size = Vector2(380, 28)
	size_row.add_child(size_slider)
	var size_val := Label.new()
	size_val.text = "%.2fx" % Settings.note_scale
	size_val.custom_minimum_size.x = 90
	size_row.add_child(size_val)
	size_slider.value_changed.connect(func(v: float):
		Settings.note_scale = v
		size_val.text = "%.2fx" % v
		Settings.save_settings()
	)
	box.add_child(size_row)

	# 打擊特效（低效能裝置可以整個關掉）
	var fx_head := Label.new()
	fx_head.text = "打擊特效"
	fx_head.add_theme_color_override("font_color", Color("9e9e9e"))
	box.add_child(fx_head)

	var fx_on := CheckBox.new()
	fx_on.text = "顯示擊中粒子（關閉可提升低效能裝置的幀率）"
	fx_on.button_pressed = Settings.hit_fx_enabled
	box.add_child(fx_on)

	var fxc_row := HBoxContainer.new()
	var fxc_lab := Label.new()
	fxc_lab.text = "粒子數量"
	fxc_lab.custom_minimum_size.x = 110
	fxc_row.add_child(fxc_lab)
	var fxc_slider := HSlider.new()
	fxc_slider.min_value = 0.25
	fxc_slider.max_value = 2.0
	fxc_slider.step = 0.05
	fxc_slider.value = Settings.hit_fx_count
	fxc_slider.custom_minimum_size = Vector2(380, 28)
	fxc_row.add_child(fxc_slider)
	var fxc_val := Label.new()
	fxc_val.text = "%.2fx" % Settings.hit_fx_count
	fxc_val.custom_minimum_size.x = 90
	fxc_row.add_child(fxc_val)
	box.add_child(fxc_row)

	var fxs_row := HBoxContainer.new()
	var fxs_lab := Label.new()
	fxs_lab.text = "粒子大小"
	fxs_lab.custom_minimum_size.x = 110
	fxs_row.add_child(fxs_lab)
	var fxs_slider := HSlider.new()
	fxs_slider.min_value = 0.5
	fxs_slider.max_value = 2.0
	fxs_slider.step = 0.05
	fxs_slider.value = Settings.hit_fx_size
	fxs_slider.custom_minimum_size = Vector2(380, 28)
	fxs_row.add_child(fxs_slider)
	var fxs_val := Label.new()
	fxs_val.text = "%.2fx" % Settings.hit_fx_size
	fxs_val.custom_minimum_size.x = 90
	fxs_row.add_child(fxs_val)
	box.add_child(fxs_row)

	var apply_fx_ui := func(on: bool):
		fxc_slider.editable = on
		fxs_slider.editable = on
		fxc_row.modulate.a = 1.0 if on else 0.45
		fxs_row.modulate.a = 1.0 if on else 0.45
	apply_fx_ui.call(Settings.hit_fx_enabled)
	fx_on.toggled.connect(func(on: bool):
		Settings.hit_fx_enabled = on
		Settings.save_settings()
		apply_fx_ui.call(on)
	)
	fxc_slider.value_changed.connect(func(v: float):
		Settings.hit_fx_count = v
		fxc_val.text = "%.2fx" % v
		Settings.save_settings()
	)
	fxs_slider.value_changed.connect(func(v: float):
		Settings.hit_fx_size = v
		fxs_val.text = "%.2fx" % v
		Settings.save_settings()
	)

	box.add_child(_gap(6))

	var mech := Label.new()
	mech.text = "譜面會控制視窗（移動 / 縮放 / 分割）—— 這是遊戲機制，固定開啟。"
	mech.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mech.add_theme_font_size_override("font_size", 12)
	mech.add_theme_color_override("font_color", Color("9e9e9e"))
	box.add_child(mech)

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
	panel.custom_minimum_size = Vector2(460, 470)
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

	box.add_child(_gap(6))

	# --- 背景（依譜面記住）---
	var bg_cap := Label.new()
	bg_cap.text = "背 景"
	bg_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bg_cap.add_theme_font_size_override("font_size", 11)
	bg_cap.add_theme_color_override("font_color", Color("6a6a6a"))
	box.add_child(bg_cap)

	var bg_row := HBoxContainer.new()
	bg_row.add_theme_constant_override("separation", 8)
	bg_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_bg_black_btn = _small_button("純 黑", func(): _set_bg_mode("black"))
	_bg_auto_btn = _small_button("譜面預設", func(): _set_bg_mode("auto"))
	_bg_custom_btn = _small_button("自訂照片…", _pick_custom_bg, 150.0)
	bg_row.add_child(_bg_black_btn)
	bg_row.add_child(_bg_auto_btn)
	bg_row.add_child(_bg_custom_btn)
	box.add_child(bg_row)

	# 小預覽圖：暫停畫面本身會壓暗整個遊戲，光看按鈕不知道換了什麼。
	_bg_preview = TextureRect.new()
	_bg_preview.custom_minimum_size = Vector2(0, 72)
	_bg_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg_preview.visible = false
	box.add_child(_bg_preview)

	_bg_label = Label.new()
	_bg_label.text = "背景：純黑"
	_bg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bg_label.add_theme_font_size_override("font_size", 11)
	_bg_label.add_theme_color_override("font_color", Color("6a6a6a"))
	box.add_child(_bg_label)

	return root


func _build_result() -> Control:
	var root := _full_rect()
	root.theme = _theme
	root.add_child(_bg(Color("000000")))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 56)
	center.add_child(row)

	# --- 左：分數與判定細項 ---
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 6)
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	left.custom_minimum_size = Vector2(440, 0)
	row.add_child(left)

	var cap := Label.new()
	cap.text = "結　算"
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 24)
	cap.add_theme_color_override("font_color", Color("8c8c8c"))
	left.add_child(cap)

	_result_score = Label.new()
	_result_score.text = "0000000"
	_result_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_score.add_theme_font_size_override("font_size", 72)
	_result_score.add_theme_color_override("font_color", Color("ffffff"))
	left.add_child(_result_score)

	var max_label := Label.new()
	max_label.text = "/ 1,000,000"
	max_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	max_label.add_theme_font_size_override("font_size", 14)
	max_label.add_theme_color_override("font_color", Color("6a6a6a"))
	left.add_child(max_label)

	left.add_child(_gap(12))

	_result_detail = Label.new()
	_result_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_detail.add_theme_font_size_override("font_size", 15)
	_result_detail.add_theme_color_override("font_color", Color("9a9a9a"))
	left.add_child(_result_detail)

	left.add_child(_gap(26))

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 12)
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_child(_button("再 來 一 次", func(): _restart(), 190.0))
	btns.add_child(_button("回 主 選 單", func(): _back_to_menu(), 190.0))
	left.add_child(btns)

	# --- 右：評價階梯（由好到差，由上往下）---
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 4)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(right)

	var gcap := Label.new()
	gcap.text = "評 價"
	gcap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gcap.add_theme_font_size_override("font_size", 12)
	gcap.add_theme_color_override("font_color", Color("5c5c5c"))
	right.add_child(gcap)

	_grade_rows.clear()
	for tier in Playfield.GRADE_TIERS:
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(340, 0)
		right.add_child(panel)

		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 10)
		panel.add_child(hb)

		var letter := Label.new()
		letter.text = str(tier.letter)
		letter.custom_minimum_size = Vector2(58, 0)
		letter.add_theme_font_size_override("font_size", 20)
		hb.add_child(letter)

		var note := Label.new()
		note.text = str(tier.note)
		note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		note.add_theme_font_size_override("font_size", 12)
		hb.add_child(note)

		var need := Label.new()
		need.text = "—" if int(tier.min) <= 0 else _fmt_num(int(tier.min))
		need.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		need.add_theme_font_size_override("font_size", 13)
		hb.add_child(need)

		_grade_rows.append({
			"letter": str(tier.letter),
			"panel": panel,
			"letter_label": letter,
			"note": note,
			"need": need,
		})

	return root


func _fill_result() -> void:
	if playfield == null:
		return
	var grade := playfield.grade_letter()
	_result_score.text = _fmt_num(playfield.score)
	_result_detail.text = "ACC %.2f%%    MAX COMBO %d\nPERFECT %d    GREAT %d    GOOD %d    MISS %d" % [
		playfield.accuracy() * 100.0,
		playfield.max_combo,
		playfield.counts["PERFECT"],
		playfield.counts["GREAT"],
		playfield.counts["GOOD"],
		playfield.counts["MISS"],
	]

	# 評價階梯：命中的那一列亮起來，其餘壓暗
	for r in _grade_rows:
		var hit: bool = str(r.letter) == grade
		var panel: PanelContainer = r.panel
		if hit:
			panel.add_theme_stylebox_override("panel", _sb(Color("151515"), Color("ffffff"), 1))
		else:
			panel.add_theme_stylebox_override("panel", _sb(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0))
		var letter: Label = r.letter_label
		letter.add_theme_font_size_override("font_size", 30 if hit else 20)
		letter.add_theme_color_override("font_color", Color("ffffff") if hit else Color("4a4a4a"))
		var note: Label = r.note
		note.add_theme_color_override("font_color", Color("b8b8b8") if hit else Color("3a3a3a"))
		var need: Label = r.need
		need.add_theme_color_override("font_color", Color("d8d8d8") if hit else Color("3a3a3a"))

	# 開發用：自動測試時把結果印到 console，方便用 headless 驗證判定是否正確
	if "--autoplay" in OS.get_cmdline_user_args():
		print("[AUTOTEST] grade=%s score=%d acc=%.4f max_combo=%d P=%d G=%d D=%d M=%d" % [
			grade,
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
	# 上次玩過而且檔案還在 → 直接玩那首；否則退回排序後的第一首。
	if not Settings.last_chart.is_empty() and FileAccess.file_exists(Settings.last_chart):
		return Settings.last_chart
	var paths := Chart.scan_charts()
	if paths.is_empty():
		return ""
	return paths[0]


func _refresh_menu_hint() -> void:
	if menu_chart_label == null:
		return
	var path := _default_chart()
	if path.is_empty():
		menu_chart_label.text = "找不到譜面 · 把 .json 放進 assets/charts/"
		return
	var chart := Chart.from_file(path)
	var prefix := "上次遊玩" if not Settings.last_chart.is_empty() else "第一首"
	if chart == null:
		menu_chart_label.text = "%s · %s" % [prefix, path.get_file()]
		return
	menu_chart_label.text = "%s · %s  ·  %s Lv.%d" % [
		prefix, chart.title, chart.difficulty, chart.level
	]


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


## 1234567 → "1,234,567"
func _fmt_num(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out


func _button(text: String, cb: Callable, min_w := 320.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 50)
	b.add_theme_font_size_override("font_size", 19)
	b.theme = _theme
	b.pressed.connect(cb)
	return b


## 暫停選單用的窄按鈕（背景切換）
func _small_button(text: String, cb: Callable, min_w := 120.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 34)
	b.add_theme_font_size_override("font_size", 14)
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


func _panel(title: String, min_size: Vector2, scroll_content := false) -> Dictionary:
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
	if scroll_content:
		# 設定項目變多時，小視窗（720p）也要能捲動，不能把「返回」擠出畫面。
		var sc := ScrollContainer.new()
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		sc.custom_minimum_size = Vector2(min_size.x - 68.0, min_size.y - 130.0)
		margin.add_child(sc)
		sc.add_child(box)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
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
