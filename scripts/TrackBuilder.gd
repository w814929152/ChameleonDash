class_name TrackBuilder
extends Node3D
## 把 LevelData 变成可见的三层跑道（横版）+ 三种机制的视觉表达。
##
## 可读性设计（Pillar: 风险必须可读）:
##   1. 跑道一律实色、不透明、无边框 —— 半透明会混色（橙+青→灰绿），
##      让玩家做减色运算才能读出脚下颜色，这是设计事故。
##   2. 全部跑道同亮度（无焦点层）—— 视觉语言只剩"青/橙"两色。
##   3. 跑道之间靠 LAYER_Y 间距的空隙自然分界，不描边。
##   4. 每 20m 一条霓虹刻度线，给速度感提供参照物。
##   5. 【新增】每段颜色切换处画一道横向白线 —— 玩家必须能看出
##      "颜色在哪个位置切换"，否则他会在毫无预兆的地方被扣血。
##
## 新增机制的视觉语言（三条不冲突的编码通道）:
##   加速带  → 色相通道：白蓝双箭头（青/橙之外的第二色相，不会误读）
##   脉冲段  → 时间通道：三段沿跑道纵向流动的品红警戒条 + 整段颜色呼吸
##   晶体    → 形状通道：悬浮八面体 + 自转 + 上下浮动（唯一会动的拾取物）

const RHYTHM_LINE_EVERY := 20.0
const BOOST_CHEVRON_EVERY := 6.0
const CRYSTAL_HEIGHT := 1.5

var level: LevelData

## 脉冲段的可动跑道块：{mat, base: Color, alt: Color}
var _pulse_tiles: Array = []
## 晶体节点：{node, ring, base_y, phase, taken}
var _crystals: Array = []
## 加速带箭头：{node, base_z}（做流光动画）
var _chevrons: Array = []

var _t := 0.0

func build(lv: LevelData) -> void:
	level = lv
	_pulse_tiles.clear()
	_crystals.clear()
	_chevrons.clear()
	_t = 0.0
	for c in get_children():
		c.queue_free()

	var z := 0.0
	for i in lv.segments.size():
		var seg: Dictionary = lv.segments[i]
		var length := float(seg["length"])
		var colors: Array = seg["colors"]
		var is_pulse: bool = bool(seg.get("pulse", false))
		var boost: float = float(seg.get("boost", 1.0))

		for layer in GameConfig.LAYER_COUNT:
			if int(colors[layer]) == GameConfig.NO_TRACK:
				continue
			for lane in GameConfig.LANE_COUNT:
				_create_tile(layer, lane, int(colors[layer]), z, length, is_pulse)
			if is_pulse:
				_create_pulse_marker(layer, z, length)
			if boost > 1.0:
				_create_boost_markers(layer, z, length)

		_create_rhythm_lines(z, length, colors)
		_create_color_seam(z, length, colors)
		_create_crystals(seg, z)
		z -= length

	_create_finish_line(z)

# ------------------------------------------------------------
# 跑道块
# ------------------------------------------------------------
func _create_tile(layer: int, lane: int, color_id: int, z_start: float,
		length: float, is_pulse: bool) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(GameConfig.LANE_WIDTH, GameConfig.TRACK_THICKNESS, length)
	mi.mesh = box

	var c := GameConfig.lane_color_value(color_id)
	mi.material_override = _neon_mat(c, GameConfig.TRACK_EMISSION)
	mi.position = Vector3(
		GameConfig.LANE_X[lane],
		GameConfig.LAYER_Y[layer],
		z_start - length * 0.5
	)
	add_child(mi)

	if is_pulse:
		# 脉冲块注册到可动列表：运行时每帧把 albedo/emission 在青橙之间推。
		# 这里不复制材质 —— 每个块一份材质是必要的，否则整段会一起闪成一色，
		# 而"整段一起闪"正是脉冲段要表达的东西，所以其实也说得通；
		# 但各层基础色可能不同，必须各自持有材质。
		_pulse_tiles.append({
			"mat": mi.material_override,
			"base": c,
			"alt": GameConfig.lane_color_value(1 - color_id),
		})

