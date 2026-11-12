class_name Conductor
extends Node
## 音樂時鐘。
##
## 音樂遊戲最關鍵的不是畫面，是「現在到底是第幾秒」。
## AudioStreamPlayer.get_playback_position() 一次只更新一個 mix block，
## 直接拿來判定會有 10~30ms 的鋸齒，所以慣例是：
##
##   實際時間 = 播放位置 + 距離上次混音的時間 - 輸出延遲
##
## 另外加了兩個東西：
##   * preroll：歌曲開始前的預捲（讓音符先掉下來），此時 song_time 為負。
##   * offset：玩家的音畫補償，正的值會讓譜面整體延後。

var player: AudioStreamPlayer

## 目前歌曲時間（秒）。預捲期間為負值。
var song_time := 0.0

var started := false
var paused := false

## 使用者補償（秒）
var offset := 0.0

var _preroll_left := 0.0
var _preroll_total := 0.0

## 音訊停擺偵測。
##
## 判定時間唯一的真相應該是音訊時鐘，但音訊時鐘有可能「壞掉」：
## 換音訊輸出裝置、藍牙斷線、系統休眠回來、headless 的 Dummy 驅動、
## 離屏錄影模式，都會讓 get_playback_position() 落後甚至完全不動。
## 這時如果還盲信它，整首歌會凍結在第一秒，玩家只看到音符停在空中。
##
## 做法是開一個時間窗口（0.5 秒），比較「音訊位置前進量」與「幀時間累積量」：
##   ratio ≈ 1  → 音訊正常，用音訊時鐘（精準，含輸出延遲補償）
##   ratio < 0.6 → 音訊不可信，改用 delta 推進
##
## 連續兩個壞窗口才鎖定，而且鎖定後「不再切回」。
## 這點對音遊很重要：兩個時鐘來回切換會讓時間軸跳動，
## 玩家會看到音符瞬移、判定莫名變成 MISS，比單純用 delta 更糟。
var _win_pos := 0.0     # 窗口內音訊位置前進量
var _win_time := 0.0    # 窗口內累積的幀時間
var _bad_windows := 0
var _last_pos := -1.0
var _clock_broken := false

const STALL_WINDOW := 0.5
const STALL_RATIO := 0.6
const STALL_CONFIRM := 2


func _ready() -> void:
	player = AudioStreamPlayer.new()
	player.bus = "Master"
	add_child(player)


## stream 可為 null（沒有音樂也能測試譜面）
func setup(stream: AudioStream, preroll_sec: float, offset_sec: float) -> void:
	player.stream = stream
	_preroll_left = maxf(preroll_sec, 0.0)
	_preroll_total = _preroll_left
	offset = offset_sec
	song_time = -_preroll_left
	started = false
	paused = false
	_win_pos = 0.0
	_win_time = 0.0
	_bad_windows = 0
	_last_pos = -1.0
	_clock_broken = false


func start() -> void:
	_preroll_left = _preroll_total
	song_time = -_preroll_left
	started = false
	paused = false
	_win_pos = 0.0
	_win_time = 0.0
	_bad_windows = 0
	_last_pos = -1.0
	_clock_broken = false
	if player.stream != null and _preroll_left <= 0.0:
		player.play()
		started = true


func stop() -> void:
	player.stop()
	started = false


func set_paused(value: bool) -> void:
	paused = value
	if player.playing:
		player.stream_paused = value


func _process(delta: float) -> void:
	if paused:
		return

	if not started:
		_preroll_left -= delta
		song_time = -_preroll_left
		if _preroll_left <= 0.0:
			if player.stream != null:
				player.play()
			started = true
			song_time = -offset
		return

	if player.playing:
		var pos := player.get_playback_position()
		if _last_pos >= 0.0 and pos > _last_pos:
			_win_pos += pos - _last_pos
		_last_pos = pos
		_win_time += delta

		if _win_time >= STALL_WINDOW:
			if _win_pos < _win_time * STALL_RATIO:
				_bad_windows += 1
				if _bad_windows >= STALL_CONFIRM:
					_clock_broken = true
			else:
				_bad_windows = 0
			_win_pos = 0.0
			_win_time = 0.0

		if _clock_broken:
			# 音訊時鐘已判定不可信，改由幀時間推進（單向，不切回）
			song_time += delta
		else:
			song_time = _audio_time() - offset
	else:
		# 音檔播完（或根本沒有音檔）時，仍讓時間繼續走，歌曲才會結束
		song_time += delta


func _audio_time() -> float:
	var t := player.get_playback_position()
	# 補上「距離上次混音」與「輸出延遲」，讓判定時間貼近耳朵聽到的聲音
	t += AudioServer.get_time_since_last_mix()
	t -= AudioServer.get_output_latency()
	return maxf(t, 0.0)


## 目前拍數（需要譜面才能換算）
func beat(chart: Chart) -> float:
	if chart == null:
		return 0.0
	return chart.beat_at_song_time(song_time)


## 預捲剩餘秒數（給倒數 UI 用）
func preroll_left() -> float:
	return maxf(-song_time, 0.0)
