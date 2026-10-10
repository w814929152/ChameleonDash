extends Node
## 关卡流程【实机】测试：用真引擎、60fps 定步长，把三关从头跑到尾。
##
## ── 为什么必须有它（而不是靠 SelfTest）────────────────────────────
## SelfTest 的四原型是【纸面模拟】：它按公式算行进时间、按公式算成本。
## 但本项目历史上真正出过的两个 bug ——「跳跃按键无效」和「连跳成本算错」——
## 纸面模型全都看不见，只有把引擎跑起来才暴露。原因写在 MEMORY.md 的「铁律」里：
## **凡是要验"物理能不能做到"，一律调用引擎本体。**
##
## ── 它验什么 ────────────────────────────────────────────────────
##   1. 三关 × 多种"打法开关"组合，能不能真的跑到终点（真引擎，不是纸面）
##   2. 死亡的话死在哪、因为什么（给出最后 12 帧的逐帧轨迹）
##   3. 全程有没有"按键被吞"（按下跳跃却仍在地面上）—— 历史上最恶劣的 bug
##   4. 每个段进入时的层号与能量（能量轨迹，用来判断"这段是不是无解")
##   5. 流程状态机：READY→PLAYING→WIN→下一关 / DEAD→重开，以及星级分档
##
## ── 它不做什么 ─────────────────────────────────────────────────
## 绝不重写任何物理。落点一律问引擎（Player.next_track_layer / jump_reach），
## 本脚本只负责"每帧替玩家按一个键"，然后把 Main._process 里 PLAYING 分支的
## 那三行照原样调一遍。跑不出结果就是关卡或引擎的问题，不是模型的问题。
##
## 运行（**带窗口**，要用真输入注入）：
##   godot --path D:/ChameleonDash res://scenes/PlayTest.tscn

const DT := 1.0 / 60.0
## 单次跑动的秒数上限。理论最优 47~56s，留 5 倍余量足以识别"卡住"。
const MAX_SEC := 300.0
## 诊断用：死亡时回放最后多少帧
const TAIL := 12
## 诊断用：是否对【所有】跑动都打印段轨迹（默认只对失败打印 —— 失败时它揭示
## "死因不在死的那一段，而在前面某段把能量用光了"）。
## 核对"bot 走的路线是不是关卡设计的那条"时把它改成 true。
const SHOW_SEG_TRACE := false

var failures := 0
var _shift_down := false

