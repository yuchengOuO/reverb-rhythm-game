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
## 沒接到的長條：整條要「掉過判定線」之後才淡出，而不是停在原地消失。
## 這段時間 = 判定線之後還要繼續掉多久（實際會掉 pps × 0.85 像素，一定出畫面）。
const MISS_FALL := 0.85

## --- 擊中粒子 ---
##
## 舊版每一軌只有一個 CPUParticles2D；連打時新的一顆會 restart() 同一個發射器，
## 把上一顆還在飛的粒子整個清掉 —— 看起來就是「新特效覆蓋舊特效」。
## 這裡改成每一軌準備多個獨立發射器、環狀輪替：
## 每次擊中都有自己的粒子，前一次的特效會繼續跑完，不會被吃掉。
##
## 生命週期 1.4 秒 + 重力 900：粒子會先往上炸開，再掉到判定線以下。
## 就算是 4K（判定線離底部 346px）也能在消失前掉出畫面，
## 不會出現「粒子在半空中被硬切」的殘影。
##
## 12 個／軌是為了涵蓋「1/32 連打」：1.4 秒內最多會有 11 顆同時在跑。
const FX_POOL_PER_LANE := 12
const FX_LIFETIME := 1.4
const FX_GRAVITY := 900.0

## --- 結算 ---
## 歌曲或譜面「完全結束」之後再等這麼久才進結算畫面。
const RESULT_DELAY := 3.0

## --- 計分（滿分 1,000,000）---
##
## 判定分 90% + 連擊分 10%。
##   判定分 = 900,000 ×（Σ 音符權重 / 音符總數）
##   連擊分 = 100,000 ×（最大連擊 / 音符總數）
##
## 每個音符的權重上限是 1.0：
##   短音   = 判定權重（PERFECT 1.0 / GREAT 0.8 / GOOD 0.4 / MISS 0）
##   長條   = 頭部 70% × 判定權重 + 尾端 30%（完整接到才有）
## 所以「全部 PERFECT + 全部長條都接到尾端 + 不斷 combo」正好是 1,000,000。
const MAX_SCORE := 1000000
const SCORE_ACC_RATIO := 0.9
const SCORE_COMBO_RATIO := 0.1
## 長條的尾端佔這顆音符的多少比重（其餘是頭部判定）
const HOLD_TAIL_RATIO := 0.3

const WEIGHT_PERFECT := 1.0
const WEIGHT_GREAT := 0.8
const WEIGHT_GOOD := 0.4

## 評價表：由好到差，結算畫面照這個順序由上往下排。
## min 是門檻分數（含）。
const GRADE_TIERS := [
	{"letter": "SS", "min": 1000000, "note": "全部 PERFECT"},
	{"letter": "S", "min": 950000, "note": "95 萬"},
	{"letter": "A", "min": 880000, "note": "88 萬"},
	{"letter": "B", "min": 800000, "note": "80 萬"},
	{"letter": "C", "min": 650000, "note": "65 萬"},
	{"letter": "D", "min": 0, "note": "未滿 65 萬"},
]

const BG := Color(0, 0, 0)

## --- 背景圖 ---
## 由 Main 依「譜面預設 / 玩家選擇」載入後傳進來；null = 純黑。
## 尺寸不一定是舞台大小，繪製時用 cover 等比填滿。
var bg_texture: Texture2D = null
## 壓暗程度（0 = 原圖，1 = 全黑）
var bg_dim := 0.45

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

## 版面尺寸。**開場就固定**，之後視窗怎麼縮放都不變 —— 這是「譜面 UI」的座標系。
## 視窗變小只是把外圍裁掉、變大只是露出更多背景，音符與判定點不會跟著縮放。
var stage_size := Vector2(1280, 720)

## 目前實際的繪圖區大小（由 Main 每幀同步，會隨視窗大小改變）。
var view_size := Vector2(1280, 720)

## 版面在繪圖區裡置中所需的位移 = (view_size - stage_size) / 2。
## 整個 Playfield 節點會被搬到這個位置，所以 _draw() 裡一律用版面座標。
var _view_offset := Vector2.ZERO

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
## 擊中粒子：每一軌一組「環狀輪替」的發射器，避免連打時新特效清掉舊特效。
var _fx_pool: Array = []
var _fx_next: Array[int] = [0, 0, 0, 0]
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
var _last_view := Vector2.ZERO
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
			"completed": false,  # 長條是否有「完整接到尾端」（決定要不要在判定線噴光）
			"tail_fx": false,    # 尾端收乾淨的光暈是否已經噴過
			"fall_at": 0.0,      # 放開後開始往下掉的時間（0 = 沒在掉）
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
	# 譜面可能指定了不同的大小，版面要重算
	_layout()


