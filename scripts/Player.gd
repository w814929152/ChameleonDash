class_name Player
extends Node3D
## 玩家：自动前进，只有四件事能做 —— 换层 / 跳跃 / 切色 / 冲刺。
##
## 判定表（这是整个游戏的核心，改动前先想清楚会打破哪一条）：
##   地面 · 同色   → +8/s            安全
##   地面 · 异色   → -18/s           归零即死
##   空中 · 任意   → 冻结，不增不减  不判定（跳跃 = 唯一的无敌帧）
##   冲刺 · 任意   → -24/s           归零即死（冲刺到底会自杀，必须自己停）
##
## 三条由判定表自然长出的战术：
##   1. 异色段上跳着走（滞空冻结消耗），同色段上别跳（冻结 = 白送收益）
##   2. 切色前先跳 —— 空中豁免能救"手滑切色导致的归零"
##   3. 能量低的时候切色，沉没成本最小
##
## 2026-10-10 新增：三种机制接入这张判定表的方式
##   加速带 —— 只改 speed，不改判定表。它是"改写账本"而不是"新增规则"。
##   脉冲段 —— 改的是 color_at_t 的返回值，判定表本身一行没动。
##   晶体   —— 判定表之外的一次性加值，不参与任何持续结算。
## 三个机制都刻意没有往判定表里加分支 —— 判定表的简洁是本作可读性的地基。

signal died(reason: String)
signal finished(time: float)
signal crystal_taken(index: int)

enum State { SAME, DIFF, AIR, DASH }

var level: LevelData
var distance := 0.0
var layer := 0
var player_color := 0          # 0 = A(青), 1 = B(橙)
var energy := GameConfig.ENERGY_START
var state: int = State.SAME
var alive := true
var elapsed := 0.0

var airborne := false
var jump_t := 0.0
var jump_from := 0
var jump_to := 0
var jump_cd := 0.0
## 跳跃抛物线的系数（y = 层高 + _jump_b·t + _jump_a·t²）。
## 顶点固定为 GameConfig.JUMP_APEX_Y —— 与落点无关，所以三种向上跳跃
## （原地 / 上一层 / 上两层）共用同一条公式，只是系数不同。
## 【2026-10-10】取代了旧的 _jump_arc（"lerp + sin(πt)·弧高"那套）。
var _jump_a := 0.0
var _jump_b := 0.0
## 本次空中的总时长。跳跃与坠落共用一套空中机制，但时长各自独立可调
## （坠落比跳跃快 —— 重力本来就该更快，理由见 GameConfig.FALL_AIR_TIME）。
var _air_time := GameConfig.JUMP_AIR_TIME
## 本次空中是【坠落】（踩空/掉层）而不是【主动跳】。
## 用途：落地压扁更狠、HUD 文案区分"空中/坠落"。
var falling := false
## 上一帧的实际水平速度。跳跃落点解析要用它算"我落地时会跑到哪"（见 next_track_layer）。
var _cur_speed := GameConfig.SPEED_BASE

var dashing := false
var _dash_armed := false
var grace := GameConfig.DEATH_GRACE_SEC

## 当前脚下的机制状态（供 HUD 读取）
var on_boost := false
var in_pulse := false
var pulse_active := false      # 脉冲段当前是否处于"已翻转"相位
var collected_crystals: Array = []

var _x := 0.0
var _y := 0.0
var _squash := 1.0
var _prev_distance := 0.0
var _crystal_list: Array = []
var _rig: Node3D
var _body_mat: StandardMaterial3D
var _ring_mat: StandardMaterial3D
var _ring: Node3D
var _dash_fx: CPUParticles3D
var _burst: Node3D
var _burst_t := 1.0

func setup(lv: LevelData) -> void:
	level = lv
	energy = GameConfig.ENERGY_START
	distance = 0.0
	layer = 0
	player_color = 0
	alive = true
	elapsed = 0.0
	dashing = false
	_dash_armed = false
	airborne = false
	falling = false
	_air_time = GameConfig.JUMP_AIR_TIME
	_jump_a = 0.0
	_jump_b = 0.0
	jump_cd = 0.0
	grace = GameConfig.DEATH_GRACE_SEC
	_squash = 1.0
	collected_crystals.clear()
	on_boost = false
	in_pulse = false
	_burst_t = 1.0
	_x = 0.0
	_y = GameConfig.LAYER_Y[layer]
	_prev_distance = 0.0
	_crystal_list = lv.crystal_list()
	_build_mesh()
	_refresh_visual()

