extends Node
## 全域設定（Autoload）
##
## 負責三件事：
##   1. 建立並套用四軌的 InputMap 動作（lane_0 ~ lane_3），讓鍵位可以自由更改。
##   2. 保存玩家偏好：延遲補償、流速、視窗特效開關、音量。
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

## 是否允許譜面控制真實視窗（移動、縮放、分割）。
var window_fx: bool = true

## 音符外觀："bar" = 長條光塊（預設）／"orb" = 圓形光球
var note_style: String = "bar"

## 打擊音效音量（0~1）
var master_volume: float = 0.85

## 全螢幕
var fullscreen: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_actions()
	load_settings()
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
	window_fx = bool(cf.get_value("game", "window_fx", window_fx))
	var ns := str(cf.get_value("game", "note_style", note_style))
	note_style = ns if ns in ["bar", "orb"] else "bar"
	master_volume = clampf(float(cf.get_value("audio", "volume", master_volume)), 0.0, 1.0)
	fullscreen = bool(cf.get_value("video", "fullscreen", fullscreen))


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("input", "keys", keys)
	cf.set_value("game", "offset_ms", offset_ms)
	cf.set_value("game", "scroll_speed", scroll_speed)
	cf.set_value("game", "window_fx", window_fx)
	cf.set_value("game", "note_style", note_style)
	cf.set_value("audio", "volume", master_volume)
	cf.set_value("video", "fullscreen", fullscreen)
	cf.save(CONFIG_PATH)
