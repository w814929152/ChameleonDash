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
## 跳跃抛物线的系数（y = 出发层 + _jump_b·t + _jump_a·t²）。
## 【2026-10-10 三次定稿】峰值 = GameConfig.jump_apex_from(出发层) = 出发层 + 4.4。
## 峰值只由【出发层】决定，与落点无关 —— 因为跳跃不再指定目标层（见 request_jump）。
## 三种向上的竖直动作（跳上一层 / 落回本层 / 无路时的原地弹）共用这一条公式。
## 【2026-10-10】取代了旧的 _jump_arc（"lerp + sin(πt)·弧高"那套）。
var _jump_a := 0.0
var _jump_b := 0.0
## 本次空中的总时长。
## 【2026-10-10 四次定稿】跳跃与坠落共用同一套空中机制，但时长的【来源】不同：
##   跳跃 = 常量 JUMP_AIR_TIME（峰值是设计定的，时长是它的独立旋钮）
##   坠落 = 自由落体 √(2h/g)，由落差算出来（见 GameConfig.fall_air_time）
##   所以下坠这条路上 _air_time 是【结果】，不再是可调的参数。
var _air_time := GameConfig.JUMP_AIR_TIME
## 本次空中是【坠落】（踩空/掉层）而不是【主动跳】。
## 用途：落地压扁更狠、HUD 文案区分"空中/坠落"。
var falling := false
## 上一帧的实际水平速度。落点解析要用它算"我落地时会跑到哪"（见 _resolve_landing）。
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
		# 曲线由 falling 决定，不再由"落点是不是更低"决定 ——
		#   下坠/踩空走 t²；跳跃走抛物线（先上后下）。
		# 【2026-10-10 四次定稿】下坠的 t² 现在【就是】自由落体，不是"看起来像"：
		#   y = 出发层 + (落点层−出发层)·t² ，t = 真实时间 / _air_time，
		#   而 _air_time = √(2h/g) → 展开得 y = 出发层 − ½g·(真实时间)²，逐项相等。
		#   所以这条曲线一个字都不用改，变的只是 _air_time 从常量变成了 g 的解 ——
		#   落差越大，_air_time 越长，t² 自动把它拉成"掉得更远 = 掉得更久"。
		#   这也顺带保住了剪影那半：_squash 仍按 t 线性长大，而 t 现在与真实速度同源。
		# 【2026-10-10 三次定稿】旧版判据是 jump_to < jump_from，现在跳跃也可能落在
		#   更低的层（在段末尾起跳、上一层又是缺口 → 跳出去落到底下那层）。
		#   那次仍然是"跳"：先上升再落下来，所以必须走抛物线。用 falling 判才对。
		if falling:
			_y = lerpf(GameConfig.LAYER_Y[jump_from], GameConfig.LAYER_Y[jump_to], jump_t * jump_t)
		else:
			# 跳跃：抛物线 y = 出发层 + b·t + a·t²，峰值 = 出发层 + 4.4。
			#
			# 【2026-10-10 三次定稿】峰值只由【出发层】决定，与落点无关 ——
			#   因为跳跃不再指定目标层（用户要求"只有单纯的跳跃"）。
			#   于是"落回本层"与"跳上一层"弧高完全一样，弧线不再透露落点；
			#   这件事交给脚下光环 + HUD 的层号（见 GameConfig 里的可读性说明）。
			#   系数在 request_jump 里算好（抛物线过两个端点、峰值恰为峰值高度）。
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

	# 【2026-10-10 三次定稿】这里不再自己写一遍下落扫描，改为调用 _resolve_landing
	#   —— 区间 [0, layer−1]：必须往下走，且允许一次掉过多层（层1 空、层0 有跑道
	#   是留空关卡里最常见的地形）。
	# 【2026-10-10 四次定稿】落点时刻改成 _fall_time_to（自由落体 √(2h/g)）：
	#   掉两层比掉一层慢，所以两层各自的穿越距离也不同 —— 这正是"自然下落"。
	#   跳跃 / 主动下坠 / 踩空三条路径仍然共用同一个落点函数。
	var from_layer := layer
	var target := _resolve_landing(0, from_layer - 1, _fall_time_to)

	if target < 0:
		_die("坠落 —— 脚下与下方都没有跑道")
		return

	airborne = true
	falling = true
	# 时长是【算出来的】，不是查表来的：落差越大掉得越久（旧版固定 0.5s 是错的）
	_air_time = GameConfig.fall_air_time(from_layer, target)
	# 下坠走 t²（由 falling 分支决定），而 t² 配上这个 _air_time 就是自由落体
	#   （推导见 _update_jump 里那段注释），所以不需要额外的系数。
	#   清零是防御性的：万一将来有人把 jump_to/jump_from 改了，
	#   也不会拿上一次跳跃的系数来画坠落。
	_jump_a = 0.0
	_jump_b = 0.0
	jump_t = 0.0
	jump_from = from_layer
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
	# 没进场景树就没有全局变换，GPUParticles3D 的 emitting 赋值会报
	#   "Condition !is_inside_tree() is true"（它内部要拿全局位置算发射点）。
	#   LogicTest 刻意直接 new Player 跑机制断言、不入树（验的是纯逻辑），
	#   于是测试输出里会混进一条 ERROR —— 无害但污染"全绿"的可读性。
	#   特效是纯表现层，没入树时整段跳过，不影响任何判定。
	if not is_inside_tree():
		return
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
## 竖直动作。dir > 0 = 跳（W / 空格），dir < 0 = 落（S）。
##
## 【2026-10-10 三次定稿 · 跳跃不再指定目标层】
##   用户原话：「去掉跳到上一层跑道的规则，只有单纯的跳跃，跳跃的高度可以
##   足够让玩家跳到上一层的跑道」。
##   于是这里不再有"该方向上最近的实体跑道"这种查表。动作只做两件事：
##     ① 定一个【峰值高度】（跳 = 本层 + 4.4，落 = 本层）
##     ② 问一次 _resolve_landing：这个峰值之下，最高的实体跑道在哪
##   层是升上去之后自己撞上的 —— 跳跃不知道上面有没有路，关卡知道。
##
##   由此"只能跳一层"不再是规则而是几何推论（4.4 够到 +3.2，够不到 +6.4）；
##   而"跳跃能跳多高"与"上面有什么"彻底解耦，所以：
##     同一段跑道上，跳上去 / 弹回原地，用的【是同一条弧线】。
##
##   没有任何可落的跑道时（该方向前方是一片虚空）→ 退化成【原地弹跳】：
##   不换层、不前进，但按键一定有反馈。这是旧规则里"该方向没有跑道 → 原地跳"
##   那条在"单纯跳跃"下的自然残留 —— 跳跃绝不允许【按了就死】。
##   代价定价：没换层才看颜色（同色免费 / 异色照收 8 点，见 INPLACE_JUMP_FREE_ON_SAME）；
##   换了层一律 8 点。
func request_jump(dir: int) -> void:
	if not alive or airborne or jump_cd > 0.0 or level == null:
		return

	var jumping := dir > 0
	var apex: float = GameConfig.LAYER_Y[layer]
	var lowest: int = 0
	var highest: int = layer - 1
	# 落点时刻的那条规矩：跳跃是常量，下坠是自由落体。这是三条路径唯一的差别。
	var time_for: Callable = _jump_time_to if jumping else _fall_time_to
	if jumping:
		apex = GameConfig.jump_apex_from(layer)
		highest = _top_layer_under(apex)        # 跳：最远够到 本层+1
	else:
		highest = layer - 1                     # 落：必须真的往下走
	var from_layer := layer
	var target := _resolve_landing(lowest, highest, time_for)

	if target < 0:
		# 这个方向没有可落的跑道。原地弹跳（走跳跃那条弧线，与本层起跳一致）——
		# 按键永远有反馈，且【绝不致死】：真掉下去了也是下一帧的缺口判定说话。
		jumping = true
		target = layer
		apex = GameConfig.jump_apex_from(layer)

	airborne = true
	falling = not jumping
	# 时长：跳跃取常量；下坠取落差的重力解（掉 1 层 0.50s / 掉 2 层 0.71s）。
	#   下坠这条路上 _air_time 是【结果】—— 它必须和 jump_to 配套，
	#   否则 t² 曲线画出来的就不是重力（改落点却不改时长 = 掉两层凭空变快）。
	_air_time = GameConfig.JUMP_AIR_TIME if jumping \
		else GameConfig.fall_air_time(from_layer, target)
	jump_t = 0.0
	jump_from = from_layer
	jump_to = target
	# 起跳拉伸 1.32（与坠落的 1.38 刻意错开，见 GameConfig.FALL_STRETCH）。
	#   坠落那一路的拉伸由 _update_transform 按 t 驱动，这里给 1.0 让位。
	_squash = 1.32 if jumping else 1.0
	# 弧线峰值 = 本层 + 4.4（顶层受 JUMP_APEX_MAX_Y 夹住）。
	#   滞空保持常量（JUMP_AIR_TIME）：它同时是跳跃成本的净收益核算基准、
	#   也是"一次跳跃前进多远"这个关卡段长下界的来源。
	if jumping:
		_solve_jump_arc(layer, target, apex)

	# 定价：只有【没换层】才看脚下颜色（同色免费 / 异色照收 8 点）。
	#   判定刻意用 color_at_t（当前时刻的真实颜色）而不是缓存的 state：
	#   按键发生在 tick 之前，用缓存值会读到上一帧的颜色，脉冲段上会错一档。
	var cost := 0.0
	if target != layer:
		cost = GameConfig.JUMP_ENERGY_COST if jumping else GameConfig.FALL_ENERGY_COST
	elif GameConfig.INPLACE_JUMP_FREE_ON_SAME \
			and level.color_at_t(distance, layer, elapsed) != player_color:
		cost = GameConfig.JUMP_ENERGY_COST
	energy = maxf(energy - cost, 0.0)