# ============================================================
# 入口
# ============================================================
func _ready() -> void:
	# 注入式输入必须【逐事件立即生效】。Godot 默认 use_accumulated_input = true，
	# 会把事件攒到帧末再派发；而本测试的关卡矩阵是在【同一帧内同步跑完 12 个实例】的，
	# 攒到帧末 = 事件永远追不上代码，"用了冲刺"会静默变成"没用冲刺"。
	Input.use_accumulated_input = false
	_probe_input_injection()
	_run_level_matrix()
	await _test_state_machine()
	_print_coverage_gaps()
	print("========================================")
	if failures == 0:
		print("关卡流程实机测试全部通过")
	else:
		print("失败 %d 项" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check(name: String, cond: bool) -> void:
	if cond:
		print("  [PASS] " + name)
	else:
		failures += 1
		print("  [FAIL] " + name)

func _note(msg: String) -> void:
	print("     · " + msg)

## 造一个真的 Main 实例，但把它的 _process 关掉 ——
## 否则 Main._process 和我自己的循环会各 tick 一次，玩家速度翻倍。
## 这不是"绕过引擎"：我照样手动调它 PLAYING 分支的那三行（见 _frame）。
##
## ⚠ 顺序：必须 add_child 【之后】再 set_process(false)。
##   Godot 在节点进树时会按"脚本里有没有 _process"重新打开处理开关，
##   add_child 之前关会被覆盖掉。这个坑极其隐蔽 ——
##   矩阵循环整段跑在同一帧里、Main._process 根本没机会执行，
##   所以"双 tick"在那里看不出来；只在状态机（有 await 跨帧）里才暴露成
##   "重开后距离不是 0 而是 0.8m"。
func _make_main() -> Node3D:
	var main: Node3D = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	main.set_process(false)
	# 这条断言是防线：将来顺序被人改回去，这里会立刻喊出来，
	#   而不是让"距离 0.8m"这种症状再去骗一次人。
	assert(not main.is_processing(), "Main 的 _process 没关上 —— 会和测试循环双 tick")
	return main

func _frame(main: Node3D) -> void:
	# 与 Main._process 的 PLAYING 分支逐行一致。改动那里就要改这里。
	main.player.tick(DT)
	main._tick_world_anim(DT)
	main.hud.update_hud(main.player, main.level)

# ============================================================
# 0. 输入注入能不能用
# ============================================================
## 冲刺读的是 Input.is_key_pressed(KEY_SHIFT)，而 _unhandled_input 走的是
## 视口事件派发 —— 这两条路是分开的，必须先证明注入真的生效，
## 否则后面"用了冲刺"的结果全是假的（bot 以为在冲，其实没冲）。
func _probe_input_injection() -> void:
	print("Test: 输入注入（冲刺与按键这两条路都要能走通）")
	var ev := InputEventKey.new()
	ev.keycode = KEY_SHIFT
	ev.physical_keycode = KEY_SHIFT
	ev.pressed = true
	Input.parse_input_event(ev)
	_check("注入 SHIFT 后 Input.is_key_pressed 为真（冲刺可用）",
		Input.is_key_pressed(KEY_SHIFT))
	var up := InputEventKey.new()
	up.keycode = KEY_SHIFT
	up.physical_keycode = KEY_SHIFT
	up.pressed = false
	Input.parse_input_event(up)
	_check("松开后为假（冲刺能被正确释放）", not Input.is_key_pressed(KEY_SHIFT))

# ============================================================
# 1. 关卡 × 打法矩阵
# ============================================================
## 一个"会打游戏的人"的决策函数。三个开关代表他【会不会用】某个手段 ——
## 用来验证"关卡的多种解法在真引擎里也成立"，而不是只验一条背下来的路线。
##
## 缺口规避（规则 A）不受开关控制：那不是策略，是"看懂关卡"，
## 任何一个会玩的人都会做，不做就是等死。
func _run_level_matrix() -> void:
	print("\nTest: 三关 × 打法组合（真引擎实跑）")
	# 组合名 / 会不会冲刺 / 会不会切色 / 会不会连跳
	var combos := [
		{"name": "全能", "dash": true, "switch": true, "hop": true},
		{"name": "不用冲刺", "dash": false, "switch": true, "hop": true},
		{"name": "不切色", "dash": true, "switch": false, "hop": true},
		{"name": "只用跳跃", "dash": false, "switch": false, "hop": false},
	]
	var levels: Array = LevelData.all_levels()
	for li in levels.size():
		print("\n════════ %s ════════" % levels[li].level_name)
		var line := ""
		var passed := 0
		var allround_ok := false
		for c in combos:
			var r := _run_once(li, c)
			if r["ok"]:
				passed += 1
			if c["name"] == "全能":
				allround_ok = r["ok"]
			line += "%s=%s " % [c["name"], "通" if r["ok"] else "死"]
			_print_run(levels[li], c, r)
		_note("小结：" + line)
		# ── 断言 ──
		# ⚠ 这两条断言证明的是【bot 做到过】，不是【关卡一定可以】。
		#   弱 bot 会造假阴性（关卡其实能过、bot 过不去）。所以断言失败时，
		#   先怀疑 bot 的能力，再怀疑关卡 —— 这与"校验器不许复刻引擎"是同一件事的
		#   两个方向：那条防假阳性，这条防把假阴性当成关卡问题。
		_check("%s：全能打法（会用冲刺/切色/连跳）实机通关" % levels[li].level_name,
			allround_ok)
		_check("%s：至少 2/4 种打法组合实机通关（多解性下界）" % levels[li].level_name,
			passed >= 2)

func _run_once(level_idx: int, combo: Dictionary) -> Dictionary:
	var main := _make_main()
	main.load_level(level_idx)
	main.phase = 1                    # Main.Phase.PLAYING
	main.hud.hide_result()
	var lv: LevelData = main.level
	var p: Player = main.player

	var st := {
		"jumps": 0, "jumps_gap": 0, "jumps_color": 0, "jumps_hop": 0,
		"switch": 0, "dash_frames": 0, "swallowed": 0, "swallow_log": [],
		"falls": 0, "no_escape": 0, "min_energy": p.energy,
		"seg_log": {}, "tail": [], "reason": "",
	}
	var frames := 0
	var max_frames := int(MAX_SEC / DT)
	# 上一帧的空中/坠落状态，用来采【边沿】而不是电平（见下面的计数原则）
	var was_air := false
	var was_falling := false
	while p.alive and main.phase == 1 and frames < max_frames:
		frames += 1
		_drive(p, lv, combo, st)
		_frame(main)
		# ── 计数原则：一律读【引擎当前状态】，不读"我刚才下了什么指令" ──
		#   这个项目吃过一次亏：bot 以为自己在冲刺（下了 SHIFT），引擎其实没冲
		#   （能量没到上限 = 没 arm），结果统计里"冲刺很多"、实际一次没有。
		#   读意图只能证明代码跑过，读状态才能证明引擎动了。
		if p.airborne and not was_air and not p.falling:
			st["jumps"] += 1
		if p.falling and not was_falling:
			st["falls"] += 1
		if p.dashing:
			st["dash_frames"] += 1
		was_air = p.airborne
		was_falling = p.falling
		st["min_energy"] = minf(float(st["min_energy"]), p.energy)
		# 段进入记录：每段只记第一次进入时的层与能量
		var si := lv.segment_index_at(p.distance)
		if not st["seg_log"].has(si):
			st["seg_log"][si] = "层%d/色%s/能量%.0f" % [
				p.layer, "青" if p.player_color == 0 else "橙", p.energy]
		st["tail"].append("d=%.1f 层%d 色%s 能量%.1f %s" % [
			p.distance, p.layer, "青" if p.player_color == 0 else "橙", p.energy,
			("空中" if p.airborne else "") + ("坠落" if p.falling else "") \
				+ ("冲刺" if p.dashing else "")])
		if st["tail"].size() > TAIL:
			st["tail"].pop_front()

	var res := {
		"ok": main.phase == 3,
		"time": p.elapsed,
		"dist": p.distance,
		"frames": frames,
		"total": lv.total_length(),
		"stars": 0,
	}
	for k in st:
		res[k] = st[k]
	if main.phase == 2:
		res["reason"] = "死亡"
	elif main.phase != 3:
		res["reason"] = "超时（没死也没到终点）"
	_shift_reset()
	main.queue_free()
	return res

func _print_run(lv: LevelData, combo: Dictionary, r: Dictionary) -> void:
	var star_txt := ""
	if r["ok"]:
		var stars := 1
		if r["time"] <= lv.target_time:
			stars = 2
		if r["time"] <= lv.challenge_time:
			stars = 3
		star_txt = " %s" % ("★".repeat(stars) + "☆".repeat(3 - stars))
	print("  [%s] %s%s ｜ 用时 %.1fs ｜ 终点 %.0f/%.0fm ｜ 最低能量 %.1f" % [
		combo["name"], "通关" if r["ok"] else r["reason"], star_txt,
		r["time"], r["dist"], r["total"], r["min_energy"]])
	# 冲刺用【帧】报而不是秒：它是"按住多久"的量，而 1 帧 = 0.017s 会被 %.1f 打成
	#   0.0s —— 上面 C 分支那个 bug 就是这么伪装成"完全没冲刺"的。
	print("        跳%d(缺口%d/选色%d/连跳%d) 切色%d 冲刺%d帧 坠落%d" % [
		r["jumps"], r["jumps_gap"], r["jumps_color"], r["jumps_hop"],
		r["switch"], r["dash_frames"], r["falls"]])
	if r["swallowed"] > 0:
		print("        [!] 按键被吞 %d 次：%s" % [r["swallowed"], r["swallow_log"][0]])
	# 段进入轨迹：每段第一次踏进时的 段号/层/色/能量。
	#   死因往往不在死的那一段，而在前面某段把能量用光了 ——
	#   只回放最后 12 帧等于只看尸检报告，看不到病史。
	if not r["ok"] or SHOW_SEG_TRACE:
		var segs: Dictionary = r["seg_log"]
		var keys := segs.keys()
		keys.sort()
		var line := ""
		for k in keys:
			line += "%d:%s  " % [k, segs[k]]
		print("        段轨迹（段号:层/色/能量）：" + line)
	if not r["ok"]:
		print("        轨迹（最后 %d 帧）：" % r["tail"].size())
		for t in r["tail"]:
			print("          " + t)

# ============================================================
# 2. 决策
# ============================================================
func _drive(p: Player, lv: LevelData, combo: Dictionary, st: Dictionary) -> void:
	if not p.alive or p.airborne:
		return

	# ---- A. 缺口规避（不受开关控制：这是"看懂关卡"，不是打法）----
	var gap: Variant = lv.next_gap(p.distance, p.layer)
	if gap != null:
		var gd := float(gap["dist"])
		if gd <= p.jump_reach():
			var dir := _pick_dir(p, lv)
			if dir != 0:
				_try_jump(p, dir, st)
				st["jumps_gap"] += 1
				return
			elif gd <= 0.0:
				# 已经站在缺口里、且上下都没有跑道 —— 必摔，记录后不再挣扎
				st["no_escape"] += 1

	var cell := lv.color_at_t(p.distance, p.layer, p.elapsed)
	if cell == GameConfig.NO_TRACK:
		return
	if cell == p.player_color:
		_shift(false)
		return

	# ---- 脚下异色：这里要区分两个【不同的】长度，混用会同时错两件事 ----
	#   run_seg  = 本层当前异色还连着多长 —— 回答"值不值得花 8 点跳走"
	#   run_must = 其中【没有逃生口】的那一段 —— 回答"冲刺够不够把我送过去"
	#   两者在"段边界处另一层变成同色"时就会分叉（L3 段4/段5 就是），
	#   混成一个数的话：用 run_seg 判冲刺 → 68m 的门被读成 98m，判成"冲不过"；
	#   用 run_must 判跳不跳 → 逃生口就在脚下的那一段变得"不值得跳"，反而不逃。
	var run_seg := _run_length(lv, p.distance, p.layer, cell)
	var run_must := _must_survive_len(lv, p.distance, p.layer, cell, p.player_color)
	var tank_cost := run_seg * GameConfig.COST_PER_METER_WALK

	# ---- B. 逃到同色层：上下两个方向都要看，而且必须在冲刺之前判 ----
	#   两种情形都要跳：
	#     a) 前方异色还很长（硬扛的钱 > 一次跳跃的钱）—— 花 8 点逃掉划算
	#     b) 我正在冲刺 —— 24 点/秒在烧，前方出现免费的下车口就必须下车
	#   ⚠ 只往上看是死角：站在顶层时"上"根本不存在，而收尾段是刻意做成的
	#     "一青一橙双层"—— 两条路线各自的安全层可能在上也可能在下。
	#     只查上会把"往下换层就能活"读成死局，然后得出"关卡无解"的错误结论。
	#   ⚠ 落点一律问引擎（next_track_layer / jump_reach），本函数只负责"选哪个"。
	if tank_cost > GameConfig.JUMP_ENERGY_COST or p.dashing:
		var land := p.distance + p.jump_reach()
		var up := p.next_track_layer(1)
		if up >= 0 and lv.color_at(land, up) == p.player_color:
			_try_jump(p, 1, st)
			st["jumps_color"] += 1
			return
		var dn := p.next_track_layer(-1)
		if dn >= 0 and lv.color_at(land, dn) == p.player_color:
			_try_jump(p, -1, st)
			st["jumps_color"] += 1
			return

	# ---- C. 冲刺：硬闯这段会死、而冲刺够用 —— 冲刺唯一的正当用法 ----
	#   冲刺是一个【模式】（按住不放才叫冲），判据必须分成「起冲」和「保持」两段：
	#
	#   起冲（三个条件缺一不可）：
	#     ① 硬闯的钱 > 现有能量  → 不走捷径就死
	#     ② 冲刺的钱 < 现有能量  → 这条捷径真能把我送过去
	#     ③ 引擎说现在按 SHIFT 会真的冲出去
	#   只写 ① 会变成"每次濒死都冲"，冲到一半能量归零 —— 而冲刺耗尽 = 直接死。
	#
	#   ⚠ ③ 必须问引擎（_dash_armed），不能自己写 `energy >= ENERGY_MAX`。
	#     踩过的坑：进入异色段的第一帧能量已经掉到 99.7，而报告里的 "%.0f"
	#     把它打成 100 —— 于是我看着"满能量"却永远等不到条件成立，
	#     冲刺一次都没发生。凡是要验"能不能做到"，一律问引擎本体。
	#   ⚠ 冲刺必须【提前】决策：arm 需要能量到过上限，濒死时按 SHIFT 是空的。
	#     这是"门必须建在玩家已经站着的层上"那条纪律的另一面。
	#
	#   保持：已经在冲、且剩余行程还付得起 → 继续按住。
	#   ⚠ 这里【绝不能】每帧重算起冲条件：冲刺第一帧能量就掉到 100 以下，
	#     重算会让冲刺只持续一帧（0.017s，被 %.1f 打成 0.0，看起来像"没冲"）。
	#     而冲刺期间 "能量 − 剩余米数" 是常量（1.0 点/米 掉，1.0 米/帧 走），
	#     所以起冲时证明过的那件事，冲完之前一直成立，不需要每帧重证。
	var dash_cost := run_must * GameConfig.COST_PER_METER_DASH
	if combo["dash"]:
		if p.dashing and dash_cost < p.energy:
			return                      # 继续按住，不动 SHIFT
		if tank_cost > p.energy and dash_cost < p.energy - 2.0 and p._dash_armed:
			_shift(true)
			return
	_shift(false)

	# ---- D. 切色：不切必死，且切完脚下立刻变同色（才能开始回血）----
	#   切色清空能量，所以它是"用全部家当换一条命"，不是常规手段。
	if combo["switch"] and tank_cost > p.energy:
		if lv.color_at(p.distance, p.layer) == 1 - p.player_color:
			p.request_switch_color()
			st["switch"] += 1
			return

	# ---- E. 连跳：用空中冻结抵掉异色伤害 ----
	#   一次跳跃 = 8 点成本 + 0.58s 不受伤（省 18×0.58 ≈ 10.4 点），净赚。
	#   前提是能跳成【原地跳】（下方没有跑道）—— 否则会换层，那是另一回事了。
	if combo["hop"] and tank_cost > GameConfig.JUMP_ENERGY_COST:
		if p.next_track_layer(-1) < 0:
			_try_jump(p, -1, st)
			st["jumps_hop"] += 1
			return
		elif p.next_track_layer(1) < 0:
			_try_jump(p, 1, st)
			st["jumps_hop"] += 1
			return

## 目标方向：优先落到【同色层】，其次离得近的。
## 落点一律问引擎（next_track_layer / jump_reach），本函数只做"选哪个"。
func _pick_dir(p: Player, lv: LevelData) -> int:
	var up := p.next_track_layer(1)
	var down := p.next_track_layer(-1)
	if up < 0 and down < 0:
		return 0
	if up < 0:
		return -1
	if down < 0:
		return 1
	var land := p.distance + p.jump_reach()
	var up_same := lv.color_at(land, up) == p.player_color
	var down_same := lv.color_at(land, down) == p.player_color
	if up_same and not down_same:
		return 1
	if down_same and not up_same:
		return -1
	return 1 if absi(up - p.layer) <= absi(down - p.layer) else -1

## 从 dist 起、本层颜色连续保持 cell 的长度（米）。1m 步进，测试里够用。
## 只回答"这段异色还连着多长"，不关心途中能不能换层 —— 那个问题交给
## _must_survive_len。二者混用会同时判错"跳不跳"和"冲不冲"。
func _run_length(lv: LevelData, dist: float, layer: int, cell: int) -> float:
	var d := dist
	var guard := 0
	while d < lv.total_length() and guard < 5000:
		guard += 1
		if lv.color_at(d, layer) != cell:
			return d - dist
		d += 1.0
	return lv.total_length() - dist

## 从 dist 起、【必须硬扛】的异色长度（米）。
##
## ⚠ 它与"本层颜色连续保持 cell 的长度"不是一回事。后者会跨过段边界，
##   把"前一段异色 + 后一段异色"合并成一条假长段。反例（L3 段4/段5）：
##   层1 连着 68m + 30m 都是 B，但段5 的层2 是 A —— 青玩家只需扛 68m，
##   到段5 就能跳上去。按"连续同色长度"算会得到 98m，于是"冲刺 68m 够 /
##   98m 不够"这条设计分界被抹掉，bot 误判成"冲不过去"改用切色 ——
##   测试报告里于是再也看不到冲刺门，看起来像"冲刺没人用"。
##
## 判据：一旦前方某段出现【别的层是玩家颜色】，那里就是逃生口，到此为止。
func _must_survive_len(lv: LevelData, dist: float, layer: int, cell: int, pcolor: int) -> float:
	var d := dist
	var guard := 0
	while d < lv.total_length() and guard < 5000:
		guard += 1
		if lv.color_at(d, layer) != cell:
			return d - dist
		for l in GameConfig.LAYER_COUNT:
			if l != layer and lv.color_at(d, l) == pcolor:
				return d - dist
		d += 1.0
	return lv.total_length() - dist

## 按一次跳跃，并当场检查它有没有被吞掉。
## 这是针对历史 bug（"跳跃按键无效"）的定点探针：站在地上、冷却为 0、
## 参数合法时，request_jump 必须让 airborne 变真。不真就是引擎吞键。
func _try_jump(p: Player, dir: int, st: Dictionary) -> void:
	p.request_jump(dir)
	if not p.airborne:
		st["swallowed"] += 1
		st["swallow_log"].append("d=%.1f 层%d 方向%d" % [p.distance, p.layer, dir])

func _shift(down: bool) -> void:
	if down == _shift_down:
		return
	_shift_down = down
	var ev := InputEventKey.new()
	ev.keycode = KEY_SHIFT
	ev.physical_keycode = KEY_SHIFT
	ev.pressed = down
	Input.parse_input_event(ev)

func _shift_reset() -> void:
	_shift(false)

# ============================================================
# 3. 流程状态机
# ============================================================
func _test_state_machine() -> void:
	print("\nTest: 关卡流程状态机（READY → PLAYING → WIN → 下一关 ｜ DEAD → 重开 ｜ 星级分档）")
	var main := _make_main()

	# --- 开局 ---
	main.load_level(0)
	_check("load_level 后停在 READY（等玩家按开始）", main.phase == 0)
	await _send_key(KEY_SPACE)
	_check("READY 按空格 → PLAYING", main.phase == 1)

	# --- 通关与星级分档 ---
	# L1 二星线 53s / 三星线 49s。逐档验边界 —— 光断言"phase==WIN"是假绿，
	#   因为不论算成几星 phase 都是 WIN。真正的判定结果是 HUD 标题里的星数，
	#   所以直接去读它（这是"读玩家看到的东西"，不是读内部变量）。
	main._on_finished(53.1)
	_check("53.1s（> 二星线）→ 1 星", _stars_of(main) == 1)
	main._on_finished(53.0)
	_check("53.0s（= 二星线）→ 2 星（边界必须算过）", _stars_of(main) == 2)
	main._on_finished(49.0)
	_check("49.0s（= 三星线）→ 3 星（边界必须算过）", _stars_of(main) == 3)
	main._on_finished(30.0)
	_check("30.0s（远快于三星线）→ 仍是 3 星（不会溢出）", _stars_of(main) == 3)

	# --- WIN → 下一关 ---
	main._on_finished(48.0)
	await _send_key(KEY_SPACE)
	_check("WIN 按空格 → 进入第 2 关并直接开跑",
		main.phase == 1 and main.level_index == 1)
	main._on_finished(50.0)
	await _send_key(KEY_SPACE)
	_check("WIN 按空格 → 进入第 3 关并直接开跑",
		main.level_index == 2 and main.phase == 1)
	main._on_finished(50.0)
	await _send_key(KEY_SPACE)
	# 最后一关没有"下一关"，语义上应该循环回第 1 关。落点是 READY（等开始）
	#   还是 PLAYING 都可以，但【绝不能停在 DEAD / 卡住不动】。
	_check("最后一关 WIN 按空格 → 循环回第 1 关，且没有卡死",
		main.level_index == 0 and (main.phase == 0 or main.phase == 1))

	# --- 死亡 → 重开复位 ---
	main.load_level(1)
	main.phase = 1
	main.player.distance = 123.0
	main.player.energy = 0.0
	main.player._die("测试用的强制死亡")
	_check("能量归零/强制死亡 → DEAD", main.phase == 2)
	# 死亡面板上写的是「按 空格 / R 重开本关」—— 两个键必须等价，
	#   否则等于对玩家撒谎。这里同时验，不等价就报出来。
	await _send_key(KEY_SPACE)
	# ⚠ 这里必须显式写 : bool。main 是 Node3D，main.phase 是 Variant，
	#   Variant == int 的结果也是 Variant，`:=` 推不出来 → Parse Error，
	#   而失败方式是【场景静默不加载、什么都不打印】。见 MEMORY.md。
	var space_ok: bool = main.phase == 1 and main.player.distance == 0.0
	_check("DEAD 按空格 → 立刻重新开跑且状态复位", space_ok)
	main.player.distance = 99.0
	main.player._die("再来一次")
	await _send_key(KEY_R)
	_check("DEAD 按 R → 与空格行为一致（面板是这么承诺的）",
		main.phase == 1 and main.player.distance == 0.0)
	_check("重开后状态完全复位（距离/能量/层/存活）",
		main.player.distance == 0.0 and main.player.energy == GameConfig.ENERGY_START
		and main.player.layer == 0 and main.player.alive)
	_check("重开后关卡没被换掉", main.level_index == 1)

	# --- 选关键 ---
	await _send_key(KEY_1)
	_check("按 1 → 第 1 关并直接开跑", main.level_index == 0 and main.phase == 1)
	await _send_key(KEY_3)
	_check("按 3 → 第 3 关并直接开跑", main.level_index == 2 and main.phase == 1)

	main.queue_free()
	_shift_reset()

## 注入一次按键并让视口把它派发下去。
## 必须 await 若干帧：Input.parse_input_event 是进入输入队列的，
## 不等到下一帧派发完就读 phase 会读到旧值 —— 这是这类测试最常见的假红来源。
func _send_key(code: int) -> void:
	var down := InputEventKey.new()
	down.keycode = code
	down.physical_keycode = code
	down.pressed = true
	Input.parse_input_event(down)
	await get_tree().process_frame
	await get_tree().process_frame
	var up := InputEventKey.new()
	up.keycode = code
	up.physical_keycode = code
	up.pressed = false
	Input.parse_input_event(up)
	await get_tree().process_frame

## 从 HUD 标题里数星。
## 为什么不读 Main 的内部变量：_on_finished 根本没把 stars 存成成员，
## 它是直接格式化成标题的。而"玩家看到的"就是那行标题 ——
## 读它等于读玩家看到的东西，不是读一个可能和显示不同步的副本。
## 标题不是「通关 …」时返回 -1（而不是 0），这样断言会响亮地失败而不是静默通过。
func _stars_of(main: Node3D) -> int:
	var txt: String = main.hud._center_title.text
	if not txt.begins_with("通关"):
		return -1
	var n := 0
	for i in txt.length():
		if txt[i] == "★":
			n += 1
	return n

# ============================================================
# 4. 缺考项自查
# ============================================================
## 这一节在跑完后自问：这轮测试【没覆盖】什么？写在输出里，
## 免得"全绿"被读成"没问题"。测试的价值一半在于说清它的边界。
func _print_coverage_gaps() -> void:
	print("\nTest: 本次覆盖的边界（未覆盖项也要说清）")
	_note("已覆盖：三关 × 4 种打法组合从起点跑到终点、死亡轨迹、按键吞噬探针、段级能量轨迹")
	_note("已覆盖：READY/PLAYING/WIN/DEAD 四条转移、重开复位、选关键、星级三档边界")
	_note("未覆盖：晶体拾取路线（可通关性按设计不依赖晶体，见硬约束 4）")
	_note("未覆盖：鼠标切色、ESC 退出、窗口尺寸变化")
	_note("未覆盖：手感 —— 那条只能真人玩，自动化测不出来")