# ------------------------------------------------------------
# 造型
# ------------------------------------------------------------
func _build_mesh() -> void:
	if _rig != null:
		_rig.queue_free()

	_rig = Node3D.new()
	add_child(_rig)

	# 本体：胶囊。玩家的轮廓必须是画面里最"实"的形状。
	_body_mat = StandardMaterial3D.new()
	_body_mat.emission_enabled = true
	_body_mat.emission_energy_multiplier = GameConfig.PLAYER_EMISSION
	_body_mat.roughness = 0.4

	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.46
	cap.height = 1.25
	body.mesh = cap
	body.material_override = _body_mat
	_rig.add_child(body)

	# 面罩：一条横向亮条。它同时解决两个问题 ——
	#   1. "这个球朝哪边跑"有了明确答案（跑酷里方向感是刚需）
	#   2. 纯色胶囊没有细节，远处看只是个色块，加一条高光才有"角色"感
	var visor := MeshInstance3D.new()
	var vb := BoxMesh.new()
	vb.size = Vector3(0.62, 0.16, 0.22)
	visor.mesh = vb
	var vm := StandardMaterial3D.new()
	# 面罩亮度刻意压低：白色 emission 一旦拉高，它会在 bloom 里把整个角色
	# 糊成一团白光，玩家就再也读不出"我是什么颜色"了。1.6 只够描出朝向。
	vm.albedo_color = Color(1, 1, 1)
	vm.emission_enabled = true
	vm.emission = Color(1, 1, 1)
	vm.emission_energy_multiplier = 1.6
	visor.material_override = vm
	visor.position = Vector3(0.0, 0.22, -0.40)
	_rig.add_child(visor)

	# 脚下的颜色光环：始终贴在"当前层的跑道面"上（不跟着角色升空）。
	# Rationale: 玩家要回答的问题是"我脚下是不是我的颜色"。光环把这个问题的
	#   两个答案（我的颜色 / 脚下的位置）压进同一个像素区域，横向对比变成
	#   同位置上下对比 —— 这是人眼最擅长、延迟最低的比较方式。
	_ring = Node3D.new()
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.emission_enabled = true
	_ring_mat.emission_energy_multiplier = 2.2
	var torus := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.70
	tm.outer_radius = 0.86
	tm.rings = 24
	tm.ring_segments = 6
	torus.mesh = tm
	torus.rotation.x = PI * 0.5
	torus.material_override = _ring_mat
	_ring.add_child(torus)
	add_child(_ring)

	# 冲刺拖尾
	_dash_fx = CPUParticles3D.new()
	_dash_fx.amount = 40
	_dash_fx.lifetime = 0.45
	_dash_fx.emitting = false
	_dash_fx.local_coords = false
	_dash_fx.direction = Vector3(0, 0, 1)
	_dash_fx.spread = 22.0
	_dash_fx.initial_velocity_min = 2.0
	_dash_fx.initial_velocity_max = 6.0
	_dash_fx.gravity = Vector3.ZERO
	_dash_fx.scale_amount_min = 0.10
	_dash_fx.scale_amount_max = 0.28
	# CPUParticles3D 不用 ParticleProcessMaterial（那是 GPUParticles3D 的东西），
	# 颜色直接写在节点自己的 color 属性上。
	_dash_fx.color = Color(1, 1, 1)
	var pmesh := SphereMesh.new()
	pmesh.radius = 0.2
	pmesh.height = 0.4
	pmesh.radial_segments = 6
	pmesh.rings = 3
	_dash_fx.mesh = pmesh
	_dash_fx.position = Vector3(0.0, 0.0, 0.5)
	add_child(_dash_fx)

	# 切色爆发环（初始隐藏，切色时展开）
	_burst = Node3D.new()
	_burst.visible = false
	var t2 := MeshInstance3D.new()
	var tm2 := TorusMesh.new()
	tm2.inner_radius = 0.8
	tm2.outer_radius = 1.0
	tm2.rings = 24
	tm2.ring_segments = 6
	t2.mesh = tm2
	var bm := StandardMaterial3D.new()
	bm.emission_enabled = true
	bm.emission_energy_multiplier = 2.8
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_burst.set_meta("mesh", t2)
	t2.material_override = bm
	_burst.add_child(t2)
	add_child(_burst)

