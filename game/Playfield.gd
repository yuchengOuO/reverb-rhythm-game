class_name Playfield
extends Node2D
## 四軌遊玩畫面。
##
## 設計重點：
##   * 音符「不是節點」，只是一筆資料。整個畫面用一次 _draw() 畫完，
##     所以幾百顆音符也不會有節點管理的開銷。
##   * 每一軌有自己的 Transform2D（位移 / 旋轉 / 縮放），由譜面的 lane 事件
##     隨時間插值而來。音符座標是「軌道本地座標」，因此軌道一移動，
##     上面的音符與判定點會一起被帶走 —— 這就是本作的核心玩法。
##   * 判定只看「時間 + 軌道編號」，完全不受視覺位置影響。
##     換句話說，畫面再怎麼亂，你打的還是同一件事。

signal finished

const LANE_COUNT := 4

# 判定窗口（秒）
const W_PERFECT := 0.045
const W_GREAT := 0.085
const W_GOOD := 0.135
const W_MISS := 0.180

## --- 長條（Hold）判定放寬 ---
##
## 傳統音遊的長條要求「按住到最後一刻」，只要早放開一幀就整顆 MISS，
## 對手指不穩的人非常不友善。這裡改成三件事：
##   1. 尾端放寬：離終點還有 grace 秒內放開都算完成（沒有尾判）。
##   2. 沒有尾判：完成時不判 PERFECT/GREAT，只給一點視覺回饋。
##   3. 中斷緩衝：按住期間短暫放開（換指、手滑）只要在 buffer 內按回來就不算斷。
const HOLD_GRACE_MIN := 0.18     # 最短放寬秒數
const HOLD_GRACE_MAX := 0.40     # 最長放寬秒數
const HOLD_GRACE_RATIO := 0.18   # 放寬 = 長條長度 × 18%，夾在上述範圍內
const HOLD_REPRESS_BUFFER := 0.14  # 短暫放開的容許時間
const HOLD_FADE := 0.22          # 消失時的淡出時間（避免瞬間不見）

const BG := Color(0, 0, 0)

## 主題：接住白光。
## 四軌目前刻意「無差別」——所有音符都是同一種白光，
## 玩家只能靠位置判斷軌道。日後要恢復分色，改這個陣列就好。
var LANE_COLORS: Array[Color] = [
	Color(1, 1, 1),
	Color(1, 1, 1),
	Color(1, 1, 1),
	Color(1, 1, 1),
]

## 判定字顏色。全白主題下只有 MISS 保留紅色——
## 那是畫面上唯一的彩色，失誤會立刻被看見。
var JUDGE_COLORS := {
	"PERFECT": Color(1, 1, 1),
	"GREAT": Color(0.86, 0.91, 1.0),
	"GOOD": Color(0.62, 0.67, 0.75),
	"MISS": Color(1.0, 0.30, 0.34),
}

var chart: Chart
var conductor: Conductor

## 由 Main 每幀同步（會隨視窗大小改變）
var stage_size := Vector2(1280, 720)

# --- 執行期狀態 ---
var score := 0
var combo := 0
var max_combo := 0
var counts := {"PERFECT": 0, "GREAT": 0, "GOOD": 0, "MISS": 0}
var acc_sum := 0.0
var acc_count := 0
var finished_flag := false

# --- 版面（隨視窗大小重算）---
var lane_w := 120.0
## 音符（光球）半徑
var note_r := 24.0
## 音符（長條）寬高
var note_bar_w := 92.0
var note_bar_h := 18.0
## 判定球半徑
var rec_r := 46.0
var judge_y := 604.0
var pps := 600.0  # pixels per second

var _notes: Array = []
## 正在按住、或正在淡出的長條（存 _notes 的索引）。
## 這些音符的頭部時間可能早就遠離掃描範圍，必須獨立追蹤才畫得出來。
var _active_holds: Array[int] = []
var _lane_keys: Array = [[], [], [], []]
var _fx: Array = []
var _press: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _rings: Array = []
var _judge_text := ""
var _judge_color := Color.WHITE
var _judge_timer := 0.0
var _font: Font
var _glow_tex: Texture2D
var _dot_tex: Texture2D
var _orb_tex: Texture2D
## 長條音柱用的橫向漸層（中間亮、兩側收暗，縱向均勻）
var _beam_tex: Texture2D
var _last_size := Vector2.ZERO
var _shake := 0.0

## 除錯用：自動完美打擊（啟動參數 --autohit）
var auto_play := false


func _ready() -> void:
	_font = load("res://assets/fonts/NotoSansTC-Regular.otf")
	_glow_tex = _make_glow_texture()
	_dot_tex = _make_dot_texture()
	_orb_tex = _make_orb_texture()
	_beam_tex = _make_beam_texture()
	_layout()
	_build_particles()


# --------------------------------------------------------------------------
# 初始化
# --------------------------------------------------------------------------

