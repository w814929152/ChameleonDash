class_name HUD
extends CanvasLayer
## HUD —— 反馈通道优先于机制。
## 玩家"感觉不对"时，90% 的问题在反馈通道，不在数值。这个 HUD 负责三件事：
##   1. 能量状态一眼可读（条 + 数字 + 颜色，三重编码，不靠单一通道）
##   2. 当前跑法的能量效率可见（每秒净收支）—— 让"贪"的代价变成可读的数字
##   3. 冲刺可用时给出明确召唤（能量满 = 手里握着一张牌，必须让玩家知道）

const BAR_W := 420.0
const BAR_H := 26.0

var _fill: ColorRect
var _bar_bg: ColorRect
var _energy_label: Label
var _state_label: Label
var _rate_label: Label
var _time_label: Label
var _progress_label: Label
var _hint: Label
var _gate: Label
var _mech: Label
var _center: PanelContainer
var _center_title: Label
var _center_body: Label
var _flash: ColorRect
var _flash_t := 0.0

func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# ---- 能量条 ----
	var bar_frame := ColorRect.new()
	bar_frame.color = Color(0.05, 0.05, 0.08, 0.85)
	bar_frame.position = Vector2(28, 24)
	bar_frame.size = Vector2(BAR_W + 8, BAR_H + 8)
	root.add_child(bar_frame)

	_bar_bg = ColorRect.new()
	_bar_bg.color = Color(0.16, 0.16, 0.20, 1.0)
	_bar_bg.position = Vector2(32, 28)
	_bar_bg.size = Vector2(BAR_W, BAR_H)
	root.add_child(_bar_bg)

	_fill = ColorRect.new()
	_fill.color = GameConfig.COLOR_A
	_fill.position = Vector2(32, 28)
	_fill.size = Vector2(BAR_W, BAR_H)
	root.add_child(_fill)

	_energy_label = _mk_label(root, Vector2(32, 58), Vector2(300, 26), 18)
	_state_label = _mk_label(root, Vector2(200, 58), Vector2(260, 26), 18)
	_rate_label = _mk_label(root, Vector2(32, 84), Vector2(420, 22), 15)
	_rate_label.modulate = Color(0.75, 0.78, 0.85)

	# ---- 右上：计时与进度 ----
	_time_label = _mk_label(root, Vector2(960, 24), Vector2(280, 30), 22)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_progress_label = _mk_label(root, Vector2(960, 56), Vector2(280, 22), 16)
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_progress_label.modulate = Color(0.75, 0.78, 0.85)

	# ---- 机制状态（加速带 / 脉冲相位 / 晶体）----
	# 单独占一行而不是塞进能量条区域：机制状态是"我脚下正在发生什么"，
	# 和"我有多少能量"是两个独立的问题，混在一起会让两个都读不快。
	_mech = _mk_label(root, Vector2(240, 556), Vector2(800, 32), 20)
	_mech.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# ---- 前方门预警（L3 战略决策的前提）----
	_gate = _mk_label(root, Vector2(290, 596), Vector2(700, 34), 21)
	_gate.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# ---- 中央提示 ----
	_hint = _mk_label(root, Vector2(340, 640), Vector2(600, 40), 24)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# ---- 结算面板 ----
	_center = PanelContainer.new()
	_center.position = Vector2(390, 250)
	_center.size = Vector2(500, 210)
	_center.visible = false
	root.add_child(_center)
	var vb := VBoxContainer.new()
	vb.position = Vector2(20, 16)
	_center.add_child(vb)
	_center_title = Label.new()
	_center_title.add_theme_font_size_override("font_size", 34)
	vb.add_child(_center_title)
	_center_body = Label.new()
	_center_body.add_theme_font_size_override("font_size", 17)
	_center_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_center_body.custom_minimum_size = Vector2(460, 130)
	vb.add_child(_center_body)

	# ---- 全屏闪红（濒死 / 死亡） ----
	_flash = ColorRect.new()
	_flash.color = Color(1.0, 0.15, 0.1, 0.0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_flash)