func _layout() -> void:
	var usable := minf(stage_size.x * 0.86, 640.0)
	lane_w = usable / float(LANE_COUNT)
	# 音符大小 = 玩家設定 × 譜面預設。上限卡在軌道寬度內，
	# 否則調到 1.8 倍時長條會溢出到隔壁軌，看起來像兩顆音符。
	var ns := note_scale()
	note_r = lane_w * 0.17 * ns
	note_bar_w = minf(lane_w * 0.78 * ns, lane_w * 0.98)
	note_bar_h = clampf(lane_w * 0.17 * ns, 8.0, 36.0)
	# 判定球只跟著放大一半：全放大的話四顆球會黏在一起，
	# 但完全不動又會讓大音符「塞不進」小杯子。
	rec_r = lane_w * 0.30 * lerpf(1.0, ns, 0.5)
	judge_y = stage_size.y * 0.84
	var approach := 1.15 / clampf(Settings.scroll_speed, 0.25, 3.0)
	pps = (judge_y + 80.0) / approach


## 這個譜面實際使用的音符樣式。
## 譜面在 settings.note_style 鎖定時（"bar" / "orb"）以譜面為準，
## 沒鎖定（"any"）才跟著玩家設定走。
func note_style() -> String:
	if chart != null and chart.note_style in ["bar", "orb"]:
		return chart.note_style
	return Settings.note_style


## 音符大小倍率 = 玩家設定 × 譜面預設
func note_scale() -> float:
	var s := Settings.note_scale
	if chart != null:
		s *= chart.note_scale
	return clampf(s, 0.4, 2.5)


## 換背景（遊戲中暫停選單也會呼叫）。tex = null 就是純黑。
func set_background(tex: Texture2D, dim := 0.45) -> void:
	bg_texture = tex
	bg_dim = clampf(dim, 0.0, 1.0)
	queue_redraw()


func _build_particles() -> void:
	_fx_pool.clear()
	for lane in LANE_COUNT:
		var pool: Array = []
		for k in FX_POOL_PER_LANE:
			var p := CPUParticles2D.new()
			p.emitting = false
			p.one_shot = true
			p.amount = 20
			p.lifetime = FX_LIFETIME
			p.explosiveness = 0.92
			p.direction = Vector2(0, -1)
			p.spread = 62.0
			p.initial_velocity_min = 110.0
			p.initial_velocity_max = 330.0
			p.gravity = Vector2(0, FX_GRAVITY)
			p.scale_amount_min = 0.22
			p.scale_amount_max = 0.65
			p.color = Color(1, 1, 1, 0.9)
			p.color_ramp = _fade_ramp()
			p.texture = _dot_tex
			p.local_coords = false
			add_child(p)
			pool.append(p)
		_fx_pool.append(pool)
		_fx_next[lane] = 0


# --------------------------------------------------------------------------
# 每幀更新
# --------------------------------------------------------------------------

func _process(delta: float) -> void:
	if chart == null:
		return

	if stage_size != _last_size:
		_last_size = stage_size
		_layout()

	# 視窗大小改變時只搬動版面，不重新排版（UI 不跟著縮放）
	if view_size != _last_view:
		_last_view = view_size
		_view_offset = (view_size - stage_size) * 0.5
		position = _view_offset
		queue_redraw()

	var t: float = conductor.song_time if conductor != null else 0.0

	_decay(delta)
	if t >= 0.0:
		_poll_input(t)
		if auto_play:
			_auto_hit_tick(t)
		_update_holds(t)
	_check_misses(t)
	_update_rings(delta)

	if not finished_flag and t >= finish_time():
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
	if best_dt <= W_PERFECT:
		grade = "PERFECT"; weight = WEIGHT_PERFECT
	elif best_dt <= W_GREAT:
		grade = "GREAT"; weight = WEIGHT_GREAT
	else:
		grade = "GOOD"; weight = WEIGHT_GOOD

	var n: Dictionary = _notes[best]
	# 長條的頭部只算 70%，剩下 30% 等尾端真的接到才給。
	var gain := weight
	if float(n.len) > 0.0:
		gain *= (1.0 - HOLD_TAIL_RATIO)
	n.weight = gain
	n.grade = grade
	if float(n.len) > 0.0:
		n.state = 1
		n.held = true
		n.off_at = 0.0
		_active_holds.append(best)
	else:
		n.state = 2
		n.dead_at = t

	_register_hit(grade, gain, lane, t)


