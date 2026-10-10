class_name WorldFX
extends Node3D
## 霓虹夜幕场景环境（2026-10-10 新增）。
##
## 这个脚本只做一件事：给"三层浮空跑道"一个环境身份。
## 重构前的画面是"深灰虚空里浮着几条彩色板子"—— 没有天空、没有地面、
## 没有地平线，玩家读不出速度、读不出远近、也读不出这个游戏发生在哪。
##
## 三件道具，各解决一个具体问题：
##   1. 夜空渐变 + 地平线辉光  → 解决"没有环境身份"（这是哪里？）
##   2. 体积雾                  → 解决"没有景深"（远处跑道糊成一片）
##   3. 霓虹网格地面            → 解决"没有速度感"（12m/s 看起来像静止）
##
## 注意：这里刻意不放任何 DirectionalLight3D。
##   跑道与玩家都是自发光材质，打光只会冲淡颜色饱和度，
##   而饱和度是本作唯一的语义载体（青=安全 / 橙=危险）。
##   靠 emission 而非光照来出颜色，顺带省掉了阴影贴图的开销。

const SKY_SHADER := """
shader_type sky;

uniform vec3 top_color : source_color;
uniform vec3 bottom_color : source_color;
uniform vec3 horizon_color : source_color;

void sky() {
	// EYEDIR.y: -1 正下方 .. 1 正上方。天空着色器没有 UV，只有方向。
	float h = EYEDIR.y;
	float t = clamp(h * 0.5 + 0.5, 0.0, 1.0);
	vec3 col = mix(bottom_color, top_color, pow(t, 0.85));
	// 地平线辉光带: |h| 越小越亮, 指数衰减保证只有地平线附近被点亮
	float band = exp(-abs(h) * 20.0);
	col += horizon_color * band * 0.6;
	COLOR = col;
}
"""

const GRID_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add, fog_disabled;