func _mk_label(parent: Control, pos: Vector2, sz: Vector2, fs: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = sz
	l.add_theme_font_size_override("font_size", fs)
	parent.add_child(l)
	return l

func _process(dt: float) -> void:
	if _flash_t > 0.0:
		_flash_t = maxf(_flash_t - dt, 0.0)
		_flash.color.a = _flash_t * 0.55

func flash(strength: float = 1.0) -> void:
	_flash_t = strength

func update_hud(p: Player, level: LevelData) -> void:
	var ratio := clampf(p.energy / GameConfig.ENERGY_MAX, 0.0, 1.0)
	_fill.size = Vector2(BAR_W * ratio, BAR_H)

	# 能量条颜色按状态编码：青=同色回血 / 红=异色流失 / 白=冲刺 / 灰=空中冻结
	match p.state:
		Player.State.SAME:
			_fill.color = GameConfig.COLOR_A
		Player.State.DIFF:
			_fill.color = Color(1.0, 0.22, 0.18)
		Player.State.DASH:
			_fill.color = Color(1.0, 1.0, 1.0)
		Player.State.AIR:
			_fill.color = Color(0.55, 0.58, 0.65)

	_energy_label.text = "能量 %d / %d" % [int(p.energy), int(GameConfig.ENERGY_MAX)]

	var state_text := "同色 +%.0f/s" % GameConfig.ENERGY_GAIN_SAME
	match p.state:
		Player.State.DIFF:
			state_text = "异色 -%.0f/s" % GameConfig.ENERGY_DRAIN_DIFF
		Player.State.DASH:
			state_text = "冲刺 -%.0f/s" % GameConfig.ENERGY_DRAIN_DASH
		Player.State.AIR:
			# 坠落与跳跃共用空中机制，但对玩家是两件事：
			# 一个是"我按的"，一个是"我掉下去了"。文案必须分开，否则读不出因果。
			state_text = "坠落 冻结" if p.falling else "空中 冻结"
	_state_label.text = state_text
	_state_label.modulate = Color(1.0, 0.35, 0.3) if p.state == Player.State.DIFF else Color(0.8, 0.9, 1.0)

	# 每秒净收支 —— 让"贪"的代价变成可读数字，而不是靠玩家猜
	var per_sec := 0.0
	match p.state:
		Player.State.SAME: per_sec = GameConfig.ENERGY_GAIN_SAME
		Player.State.DIFF: per_sec = -GameConfig.ENERGY_DRAIN_DIFF
		Player.State.DASH: per_sec = -GameConfig.ENERGY_DRAIN_DASH
	if p.state == Player.State.AIR:
		if p.falling:
			_rate_label.text = "坠落：结算暂停（坠落成本已扣 %d 点）" % int(GameConfig.FALL_ENERGY_COST)
		else:
			_rate_label.text = "空中：结算暂停（跳跃成本已扣 %d 点）" % int(GameConfig.JUMP_ENERGY_COST)
	else:
		_rate_label.text = "净收支 %+.1f 点/秒 ｜ 距终点 %.0f m" % [per_sec, maxf(level.total_length() - p.distance, 0.0)]

	_time_label.text = "%.1f s" % p.elapsed
	var prog := clampf(p.distance / level.total_length(), 0.0, 1.0)
	_progress_label.text = "进度 %d%% ｜ 第 %d / %d 层" % [
		int(prog * 100.0), p.layer + 1, GameConfig.LAYER_COUNT
	]

	_update_gate_warning(p, level)
	_update_mech(p, level)

	# 冲刺召唤：能量满是本作最重要的状态，必须显式提示
	if p.energy >= GameConfig.ENERGY_MAX:
		_hint.text = "能量满 —— 按住 SHIFT 冲刺（上限 %.0f m，归零即死）" % (GameConfig.ENERGY_MAX / GameConfig.COST_PER_METER_DASH)
		_hint.modulate = Color(1.0, 0.95, 0.4)
	elif p.state == Player.State.DIFF:
		_hint.text = "异色！跳起来冻结结算，或切色归零保命"
		_hint.modulate = Color(1.0, 0.35, 0.3)
	else:
		_hint.text = ""
		_hint.modulate = Color(0.8, 0.9, 1.0)

## 机制状态行：加速带 / 脉冲相位 / 晶体。
## 三者的共同点是"玩家此刻脚下的东西是什么"，与门预警（前方）分属两个时态。
func _update_mech(p: Player, level: LevelData) -> void:
	if p.on_boost:
		_mech.text = "加速带 ×%.1f —— 省时间但同色回血也变慢（%.2f 点/米）" % [
			GameConfig.BOOST_MULT,
			GameConfig.ENERGY_GAIN_SAME / (GameConfig.SPEED_BASE * GameConfig.BOOST_MULT)]
		_mech.modulate = GameConfig.COLOR_BOOST
		return

	if p.in_pulse:
		# 相位预警是本机制的全部操作空间所在：玩家必须知道"现在安不安全、还有多久翻"。
		# 判定必须用 p.state（真实结算状态），不能用 pulse_active（只是"相位翻没翻"）——
		# 翻转是好是坏取决于玩家颜色和该段基础色，两者可能同色也可能异色。
		# 用相位标记会得到"橙底上的青玩家被告知处于安全相位"这种自相矛盾的提示。
		var half := GameConfig.PULSE_PERIOD * 0.5
		var remain := half - fmod(p.elapsed, half)
		if p.state == Player.State.DIFF:
			_mech.text = "脉冲段 · 危险相位（%.1fs 后翻转）—— 跳起来冻结结算" % remain
			_mech.modulate = GameConfig.COLOR_PULSE_WARN
		else:
			_mech.text = "脉冲段 · 同色相位（%.1fs 后翻转）" % remain
			_mech.modulate = Color(0.7, 0.95, 1.0)
		return

	var np: Variant = level.next_feature(p.distance, "pulse")
	if np != null and float(np["dist"]) > 0.0 and float(np["dist"]) <= 110.0:
		_mech.text = "前方 %.0f m：脉冲段 %.0f m —— 三层同步变色，掐相位或跳着过" % [
			float(np["dist"]), float(np["len"])]
		_mech.modulate = GameConfig.COLOR_PULSE_WARN
		return

	var nb: Variant = level.next_feature(p.distance, "boost")
	if nb != null and float(nb["dist"]) > 0.0 and float(nb["dist"]) <= 60.0:
		_mech.text = "前方 %.0f m：加速带 %.0f m" % [float(nb["dist"]), float(nb["len"])]
		_mech.modulate = GameConfig.COLOR_BOOST
		return

	if not p.collected_crystals.is_empty():
		_mech.text = "晶体 ×%d 已拾取" % p.collected_crystals.size()
		_mech.modulate = GameConfig.COLOR_CRYSTAL
		return

	_mech.text = ""

## 前方门预警。90m 触发（基础速度 7.5s，够做一次切色决策）。
## 冲刺门与切色门的最优解完全相反，不告诉玩家长度就是在让他猜。
func _update_gate_warning(p: Player, level: LevelData) -> void:
	# 缺口预警优先于门预警：掉下去是"当下这一层"的即时威胁，
	# 而门还有腾挪空间。同时发生时先说缺口。
	var gap: Variant = level.next_gap(p.distance, p.layer)
	if gap != null and float(gap["dist"]) <= 90.0 and float(gap["dist"]) > 0.0:
		# 【留空改造后这条预警升级了】旧版每段三层填满，缺口是偶发事件，
		#   说"切到别的层"就够了。现在跑道大面积留空，"本层会断"每分钟发生十几次，
		#   只说"断"等于每次都要玩家自己去数哪几层还有路 —— 那不是预警是噪音。
		#   所以直接给答案：切到第几层。
		var gstart := level.segment_start(int(gap["index"]))
		var avail := level.track_layers_at(gstart)
		if avail.is_empty():
			_gate.text = "前方 %.0f m：三层全断" % float(gap["dist"])
		else:
			# 【留空改造补充 · 跳跃按次计费之后】落脚点的远近不再影响成本（跨几层都是 8 点），
			#   于是"离我最近"不再是好的推荐标准 —— "返回同色层"才是。
			#   更要紧的是 [A, X, A] 这类【收费口】：三层里根本没有你的颜色，
			#   最近的落脚点恰恰是异色。提示若只报层号，玩家会以为那是出路，
			#   跳过去才发现照样掉血 —— 那正是最坏的一种"看不清就罚"。
			var dst_pulse := level.is_pulse(gstart)
			var pool: Array = avail
			if not dst_pulse:
				var same: Array = []
				for l in avail:
					if level.color_at(gstart, int(l)) == p.player_color:
						same.append(l)
				if not same.is_empty():
					pool = same
			var best := int(pool[0])
			for l in pool:
				if absi(int(l) - p.layer) < absi(best - p.layer):
					best = int(l)
			var dir_txt := "上跳" if best > p.layer else ("下跳" if best < p.layer else "保持")
			var key_txt := "W" if best > p.layer else ("S" if best < p.layer else "W/S")
			# 脉冲段不做颜色判词：它本来就会翻转，判"安全/异色"只在当下成立，
			# 而且相位有专门的预警通道（_update_mech），混进来会给出错误暗示。
			var doomed := not dst_pulse and level.color_at(gstart, best) != p.player_color
			var tail := "（异色 · 会持续掉血）" if doomed else ""
			if float(gap["dist"]) <= p.jump_reach():
				# 【跳跃窗口】
				#   一次跳跃在空中会前进 speed × JUMP_AIR_TIME，落点在前方；
				#   所以只有当这段前瞻能越过缺口起点时按键才生效。
				#   换算成时间是恒定的 JUMP_AIR_TIME（距离随速度变，时间不变）。
				#   不显式标出窗口的话，玩家会在预警刚出现（几十米外）就按，
				#   然后判定"按键无效"—— 而这恰恰是本轮要修的病灶。
				_gate.text = "现在！按 %s %s到第 %d 层%s" % [key_txt, dir_txt, best + 1, tail]
				_gate.modulate = Color(1.0, 0.42, 0.30) if doomed else Color(1.0, 1.0, 1.0)
				return
			_gate.text = "前方 %.0f m：本层跑道中断 —— %s到第 %d 层%s" % [
				float(gap["dist"]), dir_txt, best + 1, tail]
			_gate.modulate = Color(1.0, 0.42, 0.30) if doomed else Color(1.0, 0.95, 0.35)
			return
		_gate.modulate = Color(1.0, 0.95, 0.35)
		return

	var g: Variant = level.next_gate(p.distance, p.player_color)
	if g == null or float(g["dist"]) > 90.0:
		_gate.text = ""
		return

	var d := float(g["dist"])
	var L := float(g["len"])
	if d <= 0.0:
		# 已在门内：只报剩余距离，这是"要不要提前松手冲刺"的依据
		_gate.text = "门内 还剩 %.0f m" % (L + d)
		_gate.modulate = Color(1.0, 0.35, 0.3)
		return

	var advice := "按 J 切色进（冲刺够不到）" if g["kind"] == "切色门" \
		else "攒满能量按 SHIFT 冲过去"
	_gate.text = "前方 %.0f m ｜ %.0f m %s —— %s" % [d, L, g["kind"], advice]
	_gate.modulate = Color(1.0, 0.85, 0.35) if g["kind"] == "切色门" else Color(1.0, 0.55, 0.3)

func show_result(title: String, body: String, color: Color) -> void:
	_center.visible = true
	_center_title.text = title
	_center_title.modulate = color
	_center_body.text = body

func hide_result() -> void:
	_center.visible = false