func set_chart(c: Chart) -> void:
	chart = c
	_notes.clear()
	_active_holds.clear()
	for n in chart.notes:
		_notes.append({
			"beat": float(n.beat),
			"lane": int(n.lane),
			"len": float(n.len),
			"time": float(n.time),
			"end_time": float(n.end_time),
			"state": 0,          # 0 未判定 / 1 長按中 / 2 已結束（可能還在淡出）
			"grade": "",
			"weight": 0.0,
			"held": false,       # 頭部是否已被打中（決定要不要釘在判定線上）
			"off_at": 0.0,       # 這次「放開」開始的時間，0 = 正按著
			"dead_at": 0.0,      # 幾秒後完全停止繪製（淡出用）
			"freeze_y2": -1e9,   # 失敗的長條凍結尾端位置，避免繼續往前收
		})
	_notes.sort_custom(func(a, b): return float(a.time) < float(b.time))

	_lane_keys = [[], [], [], []]
	for ev in chart.lane_events:
		var lane := int(ev.lane)
		if lane >= 0 and lane < LANE_COUNT:
			_lane_keys[lane].append(ev)
	for i in LANE_COUNT:
		_lane_keys[i].sort_custom(func(a, b): return float(a.time) < float(b.time))

	score = 0
	combo = 0
	max_combo = 0
	counts = {"PERFECT": 0, "GREAT": 0, "GOOD": 0, "MISS": 0}
	acc_sum = 0.0
	acc_count = 0
	finished_flag = false
	_judge_timer = 0.0
	_rings.clear()


func _layout() -> void:
	var usable := minf(stage_size.x * 0.86, 640.0)
	lane_w = usable / float(LANE_COUNT)
	# 音符光球與判定球的比例：音符明顯小一號，才看得出「掉進去」
	note_r = lane_w * 0.17
	note_bar_w = lane_w * 0.78
	note_bar_h = clampf(lane_w * 0.17, 10.0, 26.0)
	rec_r = lane_w * 0.30
	judge_y = stage_size.y * 0.84
	var approach := 1.15 / clampf(Settings.scroll_speed, 0.25, 3.0)
	pps = (judge_y + 80.0) / approach


func _build_particles() -> void:
	for i in LANE_COUNT:
		var p := CPUParticles2D.new()
		p.emitting = false
		p.one_shot = true
		p.amount = 20
		p.lifetime = 0.5
		p.explosiveness = 0.92
		p.direction = Vector2(0, -1)
		p.spread = 62.0
		p.initial_velocity_min = 90.0
		p.initial_velocity_max = 300.0
		p.gravity = Vector2(0, 820)
		p.scale_amount_min = 0.25
		p.scale_amount_max = 0.7
		p.color = Color(1, 1, 1, 0.9)
		p.texture = _dot_tex
		p.local_coords = false
		add_child(p)
		_fx.append(p)


# --------------------------------------------------------------------------
# 每幀更新
# --------------------------------------------------------------------------

func _process(delta: float) -> void:
	if chart == null:
		return

	if stage_size != _last_size:
		_last_size = stage_size
		_layout()

	var t: float = conductor.song_time if conductor != null else 0.0

	_decay(delta)
	if t >= 0.0:
		_poll_input(t)
		if auto_play:
			_auto_hit_tick(t)
		_update_holds(t)
	_check_misses(t)
	_update_rings(delta)

	if t > chart.duration and not finished_flag:
		finished_flag = true
		finished.emit()

	queue_redraw()


func _decay(delta: float) -> void:
	for i in LANE_COUNT:
		_press[i] = maxf(0.0, _press[i] - delta * 5.0)
	_shake = maxf(0.0, _shake - delta * 22.0)
	position = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake
	if _judge_timer > 0.0:
		_judge_timer = maxf(0.0, _judge_timer - delta)


func _poll_input(t: float) -> void:
	for i in LANE_COUNT:
		var action := Settings.LANE_ACTIONS[i]
		if Input.is_action_just_pressed(action):
			_press[i] = 1.0
			_try_hit(i, t)
		elif Input.is_action_pressed(action):
			_press[i] = maxf(_press[i], 0.45)


## 除錯用：在音符正確的時間點自動按下，用來驗證判定與計分
func _auto_hit_tick(t: float) -> void:
	# 掃出所有「已進入 PERFECT 視窗、但還沒被判定」的音符，一次全部打掉。
	#
	# 兩個地方刻意不寫死幀率，否則測試會變成在測電腦速度而不是測遊戲：
	#   1. 不用「absf(n.time - t) <= 一幀」當條件 —— 30fps 下一幀是 33ms，
	#      大於視窗就可能整格跳過音符，變成假的 MISS。
	#   2. 不是只處理佇列最前面那一顆 —— 頭部還沒進視窗時，後面的音符
	#      會先被時間追上，下一幀就變成過期。
	var i := _lower_bound(t - W_GOOD)
	while i < _notes.size():
		var n: Dictionary = _notes[i]
		if float(n.time) > t + W_PERFECT:
			break
		if int(n.state) == 0 and t >= float(n.time) - W_PERFECT * 0.5:
			_press[int(n.lane)] = 1.0
			_try_hit(int(n.lane), t)
		i += 1


