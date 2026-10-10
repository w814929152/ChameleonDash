extends Node3D
## 主循环：组装世界、跑状态机、管相机。
## 跑道与玩家在运行时构建 —— 关卡是数据驱动的，改 LevelData 不用动场景文件。

enum Phase { READY, PLAYING, DEAD, WIN }


var phase: int = Phase.READY
var level_index := 0
var level: LevelData
var player: Player
var track: TrackBuilder
var worldfx: WorldFX
var hud: HUD
var camera: Camera3D
var _anim_t := 0.0

func _ready() -> void:
	# 环境先建：天空/雾/网格必须在第一批帧就位，否则第一帧的截图会是黑场
	worldfx = WorldFX.new()
	worldfx.name = "WorldFX"
	add_child(worldfx)
	worldfx.build()

	camera = get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		camera = Camera3D.new()
		add_child(camera)
	camera.fov = GameConfig.CAM_FOV_BASE

	track = TrackBuilder.new()
	track.name = "Track"
	add_child(track)

	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.died.connect(_on_died)
	player.finished.connect(_on_finished)
	player.crystal_taken.connect(_on_crystal_taken)

	hud = HUD.new()
	add_child(hud)

	load_level(0)

func _on_crystal_taken(index: int) -> void:
	track.collect_crystal(index)

func load_level(idx: int) -> void:
	var levels := LevelData.all_levels()
	level_index = clampi(idx, 0, levels.size() - 1)
	level = levels[level_index]
	track.build(level)
	player.setup(level)
	player.position = Vector3(0.0, GameConfig.LAYER_Y[0] + 0.95, 0.0)
	camera.position = Vector3(
		GameConfig.CAM_SIDE,
		GameConfig.LAYER_MID_Y + GameConfig.CAM_UP,
		GameConfig.CAM_BEHIND)
	# 相机瞬移到位后先跑一帧 look_at，否则重置关卡的瞬间相机会从上一个
	# 关卡的朝向插值过来，开局有几帧画面是歪的
	camera.look_at(Vector3(0.0, GameConfig.LAYER_MID_Y, -GameConfig.CAM_LOOK_AHEAD))
	_anim_t = 0.0
	phase = Phase.READY
	hud.hide_result()
	hud.show_result(
		level.level_name,
		"跑道有上中下三层，颜色分青 / 橙。\n\n" \
		+ "同色积攒能量，异色消耗能量，能量归零即死。\n" \
		+ "空中不结算 —— 跳跃是唯一的救命手段。\n" \
		+ "切色会清空能量，切之前先想想值不值。\n\n" \
		+ "白蓝箭头＝加速带　品红流动条＝脉冲段　绿球＝能量晶体\n\n" \
		+ "W / 空格 跳跃（刚好够到上一层）　S 下坠　J 切色　SHIFT 冲刺\n" \
		+ "跳不上去两层 —— 上面没跑道就只会原地弹一下\n" \
		+ "下坠是自由落体：落差越大掉得越久，空层直接穿过\n" \
		+ "1 / 2 / 3 选关　R 重开\n\n" \
		+ "按 空格 开始",
		Color(0.6, 0.95, 1.0)
	)

# ------------------------------------------------------------
func _process(dt: float) -> void:
	if phase == Phase.PLAYING:
		player.tick(dt)
		hud.update_hud(player, level)
		# 低能量警告：这是"贪"的代价的可听化/可视化
		if player.energy < 25.0 and not player.airborne:
			hud.flash(0.35 * dt * 6.0)
	_tick_world_anim(dt)
	_follow_camera(dt)
	worldfx.follow(camera.position.x, camera.position.z)

## 机制的世界动画。即使玩家死了 / 还没开始也继续跑 —— 环境必须是活的，
## 死屏里脉冲段突然定格会让人以为游戏卡住了。
##
## 相位时钟的选择很关键：游玩中必须用 player.elapsed，因为那是玩家实际
## 被结算的那个时钟；用别的时钟会导致"看到的颜色"和"扣血的颜色"不是同一个
## —— 这是最恶劣的一类 bug（玩家会觉得自己被冤枉）。非游玩状态才用自由时钟。
func _tick_world_anim(dt: float) -> void:
	if phase == Phase.PLAYING:
		# 游玩中强制对齐玩家时钟 —— 二者必须是同一个数，
		# 否则"看到的颜色"和"扣血的颜色"会分裂
		_anim_t = player.elapsed
	else:
		_anim_t += dt
	var flipped := player.level != null and player.level.pulse_flipped(_anim_t)
	track.update_world(dt, _anim_t, flipped)