func _register_hit(grade: String, weight: float, lane: int, t: float) -> void:
	counts[grade] += 1
	combo += 1
	max_combo = maxi(max_combo, combo)
	acc_sum += weight
	acc_count += 1
	_recompute_score()
	_judge_text = grade
	_judge_color = JUDGE_COLORS.get(grade, Color.WHITE)
	_judge_timer = 0.55
	_spawn_burst(lane, grade, t)
	_shake = maxf(_shake, 1.5 if grade == "PERFECT" else 0.8)


## 依「目前累積的判定權重 + 最大連擊」重算總分。
## 每打一顆就重算一次，數值永遠是單調的（除了斷 combo 時連擊分會掉），
## 而且結算時一定落在 0 ~ 1,000,000 之間。
func _recompute_score() -> void:
	var total := maxi(_notes.size(), 1)
	var acc_part := float(MAX_SCORE) * SCORE_ACC_RATIO * (acc_sum / float(total))
	var combo_part := float(MAX_SCORE) * SCORE_COMBO_RATIO * (float(max_combo) / float(total))
	score = int(round(clampf(acc_part + combo_part, 0.0, float(MAX_SCORE))))


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
			# 完整接到的長條，要等尾端真的收到判定線那一刻才噴光暈。
			# 舊版是在「進入放寬區」時就噴（早了 0.4 秒），
			# 看起來像光柱還沒收完就自己先爆一下。
			if bool(n.completed) and not bool(n.tail_fx) and t >= float(n.end_time):
				n.tail_fx = true
				_spawn_ring(int(n.lane), Color(1, 1, 1, 0.55), t)
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
			n.completed = true
			n.dead_at = maxf(t + HOLD_FADE, end_t + HOLD_FADE)
			# 尾端接到 → 補上這顆長條剩下的 30% 權重
			acc_sum += HOLD_TAIL_RATIO
			_recompute_score()
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
		# 凍結光柱當下的長度：失敗的長條不該繼續「自己往前收」，
		# 那樣看起來像還在被按住。
		n.freeze_y2 = -(float(n.end_time) - t) * pps
		# 然後整條從判定線往下滑出畫面 —— MISS 就是要「超過判定線」，
		# 停在原地淡掉會讓人分不清是接到還是掉了。
		n.fall_at = t
		n.dead_at = t + MISS_FALL
		var old_grade := str(n.grade)
		if counts.has(old_grade) and counts[old_grade] > 0:
			counts[old_grade] -= 1
		counts["MISS"] += 1
		acc_sum -= float(n.weight)
		n.grade = "MISS"
		combo = 0
		_recompute_score()
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
		# 掉落距離要足夠「整條越過判定線」，所以不是 HOLD_FADE 而是 MISS_FALL。
		if float(n.len) > 0.0:
			n.dead_at = t + MISS_FALL
			_active_holds.append(k)
		else:
			n.dead_at = t
		counts["MISS"] += 1
		combo = 0
		acc_sum += 0.0
		acc_count += 1
		_recompute_score()
		_judge_text = "MISS"
		_judge_color = JUDGE_COLORS["MISS"]
		_judge_timer = 0.4


func _spawn_burst(lane: int, grade: String, t: float) -> void:
	if not Settings.hit_fx_enabled:
		return
	if lane < 0 or lane >= _fx_pool.size():
		return
	var pool: Array = _fx_pool[lane]
	if pool.is_empty():
		return
	# 環狀輪替：從下一個開始找「已經跑完」的發射器，舊的粒子繼續跑完。
	# 如果全部都還在跑（極端連打），才退回輪替最舊的那一顆。
	var pool_size: int = pool.size()
	var start: int = int(_fx_next[lane]) % pool_size
	var idx := -1
	for k in pool_size:
		var cand: CPUParticles2D = pool[(start + k) % pool_size]
		if not cand.emitting:
			idx = (start + k) % pool_size
			break
	if idx < 0:
		idx = start
	_fx_next[lane] = (idx + 1) % pool_size
	var p: CPUParticles2D = pool[idx]
	p.position = _lane_xf(lane, t).origin
	p.color = JUDGE_COLORS.get(grade, LANE_COLORS[lane])
	# 玩家設定是倍率：數量 0.25–2.0、大小 0.5–2.0。
	# PERFECT 的基準量比較多，但還是要讓低效能裝置能壓下來。
	var base_amount := 26 if grade == "PERFECT" else 14
	p.amount = clampi(int(round(base_amount * Settings.hit_fx_count)), 1, 64)
	var fx_scale := Settings.hit_fx_size
	p.scale_amount_min = 0.22 * fx_scale
	p.scale_amount_max = 0.65 * fx_scale
	p.restart()
	p.emitting = true
	_spawn_ring(lane, JUDGE_COLORS.get(grade, LANE_COLORS[lane]), t)