# ------------------------------------------------------------
# 主循环
# ------------------------------------------------------------
func tick(dt: float) -> void:
	if not alive or level == null:
		return
	elapsed += dt

	_update_dash_arming()
	_refresh_cell_state()

	_prev_distance = distance
	var speed := GameConfig.SPEED_DASH if dashing else GameConfig.SPEED_BASE * _cell_speed_mult()
	_cur_speed = speed
	distance += speed * dt

	_update_jump(dt)
	_check_track_gap()
	_check_crystals()
	_update_energy(dt)
	_update_transform(dt)
	_update_fx(dt)

	if distance >= level.total_length():
		alive = false
		finished.emit(elapsed)

## 脚下的机制快照。每帧刷一次，能量结算和 HUD 都读它，
## 避免"结算用一套值、显示用另一套值"的经典错位。
func _refresh_cell_state() -> void:
	if level == null:
		return
	on_boost = not dashing and level.boost_at(distance) > 1.0
	in_pulse = level.is_pulse(distance)
	pulse_active = in_pulse and level.pulse_flipped(elapsed)

func _cell_speed_mult() -> float:
	if not on_boost:
		return 1.0
	return level.boost_at(distance)

func _update_dash_arming() -> void:
	if not _dash_armed and energy >= GameConfig.ENERGY_MAX:
		_dash_armed = true
	var holding := Input.is_key_pressed(KEY_SHIFT)
	if _dash_armed and holding:
		dashing = true
	elif dashing:
		dashing = false
		_dash_armed = false

func _update_jump(dt: float) -> void:
	if airborne:
		jump_t += dt / _air_time
		if jump_t >= 1.0:
			jump_t = 1.0
			airborne = false
			layer = jump_to
			jump_cd = GameConfig.JUMP_COOLDOWN
			# 落地压扁：坠落砸得更狠，让"掉下来的"和"跳上去的"手感不同
			_squash = 0.60 if falling else 0.72
			falling = false
		if jump_to < jump_from:
			# 下跳 / 坠落：一律走 t² 加速 —— 从静止开始加速，才读得出"掉下去"。
			# 线性补间看起来像"被平移下去"，这正是用户说的"瞬移"感。
			# 主动下跳与踩空坠落共用这条曲线 —— 两者对玩家是同一件事：往下掉。
			_y = lerpf(GameConfig.LAYER_Y[jump_from], GameConfig.LAYER_Y[jump_to], jump_t * jump_t)
		else:
			# 向上跳 / 原地跳：共用同一条【固定顶点】抛物线（见 GameConfig.JUMP_APEX_Y）。
			#
			# 【2026-10-10 用户要求：把跳跃和跳到上一层整合】
			#   旧实现这里是两条公式两个常量 ——
			#     上跳   y = lerp(层A, 层B, t) + sin(πt)·JUMP_ARC_HEIGHT
			#     原地跳 y = 层高 + sin(πt)·INPLACE_JUMP_ARC
			#   两条曲线的形状毫无关系，只是被调参凑成了"峰值一样高"。
			#   现在两者是【同一条公式在 d=0 与 d=3.2 时的取值】——
			#   整合是结构性的，不是凑的。
			#
			#   系数在 request_jump 里算好（抛物线过两个端点、峰值恰为 JUMP_APEX_Y）。
			#   不用 sin 而用抛物线：抛物线就是重力，sin 只是"看起来像弧"。
			_y = GameConfig.LAYER_Y[jump_from] + _jump_b * jump_t + _jump_a * jump_t * jump_t
	else:
		_y = GameConfig.LAYER_Y[layer]
		jump_cd = maxf(jump_cd - dt, 0.0)