func _try_hit(lane: int, t: float) -> void:
	var start := _lower_bound(t - W_MISS * 1.5)
	var best := -1
	var best_dt := 1e9
	for k in range(start, _notes.size()):
		var n: Dictionary = _notes[k]
		if float(n.time) > t + W_MISS:
			break
		if int(n.lane) != lane or int(n.state) != 0:
			continue
		var dt := absf(float(n.time) - t)
		if dt < best_dt:
			best_dt = dt
			best = k

	if best < 0:
		# 空打：只給一點回饋，不扣分
		_spawn_ring(lane, Color(1, 1, 1, 0.25), t)
		return

	if best_dt > W_GOOD:
		return

	var grade := "MISS"
	var weight := 0.0
	var base := 0
	if best_dt <= W_PERFECT:
		grade = "PERFECT"; weight = 1.0; base = 300
	elif best_dt <= W_GREAT:
		grade = "GREAT"; weight = 0.7; base = 200
	else:
		grade = "GOOD"; weight = 0.4; base = 100

	var n: Dictionary = _notes[best]
	n.weight = weight
	n.grade = grade
	if float(n.len) > 0.0:
		n.state = 1
		n.held = true
		n.off_at = 0.0
		_active_holds.append(best)
	else:
		n.state = 2
		n.dead_at = t

	_register_hit(grade, weight, base, lane, t)


func _register_hit(grade: String, weight: float, base: int, lane: int, t: float) -> void:
	counts[grade] += 1
	combo += 1
	max_combo = maxi(max_combo, combo)
	acc_sum += weight
	acc_count += 1
	score += int(base * (1.0 + minf(combo, 200) * 0.005))
	_judge_text = grade
	_judge_color = JUDGE_COLORS.get(grade, Color.WHITE)
	_judge_timer = 0.55
	_spawn_burst(lane, grade, t)
	_shake = maxf(_shake, 1.5 if grade == "PERFECT" else 0.8)


## 長條的「尾端放寬」秒數。
## 3 秒的長條 → 0.40 秒（在 2.6 秒之後放開都算完成）；
## 0.6 秒的短長條 → 0.18 秒，避免短長條幾乎不用按。
func _hold_grace(n: Dictionary) -> float:
	return clampf(float(n.len) * HOLD_GRACE_RATIO, HOLD_GRACE_MIN, HOLD_GRACE_MAX)


func _update_holds(t: float) -> void:
	# 只走「正在按住 / 正在淡出」的清單，不再用時間視窗往回找。
	# 舊版用 _lower_bound(t - 3.0) 往回掃，超過 3 秒的長條會永遠輪不到判定，
	# 一直卡在「按住中」直到歌曲結束。
	for i in range(_active_holds.size() - 1, -1, -1):
		var idx := _active_holds[i]
		if idx < 0 or idx >= _notes.size():
			_active_holds.remove_at(i)
			continue
		var n: Dictionary = _notes[idx]

		# 已經結束的：等淡出播完就從清單移除
		if int(n.state) == 2:
			if t >= float(n.dead_at):
				_active_holds.remove_at(i)
			continue
		if int(n.state) != 1:
			_active_holds.remove_at(i)
			continue

		var end_t := float(n.end_time)

		# 1) 進入尾端放寬區 → 直接算完成。沒有尾判，所以不顯示判定字。
		#    但視覺上不能立刻消失：尾端還要繼續往判定線收，
		#    收完才淡出，否則會看到光柱在半空中被硬切。
		if t >= end_t - _hold_grace(n):
			n.state = 2
			n.dead_at = maxf(t + HOLD_FADE, end_t + HOLD_FADE)
			score += 60
			_spawn_ring(int(n.lane), Color(1, 1, 1, 0.55), t)
			continue

		# 2) 按鍵狀態：短暫放開會進緩衝，超過緩衝時間才真的算斷
		var action := Settings.LANE_ACTIONS[int(n.lane)]
		var pressed := auto_play or Input.is_action_pressed(action)
		if pressed:
			n.off_at = 0.0
			continue
		if float(n.off_at) <= 0.0:
			n.off_at = t
			continue
		if t - float(n.off_at) <= HOLD_REPRESS_BUFFER:
			continue

		# 真的放開了 → 斷 Combo，把這顆音符改記為 MISS
		n.state = 2
		n.dead_at = t + HOLD_FADE
		# 凍結光柱當下的長度：失敗的長條不該繼續「自己往前收」，
		# 那樣看起來像還在被按住。讓它就停在原地淡掉。
		n.freeze_y2 = -(float(n.end_time) - t) * pps
		var old_grade := str(n.grade)
		if counts.has(old_grade) and counts[old_grade] > 0:
			counts[old_grade] -= 1
		counts["MISS"] += 1
		acc_sum -= float(n.weight)
		n.grade = "MISS"
		combo = 0
		_judge_text = "MISS"
		_judge_color = JUDGE_COLORS["MISS"]
		_judge_timer = 0.45


