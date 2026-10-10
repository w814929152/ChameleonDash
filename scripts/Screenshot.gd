extends Node3D
## 视觉验证：把 Main 场景跑起来，推进到指定距离后截图退出。
## 用途：3D 两层跑道的可读性是本设计的头号风险（上层会遮挡下层），
##       纸面推演不算数，必须看真实渲染结果再判断。
##
## 运行：
##   godot --path D:/ChameleonDash --resolution 1280x720 res://scenes/Screenshot.tscn

## 默认写到 res://shots/ —— 那个目录带 .gdignore，Godot 不会把它扫进导入管线。
## 【2026-10-10 改】原来默认是 res://shot.png（项目根）：
##   每跑一次不带 out= 的截图，项目根就多长出一个 png + 一个 .import，
##   还会被导入器编译进 .godot/imported/。清理时挖出一堆这种残骸，
##   所以把默认值挪到专门的暂存目录 —— 治「根目录会自己脏回去」这个根因。
@export var shot_path := "res://shots/shot.png"
@export var level_index := 0
@export var player_color := 0
@export var start_distance := 200.0
@export var frames_to_wait := 90
## 起始层。拍"缺口/收费口"这类段落时必须在正确的层上开机，
## 否则玩家一落地就被判坠落，截到的是一具尸体。
@export var start_layer := 0
@export var auto_dash := false
## 0 = 不按；+1 / -1 = 开机后立刻朝该方向按一次跳跃。
## 用途：原地跳的弧线是纯视觉的，逻辑测试只能断言 airborne/jump_to，
##       看不到"到底有没有画出来"。要拍它只能让场景自己按一下。
@export var auto_jump := 0
## >0 时：等到玩家【滞空进度 jump_t 跨过该值】立刻截图，上限仍是 frames_to_wait。
## 用途：跳跃/下落的曲线是时间函数，靠"等 N 帧"去命中曲线中段完全不可靠
##   （帧率每次都不一样，实测 22 帧和 26 帧能差出 0.1 的 t）。
##   直接等 t 才是确定性的：要拍峰值就等 0.5，拍下落中段就等 0.6。
@export var wait_arc_t := -1.0
## 把脚下的颜色光环临时染成纯红。
##
## 为什么需要它：光环是玩家节点的子节点，它的 local y 是【反向补偿】出来的
##   （LAYER_Y[层] - (玩家y+0.95) + 0.06），所以 local 值本身完全读不出
##   "它贴在哪一层"。它又是玩家颜色的同色发光体，在侧视远景里和角色自身的
##   bloom 糊在一起 —— 靠肉眼在 720p 截图里找它，会把角色身上的光晕当成它。
##   （实测踩过这个坑：以为光环贴在角色身上，其实它已经在落点层上了。）
## 染红之后就一眼可辨。这是验证工具里最便宜的一条，别删。
@export var ring_debug := false

func _ready() -> void:
	# 允许命令行覆盖：-- level=2 dist=428 color=0
	# 否则每次换机位都要改默认值，很浪费。
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"level":  level_index = int(kv[1])
			"dist":   start_distance = float(kv[1])
			"color":  player_color = int(kv[1])
			"out":    shot_path = kv[1]
			# 等帧数直接决定"截图时玩家已经往前跑了多少"。
			# 默认 90 帧 ≈ 1.5s，基础速度下会前进 18m、加速带上 32m ——
			# 想抓机制段落的中段就必须把这个值压小，否则永远拍在段外。
			"frames": frames_to_wait = int(kv[1])
			"layer":  start_layer = int(kv[1])
			"jump":   auto_jump = int(kv[1])
			"at_t":   wait_arc_t = float(kv[1])
			"ring_debug": ring_debug = int(kv[1]) != 0

	var main = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	main.load_level(level_index)
	main.phase = main.Phase.PLAYING
	main.hud.hide_result()
	main.player.distance = start_distance
	main.player.player_color = player_color
	main.player.layer = clampi(start_layer, 0, GameConfig.LAYER_COUNT - 1)
	main.player._y = GameConfig.LAYER_Y[main.player.layer]
	main.player.position = Vector3(0.0, main.player._y + 0.95, -start_distance)
	main.player._refresh_visual()
	if ring_debug and main.player._ring_mat != null:
		main.player._ring_mat.emission = Color(1, 0, 0)
		main.player._ring_mat.albedo_color = Color(1, 0, 0)
	if auto_jump != 0:
		main.player.request_jump(auto_jump)

	# 让相机 lerp 追上玩家并渲染若干帧
	for i in frames_to_wait:
		await get_tree().process_frame
		if wait_arc_t >= 0.0 and main.player.airborne \
				and main.player.jump_t >= wait_arc_t:
			break

	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var out := ProjectSettings.globalize_path(shot_path)
	var err := img.save_png(out)
	# 光环的世界高度单独打出来：光环是玩家节点的子节点，local y 随 _y 反向补偿，
	#   单看 local 值完全读不出"它到底贴在哪一层"。贴错层(留在出发层 vs 落到落点层)
	#   是 3.2m 的差别，在 720p 远景里靠肉眼比对平台边缘非常不可靠 —— 必须打数。
	# 显式标注类型：三元表达式的两个分支在这一版没法自动推断类型，
	#   写 := 会直接 Parse Error（场景静默加载失败，什么都不打印）。
	var ring_y: float = main.player._ring.global_position.y if main.player._ring != null else -999.0
	print("截图已保存: %s (err=%d) 距离=%.1fm 层=%d 能量=%.1f alive=%s 空中=%s 坠落=%s arc_t=%.2f y=%.2f 环世界y=%.2f" % [
		out, err, main.player.distance, main.player.layer, main.player.energy,
		str(main.player.alive), str(main.player.airborne), str(main.player.falling),
		main.player.jump_t, main.player._y, ring_y
	])
	get_tree().quit(0)
