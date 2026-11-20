class_name ImageLoader
extends RefCounted
## 背景圖片載入工具（與 AudioLoader 對應）。
##
## 支援四種寫法：
##   1. res:// 路徑（放在 assets/backgrounds/ 裡的檔案，最推薦）
##   2. user:// 路徑（玩家自選後複製進來的圖）
##   3. 只有檔名（例如 "bg.jpg"）→ 自動到 assets/backgrounds/ 找
##   4. 絕對路徑（例如 "C:/Pictures/bg.png"）→ 執行時直接讀取
##
## 為什麼不用 ResourceLoader 讀外部檔案：外部圖片沒有 .import，
## 不會被匯入成 Texture2D。這裡用 Image.load_from_file 直接解碼，
## 再包成 ImageTexture，所以玩家換圖不需要重新開啟專案。

const SEARCH_DIRS: Array[String] = ["res://assets/backgrounds/", "user://backgrounds/"]
const EXTERNAL_EXTS: Array[String] = ["png", "jpg", "jpeg", "webp", "bmp", "tga"]


static func load_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null

	# 1. 專案內 / user:// 的匯入資源
	if (path.begins_with("res://") or path.begins_with("user://")) and ResourceLoader.exists(path):
		var res := load(path)
		if res is Texture2D:
			return res
		# user:// 的外部圖片沒有匯入資料，往下走直接解碼
		if res == null and path.begins_with("user://"):
			return load_external(path)

	# 2. 只有檔名 → 到固定資料夾找
	var file_name := path.get_file()
	if not file_name.is_empty() and file_name == path:
		for dir in SEARCH_DIRS:
			var candidate: String = dir + file_name
			if ResourceLoader.exists(candidate):
				var res2 := load(candidate)
				if res2 is Texture2D:
					return res2

	# 3. 外部檔案（含 user:// 未匯入的圖）
	if FileAccess.file_exists(path):
		return load_external(path)

	return null


static func load_external(abs_path: String) -> Texture2D:
	# Image.load_from_file 支援 res:// / user:// / 絕對路徑，
	# 但不吃 svg（svg 必須經過匯入）。背景圖以點陣圖為主。
	var ext := abs_path.get_extension().to_lower()
	if ext == "svg":
		push_warning("背景圖不支援 SVG（請先轉成 png）：" + abs_path)
		return null
	if not (ext in EXTERNAL_EXTS):
		push_warning("不支援的圖片格式：" + abs_path)
		return null
	var img := Image.load_from_file(abs_path)
	if img == null:
		push_warning("無法讀取圖片：" + abs_path)
		return null
	return ImageTexture.create_from_image(img)


## 把玩家選的圖片複製到 user://backgrounds/，回傳可以長期使用的路徑。
## 直接記住原始絕對路徑也可以，但玩家把檔案搬走 / 刪掉之後設定就失效了。
## key 用譜面路徑的雜湊，同一個譜面重選時會覆蓋同一張，不會留下垃圾檔。
static func import_custom(src_path: String, key: String) -> String:
	if src_path.is_empty() or not FileAccess.file_exists(src_path):
		return ""
	var ext := src_path.get_extension().to_lower()
	if ext == "jpeg":
		ext = "jpg"
	if not (ext in EXTERNAL_EXTS):
		return ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://backgrounds"))
	var stamp := key.md5_text().substr(0, 16) if not key.is_empty() else "custom"
	var dest := "user://backgrounds/%s.%s" % [stamp, ext]
	var bytes := FileAccess.get_file_as_bytes(src_path)
	if bytes.is_empty():
		return ""
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	f.close()
	# 有些平台不認得剛寫入的 user:// 檔案，改用絕對路徑驗證一次
	return dest if FileAccess.file_exists(dest) else ""


## 給 UI 顯示用：這個路徑能不能讀
static func can_load(path: String) -> bool:
	return load_texture(path) != null