func _check_misses(t: float) -> void:
	if t <= 0.0:
		return
	var start := _lower_bound(t - 3.0)
	for k in range(start, _notes.size()):
		var n: Dictionary = _notes[k]
		if float(n.time) > t - W_MISS:
			break
		if int(n.state) != 0:
			continue
		n.state = 2
		n.grade = "MISS"
		# 長條即使沒接到，也要讓它繼續往下掉、淡出，
		# 不能整條瞬間不見（那會看起來像遊戲破圖）。
		if float(n.len) > 0.0:
			n.dead_at = t + HOLD_FADE
			_active_holds.append(k)
		else:
			n.dead_at = t
		counts["MISS"] += 1
		combo = 0
		acc_sum += 0.0
		acc_count += 1
		_judge_text = "MISS"
		_judge_color = JUDGE_COLORS["MISS"]
		_judge_timer = 0.4


func _spawn_burst(lane: int, grade: String, t: float) -> void:
	if lane < 0 or lane >= _fx.size():
		return
	var p: CPUParticles2D = _fx[lane]
	p.position = _lane_xf(lane, t).origin
	p.color = JUDGE_COLORS.get(grade, LANE_COLORS[lane])
	p.amount = 26 if grade == "PERFECT" else 14
	p.restart()
	p.emitting = true
	_spawn_ring(lane, JUDGE_COLORS.get(grade, LANE_COLORS[lane]), t)


func _spawn_ring(lane: int, color: Color, t: float) -> void:
	_rings.append({
		"pos": _lane_xf(lane, t).origin,
		"age": 0.0,
		"life": 0.38,
		"color": color,
	})


func _update_rings(delta: float) -> void:
	for i in range(_rings.size() - 1, -1, -1):
		var r: Dictionary = _rings[i]
		r.age = float(r.age) + delta
		if float(r.age) >= float(r.life):
			_rings.remove_at(i)


func _lower_bound(time: float) -> int:
	var lo := 0
	var hi := _notes.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if float(_notes[mid].time) < time:
			lo = mid + 1
		else:
			hi = mid
	return lo


# --------------------------------------------------------------------------
# 軌道變換
# --------------------------------------------------------------------------

func _lane_center_x(lane: int) -> float:
	return stage_size.x * 0.5 + (float(lane) - 1.5) * lane_w


func _lane_state(lane: int, t: float) -> Dictionary:
	var keys: Array = _lane_keys[lane]
	if keys.is_empty():
		return {"x": 0.0, "y": 0.0, "rot": 0.0, "scale": 1.0}

	var n := keys.size()
	if t <= float(keys[0].time):
		return keys[0]
	if t >= float(keys[n - 1].time):
		return keys[n - 1]

	var lo := 0
	var hi := n - 1
	while lo + 1 < hi:
		var mid := (lo + hi) >> 1
		if float(keys[mid].time) <= t:
			lo = mid
		else:
			hi = mid

	var a: Dictionary = keys[lo]
	var b: Dictionary = keys[hi]
	var span := maxf(float(b.time) - float(a.time), 0.0001)
	var f := clampf((t - float(a.time)) / span, 0.0, 1.0)
	f = _ease(str(a.ease), f)
	return {
		"x": lerpf(float(a.x), float(b.x), f),
		"y": lerpf(float(a.y), float(b.y), f),
		"rot": lerpf(float(a.rot), float(b.rot), f),
		"scale": lerpf(float(a.scale), float(b.scale), f),
	}


func _ease(kind: String, f: float) -> float:
	match kind:
		"smooth":
			return f * f * (3.0 - 2.0 * f)
		"in":
			return f * f
		"out":
			return 1.0 - (1.0 - f) * (1.0 - f)
		"back":
			var c := 1.70158
			var x := f - 1.0
			return 1.0 + (c + 1.0) * x * x * x + c * x * x
		"step":
			return 0.0 if f < 1.0 else 1.0
		_:
			return f


func _lane_xf(lane: int, t: float) -> Transform2D:
	var st := _lane_state(lane, t)
	var sc := maxf(float(st.scale), 0.1)
	var origin := Vector2(
		_lane_center_x(lane) + float(st.x) * lane_w,
		judge_y + float(st.y) * lane_w
	)
	return Transform2D(deg_to_rad(float(st.rot)), Vector2(sc, sc), 0.0, origin)