## 粒子的透明度曲線：前段維持亮度，後段才收乾淨。
## 沒有這條曲線的話，lifetime 一到整批粒子會「瞬間消失」。
func _fade_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.9))
	g.set_color(1, Color(1, 1, 1, 0.0))
	g.add_point(0.55, Color(1, 1, 1, 0.72))
	return g


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
		return {"x": 0.0, "y": 0.0, "rot": 0.0, "scale": 1.0, "alpha": 1.0}

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
		"alpha": lerpf(float(a.get("alpha", 1.0)), float(b.get("alpha", 1.0)), f),
	}


## 這一軌目前的透明度（0.0 ~ 1.0）。譜面沒寫就當 1.0。
## 底色、判定球、以及「這一軌掉下來的音符」都乘上它。
func _lane_alpha(lane: int, t: float) -> float:
	return clampf(float(_lane_state(lane, t).get("alpha", 1.0)), 0.0, 1.0)


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
	# 背景鋪滿整個繪圖區：視窗比版面大時，多出來的地方是背景而不是黑邊。
	# 版面本身（軌道、音符、判定點、HUD）一律用 stage_size 座標，
	# 由節點位移置中，所以視窗再怎麼縮放都不會改變 UI 的大小。
	var bg_rect := Rect2(-_view_offset, view_size)
	draw_rect(bg_rect, BG)
	_draw_background(bg_rect)

	var t: float = conductor.song_time if conductor != null else 0.0

	# 第一層：四條軌道的底與邊界全部先畫完。
	# 舊版是「一條軌道畫完底、音符、判定球，再換下一條」，
	# 軌道一重疊，前面那條的底色與判定球就會壓在後面那條的音符上。
	# 拆成兩層之後，軌道底色永遠在所有音符的下面。
	for i in LANE_COUNT:
		draw_set_transform_matrix(_lane_xf(i, t))
		_draw_lane_base(_lane_alpha(i, t))

	# 第二層：音符與判定球。
	for i in LANE_COUNT:
		draw_set_transform_matrix(_lane_xf(i, t))
		var la := _lane_alpha(i, t)
		_draw_notes(i, t, la)
		_draw_receiver(i, la)
	draw_set_transform_matrix(Transform2D.IDENTITY)

	_draw_rings()
	_draw_hud(t)


func _draw_background(bg_rect: Rect2) -> void:
	# 背景圖：cover 等比填滿整個繪圖區，再壓一層黑幕。
	# 壓暗是必要的 —— 譜面的核心是白光，背景只要搶走一點對比就會影響判讀。
	if bg_texture != null:
		var tex_size := bg_texture.get_size()
		if tex_size.x > 0.0 and tex_size.y > 0.0:
			var fit := maxf(bg_rect.size.x / tex_size.x, bg_rect.size.y / tex_size.y)
			var draw_size := tex_size * fit
			var draw_pos := bg_rect.position + (bg_rect.size - draw_size) * 0.5
			draw_texture_rect(bg_texture, Rect2(draw_pos, draw_size), false, Color.WHITE)
			if bg_dim > 0.001:
				draw_rect(bg_rect, Color(0, 0, 0, bg_dim))

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


func _draw_lane_base(a: float = 1.0) -> void:
	if a <= 0.001:
		return
	var half := lane_w * 0.5
	var top := -judge_y - 160.0
	var bottom := 90.0

	# 軌道只是「比黑再亮一點點」的直條，讓四條軌有邊界但不搶戲。
	# 係數壓得很低：兩條軌道重疊時兩層加起來也只有 0.014，
	# 不會把後面那軌的音符糊掉。
	# 譜面給的單軌透明度直接乘在這兩個係數上。
	draw_rect(Rect2(-half, top, lane_w, bottom - top), Color(1, 1, 1, 0.007 * a))
	draw_line(Vector2(-half, top), Vector2(-half, bottom), Color(1, 1, 1, 0.040 * a), 1.0)
	draw_line(Vector2(half, top), Vector2(half, bottom), Color(1, 1, 1, 0.040 * a), 1.0)


