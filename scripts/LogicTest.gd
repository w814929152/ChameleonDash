extends Node
## 机制逻辑自测：判定表的每一条都必须有断言。
## 运行：godot --headless --quit-after 60 --path D:/ChameleonDash res://scenes/LogicTest.tscn

var failures := 0
var _died_flag := false

func _ready() -> void:
	_test_same_color_gain()
	_test_diff_color_drain()
	_test_switch_clears_energy()
	_test_jump_mechanics()
	_test_three_layer_jump()
	_test_inplace_jump_cost()
	_test_jump_across_boundary()
	_test_unified_jump_arc()
	_test_track_gap()
	_test_natural_fall()
	_test_air_rescue()
	_test_dash()
	_test_death()
	print("========================================")
	if failures == 0:
		print("机制自测全部通过")
	else:
		print("失败 %d 项" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _check(name: String, cond: bool) -> void:
	if cond:
		print("  [PASS] " + name)
	else:
		failures += 1
		print("  [FAIL] " + name)

func _level(rows: Array) -> LevelData:
	return LevelData.new("test", rows, 0.0, 0.0)

func _test_same_color_gain() -> void:
	print("Test: 同色回血 +8/s")
	var lv := _level([{"length": 200.0, "colors": [0,1,1]}])
	var p := Player.new()
	p.setup(lv)
	p.energy = 50.0
	for i in 60:
		p.tick(1.0 / 60.0)
	_check("1 秒回 8 点", absf(p.energy - 58.0) < 0.5)
	p.queue_free()

func _test_diff_color_drain() -> void:
	print("Test: 异色消耗 -18/s")
	var lv := _level([
		{"length": 10.0, "colors": [0,1,1]},
		{"length": 200.0, "colors": [1,0,0]},
	])
	var p := Player.new()
	p.setup(lv)
	p.energy = 50.0
	for i in 60:   # 12m：前 10m 同色(+6.67)，后 2m 异色(-3)
		p.tick(1.0 / 60.0)
	_check("混合段收支正确", absf(p.energy - 53.67) < 1.0)
	_check("状态识别为异色", p.state == Player.State.DIFF)
	p.queue_free()

func _test_switch_clears_energy() -> void:
	print("Test: 切色清空能量")
	var lv := _level([{"length": 200.0, "colors": [0,1,1]}])
	var p := Player.new()
	p.setup(lv)
	p.energy = 77.0
	p.request_switch_color()
	_check("能量归零", p.energy == 0.0)
	_check("颜色翻转", p.player_color == 1)
	p.queue_free()

func _test_jump_mechanics() -> void:
	print("Test: 跳跃（成本/冻结/换层）")
	var lv := _level([{"length": 400.0, "colors": [0,0,0]}])
	var p := Player.new()
	p.setup(lv)
	p.energy = 50.0
	p.request_jump(1)
	_check("跳跃消耗 8 点", absf(p.energy - 42.0) < 0.01)
	_check("进入空中", p.airborne)
	# 断言方式改过一次：旧版写死"45 帧 = 0.5s 滞空 + 0.25s 地面"再对总收益做算术，
	#   滞空从 0.5 改到 0.58 之后它立刻假红 —— 因为那条断言验的是【常量的算术】，
	#   不是"冻结"这件事本身。现在直接逐帧验不变量：空中每帧能量必须纹丝不动。
	#   这样以后再怎么调 JUMP_AIR_TIME 都不需要动这条断言。
	var frozen_ok := true
	var air_frames := 0
	for i in 90:
		var before := p.energy
		p.tick(1.0 / 60.0)
		if p.airborne:
			air_frames += 1
			if absf(p.energy - before) > 0.0001:
				frozen_ok = false
	_check("滞空期间逐帧能量冻结（实测 %d 帧 ≈ %.2fs）" % [air_frames, air_frames / 60.0],
		frozen_ok and air_frames >= 30)
	_check("落地换层", p.layer == 1)
	p.queue_free()

func _test_three_layer_jump() -> void:
	print("Test: 三层切层（边缘层原地跳 / 跨两层成本）")
	var lv := _level([{"length": 400.0, "colors": [0,0,0]}])
	var p := Player.new()
	p.setup(lv)
	p.energy = 50.0

	# 已在底层(0)，再向下按 = 该方向没有跑道 → 【原地跳】（2026-10-10 新规则）。
	# 脚下是同色 → 免费。但按键必须有反馈：airborne 为真、层不变。
	p.request_jump(-1)
	_check("底层向下是原地跳：不扣能量、不换层、有反馈",
		absf(p.energy - 50.0) < 0.01 and p.airborne and p.jump_to == 0)
	# 等原地跳落地。帧数用常量算，不写死 —— 滞空一改，写死的帧数就变成假绿/假红。
	for i in int(ceil(GameConfig.JUMP_AIR_TIME * 60.0)) + 12:
		p.tick(1.0 / 60.0)
	_check("原地跳落地后仍在层0", p.layer == 0)

	# 底层 → 顶层：request_jump 只走相邻一层，跨两层必须连按两次
	p.request_jump(1)
	for i in int(ceil(GameConfig.JUMP_AIR_TIME * 60.0)) + 12:
		p.tick(1.0 / 60.0)
	_check("一次跳只上一层", p.layer == 1)
	p.request_jump(1)
	for i in int(ceil(GameConfig.JUMP_AIR_TIME * 60.0)) + 12:
		p.tick(1.0 / 60.0)
	_check("连跳两次到顶层", p.layer == 2)

	# 【2026-10-10 三次定稿 · 回归守卫】站在实体跑道上按 S 必须【真的下降】。
	#   三次定稿第一次实现时，落点扫描把"本层"也算进了候选，于是按 S 会落到自己
	#   脚下 —— S 键静默失灵，而看起来一切正常（airborne 为真、有弧线）。
	#   这条断言就是那个坑的探测器：脚下有跑道时，S 必须落到更低的层。
	p.request_jump(-1)
	_check("在顶层按 S 必须下降（不能落回本层）", p.airborne and p.jump_to == 1)
	for i in int(ceil(GameConfig.fall_air_time(2, 1) * 60.0)) + 12:
		p.tick(1.0 / 60.0)
	_check("主动下坠落在层1", p.layer == 1)
	p.queue_free()

	# 【三次定稿 · 回归守卫 2】层1 是空的时候，按 S 必须能【一次掉到层0】。
	#   这是留空关卡最常见的地形（层1 空、层0 与层2 有跑道）。
	#   第一次实现时把下坠区间写成了"只准降一层"，于是这种地形下按 S 毫无反应。
	#   ⚠ 四次定稿后这里是【掉两层】→ 耗时 0.71s 而不是 0.5s，
	#     帧数必须从 fall_air_time 算，写死 0.5s 的循环会在这条上假红。
	var skip_lv := _level([{"length": 400.0, "colors": [0, -1, 0]}])
	var q := Player.new()
	q.setup(skip_lv)
	q.layer = 2
	q._y = GameConfig.LAYER_Y[2]
	q.request_jump(-1)
	_check("层1 空时按 S 一次掉到层0（跨空层下落）", q.airborne and q.jump_to == 0)
	for i in int(ceil(GameConfig.fall_air_time(2, 0) * 60.0)) + 12:
		q.tick(1.0 / 60.0)
	_check("跨空层下坠落在层0", q.layer == 0)
	q.queue_free()

func _test_inplace_jump_cost() -> void:
	print("Test: 原地跳的定价（同色免费 / 异色照收）")
	# 只有一层的关：任何方向都没有跑道 → 每次按键都是原地跳。
	# 同色轨道：免费。这是"按键永远有反馈"的核心 —— 没位移就不该计费。
	var same_lv := _level([{"length": 400.0, "colors": [0, -1, -1]}])
	var a := Player.new()
	a.setup(same_lv)                  # player_color = 0，脚下也是 0 → 同色
	a.energy = 50.0
	a.request_jump(1)
	a.request_jump(-1)                # airborne，必然被拦，不重复扣费
	_check("同色轨道原地跳免费", absf(a.energy - 50.0) < 0.01 and a.airborne)
	_check("原地跳落在本层", a.jump_to == 0)
	a.queue_free()

	# 异色轨道：照收 8 点。它在用空中冻结替玩家挡伤害，不能白送。
	var diff_lv := _level([{"length": 400.0, "colors": [1, -1, -1]}])
	var b := Player.new()
	b.setup(diff_lv)                  # player_color = 0，脚下是 1 → 异色
	b.energy = 50.0
	b.request_jump(1)
	_check("异色轨道原地跳照收 8 点", absf(b.energy - 42.0) < 0.01 and b.airborne)
	b.queue_free()

func _test_jump_across_boundary() -> void:
	print("Test: 留空关卡的跨段跳跃（段末尾起跳，落到下一段的层）")
	# 【回归测试】这一条对应"跳跃按键无效"事故，三次定稿后仍然有效 ——
	#   落点必须在【落地那一刻的距离】(distance + 速度 × 滞空) 上解析。
	#   本段只有我这层、下一段只有另一层时，玩家必须在【本段末尾】就能把落点
	#   解析到下一段。用当前距离解析 → 查的是本段 → 返回 -1 → 按键被吞，
	#   紧接着跑过边界又立刻坠落。这是本作最贵的一次事故，断言保留。
	var lv := _level([
		{"length": 72.0, "colors": [0, -1, -1]},   # 只有底层
		{"length": 48.0, "colors": [-1, 0, -1]},   # 只有中层
	])
	var reach := GameConfig.SPEED_BASE * GameConfig.JUMP_AIR_TIME   # = 6.96m

	# 段末尾前 0.5m：一次跳跃的前进距离刚好越界 → 必须能跳
	var p := Player.new()
	p.setup(lv)
	p.distance = 72.0 - 0.5
	p.layer = 0
	p.request_jump(1)
	_check("段末尾能跳向下一段的层", p.airborne and p.jump_to == 1)

	# 窗口左沿：恰好 reach 远 → 落点正好压在边界上，仍可起跳
	var w := Player.new()
	w.setup(lv)
	w.distance = 72.0 - reach
	w.layer = 0
	w.request_jump(1)
	_check("窗口左沿（落点压在边界）仍可起跳", w.airborne)

	# 太早按：落点还在本段内 → 本段没有上层，物理上自然弹回本层。
	#   新规则下这不再是"无效输入"也不是特殊分支，就是 _resolve_landing 撞出来的结果。
	var q := Player.new()
	q.setup(lv)
	q.distance = 72.0 - reach - 1.0
	q.layer = 0
	q.request_jump(1)
	_check("落点仍在段内时是原地跳（不换层）", q.airborne and q.jump_to == 0)

	# 完整跳一遍：落点在下一段的中层且存活
	var r := Player.new()
	r.setup(lv)
	r.distance = 71.5
	r.layer = 0
	r.request_jump(1)
	for i in 40:
		r.tick(1.0 / 60.0)
	_check("落地在层1 且存活", r.alive and r.layer == 1)
	_check("跳完距离已越过段边界", r.distance > 72.0)
	p.queue_free(); w.queue_free(); q.queue_free(); r.queue_free()

func _test_unified_jump_arc() -> void:
	print("Test: 跳跃（单纯跳跃 —— 峰值只由出发层决定，落点由物理撞出来）")
	# 【2026-10-10 三次定稿】用户要求「去掉跳到上一层跑道的规则，只有单纯的跳跃，
	#   跳跃的高度可以足够让玩家跳到上一层的跑道」。
	#   所以断言从上一版的"顶点 = 落点层 + 余量"改成下面这条更强的不变量：
	#
	#     ① 【弧高与落点解耦】同样从层0 起跳，"跳上一层 / 弹回本层 / 上面够不着"
	#        三种局面必须【飞一样高】—— 跳跃不知道上面有什么，是关卡决定它撞到哪。
	#        这条一旦变红，说明又有人把"落点"塞回峰值公式里了。
	#     ② 峰值落在上一层与再上一层【之间】—— 这同时就是"能跳上去"和"只能跳一层"：
	#          3.2 (+1层) < 4.4 (峰值) < 6.4 (+2层)
	#     ③ 顶层起跳被 JUMP_APEX_MAX_Y 夹住（三层盒子的顶盖）。
	#     ④ 落点：三层全满 → 落到层1；层1 是缺口 → 弹回层0（跳不到层2）。
	var y0: float = GameConfig.LAYER_Y[0]
	var y1: float = GameConfig.LAYER_Y[1]
	var y2: float = GameConfig.LAYER_Y[2]
	var expect_peak: float = y0 + GameConfig.JUMP_APEX_HEIGHT
	var tol := 0.12

	# a: 单层关（只有层0）→ 上面什么都没有，弹回本层
	var one_lv := _level([{"length": 400.0, "colors": [0, -1, -1]}])
	var a := Player.new()
	a.setup(one_lv)
	a.request_jump(1)
	var inplace_peak := -INF
	for i in 60:
		a.tick(1.0 / 60.0)
		inplace_peak = maxf(inplace_peak, a._y)

	# b: 三层全满 → 从层0 跳到层1
	var full_lv := _level([{"length": 400.0, "colors": [0, 0, 0]}])
	var b := Player.new()
	b.setup(full_lv)
	b.request_jump(1)
	var up1_peak := -INF
	for i in 60:
		b.tick(1.0 / 60.0)
		up1_peak = maxf(up1_peak, b._y)

	# c: 层1 是缺口、层2 有跑道 —— 旧规则下这一跳会【跨空层直接上顶层】，
	#    新规则下峰值 4.4 够不着 6.4，所以只能弹回层0。这就是"只能跳一层"。
	var skip_lv := _level([{"length": 400.0, "colors": [0, -1, 0]}])
	var c := Player.new()
	c.setup(skip_lv)
	c.request_jump(1)
	var skip_peak := -INF
	for i in 60:
		c.tick(1.0 / 60.0)
		skip_peak = maxf(skip_peak, c._y)

	# d: 从顶层起跳 —— 峰值照加 4.4 会到 10.8m，必须被 JUMP_APEX_MAX_Y 夹住
	var d := Player.new()
	d.setup(full_lv)
	d.layer = 2
	d._y = y2
	d.request_jump(1)
	var top_peak := -INF
	for i in 60:
		d.tick(1.0 / 60.0)
		top_peak = maxf(top_peak, d._y)

	# 60fps 采样不会正好落在峰值上（每帧 t 走 1/60/0.58 ≈ 0.029，
	#   峰值附近 1 帧的高度差 < 0.01m），但为了不写成脆弱的断言取 0.12 容差。
	_check("① 弧高与落点解耦：弹回本层 %.2f = 跳上一层 %.2f = 够不着时 %.2f" % [
			inplace_peak, up1_peak, skip_peak],
		absf(inplace_peak - up1_peak) < tol and absf(up1_peak - skip_peak) < tol)
	_check("①b 三者峰值都 = 出发层 + %.2f（实测 %.2f）" % [
			GameConfig.JUMP_APEX_HEIGHT, up1_peak],
		absf(inplace_peak - expect_peak) < tol and absf(up1_peak - expect_peak) < tol
		and absf(skip_peak - expect_peak) < tol)

	_check("② 峰值高过上一层（%.2f > %.2f）—— 够得着" % [up1_peak, y1], up1_peak > y1)
	_check("②b 峰值低于再上一层（%.2f < %.2f）—— 只能跳一层" % [up1_peak, y2],
		up1_peak < y2)
	_check("②c 冗余可见（高出上一层 %.2f ≥ 0.8 × %.2f）" % [
			up1_peak - y1, GameConfig.JUMP_APEX_CLEARANCE],
		up1_peak - y1 > GameConfig.JUMP_APEX_CLEARANCE * 0.8)

	_check("③ 顶层起跳被夹在 JUMP_APEX_MAX_Y = %.2f（实测 %.2f）" % [
			GameConfig.JUMP_APEX_MAX_Y, top_peak],
		absf(top_peak - GameConfig.JUMP_APEX_MAX_Y) < tol and top_peak < 10.0)

	_check("④ 三层全满 → 落到层1", b.layer == 1 and absf(b._y - y1) < 0.02)
	_check("④b 层1 是缺口 → 弹回层0（跳不到层2）",
		c.layer == 0 and absf(c._y - y0) < 0.02)
	_check("④c 单层关 → 弹回本层", a.layer == 0 and absf(a._y - y0) < 0.02)
	_check("④d 顶层起跳落回顶层", d.layer == 2 and absf(d._y - y2) < 0.02)

	# 滞空必须一样长 —— 弧高、落点都改了，节奏不能跟着变
	#   （JUMP_AIR_TIME 同时是"一次跳跃前进多远"的下界，见 GameConfig）。
	_check("四种局面的滞空同为 %.2fs" % GameConfig.JUMP_AIR_TIME,
		absf(a._air_time - GameConfig.JUMP_AIR_TIME) < 0.0001
		and absf(b._air_time - GameConfig.JUMP_AIR_TIME) < 0.0001
		and absf(c._air_time - GameConfig.JUMP_AIR_TIME) < 0.0001
		and absf(d._air_time - GameConfig.JUMP_AIR_TIME) < 0.0001)

	a.queue_free(); b.queue_free(); c.queue_free(); d.queue_free()

func _test_track_gap() -> void:
	print("Test: 跑道缺口（坠落代价 / 无路可走）")
	# 中层在 50~90m 处中断，上下两层都有跑道
	var lv := _level([
		{"length": 50.0, "colors": [0,0,0]},
		{"length": 40.0, "colors": [0,-1,0]},
		{"length": 200.0, "colors": [0,0,0]},
	])
	var p := Player.new()
	p.setup(lv)
	p.energy = 80.0
	p.layer = 1

	# 【2026-10-10】坠落不再是瞬移，而是一段可见动画，所以要按"过程"断言：
	#   · 进入 falling 状态（而不是一帧之内换层）
	#   · 持续 ≈0.5s（30 帧）
	#   · 全程层号不变（落地才换层）、_y 单调向下（不回弹）
	#   · 起坠那一帧扣 8 点
	# 【2026-10-10 补】坠落的表现：轨迹之外还要有【剪影】。
	#   轨迹只改"位置怎么变"，不改"身体长什么样" —— 只做轨迹的话，
	#   0.5s 里角色是一具不变的胶囊被搬下去，读不出"我在掉"。
	#   所以这里顺带采样本帧的 _squash（身体纵向缩放），断言它随 t 长大。
	var air_frames := 0
	var started := false
	var layer_changed_midair := false
	var y_went_up := false
	var e_before_fall := 0.0
	var e_first_air := 0.0
	var y_prev := p._y
	var sq_first := 0.0
	var sq_last := 0.0
	var sq_prev := 0.0
	var sq_shrank := false
	# 光环的【世界坐标 y】。光环是 local position（相对玩家），
	#   所以世界高度 = 光环 local y + 玩家 position.y。
	#   恒等式：LAYER_Y[ring_layer] - (_y+0.95) + 0.06 + (_y+0.95) = LAYER_Y[ring_layer] + 0.06
	#   —— 也就是"光环离玩家多高"会随 _y 变，但它在世界里的高度只由 ring_layer 决定。
	var ring_world_y := 0.0
	for i in 60 * 8:
		var e0 := p.energy
		var l0: int = p.layer
		p.tick(1.0 / 60.0)
		if p.falling:
			if not started:
				started = true
				e_before_fall = e0
				e_first_air = p.energy
			air_frames += 1
			if p.layer != l0:
				layer_changed_midair = true
			if p._y > y_prev:
				y_went_up = true
			if sq_first == 0.0:
				sq_first = p._squash
			if p._squash < sq_prev - 0.0001:
				sq_shrank = true
			sq_prev = p._squash
			sq_last = p._squash
			ring_world_y = p._ring.position.y + p.position.y
		elif started:
			break
		y_prev = p._y

	_check("踩空进入【坠落】状态，而不是瞬移换层", started)
	# 【四次定稿】掉一层 = 0.50s 是【自由落体的解】，不再是常量 FALL_AIR_TIME。
	#   帧数从 GameConfig 算，写死 30 的话这条断言会在下一次标定时无声变成假话。
	var one_layer_frames := int(round(GameConfig.fall_air_time(1, 0) * 60.0))
	_check("掉一层的坠落时长 = 自由落体解 %.2fs（%d 帧）" % [
		GameConfig.fall_air_time(1, 0), one_layer_frames],
		absi(air_frames - one_layer_frames) <= 2)
	_check("坠落期间层号不变（落地才换层）", not layer_changed_midair)
	_check("坠落全程单调向下，没有回弹", not y_went_up)
	_check("起坠当帧扣约 8 点", (e_before_fall - e_first_air) > 7.5 and (e_before_fall - e_first_air) < 8.5)
	_check("落地在下层且不致死（落在同色上）", p.layer == 0 and p.alive and not p.falling)
	_check("坠落起帧接近原形（起坠速度≈0，不该立刻被拉长）", sq_first > 0.99 and sq_first < 1.06)
	_check("坠落末帧拉长到 FALL_STRETCH %.2f 附近" % GameConfig.FALL_STRETCH,
		absf(sq_last - GameConfig.FALL_STRETCH) < 0.05)
	_check("拉伸全程单调变大（与 t² 速度同源，不是常量）", not sq_shrank)
	# 出发层是 1、落点层是 0，两者相距一整个层间距，
	#   所以这条断言真的能分辨"贴落点"和"留在出发层"（后者会是 3.26）。
	_check("坠落时光环贴【落点层】，不悬在角色头顶",
		absf(ring_world_y - (GameConfig.LAYER_Y[0] + 0.06)) < 0.01)
	p.queue_free()

	# 上跳不能被套上"坠落拉伸"：两条曲线共用一个空中机制，
	# 一旦 falling 标志置错，上跳会被拉成 1.38 —— 玩家会读成"我在掉"。
	var lv3 := _level([{"length": 400.0, "colors": [0, 0, 0]}])
	var p3 := Player.new()
	p3.setup(lv3)
	p3.request_jump(1)
	var up_max_sq := 0.0
	var up_ever_falling := false
	var up_ring_world_y := 0.0
	for i in 40:
		p3.tick(1.0 / 60.0)
		up_max_sq = maxf(up_max_sq, p3._squash)
		# 只采【滞空期】的值。40 帧里上跳早就落地了，落地后 layer 会变成 1，
		#   光环当然跟着到层1 —— 那是正确行为，不该拿来做这条断言。
		if p3.airborne:
			up_ring_world_y = p3._ring.position.y + p3.position.y
		if p3.falling:
			up_ever_falling = true
	_check("上跳全程不被标记为坠落", not up_ever_falling)
	_check("上跳剪影与坠落不同（起跳 1.32 衰减，永不达 %.2f）" % GameConfig.FALL_STRETCH,
		up_max_sq < 1.35)
	# 上跳的方向与坠落相反 → 参照点也必须相反：出发层在【下方】，
	#   光环留在那里读作"我离开的那块地"，不会变成悬空异物。
	_check("上跳时光环留在【出发层】（与坠落刻意不对称）",
		absf(up_ring_world_y - (GameConfig.LAYER_Y[0] + 0.06)) < 0.01)
	p3.queue_free()

	# 底层与中层同时断了：玩家在底层，下方无路 → 死
	var lv2 := _level([
		{"length": 50.0, "colors": [0,0,0]},
		{"length": 40.0, "colors": [-1,-1,0]},
		{"length": 200.0, "colors": [0,0,0]},
	])
	var p2 := Player.new()
	p2.setup(lv2)
	p2.energy = 80.0
	p2.layer = 0
	for i in 60 * 5:
		if not p2.alive:
			break
		p2.tick(1.0 / 60.0)
	_check("下方也无跑道则坠落致死", not p2.alive)
	p2.queue_free()

func _test_natural_fall() -> void:
	print("Test: 下坠 = 自由落体（时长由落差算出来，不是常量）")
	# 【2026-10-10 四次定稿】用户要求"跳到下一层的逻辑，变成自然下落"。
	#   旧的 FALL_AIR_TIME = 0.5 是常量 → 掉两层和掉一层一样快，
	#   观感上"两层楼的落差被凭空压缩了"，且时长这个纯物理量被一个玩法旋钮钉住。
	#   现在 t = √(2h/g)：时长是【结果】。

	# ① 时长公式本身
	var t1 := GameConfig.fall_air_time(2, 1)
	var t2 := GameConfig.fall_air_time(2, 0)
	_check("掉一层 %.3fs（沿用旧 0.5s 作标定锚点，最常见那次坠落逐帧不变）" % t1,
		absf(t1 - 0.5) < 0.001)
	_check("掉两层 = 掉一层 × √2（%.4fs vs %.4fs）" % [t2, t1 * sqrt(2.0)],
		absf(t2 - t1 * sqrt(2.0)) < 0.001)
	_check("落差越大掉得越久（这是'自然'的全部含义）", t2 > t1)
	_check("不是下落时长为 0（同层 / 往上）",
		GameConfig.fall_air_time(0, 0) == 0.0 and GameConfig.fall_air_time(0, 2) == 0.0)

	# ② 实机：层1 空、层0 与层2 有跑道（留空关卡最常见的地形），
	#    玩家从层2 一次掉到层0，帧数必须是掉一层的 √2 倍。
	#    （这条才是"引擎真的按落差给时长"的证据 —— ①只验了公式）
	#    ⚠ 不能用"三层全满"的关来测：那种关里从层2 下坠只会落到层1，
	#      落差只有一层，测出来当然还是 30 帧。
	var gap_lv := _level([{"length": 400.0, "colors": [0, -1, 0]}])
	var p := Player.new()
	p.setup(gap_lv)
	p.layer = 2
	p._y = GameConfig.LAYER_Y[2]
	# reach_to 是 HUD 预警与 bot 决策读的"这次动作会前进多远"。
	#   它是【第二个入口】（落点本体在 _resolve_landing 里），所以必须验它与实机相符 ——
	#   一旦分家，症状就是"提示说现在按来得及、按下去却落空"。
	var reach_claim := p.reach_to(0)
	var d_start := p.distance
	p.request_jump(-1)
	var frames_2 := 0
	var ys: Array[float] = [p._y]
	while p.airborne and frames_2 < 600:
		p.tick(1.0 / 60.0)
		frames_2 += 1
		if p.airborne:
			ys.append(p._y)
	_check("掉两层用 %d 帧（掉一层 %.0f 帧）" % [frames_2, t1 * 60.0],
		absi(frames_2 - int(round(t2 * 60.0))) <= 2)
	_check("跨空层掉两层后落地在层0（不是层1）", p.layer == 0)
	# 实机前进距离含"落地那一帧也走了 0.2m"，所以给 0.2m 容差
	_check("reach_to(层0) = %.2fm，与实机前进 %.2fm 相符" % [reach_claim, p.distance - d_start],
		absf(reach_claim - (p.distance - d_start)) < 0.25)
	# reach_to 必须真的分方向（否则又回到"一个数糊两个方向"的老坑）
	var dir_probe := Player.new()
	dir_probe.setup(gap_lv)
	dir_probe.layer = 2
	dir_probe._y = GameConfig.LAYER_Y[2]
	var r_up := dir_probe.reach_to(2)          # 顶层原地弹 = 跳跃
	var r_1 := dir_probe.reach_to(1)           # 掉一层
	var r_2 := dir_probe.reach_to(0)           # 掉两层
	_check("reach_to 分方向且不等：弹 %.2f / 掉一层 %.2f / 掉两层 %.2f" % [r_up, r_1, r_2],
		r_up > r_1 + 0.5 and r_2 > r_up + 1.0)
	dir_probe.queue_free()

	# ③ 轨迹必须是【恒加速度】：逐帧位移的一阶差分单调，二阶差分恒定。
	#    为什么要单验这一条：_y 只进视觉不进判定，所以 SelfTest/PlayTest 都
	#    查不到它。改了落点却没改 _air_time（或把 t² 换成别的曲线），
	#    三套校验全绿，而画面里"掉下去"会变成"被搬下去"。
	#
	#    ⚠ 符号：y 是【向下减小】的，所以"越掉越快"意味着 d = y[i]−y[i−1]
	#      越来越负（d1 < d0），二阶差分也就【是负的】−g·dt²。
	#      第一次实现时按"正的"写，四条断言全假红 —— 方向搞反比数值错更难发现。
	#
	#    二阶差分 = ½g·dt²·[(n+1)² − 2n² + (n−1)²] = g·dt²，与 n 无关 ——
	#    所以"二阶差分是个常量"就是"加速度是常量"，它的值可以直接对比 g，
	#    不需要知道这是第几帧（帧计数不参与断言）。
	var dd_min := 1e9
	var dd_max := -1e9
	var dd_sum := 0.0
	var dd_n := 0
	var monotone := true
	for i in range(2, ys.size()):
		var d1 := ys[i] - ys[i - 1]
		var d0 := ys[i - 1] - ys[i - 2]
		if d1 >= d0:
			monotone = false        # 越掉越快：每帧位移必须严格更负
		dd_sum += d1 - d0
		dd_n += 1
		dd_min = minf(dd_min, d1 - d0)
		dd_max = maxf(dd_max, d1 - d0)
	var dt := 1.0 / 60.0
	_check("下坠逐帧位移单调下压（越掉越快，不存在匀速段）", monotone)
	_check("二阶差分恒定 = 恒加速度（极差 %.6f < 0.001）" % (dd_max - dd_min),
		dd_max - dd_min < 0.001)
	var dd_mean := -dd_sum / float(maxi(dd_n, 1))
	_check("加速度实测 %.6f = g·dt²（FALL_GRAVITY %.1f）" % [
		dd_mean, GameConfig.FALL_GRAVITY],
		absf(dd_mean - GameConfig.FALL_GRAVITY * dt * dt) < 0.0005)
	p.queue_free()

	# ④ 查询与动作同源 —— 铁律的可执行版本。
	#    next_track_layer 是校验器(check_forward_escape)和 bot 读的"查询"，
	#    request_jump 是玩家按的"动作"。两者一旦分家就是
	#    "校验通过而玩不了"（历史事故）。这里并排跑一遍，逐组比对。
	var probe_lv := _level([
		{"length": 40.0, "colors": [0, 0, 0]},
		{"length": 40.0, "colors": [0, -1, 0]},
		{"length": 200.0, "colors": [0, 0, 0]},
	])
	var same := true
	var groups := 0
	for d in [10.0, 38.0, 45.0, 79.0, 90.0]:
		for dir in [1, -1]:
			var qa := Player.new()
			qa.setup(probe_lv)
			qa.layer = 2
			qa._y = GameConfig.LAYER_Y[2]
			qa.distance = d
			_cur_speed_of(qa)
			var query := qa.next_track_layer(dir)
			qa.request_jump(dir)
			groups += 1
			# 语义约定：查询返回 -1 = "这个方向没有落点"，
			#   此时动作必须退化成【原地弹】（jump_to == 出发层）而不是别的层 ——
			#   否则查询说"无路"而动作却把人送到某层，两边就在撒谎。
			var want: int = query if query >= 0 else 2
			if qa.jump_to != want:
				same = false
				print("      ✗ dist=%.0f dir=%d 查询=%d 动作=%d" % [d, dir, query, qa.jump_to])
			qa.queue_free()
	_check("落点【查询】与落点【动作】逐组一致（%d 组 距离×方向）" % groups, same)

## 把 _cur_speed 刷新到当前距离应有的值（查询/动作都读它，测试里不能只填 distance）。
func _cur_speed_of(p: Player) -> void:
	p._cur_speed = GameConfig.SPEED_BASE * (p.level.boost_at(p.distance) if p.level != null else 1.0)

func _test_air_rescue() -> void:
	print("Test: 空中救济（跳跃+切色连招救命）")
	var lv := _level([
		{"length": 10.0, "colors": [0,1,1]},
		{"length": 300.0, "colors": [1,1,1]},
	])
	var p := Player.new()
	p.setup(lv)
	p.energy = 20.0
	for i in 30:
		p.tick(1.0 / 60.0)          # 6m，第一段内
	for i in 20:
		p.tick(1.0 / 60.0)          # 进入异色段约 0.33s
	p.request_jump(1)               # -8 → 剩约 6
	p.request_switch_color()        # 空中切色归零
	_check("空中归零不判死", p.alive)
	for i in 40:
		p.tick(1.0 / 60.0)          # 落地：全 B 段对翻转后的 B 玩家 = 同色
	_check("落地同色获救回血", p.alive and p.energy > 0.0)
	p.queue_free()

func _test_dash() -> void:
	print("Test: 冲刺（满能量武装 / 24m/s / 松手消耗机会）")
	var lv := _level([{"length": 400.0, "colors": [0,1,1]}])
	var p := Player.new()
	p.setup(lv)
	p.energy = 100.0
	for i in 5:
		p.tick(1.0 / 60.0)
	_check("满能量自动武装", p._dash_armed)

	var ev := InputEventKey.new()
	ev.keycode = KEY_SHIFT
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	var d0 := p.distance
	p.tick(1.0 / 60.0)
	_check("按住 Shift 进入冲刺", p.dashing)
	_check("冲刺速度 24 m/s", absf((p.distance - d0) - GameConfig.SPEED_DASH / 60.0) < 0.01)

	var ev2 := InputEventKey.new()
	ev2.keycode = KEY_SHIFT
	ev2.pressed = false
	Input.parse_input_event(ev2)
	Input.flush_buffered_events()
	p.tick(1.0 / 60.0)
	_check("松手退出并消耗冲刺机会", not p.dashing and not p._dash_armed)
	p.queue_free()

func _test_death() -> void:
	print("Test: 异色能量归零即死")
	_died_flag = false
	var lv := _level([
		{"length": 10.0, "colors": [0,1,1]},
		{"length": 300.0, "colors": [1,0,0]},
	])
	var p := Player.new()
	p.setup(lv)
	p.energy = 10.0
	p.died.connect(func(_r: String) -> void: _died_flag = true)
	for i in 300:
		if not p.alive:
			break
		p.tick(1.0 / 60.0)
	_check("触发死亡", _died_flag and not p.alive)
	p.queue_free()