## 解一条抛物线 y(t) = 出发层 + b·t + a·t²，过 (0, 出发层) 与 (1, 落点层)，
## 且峰值【恰好】= apex。只用于跳跃（下坠/踩空走 t²，见 _update_jump）。
##
## 推导（要改先看 GameConfig 里那段注释，别在这里重新推）：
##   y(0) = 出发层          → 常数项就是出发层
##   y(1) = 落点层          →  b + a = d，其中 d = 落点层 − 出发层
##   峰值 = apex            →  出发层 − b²/(4a) = apex
##   令 m = apex − 出发层、u = √m + √(m − d)，解得
##     b = 2u√m ,  a = d − b ,  峰值时刻 t_p = b / (2(b − d))
##
## 为什么取"加号"那支根（u = √m + √(m−d) 而不是减号）：
##   减号那支在 d = 0（落回本层）时退化成 u = 0 → a = b = 0 → 曲线恒等于层高，
##   也就是"原地弹跳什么都看不见"。加号那支在 d = 0 时自动给出对称弧（t_p = 0.5）。
##
## 【三次定稿后 d 只有三种取值】0（弹回本层）/ 3.2（跳上一层）/ 负值（在段末尾
##   起跳、上一层是缺口 → 跳出去落到更低那层）。三种都满足 m − d > 0，
##   所以 sqrt 永远不会拿到负数（maxf 只是防御）。
func _solve_jump_arc(from_layer: int, to_layer: int, apex: float) -> void:
	var from_y: float = GameConfig.LAYER_Y[from_layer]
	var m: float = apex - from_y                        # 这一跳要爬多高
	var d: float = GameConfig.LAYER_Y[to_layer] - from_y # 净位移（弹回本层为 0）
	var u: float = sqrt(m) + sqrt(maxf(m - d, 0.0))
	_jump_b = 2.0 * u * sqrt(m)
	_jump_a = d - _jump_b