## 判定點設計：承接光的球體。
##
## 每一軌底部是一顆懸在黑暗中的光球，音符（白光）掉進球裡就是「接住」。
## 球本身刻意做成半透明——它是容器，不是障礙物，所以不會擋住掉下來的白光。
##
## 為了讓玩家抓得到時間點，球的「赤道」有一條極淡的水平線，
## 音符的中心對齊這條線的瞬間就是判定點。
func _draw_receiver(lane: int, a: float = 1.0) -> void:
	if a <= 0.001:
		return
	var p: float = _press[lane]
	var r := rec_r * (1.0 + 0.10 * p)

	# 外圈光暈
	var gs := r * 3.4
	draw_texture_rect(
		_glow_tex,
		Rect2(-gs * 0.5, -gs * 0.5, gs, gs),
		false, Color(1, 1, 1, (0.09 + 0.26 * p) * a)
	)

	# 赤道線：真正的判定基準。球體是「容器」，這條線才是「接住的位置」。
	var eq := lane_w * 0.46
	draw_line(Vector2(-eq, 0), Vector2(eq, 0), Color(1, 1, 1, (0.14 + 0.26 * p) * a), 1.0)

	# 玻璃球：內部幾乎透明，靠邊緣的一圈光把「球」的形狀撐出來。
	# 如果連內部都填亮，會變成一顆灰色圓盤，看起來就不像球了。
	draw_texture_rect(
		_orb_tex,
		Rect2(-r, -r, r * 2.0, r * 2.0),
		false, Color(1, 1, 1, (0.10 + 0.52 * p) * a)
	)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 56, Color(1, 1, 1, (0.72 + 0.28 * p) * a), 1.6, true)
	draw_arc(Vector2.ZERO, r * 0.90, 0.0, TAU, 56, Color(1, 1, 1, (0.12 + 0.22 * p) * a), 1.0, true)

	# 球心：平常只是一點微光，接到光時才亮成熱點
	draw_circle(Vector2.ZERO, r * 0.16, Color(1, 1, 1, (0.30 + 0.70 * p) * a))


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
	return note_bar_w * 0.5 if note_style() == "bar" else note_r


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


## 畫一顆音符（依音符樣式決定長條或圓球）。
func _draw_note(pos: Vector2, alpha: float) -> void:
	if note_style() == "bar":
		_draw_bar_note(pos, alpha)
	else:
		_draw_orb(pos, note_r, 1.0, alpha)


## 長條的音柱。head_y 是頭部（判定端）的位置，尾端依 end_time 算。
##
## 「被接住」的長條頭部釘在判定線上，光柱會隨著時間被判定線吃掉。
## 這裡有一個關鍵的夾鉗：尾端不能越過頭部。
## 少了它，尾端通過判定線之後 head/tail 的上下關係會翻轉，
## min()/abs() 算出來的區間就變成「從判定線往下長」，
## 看起來像判定線下面冒出一小截殘光（而且 miss 的時候更明顯）。
func _draw_hold_body(n: Dictionary, t: float, head_y: float, alpha: float) -> void:
	var tail_y := -(float(n.end_time) - t) * pps
	# 失敗的長條已凍結長度（見 _update_holds）
	var frozen := float(n.get("freeze_y2", -1e9))
	if frozen > -1e8:
		tail_y = frozen
	# 放開後整條一起往下掉（頭部與尾端同步位移，長度不變）
	if float(n.get("fall_at", 0.0)) > 0.0:
		tail_y += (t - float(n.fall_at)) * pps
	# 被接住 → 光柱只存在於判定線「之上」，尾端最多收到判定線為止
	if bool(n.held):
		tail_y = minf(tail_y, head_y)
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
		# 只在「還有柱身」的時候畫 —— 整條被吃掉之後再畫，
		# 光帽就會單獨留在判定線上變成一個多出來的亮塊。
		var tail_hw := _note_half_w() * 0.62
		var tail_hh := (note_bar_h * 0.34) if note_style() == "bar" else (note_r * 0.62)
		_draw_capsule(Vector2(0, tail_y), tail_hw, tail_hh, Color(1, 1, 1, 0.55 * a))