# --------------------------------------------------------------------------
# 繪製
# --------------------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, stage_size), BG)
	_draw_background()

	var t: float = conductor.song_time if conductor != null else 0.0

	# 第一層：四條軌道的底與邊界全部先畫完。
	# 舊版是「一條軌道畫完底、音符、判定球，再換下一條」，
	# 軌道一重疊，前面那條的底色與判定球就會壓在後面那條的音符上。
	# 拆成兩層之後，軌道底色永遠在所有音符的下面。
	for i in LANE_COUNT:
		draw_set_transform_matrix(_lane_xf(i, t))
		_draw_lane_base()

	# 第二層：音符與判定球。
	for i in LANE_COUNT:
		draw_set_transform_matrix(_lane_xf(i, t))
		_draw_notes(i, t)
		_draw_receiver(i)
	draw_set_transform_matrix(Transform2D.IDENTITY)

	_draw_rings()
	_draw_hud(t)


func _draw_background() -> void:
	# 純黑。這個主題的重點就是「除了光以外什麼都沒有」，
	# 所以背景不鋪任何色塊，只留兩樣極淡的東西：
	#   1. 拍線（幫助抓節奏，但不是給眼睛看的裝飾）
	#   2. 承接線下方的一層光池（暗示光被接住後往下沉）
	if chart == null:
		return
	var t: float = conductor.song_time if conductor != null else 0.0

	var pool_w := stage_size.x * 0.62
	draw_texture_rect(
		_glow_tex,
		Rect2(stage_size.x * 0.5 - pool_w * 0.5, judge_y - stage_size.y * 0.12,
			pool_w, stage_size.y * 0.34),
		false, Color(1, 1, 1, 0.05)
	)

	var beat := chart.beat_at_song_time(t)
	var frac := beat - floorf(beat)
	var spacing := 96.0
	var count := int(stage_size.y / spacing) + 2
	for k in count:
		var y := fposmod(float(k) * spacing + frac * spacing, stage_size.y + spacing) - spacing * 0.5
		draw_line(Vector2(0, y), Vector2(stage_size.x, y), Color(1, 1, 1, 0.013), 1.0)


func _draw_lane_base() -> void:
	var half := lane_w * 0.5
	var top := -judge_y - 160.0
	var bottom := 90.0

	# 軌道只是「比黑再亮一點點」的直條，讓四條軌有邊界但不搶戲。
	# 係數壓得很低：兩條軌道重疊時兩層加起來也只有 0.014，
	# 不會把後面那軌的音符糊掉。
	draw_rect(Rect2(-half, top, lane_w, bottom - top), Color(1, 1, 1, 0.007))
	draw_line(Vector2(-half, top), Vector2(-half, bottom), Color(1, 1, 1, 0.040), 1.0)
	draw_line(Vector2(half, top), Vector2(half, bottom), Color(1, 1, 1, 0.040), 1.0)


## 判定點設計：承接光的球體。
##
## 每一軌底部是一顆懸在黑暗中的光球，音符（白光）掉進球裡就是「接住」。
## 球本身刻意做成半透明——它是容器，不是障礙物，所以不會擋住掉下來的白光。
##
## 為了讓玩家抓得到時間點，球的「赤道」有一條極淡的水平線，
## 音符的中心對齊這條線的瞬間就是判定點。
func _draw_receiver(lane: int) -> void:
	var p: float = _press[lane]
	var r := rec_r * (1.0 + 0.10 * p)

	# 外圈光暈
	var gs := r * 3.4
	draw_texture_rect(
		_glow_tex,
		Rect2(-gs * 0.5, -gs * 0.5, gs, gs),
		false, Color(1, 1, 1, 0.09 + 0.26 * p)
	)

	# 赤道線：真正的判定基準。球體是「容器」，這條線才是「接住的位置」。
	var eq := lane_w * 0.46
	draw_line(Vector2(-eq, 0), Vector2(eq, 0), Color(1, 1, 1, 0.14 + 0.26 * p), 1.0)

	# 玻璃球：內部幾乎透明，靠邊緣的一圈光把「球」的形狀撐出來。
	# 如果連內部都填亮，會變成一顆灰色圓盤，看起來就不像球了。
	draw_texture_rect(
		_orb_tex,
		Rect2(-r, -r, r * 2.0, r * 2.0),
		false, Color(1, 1, 1, 0.10 + 0.52 * p)
	)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 56, Color(1, 1, 1, 0.72 + 0.28 * p), 1.6, true)
	draw_arc(Vector2.ZERO, r * 0.90, 0.0, TAU, 56, Color(1, 1, 1, 0.12 + 0.22 * p), 1.0, true)

	# 球心：平常只是一點微光，接到光時才亮成熱點
	draw_circle(Vector2.ZERO, r * 0.16, Color(1, 1, 1, 0.30 + 0.70 * p))