## 缺口判定：脚下这层在此段没有跑道 → 坠落。
## 空中不判定 —— 给"已经起跳但还没落地"的玩家 6m 宽限。
##
## 【2026-10-10 改：从瞬移改为真正的下落】
##   旧版在这里一帧之内改掉 layer 和 _y —— 玩家看到的是"闪了一下"。
##   现在改成【起一段下落】，复用整套空中机制（能量冻结、不可再跳、落地压扁
##   全都白拿）。校验器的坠落模型本来就是按"0.5s + 6m"算的，
##   所以这次是引擎向模型靠拢，不是反过来。
func _check_track_gap() -> void:
	if airborne or not alive:
		return
	if level.color_at(distance, layer) != GameConfig.NO_TRACK:
		return

	# 落到哪一层要在【落地时的距离】上解析 —— 与 next_track_layer 同一套规矩。
	# 下落期间玩家还会前进 speed × FALL_AIR_TIME，用当前距离解析会拿错段。
	var land := distance + _cur_speed * GameConfig.FALL_AIR_TIME
	var target := -1
	for i in range(layer - 1, -1, -1):
		if level.color_at(land, i) != GameConfig.NO_TRACK:
			target = i
			break

	if target < 0:
		_die("坠落 —— 脚下与下方都没有跑道")
		return

	airborne = true
	falling = true
	_air_time = GameConfig.FALL_AIR_TIME
	# 下坠不走抛物线（_jump_to < _jump_from 那条分支只做 t²），系数清零是防御性的：
	#   万一将来有人把 jump_to/jump_from 改了，也不会拿上一次跳跃的系数来画坠落。
	_jump_a = 0.0
	_jump_b = 0.0
	jump_t = 0.0
	jump_from = layer
	jump_to = target
	# 按【次】计费，不按层数：掉 2 层与掉 1 层同价（见 GameConfig.FALL_ENERGY_COST）
	energy = maxf(energy - GameConfig.FALL_ENERGY_COST, 0.0)
	# 与跳跃一致：这里不判死，落在同色上还能救回来

## 晶体：本帧跨过晶体所在距离、且正好在那一层 → 拾取。
## 用"区间穿越检测"(上一帧位置 < d ≤ 本帧位置) 而不是"距离差 < ε"：
##   冲刺 + 加速带下单帧前进可达 0.7m，用 ε 判定会在帧率抖动时漏拾取。
##   区间检测是帧率无关的，不会漏。
func _check_crystals() -> void:
	if _crystal_list.is_empty():
		return
	for i in _crystal_list.size():
		if collected_crystals.has(i):
			continue
		var c: Dictionary = _crystal_list[i]
		if int(c["layer"]) != layer:
			continue
		var d := float(c["dist"])
		if _prev_distance < d and distance >= d:
			collected_crystals.append(i)
			energy = minf(energy + float(c["value"]), GameConfig.ENERGY_MAX)
			crystal_taken.emit(i)

func _update_energy(dt: float) -> void:
	if airborne:
		state = State.AIR
		return                      # 空中：冻结，不判定死亡
	if dashing:
		state = State.DASH
		energy -= GameConfig.ENERGY_DRAIN_DASH * dt
		if energy <= 0.0:
			energy = 0.0
			_die("冲刺能量耗尽 —— 冲刺到底会自杀，要在归零前松手")
		return

	var cell := level.color_at_t(distance, layer, elapsed)
	if cell == player_color:
		state = State.SAME
		energy = minf(energy + GameConfig.ENERGY_GAIN_SAME * dt, GameConfig.ENERGY_MAX)
		grace = GameConfig.DEATH_GRACE_SEC
	else:
		state = State.DIFF
		energy -= GameConfig.ENERGY_DRAIN_DIFF * dt
		if energy <= 0.0:
			energy = 0.0
			if GameConfig.DEATH_GRACE_SEC > 0.0:
				grace -= dt
				if grace <= 0.0:
					_die("能量耗尽")
			else:
				_die("能量耗尽")