func _neon_mat(c: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	# albedo 压暗、亮度全交给 emission：本场景没有直射光，
	# 颜色完全由自发光决定，这样饱和度不会被环境光冲淡。
	mat.albedo_color = c * GameConfig.TRACK_ALBEDO_MIX
	mat.emission_enabled = true
	mat.emission = c
	mat.emission_energy_multiplier = energy
	mat.roughness = 0.85
	return mat

# ------------------------------------------------------------
# 脉冲段警戒标记：沿纵向流动的品红条
# ------------------------------------------------------------
## 用"流动"而不是"闪烁"来标记脉冲段，是两个原因:
##   1. 颜色本身已经在闪了，再叠加闪烁会变成一片噪声，读不出哪段是脉冲段；
##   2. 流动方向与前进方向一致，顺带强化速度感。
func _create_pulse_marker(layer: int, z_start: float, length: float) -> void:
	var y: float = GameConfig.LAYER_Y[layer] + GameConfig.TRACK_THICKNESS * 0.55
	var step := 4.0
	var d := 0.0
	while d < length:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(GameConfig.LANE_WIDTH * 0.16, 0.07, 0.5)
		mi.mesh = box
		var mat := _neon_mat(GameConfig.COLOR_PULSE_WARN, 2.0)
		mat.albedo_color = GameConfig.COLOR_PULSE_WARN
		mi.material_override = mat
		mi.position = Vector3(
			-GameConfig.LANE_WIDTH * 0.42, y, z_start - d - 0.25)
		add_child(mi)
		var mi2 := mi.duplicate()
		mi2.position.x = GameConfig.LANE_WIDTH * 0.42
		mi2.material_override = mat
		add_child(mi2)
		d += step

# ------------------------------------------------------------
# 加速带：白蓝双箭头
# ------------------------------------------------------------
func _create_boost_markers(layer: int, z_start: float, length: float) -> void:
	var y: float = GameConfig.LAYER_Y[layer] + GameConfig.TRACK_THICKNESS * 0.62
	var half_w := GameConfig.LANE_WIDTH * 0.45
	var depth := 1.5
	var arm_len := sqrt(half_w * half_w + depth * depth)
	var d := 1.5
	while d < length - 1.0:
		for sx in [-1.0, 1.0]:
			var bar := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(arm_len, 0.10, 0.45)
			bar.mesh = bm
			# 箭头指向 -Z（前进方向）: 旋转角使条形轴对齐
			# 从箭尖指向 (sx·half_w, 0, +depth) 的方向向量。
			bar.rotation.y = atan2(-depth, sx * half_w)
			bar.position = Vector3(sx * half_w * 0.5, y, z_start - d + depth * 0.5)
			bar.material_override = _neon_mat(GameConfig.COLOR_BOOST, 2.4)
			add_child(bar)
		d += BOOST_CHEVRON_EVERY

# ------------------------------------------------------------
# 节奏刻度线
# ------------------------------------------------------------
func _create_rhythm_lines(z_start: float, length: float, colors: Array) -> void:
	var d := RHYTHM_LINE_EVERY
	while d < length:
		for layer in GameConfig.LAYER_COUNT:
			if int(colors[layer]) == GameConfig.NO_TRACK:
				continue
			var line := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(GameConfig.LANE_WIDTH * GameConfig.LANE_COUNT, 0.05, 0.28)
			line.mesh = box
			line.material_override = _neon_mat(GameConfig.RHYTHM_COLOR, GameConfig.RHYTHM_EMISSION)
			line.position = Vector3(
				0.0, GameConfig.LAYER_Y[layer] + GameConfig.TRACK_THICKNESS * 0.55,
				z_start - d)
			add_child(line)
		d += RHYTHM_LINE_EVERY

# ------------------------------------------------------------
# 颜色切换标线
# ------------------------------------------------------------
## 在每段边界画一道横贯全宽的白线（跑道上）。
## Rationale: 玩家必须能看出"颜色在哪儿切换"。没有这条线时，两次跑同一条关卡
##   会得到不一致的记忆（"我上次明明没死在这儿"），因为玩家记的是相对位置的
##   视觉锚点，而不是米数。这条线就是免费的锚点。
func _create_color_seam(z_start: float, length: float, colors: Array) -> void:
	for layer in GameConfig.LAYER_COUNT:
		if int(colors[layer]) == GameConfig.NO_TRACK:
			continue
		var seam := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(GameConfig.LANE_WIDTH, 0.04, 0.22)
		seam.mesh = box
		var mat := _neon_mat(Color(1, 1, 1), 1.1)
		seam.material_override = mat
		seam.position = Vector3(
			0.0, GameConfig.LAYER_Y[layer] + GameConfig.TRACK_THICKNESS * 0.55, z_start)
		add_child(seam)

# ------------------------------------------------------------
# 能量晶体
# ------------------------------------------------------------
func _create_crystals(seg: Dictionary, z_start: float) -> void:
	if not seg.has("crystals"):
		return
	for c in seg["crystals"]:
		var layer := int(c[0])
		var offset := float(c[1])
		if layer < 0 or layer >= GameConfig.LAYER_COUNT:
			continue
		# 晶体必须长在实体跑道上：悬在空层里的晶体玩家永远拿不到，
		# 那是关卡数据写错，不是设计。宁可静默跳过也不要生成一个不可能的奖励。
		var seg_colors: Array = seg["colors"]
		if int(seg_colors[layer]) == GameConfig.NO_TRACK:
			continue
		var holder := Node3D.new()
		var y: float = GameConfig.LAYER_Y[layer] + CRYSTAL_HEIGHT
		holder.position = Vector3(0.0, y, z_start - offset)
		add_child(holder)

		var mi := MeshInstance3D.new()
		var sp := SphereMesh.new()
		sp.radius = 0.42
		sp.height = 0.84
		sp.radial_segments = 12
		sp.rings = 6
		mi.mesh = sp
		var mat := StandardMaterial3D.new()
		mat.albedo_color = GameConfig.COLOR_CRYSTAL
		mat.emission_enabled = true
		mat.emission = GameConfig.COLOR_CRYSTAL
		mat.emission_energy_multiplier = 3.2
		mi.material_override = mat
		holder.add_child(mi)

		# 外圈光环：让晶体在远景里也能被认出来（球体在远处只剩几个像素）
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.62
		tm.outer_radius = 0.74
		tm.rings = 20
		tm.ring_segments = 6
		ring.mesh = tm
		ring.material_override = _neon_mat(GameConfig.COLOR_CRYSTAL, 2.2)
		holder.add_child(ring)

		_crystals.append({
			"holder": holder,
			"inner": mi,
			"ring": ring,
			"base_y": y,
			"phase": float(_crystals.size()) * 1.7,
			"taken": false,
		})

# ------------------------------------------------------------
# 终点
# ------------------------------------------------------------
func _create_finish_line(z_end: float) -> void:
	var top: float = GameConfig.LAYER_Y[GameConfig.LAYER_COUNT - 1] + 3.4
	var bottom: float = GameConfig.LAYER_Y[0] - 1.2
	var height := top - bottom
	var mid := (top + bottom) * 0.5

	# 发光拱门：两根立柱 + 顶梁 + 一条横贯的终点光带
	for sx in [-1.0, 1.0]:
		var pil := MeshInstance3D.new()
		var pb := BoxMesh.new()
		pb.size = Vector3(0.7, height, 0.7)
		pil.mesh = pb
		pil.material_override = _neon_mat(Color(1, 1, 1), 1.9)
		pil.position = Vector3(
			sx * (GameConfig.LANE_WIDTH * 0.5 + 0.5), mid, z_end)
		add_child(pil)

	var beam := MeshInstance3D.new()
	var bb := BoxMesh.new()
	bb.size = Vector3(GameConfig.LANE_WIDTH + 2.4, 0.8, 0.8)
	beam.mesh = bb
	beam.material_override = _neon_mat(Color(1, 1, 1), 1.9)
	beam.position = Vector3(0.0, top, z_end)
	add_child(beam)

	# 终点光幕：竖向的半透明光带，冲刺中也能一眼看到
	var curtain := MeshInstance3D.new()
	var cb := BoxMesh.new()
	cb.size = Vector3(GameConfig.LANE_WIDTH + 2.0, height, 0.15)
	curtain.mesh = cb
	var cm := _neon_mat(Color(0.85, 1.0, 1.0), 1.4)
	cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.albedo_color = Color(0.85, 1.0, 1.0, 0.30)
	curtain.material_override = cm
	curtain.position = Vector3(0.0, mid, z_end - 0.2)
	add_child(curtain)

# ------------------------------------------------------------
# 每帧动画
# ------------------------------------------------------------
func update_world(dt: float, t: float, pulse_flipped: bool) -> void:
	_t = t

	# 脉冲段：整段在青橙之间呼吸。
	# 用 0.18s 的补间而不是硬切 —— 硬切在 60fps 下会产生一条明显的撕裂线，
	# 而玩家需要的是一个"渐变中"的连续信号，不是二值跳变。
	for pt in _pulse_tiles:
		var mat: StandardMaterial3D = pt["mat"]
		var want: Color = pt["alt"] if pulse_flipped else pt["base"]
		var cur := mat.emission
		var lit := cur.lerp(want, clampf(dt / 0.18, 0.0, 1.0))
		mat.emission = lit
		mat.albedo_color = lit * GameConfig.TRACK_ALBEDO_MIX

	# 晶体：自转 + 浮动 + 光环倾斜
	for c in _crystals:
		if c["taken"]:
			continue
		var holder: Node3D = c["holder"]
		holder.rotation.y += dt * 1.6
		holder.position.y = float(c["base_y"]) + sin(t * 2.2 + float(c["phase"])) * 0.22
		var ring: Node3D = c["ring"]
		ring.rotation.x = t * 1.1 + float(c["phase"])
		ring.rotation.z = t * 0.7

func collect_crystal(index: int) -> void:
	if index < 0 or index >= _crystals.size():
		return
	var c = _crystals[index]
	if c["taken"]:
		return
	c["taken"] = true
	(c["holder"] as Node).visible = false

func reset_crystals() -> void:
	for c in _crystals:
		c["taken"] = false
		(c["holder"] as Node).visible = true