## 【竖直动作的落点解析 —— 本作跳跃机制的全部物理就在这一个函数里】
##
## 在 [lowest, highest] 这个层区间里【从高往低】找第一块能站住的实体跑道。返回 -1 = 一块都没有。
##
## 【2026-10-10 三次定稿】跳跃 / 主动下坠 / 踩空三条路径共用它。共用是刻意的：
##   白天那次"跳跃按键无效"事故的根因就是【两套落点规则】—— 校验器和引擎各算各的，
##   通过校验而玩不了。每多一条复刻就多一次假阳性。
##
## lowest / highest  允许落脚的层区间（都含端点）。
##   跳跃：lowest = 0（本层也能弹回）、highest = 峰值够得到的最高的层（= 本层+1）。
##   下坠 / 踩空：lowest = 0、highest = **layer − 1**。两端合起来的意思是
##     "必须真的往下走，且可以一直掉到下面最高的那条"，
##     ⚠ 两个端点都不能改：highest 若放到 layer 就把本层算进来，按 S 会落在自己
##       脚下（原地弹），S 键静默失灵；lowest 若抬到 layer−1 又会让"层1 是空的、
##       层0 有跑道"这种最常见的地形变成无路可走（掉不到层0，只能等死）。
##
## time_for  一个回调：**落到第 l 层要用几秒**。这是三条路径唯一的差别。
##
## 【2026-10-10 四次定稿：从"一个时长"改成"每层一个时长"】
##   旧签名是 `land_time: float` —— 所有候选层共用同一个落点时刻。那是为跳跃写的，
##   因为跳跃够到的层由峰值决定，和时长本身就是解耦的两件事。
##   但下坠是自由落体：掉 1 层和掉 2 层的耗时【本来就不同】，共用一个时长
##   等于假装落差不存在（旧版 FALL_AIR_TIME = 0.5 让掉两层凭空变快）。
##   改成回调之后，"选哪一层"和"几秒到"就解耦了：
##     跳跃 → func(_l): return JUMP_AIR_TIME         （常量，与层无关）
##     下坠 → func(l):  return fall_air_time(出发层, l)（重力解，随落差生长）
##   仍然是【一套】循环、一套 color_at 判定、一套"从高往低取第一块" ——
##   分家的只剩"时刻怎么算"这一条，而且它现在是显式传进来的，藏不住。
##
##   为什么落点必须按【落地那一刻的距离】查：空中还会以 _cur_speed 前进 time 秒
##     （跳跃 6.96m；下坠掉一层 6m、掉两层 8.5m），拿当前距离去查会查到上一段的
##     颜色，那正是老事故。
##
## 用 color_at 而不是 color_at_t：脉冲段翻转相位时跑道依然【存在】，只是颜色变了。
##   用带时间的版本会让玩家在最需要起跳的那一刻被判定"那边没路"。
func _resolve_landing(lowest: int, highest: int, time_for: Callable) -> int:
	if level == null:
		return -1
	for l in range(highest, lowest - 1, -1):
		# l < 0（在最底层要求"必须往下"）→ 一层都不可落。必须显式判：
		#   GDScript 的负下标是"从末尾数"，LAYER_Y[-1] 会静默变成顶层。
		# l >= LAYER_COUNT 同理，range 的上端可能越界（跳跃时 highest 会算到 3）。
		if l < 0:
			return -1
		if l >= GameConfig.LAYER_COUNT:
			continue
		var land := distance + _cur_speed * float(time_for.call(l))
		if level.color_at(land, l) != GameConfig.NO_TRACK:
			return l
	return -1