## 畫一顆發光球（音符與判定點共用）。
## bright 控制整體亮度：音符接近 1.0（實心亮球），判定球只有 0.2 左右（暗玻璃球）。
func _draw_orb(pos: Vector2, r: float, bright: float, alpha: float = 1.0) -> void:
	var gs := r * 4.2
	draw_texture_rect(
		_glow_tex,
		Rect2(pos.x - gs * 0.5, pos.y - gs * 0.5, gs, gs),
		false, Color(1, 1, 1, 0.26 * bright * alpha)
	)
	# 暗圈：所有音符都是白的，兩顆重疊時會糊成一團白光，
	# 看不出是兩顆。先用黑色（在黑底上看不見）挖出一圈間隙，
	# 重疊的地方就會露出一道暗縫，後面的音符才辨識得出來。
	draw_circle(pos, r * 1.24, Color(0, 0, 0, 0.85 * alpha), true, -1.0, true)
	draw_texture_rect(
		_orb_tex,
		Rect2(pos.x - r, pos.y - r, r * 2.0, r * 2.0),
		false, Color(1, 1, 1, bright * alpha)
	)
	draw_arc(pos, r, 0.0, TAU, 40, Color(1, 1, 1, 0.55 * bright * alpha), 1.2, true)


## 音符寬度的一半。長條與圓球共用，長條的判定/繪製才會跟著樣式走。
func _note_half_w() -> float:
	return note_bar_w * 0.5 if Settings.note_style == "bar" else note_r


## 膠囊（圓角長條）。Godot 沒有內建的圓角矩形，用一個矩形 + 兩顆圓接起來。
func _draw_capsule(pos: Vector2, hw: float, hh: float, col: Color) -> void:
	var r := minf(hh, hw)
	draw_rect(Rect2(pos.x - hw + r, pos.y - hh, (hw - r) * 2.0, hh * 2.0), col)
	draw_circle(Vector2(pos.x - hw + r, pos.y), r, col, true, -1.0, true)
	draw_circle(Vector2(pos.x + hw - r, pos.y), r, col, true, -1.0, true)


## 長條狀音符：一顆橫向的光塊，中間有一條更亮的燈絲。
func _draw_bar_note(pos: Vector2, alpha: float) -> void:
	var hw := note_bar_w * 0.5
	var hh := note_bar_h * 0.5
	# 外光暈
	draw_texture_rect(
		_glow_tex,
		Rect2(pos.x - note_bar_w * 1.05, pos.y - note_bar_h * 2.6,
			note_bar_w * 2.1, note_bar_h * 5.2),
		false, Color(1, 1, 1, 0.17 * alpha)
	)
	# 暗圈（同圓球的用意：重疊時留一道縫）
	_draw_capsule(pos, hw + 1.8, hh + 1.8, Color(0, 0, 0, 0.85 * alpha))
	# 本體：刻意不到全白，背後的柔光才透得出來
	_draw_capsule(pos, hw, hh, Color(1, 1, 1, 0.90 * alpha))
	# 燈絲
	draw_line(
		Vector2(pos.x - hw + hh, pos.y), Vector2(pos.x + hw - hh, pos.y),
		Color(1, 1, 1, alpha), maxf(note_bar_h * 0.26, 1.5)
	)


## 畫一顆音符（依 Settings.note_style 決定長條或圓球）。
func _draw_note(pos: Vector2, alpha: float) -> void:
	if Settings.note_style == "bar":
		_draw_bar_note(pos, alpha)
	else:
		_draw_orb(pos, note_r, 1.0, alpha)


## 長條的音柱。head_y 是頭部（判定端）的位置，尾端依 end_time 算。
func _draw_hold_body(n: Dictionary, t: float, head_y: float, alpha: float) -> void:
	var tail_y := -(float(n.end_time) - t) * pps
	# 失敗的長條已凍結長度（見 _update_holds）
	var frozen := float(n.get("freeze_y2", -1e9))
	if frozen > -1e8:
		tail_y = frozen
	var body_top := minf(head_y, tail_y)
	var body_h := absf(head_y - tail_y)

	# 正在按住 → 亮；手放開但還在緩衝期 → 暗一階，給玩家「快掉了」的提示
	var holding := int(n.state) == 1 and float(n.off_at) <= 0.0
	var a := alpha * (1.0 if holding else 0.72)

	if body_h > 1.0:
		var bw := _note_half_w() * 0.42
		# 外層柔光（擴散到柱身之外）
		draw_texture_rect(
			_glow_tex,
			Rect2(-bw * 3.2, body_top, bw * 6.4, body_h),
			false, Color(1, 1, 1, 0.10 * a)
		)
		# 柱身本體：用橫向漸層，中心是真正的亮白，兩側才收暗。
		# 整條同亮度的話會變成一根灰色柱子，看起來不像光。
		draw_texture_rect(
			_beam_tex,
			Rect2(-bw * 1.15, body_top, bw * 2.3, body_h),
			false, Color(1, 1, 1, 0.92 * a)
		)
		# 邊界：淡淡一圈，讓光柱的寬度有定義
		draw_line(Vector2(-bw * 1.15, body_top), Vector2(-bw * 1.15, body_top + body_h), Color(1, 1, 1, 0.22 * a), 1.0)
		draw_line(Vector2(bw * 1.15, body_top), Vector2(bw * 1.15, body_top + body_h), Color(1, 1, 1, 0.22 * a), 1.0)

	# 尾端的光帽：一小段收尾，不用大球。
	# 大球在這個尺寸下會變成一顆灰色圓盤，反而像雜點。
	var tail_hw := _note_half_w() * 0.62
	var tail_hh := (note_bar_h * 0.34) if Settings.note_style == "bar" else (note_r * 0.62)
	_draw_capsule(Vector2(0, tail_y), tail_hw, tail_hh, Color(1, 1, 1, 0.55 * a))