func _update_transform(dt: float) -> void:
	position = Vector3(_x, _y + 0.95, -distance)
	# 挤压拉伸：体积守恒的经典做法（拉高就变窄），比直接改 scale.y 更像"弹性体"
	if airborne and falling:
		# 坠落：身体随下落速度持续拉长。t² 轨迹的瞬时速度 ∝ t，
		#   所以拉伸也 ∝ t —— 起坠当帧是原形（速度≈0），越接近地面越长。
		#   这补上了"下落的表现"里轨迹之外的另一半：光有轨迹的话，
		#   角色只是一具不变的胶囊被搬下去，读不出"我在掉"。
		_squash = 1.0 + (GameConfig.FALL_STRETCH - 1.0) * jump_t
	else:
		_squash = lerpf(_squash, 1.0, 1.0 - exp(-13.0 * dt))
	var s := clampf(_squash, 0.55, 1.5)
	var lateral := 1.0 / sqrt(s)
	_rig.scale = Vector3(lateral, s, lateral)

	# 地面光环贴在跑道面上（不随角色升空）。
	#
	# 【2026-10-10 补：向下运动时光环贴【落点层】，不再留在出发层】
	#   这个副作用是我们自己造的：坠落从"一帧瞬移"改成 0.5s 动画之前，
	#   airborne and jump_to < jump_from 这个组合最多存在一帧，
	#   所以"光环留在出发层"从来没被看见过。动画化之后它变成一个
	#   悬在角色【头顶】整整 0.5s 的铁圈 —— 截图里那是画面中最像 bug 的东西。
	#   而留空改造让缺口成为高频事件，这个铁圈会被反复看到。
	#
	#   语义上也更对：坠落期间玩家完全无法操作（能量冻结、不能再跳），
	#   唯一还有意义的判断就是"我落下去的那层是不是我的颜色"。
	#   光环是玩家的颜色参照物，就该待在会被判定的那个位置上。
	#   玩家有 0.5s 的免费时间去读它 —— 这 0.5s 不用来回答这个问题就是浪费。
	#
	#   上跳刻意保持留在出发层：出发层在玩家【下方】，读作"我离开的那块地"，
	#   符合"被留下的东西应该在身后"的直觉，不会变成悬空异物。
	#   方向不同 → 参照点不同，这条不对称是有理由的，不是遗漏。
	if _ring != null:
		var ring_layer := layer
		if airborne and jump_to < jump_from:
			ring_layer = jump_to
		_ring.position = Vector3(0.0, GameConfig.LAYER_Y[ring_layer] - (_y + 0.95) + 0.06, 0.0)
		_ring.scale = Vector3.ONE * (1.0 + (1.0 - s) * 0.6)

func _update_fx(dt: float) -> void:
	if _dash_fx != null:
		_dash_fx.emitting = dashing
		if dashing:
			_dash_fx.color = GameConfig.lane_color_value(player_color)

	if _burst_t < 1.0 and _burst != null:
		_burst_t = minf(_burst_t + dt / 0.35, 1.0)
		var e := _burst_t
		var mesh: MeshInstance3D = _burst.get_meta("mesh")
		_burst.scale = Vector3.ONE * (0.5 + e * 3.2)
		var m: StandardMaterial3D = mesh.material_override
		m.emission = GameConfig.lane_color_value(player_color)
		m.albedo_color = Color(m.emission.r, m.emission.g, m.emission.b, 1.0 - e)
		_burst.visible = e < 1.0