uniform vec3 line_color : source_color;
uniform float cell = 6.0;
uniform float fade_dist = 170.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// 用【世界坐标】画线而不是用 UV: 平面跟着相机走, 但线钉在世界空间,
	// 于是网格相对玩家是运动的 —— 这才是速度感, 不是一块贴图在地上滑。
	vec2 p = world_pos.xz / cell;
	vec2 g = abs(fract(p) - 0.5);
	vec2 w = fwidth(p) * 1.4;
	vec2 line = smoothstep(w, vec2(0.0), g);
	float l = max(line.x, line.y);
	float d = length(world_pos.xz - CAMERA_POSITION_WORLD.xz);
	float fade = 1.0 - clamp(d / fade_dist, 0.0, 1.0);
	fade *= fade;
	ALBEDO = line_color * l * fade;
	ALPHA = l * fade * 0.9;
}
"""

var _grid: MeshInstance3D
var _grid_mat: ShaderMaterial
var _env: WorldEnvironment
var _pylons: Array = []

func build() -> void:
	_build_environment()
	_build_grid()
	_build_pylons()

# ------------------------------------------------------------
func _build_environment() -> void:
	_env = WorldEnvironment.new()
	_env.name = "NeonEnvironment"
	var env := Environment.new()

	# ---- 夜空 ----
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SKY_SHADER
	sm.shader = sh
	sm.set_shader_parameter("top_color", GameConfig.SKY_TOP)
	sm.set_shader_parameter("bottom_color", GameConfig.SKY_BOTTOM)
	sm.set_shader_parameter("horizon_color", GameConfig.SKY_HORIZON)
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky

	# 环境光只从天空取，能量压低：跑道靠 emission 出颜色，不靠环境光
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.30

	# ---- 雾：景深 + 隐藏远景噪声 ----
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = GameConfig.FOG_COLOR
	env.fog_light_energy = 1.0
	env.fog_density = GameConfig.FOG_DENSITY
	env.fog_aerial_perspective = GameConfig.FOG_AERIAL

	# ---- 辉光（本项目画面表现的主力）----
	# 阈值 1.0 = 只有超过纯白的部分才晕开。跑道 emission 1.35 → 刚好越过阈值
	# 得到一圈薄光晕但不糊；玩家 emission 2.6 → 强烈光晕，稳居画面最亮。
	env.glow_enabled = true
	env.glow_intensity = 0.90
	env.glow_strength = 1.05
	env.glow_bloom = 0.18
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	# 阈值 0.9：略低于跑道 emission(1.05)，于是跑道有一层薄辉光；
	# 玩家 emission(1.7) 远高于阈值 → 辉光明显更厚。二者差的不是"亮不亮"，
	# 而是"光晕有多厚" —— 用光晕而不是用亮度来区分玩家和跑道，
	# 才能在"玩家最醒目"和"颜色不失真"之间同时成立。
	env.glow_hdr_threshold = 0.90
	env.glow_hdr_scale = 1.6

	_env.environment = env
	add_child(_env)

# ------------------------------------------------------------
func _build_grid() -> void:
	_grid = MeshInstance3D.new()
	_grid.name = "Grid"
	var plane := PlaneMesh.new()
	plane.size = Vector2(420.0, 420.0)
	# 细分不能太高：兼容渲染器下这个平面每帧要跑一遍片元着色器
	plane.subdivide_width = 1
	plane.subdivide_depth = 1
	_grid.mesh = plane
	_grid_mat = ShaderMaterial.new()
	var gsh := Shader.new()
	gsh.code = GRID_SHADER
	_grid_mat.shader = gsh
	_grid_mat.set_shader_parameter("line_color", GameConfig.GRID_COLOR)
	_grid_mat.set_shader_parameter("cell", GameConfig.GRID_CELL)
	_grid_mat.set_shader_parameter("fade_dist", GameConfig.GRID_FADE)
	_grid.material_override = _grid_mat
	_grid.position = Vector3(0.0, GameConfig.GRID_Y, 0.0)
	add_child(_grid)

# ------------------------------------------------------------
## 远景霓虹城市：制造视差，让"我在往前走"这件事有一层远景证据。
##
## 【第一版做错了，这里记一笔】第一版把塔建成"从地面向上长"，
##   塔顶高度 14–52m，而三层跑道在 y = 0 ~ 6.4 —— 于是塔直接横穿跑道，
##   在画面里看起来就是一根蓝色柱子立在你正前方。玩家会当成障碍物去躲。
##   背景物绝不允许出现在"玩家会做判定"的那条视觉走廊上。
## 修正：整座城市压在跑道之下（悬浮跑道 = 城市上空的飞行轨道）。
##   于是无论塔多高、多远，它的屏幕投影永远落在跑道下方 ——
##   物理上不可能和跑道产生视觉歧义，比"调低亮度"可靠得多。
func _build_pylons() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261010
	var z := 40.0
	while z > -1600.0:
		for side in [-1.0, 1.0]:
			if rng.randf() > 0.5:
				continue
			var h := rng.randf_range(18.0, 65.0)
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(rng.randf_range(3.0, 9.0), h, rng.randf_range(3.0, 9.0))
			mi.mesh = box
			var mat := StandardMaterial3D.new()
			# 塔一律用青系冷色：暖色是留给人（玩家）和危险（橙跑道）的，
			# 背景一旦用了橙，橙跑道的"危险"语义会被稀释。
			# 亮度压到 0.5 以下：背景物的正确存在感是"你注意到它时它已经在了"，
			# 而不是"你一边跑一边在想那根柱子是不是障碍物"。
			var c := Color(0.07, 0.22, 0.44) * rng.randf_range(0.35, 0.75)
			mat.albedo_color = c
			mat.emission_enabled = true
			mat.emission = c
			mat.emission_energy_multiplier = 0.8
			mi.material_override = mat
			mi.position = Vector3(
				side * rng.randf_range(55.0, 190.0),
				GameConfig.GRID_Y - h * 0.5 - 7.0,
				z + rng.randf_range(-8.0, 8.0)
			)
			add_child(mi)
			_pylons.append(mi)
		z -= rng.randf_range(28.0, 80.0)

# ------------------------------------------------------------
## 每帧由 Main 调用：网格跟着相机滑动，避免走到边界外看到虚空。
## 注意网格只是"窗口"跟着相机走 —— 线本身钉在世界坐标里（见 GRID_SHADER），
## 所以玩家看到的仍然是"地面在往后跑"。
func follow(cam_x: float, cam_z: float) -> void:
	if _grid != null:
		_grid.position.x = cam_x
		_grid.position.z = cam_z