func _follow_camera(dt: float) -> void:
	if player == null or camera == null:
		return
	# 横版侧视：相机在跑道侧面(SIDE)，略微后置(BEHIND)并看向前方(AHEAD)。
	# 高度锚定在三层几何中心，不跟玩家所在层走 —— 见 GameConfig.LAYER_MID_Y。
	# 指数平滑：与帧率无关，比 lerp(a,b,0.1) 正确。
	var target := Vector3(
		player.position.x + GameConfig.CAM_SIDE,
		GameConfig.LAYER_MID_Y + GameConfig.CAM_UP,
		player.position.z + GameConfig.CAM_BEHIND)
	camera.position = camera.position.lerp(target, 1.0 - exp(-8.0 * dt))
	camera.look_at(Vector3(
		player.position.x, GameConfig.LAYER_MID_Y,
		player.position.z - GameConfig.CAM_LOOK_AHEAD))
	var want_fov := GameConfig.CAM_FOV_DASH if player.dashing else GameConfig.CAM_FOV_BASE
	camera.fov = lerpf(camera.fov, want_fov, 1.0 - exp(-5.0 * dt))

# ------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if phase == Phase.PLAYING:
			player.request_switch_color()
		return

	if not (event is InputEventKey) or not event.pressed or event.echo:
		return

	match event.keycode:
		KEY_ESCAPE:
			get_tree().quit()
		KEY_R:
			# 「按 空格 / R 重开本关」是死亡面板与通关面板上的原话，两个键必须等价。
			# 旧实现是直接 load_level()，停在 READY —— 玩家按 R 之后拿到的是教学卡，
			# 还得再按一次空格，而按空格却能直接开跑。PlayTest 把这条不一致抓了出来。
			# READY 下保持不动：那时玩家正在读教学卡，按 R 不该把他直接扔进关卡。
			if phase != Phase.READY:
				load_level(level_index)
				phase = Phase.PLAYING
				hud.hide_result()
		KEY_SPACE:
			if phase == Phase.READY:
				phase = Phase.PLAYING
				hud.hide_result()
			elif phase == Phase.DEAD:
				load_level(level_index)
				phase = Phase.PLAYING
				hud.hide_result()
			elif phase == Phase.WIN:
				_next_level()
			elif phase == Phase.PLAYING:
				player.request_jump(1)
		KEY_ENTER:
			if phase == Phase.READY:
				phase = Phase.PLAYING
				hud.hide_result()
			elif phase == Phase.DEAD:
				load_level(level_index)
				phase = Phase.PLAYING
				hud.hide_result()
			elif phase == Phase.WIN:
				_next_level()
		KEY_N:
			if phase == Phase.WIN:
				_next_level()
		KEY_1, KEY_2, KEY_3:
			# 选关：demo 必须允许直接跳到任意一关，否则每次都要重打教学
			var idx: int = event.keycode - KEY_1
			if idx < LevelData.all_levels().size():
				load_level(idx)
				phase = Phase.PLAYING
				hud.hide_result()
		KEY_W, KEY_UP:
			if phase == Phase.PLAYING:
				player.request_jump(1)
		KEY_S, KEY_DOWN:
			if phase == Phase.PLAYING:
				player.request_jump(-1)
		KEY_J:
			if phase == Phase.PLAYING:
				player.request_switch_color()

func _next_level() -> void:
	var levels := LevelData.all_levels()
	if level_index + 1 < levels.size():
		load_level(level_index + 1)
		phase = Phase.PLAYING
		hud.hide_result()
	else:
		load_level(0)

# ------------------------------------------------------------
func _on_died(reason: String) -> void:
	phase = Phase.DEAD
	hud.flash(1.0)
	hud.show_result(
		"死亡",
		"%s\n\n跑出 %.0f m ｜ 用时 %.1f s\n\n按 空格 / R 重开本关" % [reason, player.distance, player.elapsed],
		Color(1.0, 0.35, 0.3)
	)

func _on_finished(time: float) -> void:
	phase = Phase.WIN
	var stars := 1
	if time <= level.target_time:
		stars = 2
	if time <= level.challenge_time:
		stars = 3
	var star_str := "★".repeat(stars) + "☆".repeat(3 - stars)
	hud.show_result(
		"通关 %s" % star_str,
		"用时 %.1f s ｜ 剩余能量 %d\n二星 %.0f s ｜ 三星 %.0f s\n\n按 空格 下一关　R 重开" % [
			time, int(player.energy), level.target_time, level.challenge_time
		],
		Color(0.6, 1.0, 0.7)
	)