## 畫單一顆音符（含長條音柱）。state 2 的淡出也在這裡處理。
func _draw_note_entry(n: Dictionary, t: float, lane_alpha: float = 1.0) -> void:
	var state := int(n.state)
	# 這一軌的透明度也套在音符上：軌道變淡，掉下來的音符一起變淡
	var alpha := lane_alpha
	if state == 2:
		var dead := float(n.dead_at)
		if dead <= 0.0 or t >= dead:
			return
		var f := clampf((dead - t) / HOLD_FADE, 0.0, 1.0)
		alpha *= f * f  # 平方 → 收尾更柔，不會像被硬切掉

	var y := -(float(n.time) - t) * pps
	# 打中過的長條：頭部釘在判定線上，由尾端往回收
	if bool(n.held):
		y = 0.0
	# 中途放開（算 MISS）：頭部從判定線開始往下掉，整條跟著滑出畫面
	var drop := 0.0
	if float(n.get("fall_at", 0.0)) > 0.0:
		drop = (t - float(n.fall_at)) * pps
		y = drop
	# 剔除：長條不能只看頭部 —— 頭掉出畫面時尾端可能還在螢幕上，
	# 那時候把整條丟掉會變成「光柱在半空中被切斷」。
	var bottom := 420.0
	if float(n.len) > 0.0:
		bottom += float(n.len) * pps
	if y < -judge_y - 260.0 or y > bottom:
		return

	if float(n.len) > 0.0:
		_draw_hold_body(n, t, y, alpha)

	_draw_note(Vector2(0, y), alpha)


func _draw_notes(lane: int, t: float, lane_alpha: float = 1.0) -> void:
	# 1) 先畫「正在按住 / 正在淡出」的長條。
	#    它們的頭部時間可能早就掉出下面的掃描範圍，
	#    不獨立畫的話，按住超過 0.5 秒整條光柱就會突然不見。
	for idx in _active_holds:
		if idx < 0 or idx >= _notes.size():
			continue
		var hn: Dictionary = _notes[idx]
		if int(hn.lane) == lane:
			_draw_note_entry(hn, t, lane_alpha)

	# 2) 再掃「還沒被判定」的音符
	var approach := (judge_y + 80.0) / pps
	var start := _lower_bound(t - 0.5)
	for k in range(start, _notes.size()):
		var n: Dictionary = _notes[k]
		if float(n.time) > t + approach + 0.6:
			break
		if int(n.lane) != lane or int(n.state) != 0:
			continue
		_draw_note_entry(n, t, lane_alpha)


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

	# 分數（固定 7 位，滿分 1000000；位數不跳動，眼睛比較好讀）
	_text_right(w - 34.0 * s, 52.0 * s, "%07d" % score, int(34.0 * s), Color(1, 1, 1, 0.95))

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

## 音檔完全播完的「歌曲時間」。沒有音檔（或長度未知）時回傳 INF。
func song_end_time() -> float:
	if conductor == null or conductor.player == null:
		return INF
	var stream: AudioStream = conductor.player.stream
	if stream == null:
		return INF
	var length := stream.get_length()
	if length <= 0.0:
		return INF
	# song_time 的定義是「播放位置 − 玩家偏移」，所以音檔結尾要扣掉同一個偏移
	return length - conductor.offset


## 什麼時候進結算畫面。
##
## 規則：歌曲結束 / 譜面內容結束，取「先發生的那一個」再等 3 秒。
##   * 歌曲先結束 → 歌曲結束 + 3 秒
##   * 譜面先結束 → 最後一顆音符 / 特效 / 軌道 / 視窗事件結束 + 3 秒
## 取先結束的那一個是為了避免「音檔尾巴很長、譜面早就打完」時要空等好幾分鐘。
func finish_time() -> float:
	if chart == null:
		return INF
	var chart_end := chart.content_end_time()
	var song_end := song_end_time()
	if song_end < INF:
		chart_end = minf(chart_end, song_end)
	return chart_end + RESULT_DELAY


func accuracy() -> float:
	if acc_count == 0:
		return 0.0
	return acc_sum / float(acc_count)


func grade_letter() -> String:
	for tier in GRADE_TIERS:
		if score >= int(tier.min):
			return str(tier.letter)
	return "D"
