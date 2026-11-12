class_name AudioLoader
extends RefCounted
## 音樂檔載入工具。
##
## 支援三種寫法：
##   1. res:// 路徑（放在 assets/audio/ 裡的檔案，最推薦）
##   2. 只有檔名（例如 "my_song.mp3"）→ 自動到 assets/audio/ 找
##   3. 絕對路徑（例如 "C:/Music/song.mp3"）→ 執行時直接讀取，不必匯入
##
## 注意：Godot 原生不支援 .m4a / .aac，請先轉成 mp3 或 ogg：
##   ffmpeg -i song.m4a -b:a 192k song.mp3

const SEARCH_DIRS: Array[String] = ["res://assets/audio/", "user://audio/"]


static func load_stream(path: String) -> AudioStream:
	if path.is_empty():
		return null

	# 1. 專案內資源
	if (path.begins_with("res://") or path.begins_with("user://")) and ResourceLoader.exists(path):
		var res := load(path)
		if res is AudioStream:
			return res

	# 2. 只有檔名 → 到固定資料夾找
	var file_name := path.get_file()
	for dir in SEARCH_DIRS:
		var candidate := dir + file_name
		if ResourceLoader.exists(candidate):
			var res2 := load(candidate)
			if res2 is AudioStream:
				return res2

	# 3. 外部絕對路徑
	if FileAccess.file_exists(path):
		return load_external(path)

	return null


static func load_external(abs_path: String) -> AudioStream:
	match abs_path.get_extension().to_lower():
		"mp3":
			return AudioStreamMP3.load_from_file(abs_path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(abs_path)
		"wav":
			var wav := AudioStreamWAV.load_from_file(abs_path)
			return wav
	push_warning("不支援的音訊格式：" + abs_path)
	return null


## 給 UI 顯示用：這個路徑能不能播
static func can_load(path: String) -> bool:
	return load_stream(path) != null