# ------------------------------------------------------------
# 操作
# ------------------------------------------------------------
## dir: +1 上一层 / -1 下一层。
##
## 【2026-10-10 改】落点 = 该方向上【最近的实体跑道】，而不是"相邻层"。
##   关卡大幅留空后，相邻层经常是空的。旧规则下"往空层跳"会让玩家立刻坠落
##   —— 玩家朝正确方向做了一个操作，却因此受到惩罚，这是最坏的一类反馈。
##   现在：空层被自动跳过；中途若有实体跑道，就落在它上面（不穿透实体）。
##
## 该方向没有任何实体跑道 → 【原地跳】（不换层、不前进），按键依然有反馈。
##   【2026-10-10 用户要求：玩家在任何时刻都可以跳跃】
##   旧规则是静默 return（"无效输入，不扣能量"）。它源自"三层填满"的年代 ——
##   那时"该方向没跑道"约等于"你在最顶层还想往上"，确实是没意义的输入，
##   静默吞掉是对的。但大幅留空之后这个局面变成了高频事件：
##   静默吞掉就不再是"过滤无意义输入"，而是"按键坏了"，见 next_track_layer 的注释。
##   成本：同色轨道免费 / 异色轨道照收 8 点（GameConfig.INPLACE_JUMP_FREE_ON_SAME）。
func request_jump(dir: int) -> void:
	if not alive or airborne or jump_cd > 0.0 or level == null:
		return

	var target := next_track_layer(dir)
	# 【2026-10-10 用户要求：玩家在任何时刻都可以跳跃】
	#   旧规则 = 该方向没有实体跑道就静默 return。那在"三层填满"的年代是合理的：
	#   那时"该方向没跑道"基本等于"你在最顶层还想往上"，是真的无意义输入。
	#   但大幅留空之后它成了高频事件 —— 此时静默吞掉按键，玩家读到的是
	#   "我的操作没被听见"，而不是"这个方向没路"。
	#   现在改成【原地跳】：按键永远有反馈，但不换层、不前进。
	#   成本按"你是不是在拿它逃伤害"定价（见 GameConfig.INPLACE_JUMP_FREE_ON_SAME）。
	var in_place := target < 0
	if in_place:
		target = layer

	airborne = true
	falling = false
	_air_time = GameConfig.JUMP_AIR_TIME
	jump_t = 0.0
	jump_from = layer
	jump_to = target
	_squash = 1.32                      # 起跳拉伸
	# 跨越层数【不再影响弧线】—— 顶点是固定的绝对高度（GameConfig.JUMP_APEX_Y）。
	#   旧实现按 span 放大弧高（span=2 时 ×1.55），结果是"跳得越远弧线越高"，
	#   玩家能从弧线预判落点。用户要求统一，这条预判线索就交还给关卡本身了。
	#   滞空同样保持常量（JUMP_AIR_TIME）：它同时是跳跃成本的净收益核算基准、
	#   也是"一次跳跃前进多远"这个关卡段长下界的来源。
	_solve_jump_arc(layer, target)

	# 原地跳的定价：脚下是同色 → 免费（它没在替你挡伤害）；
	# 脚下是异色 → 照收，因为空中冻结实打实挡掉了 9 点伤害。
	# 判定刻意用 color_at_t（当前时刻的真实颜色）而不是缓存的 state：
	# 按键发生在 tick 之前，用缓存值会读到上一帧的颜色，脉冲段上会错一档。
	var cost: float = GameConfig.JUMP_ENERGY_COST
	if in_place and GameConfig.INPLACE_JUMP_FREE_ON_SAME \
			and level.color_at_t(distance, layer, elapsed) == player_color:
		cost = 0.0
	energy = maxf(energy - cost, 0.0)

## 解一条【固定顶点】的抛物线 y(t) = 层A + b·t + a·t²，过 (0, 层A) 与 (1, 层B)，
## 且峰值恰好 = GameConfig.JUMP_APEX_Y。只用于向上/原地跳（下坠走 t²，见 _update_jump）。
##
## 推导（别在这里重新推一遍，要改先看 GameConfig.JUMP_APEX_Y 的注释）：
##   y(0) = 层A            → 常数项就是层A
##   y(1) = 层B            →  b + a = d，其中 d = 层B − 层A
##   峰值 = 顶点            →  层A − b²/(4a) = 顶点
##   令 m = 顶点 − 层A（这一跳要爬多高）、u = √m + √(m − d)，解得
##     b = 2u√m ,  a = d − b ,  峰值时刻 t_p = b / (2(b − d))
##
## 为什么取"加号"那支根（u = √m + √(m−d) 而不是减号）：
##   减号那支在 d = 0（原地跳）时退化成 u = 0 → a = b = 0 → 曲线恒等于层高，
##   也就是"原地跳什么都看不见"。加号那支在 d = 0 时自动给出对称弧（t_p = 0.5）。
##
## 调用前提：target ≥ layer（向上或原地）。顶点高于顶层，所以 m > 0 恒成立；
##   m − d = 顶点 − 层B ≥ 余量 > 0 也恒成立，sqrt 不会拿到负数。
func _solve_jump_arc(from_layer: int, to_layer: int) -> void:
	var from_y: float = GameConfig.LAYER_Y[from_layer]
	var to_y: float = GameConfig.LAYER_Y[to_layer]
	var m: float = GameConfig.JUMP_APEX_Y - from_y     # 这一跳要爬多高
	var d: float = to_y - from_y                       # 净位移（原地跳为 0）
	var u: float = sqrt(m) + sqrt(maxf(m - d, 0.0))
	_jump_b = 2.0 * u * sqrt(m)
	_jump_a = d - _jump_b

