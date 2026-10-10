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
	p.queue_free()

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
	# 【回归测试】这一条对应"跳跃按键无效"事故。
	#   留空改造后最常见的局面：本段只有我这层，下一段只有另一层。
	#   玩家必须在【本段末尾】就能把落点解析到【下一段】——
	#   旧引擎按"当前距离"解析，于是永远查的是本段，返回 -1，按键被整个吞掉，
	#   紧接着跑过边界当场坠落。校验器当时按"段边界"解析，所以全绿。
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

	# 太早按：落点还在本段内，本段没有上层 → 不再是"无效"，
	# 而是【原地跳】（不换层）。按键依然有反馈，这是 2026-10-10 的规则改动。
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
	print("Test: 跳跃整合（三种向上跳共用同一条固定顶点曲线）")
	# 【2026-10-10 用户要求】把「跳跃」和「跳到上一层」整合成同一条曲线，
	#   顶点取【固定的绝对高度】。所以断言从上一轮的"两种跳跃凑成一样高"
	#   升级为"三种跳跃的峰值都等于 JUMP_APEX_Y" ——
	#   原地跳(d=0)、上1层(d=3.2)、跨空层上2层(d=6.4)。
	#
	#   它们的峰值【时刻】不同（爬得越高峰值越靠后）：d=0 → t_p=0.5、
	#   d=3.2 → ≈0.568、d=6.4 → ≈0.716。但公式和顶点是同一个 ——
	#   这就是"整合"：不再是两条曲线被调参凑到一起。
	var apex := GameConfig.JUMP_APEX_Y
	var top := GameConfig.LAYER_Y[GameConfig.LAYER_COUNT - 1]

	# 单层关：该方向没有跑道 → 原地跳
	var one_lv := _level([{"length": 400.0, "colors": [0, -1, -1]}])
	var a := Player.new()
	a.setup(one_lv)
	a.request_jump(1)
	var inplace_peak := -INF
	for i in 60:
		a.tick(1.0 / 60.0)
		inplace_peak = maxf(inplace_peak, a._y)

	# 三层全满 → 从层0 跳到层1
	var full_lv := _level([{"length": 400.0, "colors": [0, 0, 0]}])
	var b := Player.new()
	b.setup(full_lv)
	b.request_jump(1)
	var up1_peak := -INF
	for i in 60:
		b.tick(1.0 / 60.0)
		up1_peak = maxf(up1_peak, b._y)

	# 层1 是缺口 → 从层0 一次【跨过空层】跳到层2
	var skip_lv := _level([{"length": 400.0, "colors": [0, -1, 0]}])
	var c := Player.new()
	c.setup(skip_lv)
	c.request_jump(1)
	var up2_peak := -INF
	for i in 60:
		c.tick(1.0 / 60.0)
		up2_peak = maxf(up2_peak, c._y)

	# 60fps 采样不会正好落在峰值上（每帧 t 走 1/60/0.58 ≈ 0.029，
	#   峰值附近 1 帧的高度差 < 0.01m），但为了不写成脆弱的断言取 0.12 容差。
	var tol := 0.12
	_check("原地跳峰值 = 固定顶点 %.2f（偏差 < %.2f）" % [apex, tol],
		absf(inplace_peak - apex) < tol)
	_check("跳上一层峰值 = 同一个顶点（与原地跳严格同高）",
		absf(up1_peak - apex) < tol)
	_check("跨空层跳两层峰值 = 同一个顶点（跳一层与跳两层视觉一样）",
		absf(up2_peak - apex) < tol)
	_check("顶点高于顶层 %.1fm（统一冲到顶层之上）" % top, inplace_peak > top)
	_check("顶点 = 顶层 + JUMP_APEX_CLEARANCE %.2f" % GameConfig.JUMP_APEX_CLEARANCE,
		absf(apex - (top + GameConfig.JUMP_APEX_CLEARANCE)) < 0.001)

	# 落点仍然由【方向上的最近实体跑道】决定 —— 顶点统一不等于落点统一。
	_check("原地跳不换层（落回层0）", a.layer == 0 and absf(a._y - GameConfig.LAYER_Y[0]) < 0.02)
	_check("跳上一层落在层1", b.layer == 1 and absf(b._y - GameConfig.LAYER_Y[1]) < 0.02)
	_check("跨空层落在层2（不是层1）", c.layer == 2 and absf(c._y - GameConfig.LAYER_Y[2]) < 0.02)

	# 三种跳跃的滞空必须一样长 —— 否则"整合"只整合了形状，没整合节奏。
	_check("三种跳跃滞空同为 %.2fs" % GameConfig.JUMP_AIR_TIME,
		absf(a._air_time - GameConfig.JUMP_AIR_TIME) < 0.0001
		and absf(b._air_time - GameConfig.JUMP_AIR_TIME) < 0.0001
		and absf(c._air_time - GameConfig.JUMP_AIR_TIME) < 0.0001)

	a.queue_free(); b.queue_free(); c.queue_free()

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
	_check("坠落有可见时长 ≈0.5s（30 帧）", air_frames >= 28 and air_frames <= 32)
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