## 畫單一顆音符（含長條音柱）。state 2 的淡出也在這裡處理。
func _draw_note_entry(n: Dictionary, t: float) -> void:
	var state := int(n.state)
	var alpha := 1.0
	if state == 2:
		var dead := float(n.dead_at)
		if dead <= 0.0 or t >= dead:
			return
		alpha = clampf((dead - t) / HOLD_FADE, 0.0, 1.0)
		alpha *= alpha  # 平方 → 收尾更柔，不會像被硬切掉

	var y := -(float(n.time) - t) * pps
	# 打中過的長條：頭部釘在判定線上，由尾端往回收
	if bool(n.held):
		y = 0.0
	if y < -judge_y - 260.0 or y > 420.0:
		return

	if float(n.len) > 0.0:
		_draw_hold_body(n, t, y, alpha)

	_draw_note(Vector2(0, y), alpha)


func _draw_notes(lane: int, t: float) -> void:
	# 1) 先畫「正在按住 / 正在淡出」的長條。
	#    它們的頭部時間可能早就掉出下面的掃描範圍，
	#    不獨立畫的話，按住超過 0.5 秒整條光柱就會突然不見。
	for idx in _active_holds:
		if idx < 0 or idx >= _notes.size():
			continue
		var hn: Dictionary = _notes[idx]
		if int(hn.lane) == lane:
			_draw_note_entry(hn, t)

	# 2) 再掃「還沒被判定」的音符
	var approach := (judge_y + 80.0) / pps
	var start := _lower_bound(t - 0.5)
	for k in range(start, _notes.size()):
		var n: Dictionary = _notes[k]
		if float(n.time) > t + approach + 0.6:
			break
		if int(n.lane) != lane or int(n.state) != 0:
			continue
		_draw_note_entry(n, t)


func _draw_rings() -> void:
	for r in _rings:
		var age := float(r.age)
		var life := float(r.life)
		var f := clampf(age / life, 0.0, 1.0)
		var col: Color = r.color
		# 光被接住的瞬間：一道白光向兩側擴散
		var half := lane_w * (0.22 + f * 0.95)
		col.a = (1.0 - f) * 0.65
		draw_line(r.pos + Vector2(-half, 0.0), r.pos + Vector2(half, 0.0), col, 2.2 * (1.0 - f) + 0.5)
		# 承接點上殘留的一小團光
		var g := 1.0 - f
		var gs := rec_r * 4.4
		draw_texture_rect(
			_glow_tex,
			Rect2(r.pos.x - gs * 0.5, r.pos.y - gs * 0.5, gs, gs),
			false, Color(1, 1, 1, 0.34 * g * g)
		)