## 跳跃的落点时刻：常量。峰值由 JUMP_APEX_HEIGHT 定死，与落到哪一层无关。
func _jump_time_to(_to_layer: int) -> float:
	return GameConfig.JUMP_AIR_TIME

## 下坠的落点时刻：自由落体 √(2h/g)。从【当前层】算，不是从候选层算。
func _fall_time_to(to_layer: int) -> float:
	return GameConfig.fall_air_time(layer, to_layer)

## 峰值高度 apex 之下【最高】的那一层。跳跃"最远只能够到这一层"，
## 所以它同时表达了"跳得到"和"只能跳一层"两条 —— 由同一个 apex 反解，不会各说各话。
func _top_layer_under(apex: float) -> int:
	var top := -1
	for l in GameConfig.LAYER_COUNT:
		if GameConfig.LAYER_Y[l] <= apex + 0.001:
			top = l
	return top

## 若现在朝 dir 做一次竖直动作，会落在哪一层。返回 -1 = 落不到任何实体跑道。
##
## 【这是查询，不是动作】校验器（SelfTest.check_forward_escape）和 bot（PlayTest）
##   靠它决定"这里有没有路""值不值得按"。所以它必须和 request_jump 走同一个
##   _resolve_landing —— 复刻一份落点规则 = 制造假阳性，这条纪律是有血债的。
func next_track_layer(dir: int) -> int:
	if level == null:
		return -1
	if dir > 0:
		var apex := GameConfig.jump_apex_from(layer)
		return _resolve_landing(0, _top_layer_under(apex), _jump_time_to)
	return _resolve_landing(0, layer - 1, _fall_time_to)

## 落到 [to_layer] 的那一次竖直动作会前进多少米 —— 也就是落点解析查的那个距离
## （distance + 本值）。
##
## 【2026-10-10 四次定稿 · 取代了旧的 jump_reach()】
##   旧版只有一个 `jump_reach()` = _cur_speed × JUMP_AIR_TIME，因为那时下坠的
##   滞空是个常量（FALL_AIR_TIME = 0.5），和跳跃差不多，一个数糊得过去。
##   下坠改成自由落体之后这个假设塌了：掉一层只走 6.0m（比重载 6.96m 短）、
##   掉两层要走 8.49m。用一个数去回答两个方向的问题，两边都会错 ——
##     用 6.96 判"掉一层来得及"→ 提前 0.96m 就喊"现在可以按"，
##       玩家按下去落点却还在缺口里 → 就是"按键无效"那个老症状；
##     用 6.96 判"掉两层来得及"→ 又白白晚喊 1.5m，玩家以为没机会了。
##   所以必须传目标层：上跳/原地弹是常量，下坠由落差算出来。
func reach_to(to_layer: int) -> float:
	if to_layer >= layer:
		# 上跳，以及"无路可退时的原地弹"（那条路走的就是跳跃弧线）
		return _cur_speed * GameConfig.JUMP_AIR_TIME
	return _cur_speed * GameConfig.fall_air_time(layer, to_layer)

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
