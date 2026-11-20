extends Node
## 全域設定（Autoload）
##
## 負責三件事：
##   1. 建立並套用四軌的 InputMap 動作（lane_0 ~ lane_3），讓鍵位可以自由更改。
##   2. 保存玩家偏好：延遲補償、流速、音符樣式與大小、上次遊玩的譜面、音量。
##   3. 提供其他腳本讀取設定。
##
## 設定檔位置：user://settings.cfg
## （Windows 實際路徑：%APPDATA%\Godot\app_userdata\殘響 REVERB\settings.cfg）

signal changed

const CONFIG_PATH := "user://settings.cfg"
const LANE_ACTIONS: Array[String] = ["lane_0", "lane_1", "lane_2", "lane_3"]
const DEFAULT_KEYS: Array[int] = [KEY_D, KEY_F, KEY_J, KEY_K]

## 每一軌目前綁定的實體按鍵（physical keycode，不受鍵盤語系影響）
var keys: Array[int] = DEFAULT_KEYS.duplicate()

## 音畫偏移（毫秒）。正值 = 譜面整體延後，覺得「音符太早」時調大。
var offset_ms: float = 0.0

## 流速倍率。1.0 為基準，越大音符掉得越快（可視距離不變）。
var scroll_speed: float = 1.0

## 音符外觀："bar" = 長條光塊（預設）／"orb" = 圓形光球
var note_style: String = "bar"

## 音符大小倍率（0.6 ~ 1.8）。譜面自己也可以指定，兩者相乘。
var note_scale: float = 1.0

## 上次遊玩的譜面路徑。"開始遊玩"會直接從這首開始。
var last_chart: String = ""

## 打擊音效音量（0~1）
var master_volume: float = 0.85

## 全螢幕
var fullscreen: bool = false

## --- 打擊特效 ---
## 低效能裝置可以整個關掉；數量 / 大小是倍率，不是絕對值。
var hit_fx_enabled: bool = true
var hit_fx_count: float = 1.0
var hit_fx_size: float = 1.0

## --- 每個譜面的背景偏好 ---
## key = 譜面路徑的雜湊；value = {"mode": "auto" / "black" / "custom",
##                                "path": "user://backgrounds/xxx.jpg"}
## 存在獨立的 user://backgrounds.json：譜面很多時不會把 settings.cfg 撐大，
## 而且玩家換圖不需要動到遊戲本身的設定。
var _backgrounds: Dictionary = {}
const BG_CONFIG_PATH := "user://backgrounds.json"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_actions()
	load_settings()
	load_backgrounds()
	apply_input_map()
	apply_audio()


func _ensure_actions() -> void:
	for action in LANE_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)


## 把 keys[] 套用到 InputMap。使用 physical_keycode，所以 AZERTY / 注音輸入
## 都不會影響判定。
func apply_input_map() -> void:
	for i in LANE_ACTIONS.size():
		var action := LANE_ACTIONS[i]
		InputMap.action_erase_events(action)
		var ev := InputEventKey.new()
		ev.physical_keycode = keys[i]
		InputMap.action_add_event(action, ev)


func apply_audio() -> void:
	var db := linear_to_db(clampf(master_volume, 0.0001, 1.0))
	AudioServer.set_bus_volume_db(0, db)


func key_label(lane: int) -> String:
	if lane < 0 or lane >= keys.size():
		return "?"
	return OS.get_keycode_string(keys[lane])


## 設定某一軌的按鍵；若與其他軌衝突則交換，避免兩軌同鍵。
func set_key(lane: int, keycode: int) -> void:
	if lane < 0 or lane >= keys.size():
		return
	for i in keys.size():
		if i != lane and keys[i] == keycode:
			keys[i] = keys[lane]
			break
	keys[lane] = keycode
	apply_input_map()
	save_settings()
	changed.emit()


func load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(CONFIG_PATH) != OK:
		return
	var saved_keys = cf.get_value("input", "keys", null)
	if saved_keys is Array and saved_keys.size() == LANE_ACTIONS.size():
		for i in keys.size():
			var k := int(saved_keys[i])
			keys[i] = k if k > 0 else DEFAULT_KEYS[i]
	offset_ms = float(cf.get_value("game", "offset_ms", offset_ms))
	scroll_speed = clampf(float(cf.get_value("game", "scroll_speed", scroll_speed)), 0.25, 3.0)
	var ns := str(cf.get_value("game", "note_style", note_style))
	note_style = ns if ns in ["bar", "orb"] else "bar"
	note_scale = clampf(float(cf.get_value("game", "note_scale", note_scale)), 0.6, 1.8)
	last_chart = str(cf.get_value("game", "last_chart", last_chart))
	master_volume = clampf(float(cf.get_value("audio", "volume", master_volume)), 0.0, 1.0)
	fullscreen = bool(cf.get_value("video", "fullscreen", fullscreen))
	hit_fx_enabled = bool(cf.get_value("game", "hit_fx_enabled", hit_fx_enabled))
	hit_fx_count = clampf(float(cf.get_value("game", "hit_fx_count", hit_fx_count)), 0.25, 2.0)
	hit_fx_size = clampf(float(cf.get_value("game", "hit_fx_size", hit_fx_size)), 0.5, 2.0)


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("input", "keys", keys)
	cf.set_value("game", "offset_ms", offset_ms)
	cf.set_value("game", "scroll_speed", scroll_speed)
	cf.set_value("game", "note_style", note_style)
	cf.set_value("game", "note_scale", note_scale)
	cf.set_value("game", "last_chart", last_chart)
	cf.set_value("audio", "volume", master_volume)
	cf.set_value("video", "fullscreen", fullscreen)
	cf.set_value("game", "hit_fx_enabled", hit_fx_enabled)
	cf.set_value("game", "hit_fx_count", hit_fx_count)
	cf.set_value("game", "hit_fx_size", hit_fx_size)
	cf.save(CONFIG_PATH)


# --------------------------------------------------------------------------
# 每個譜面的背景
# --------------------------------------------------------------------------

## 譜面路徑 → 穩定的短 key（同一個譜面永遠對到同一張背景）。
func chart_key(chart_path: String) -> String:
	if chart_path.is_empty():
		return ""
	return chart_path.md5_text().substr(0, 16)


func background_mode(key: String) -> String:
	var d = _backgrounds.get(key, {})
	if typeof(d) != TYPE_DICTIONARY:
		return "auto"
	var m := str(d.get("mode", "auto"))
	return m if m in ["auto", "black", "custom"] else "auto"


func background_path(key: String) -> String:
	var d = _backgrounds.get(key, {})
	if typeof(d) != TYPE_DICTIONARY:
		return ""
	return str(d.get("path", ""))


func set_background(key: String, mode: String, path := "") -> void:
	if key.is_empty():
		return
	_backgrounds[key] = {
		"mode": mode if mode in ["auto", "black", "custom"] else "auto",
		"path": path,
	}
	save_backgrounds()


func load_backgrounds() -> void:
	if not FileAccess.file_exists(BG_CONFIG_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(BG_CONFIG_PATH))
	if typeof(data) == TYPE_DICTIONARY:
		_backgrounds = data


func save_backgrounds() -> void:
	var f := FileAccess.open(BG_CONFIG_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_backgrounds, "\t"))
	f.close()