func _draw_hud(t: float) -> void:
	if _font == null:
		return
	var w := stage_size.x
	var h := stage_size.y
	var s := h / 720.0
	var white := Color(1, 1, 1, 1)

	# 進度條
	if chart != null:
		var prog := clampf(t / maxf(chart.duration, 0.001), 0.0, 1.0)
		draw_rect(Rect2(0, 0, w, 3.0), Color(1, 1, 1, 0.06))
		draw_rect(Rect2(0, 0, w * prog, 3.0), Color(1, 1, 1, 0.72))

	# 分數
	_text_right(w - 34.0 * s, 52.0 * s, str(score), int(34.0 * s), Color(1, 1, 1, 0.95))

	# 準度
	var acc := 0.0
	if acc_count > 0:
		acc = acc_sum / float(acc_count)
	draw_string(
		_font, Vector2(30.0 * s, 38.0 * s),
		"ACC %.2f%%" % (acc * 100.0),
		HORIZONTAL_ALIGNMENT_LEFT, -1, int(15.0 * s), Color(1, 1, 1, 0.5)
	)
	if chart != null:
		draw_string(
			_font, Vector2(30.0 * s, 62.0 * s),
			"%s  ·  %s Lv.%d" % [chart.title, chart.difficulty, chart.level],
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(13.0 * s), Color(1, 1, 1, 0.32)
		)

	# Combo
	if combo >= 3:
		var cs := int(46.0 * s)
		var txt := str(combo)
		var sz := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, cs)
		var cpos := Vector2(w * 0.5 - sz.x * 0.5, judge_y - 158.0 * s)
		# 描邊：Combo 與判定字會壓在掉落的音符上，沒有描邊會糊在一起
		draw_string_outline(_font, cpos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, cs, 6, Color(0, 0, 0, 0.55))
		draw_string(
			_font, cpos,
			txt, HORIZONTAL_ALIGNMENT_LEFT, -1, cs, Color(1, 1, 1, 0.9)
		)
		draw_string(
			_font, Vector2(w * 0.5 - 26.0 * s, judge_y - 138.0 * s),
			"COMBO", HORIZONTAL_ALIGNMENT_LEFT, -1, int(11.0 * s), Color(1, 1, 1, 0.35)
		)

	# 判定文字
	if _judge_timer > 0.0:
		var a := clampf(_judge_timer / 0.55, 0.0, 1.0)
		var pop := 1.0 + (1.0 - a) * 0.18
		var js := int(30.0 * s)
		var sz2 := _font.get_string_size(_judge_text, HORIZONTAL_ALIGNMENT_LEFT, -1, js)
		draw_set_transform(Vector2(w * 0.5, judge_y - 100.0 * s), 0.0, Vector2(pop, pop))
		var col := _judge_color
		col.a = a
		draw_string_outline(
			_font, Vector2(-sz2.x * 0.5, 0), _judge_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, js, 5, Color(0, 0, 0, 0.5 * a)
		)
		draw_string(
			_font, Vector2(-sz2.x * 0.5, 0), _judge_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, js, col
		)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# 預捲倒數
	if t < 0.0:
		var n := int(ceil(-t))
		var txt2 := str(n) if n > 0 else "GO"
		var cs2 := int(96.0 * s)
		var sz3 := _font.get_string_size(txt2, HORIZONTAL_ALIGNMENT_LEFT, -1, cs2)
		draw_string(
			_font, Vector2(w * 0.5 - sz3.x * 0.5, h * 0.45),
			txt2, HORIZONTAL_ALIGNMENT_LEFT, -1, cs2, Color(1, 1, 1, 0.22)
		)


func _text_right(x_right: float, y: float, text: String, font_size: int, color: Color) -> void:
	var sz := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(_font, Vector2(x_right - sz.x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


# --------------------------------------------------------------------------
# 程式產生的貼圖（不需要外部素材）
# --------------------------------------------------------------------------

## 判定點用的球體貼圖。
##
## 一般的徑向漸層是「一路線性變暗」，畫成小圓會變成灰撲撲的圓盤。
## 這顆球刻意做成：中心 42% 維持接近實白（像被照亮的實心球），
## 之後才快速收暗，最後一圈歸零——這樣才有「發光球體」的體積感。
func _make_orb_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1.0))
	g.set_color(1, Color(1, 1, 1, 0.0))
	g.add_point(0.40, Color(1, 1, 1, 0.92))
	g.add_point(0.72, Color(1, 1, 1, 0.30))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 256
	gt.height = 256
	return gt


## 光柱貼圖：橫向漸層（中心全白、兩側收暗），縱向完全均勻。
## 用徑向漸層拉長的話，柱子的上下兩端也會跟著變暗，長長條會變成「兩頭尖」。
func _make_beam_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.0))
	g.set_color(1, Color(1, 1, 1, 0.0))
	g.add_point(0.34, Color(1, 1, 1, 0.55))
	g.add_point(0.50, Color(1, 1, 1, 1.0))
	g.add_point(0.66, Color(1, 1, 1, 0.55))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_LINEAR
	gt.fill_from = Vector2(0.0, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 128
	gt.height = 8
	return gt


func _make_glow_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.55))
	g.set_color(1, Color(1, 1, 1, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.0, 0.5)
	gt.width = 256
	gt.height = 256
	return gt


func _make_dot_texture(size: int = 32) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size, size) * 0.5
	var radius := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(center) / radius
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = pow(a, 1.7)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


# --------------------------------------------------------------------------
# 給結算畫面用
# --------------------------------------------------------------------------

func accuracy() -> float:
	if acc_count == 0:
		return 0.0
	return acc_sum / float(acc_count)


func grade_letter() -> String:
	var a := accuracy()
	if counts["MISS"] == 0 and a >= 0.995:
		return "SS"
	if a >= 0.97:
		return "S"
	if a >= 0.92:
		return "A"
	if a >= 0.85:
		return "B"
	if a >= 0.75:
		return "C"
	return "D"