## 该方向上最近的实体跑道所在层。返回 -1 = 该方向没有跑道。
##
## 注意用 color_at 而不是 color_at_t：脉冲段翻转相位时跑道依然【存在】，
## 只是颜色变了。用带时间的版本会让玩家在最需要起跳的那一刻被判定"那边没路"。
##
## 【2026-10-10 修 · "跳跃按键无效"】
##   旧版按【当前距离】解析落点。但一次跳跃在空中会前进
##   speed × JUMP_AIR_TIME（常速 = 12 × 0.58 = 6.96m），落点其实在【前方】。
##   关卡大幅留空后，玩家站在段末尾按下跳跃时，落点已经越过段边界落到了下一段上；
##   而旧版还在查上一段的颜色 —— 上一段那个方向根本没有跑道 → 返回 -1 →
##   【按键被整个吞掉】。紧接着玩家跑过边界，又立刻判定坠落。
##   于是"往上跳到另一层"这个留空关卡的核心动作，几乎每一次都按不出来。
##
##   纸面校验器（SelfTest）一直是按【段边界】解析落点的，所以它一直是对的 ——
##   这次错的是引擎，不是关卡。教训与上一轮（原型错、关卡对）方向相反，但同源:
##   【校验器和引擎必须共用同一套落点模型，否则"通过校验"毫无意义。】
##
## 依赖：段长 ≥ speed × JUMP_AIR_TIME。冲刺速度下是 12m，硬约束 3 已保证段长 ≥ 12m。
func next_track_layer(dir: int) -> int:
	if level == null:
		return -1
	var land := distance + _cur_speed * GameConfig.JUMP_AIR_TIME
	var l := layer + dir
	while l >= 0 and l < GameConfig.LAYER_COUNT:
		if level.color_at(land, l) != GameConfig.NO_TRACK:
			return l
		l += dir
	return -1

## 本帧起跳会前进的水平距离（= 当前速度 × 滞空时间）。
## 缺口预警用它判断"现在按还来不来得及"：跳跃窗口 = 0.5s，与速度无关，
## 但换算成距离会随速度变（常速 6m / 加速带 10.8m / 冲刺 12m）。
func jump_reach() -> float:
	return _cur_speed * GameConfig.JUMP_AIR_TIME

func request_switch_color() -> void:
	if not alive:
		return
	if GameConfig.SWITCH_CLEARS_ENERGY:
		energy = 0.0
		_dash_armed = false
	player_color = 1 - player_color
	grace = GameConfig.DEATH_GRACE_SEC
	_burst_t = 0.0
	if _burst != null:
		_burst.visible = true
	_refresh_visual()

# ------------------------------------------------------------
func _die(reason: String) -> void:
	if not alive:
		return
	alive = false
	dashing = false
	died.emit(reason)

func _refresh_visual() -> void:
	if _body_mat == null:
		return
	var c := GameConfig.lane_color_value(player_color)
	_body_mat.albedo_color = c
	_body_mat.emission = c
	if _ring_mat != null:
		_ring_mat.albedo_color = c
		_ring_mat.emission = c

## 单位距离能量效率，供 HUD 提示"当前跑法是否划算"
func current_efficiency() -> float:
	match state:
		State.SAME: return GameConfig.GAIN_PER_METER_SAME
		State.DIFF: return -GameConfig.COST_PER_METER_WALK
		State.DASH: return -GameConfig.COST_PER_METER_DASH
		_: return 0.0
