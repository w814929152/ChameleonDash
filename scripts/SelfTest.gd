extends Node
## ============================================================
## 纸面数值模拟器 / 关卡校验器
##
## 用途：不开游戏、不手动玩，就能回答三个问题：
##   1. 这关能不能通？（能量预算够不够）
##   2. 理论最优用时是多少？（用来校准二星 / 三星线）
##   3. 关卡有没有违反设计硬约束？
##
## 模拟的"玩家"是四种贪心理性原型，区别只在【几种走法都划算时优先谁】：
##   冲刺流 —— 能冲刺就冲刺 > 硬闯 > 切色
##   保守流 —— 硬闯 > 冲刺 > 切色
##   切色流 —— 切色划算就切 > 硬闯 > 冲刺
##   连跳流 —— 连跳穿异色 > 冲刺 > 切色（2026-10-10 新增，见 hop_cost）
##   四种共同点：找同色格子 → 异层就跳(8点)；切色前必跳（空中豁免是救济通道）。
## 判定标准是"至少三型能通" —— 两型能通仍然像在背答案。
##
## 【新机制的建模原则：一律悲观】
##   加速带 —— 按实际倍率算（这是精确的，不需要悲观）。
##   脉冲段 —— 按"最坏相位对齐"算：取窗口内敌人相位的最大累计时长。
##             玩家掐相位能过得更好，但校验器不给他这个便宜。
##   晶体   —— 一律按"一颗没吃到"算（见 LevelData 硬约束 4）。
##   宁可校验器悲观：悲观只会让关卡更保险，乐观会让关卡偷偷不可通。
##
## 运行：godot --headless --path D:/ChameleonDash res://scenes/SelfTest.tscn
## ============================================================

func _ready() -> void:
	var all_ok := true
	for lv in LevelData.all_levels():
		print("\n════════ ", lv.level_name, " ════════")
		print("  全长 %.0f m" % lv.total_length())

		var best_time := INF
		var alive_arches := 0

		var arches := [Arch.DASH, Arch.WALK, Arch.SWITCH, Arch.HOP]
		for arch in arches:
			var r := simulate(lv, arch)
			var ok: bool = r["survive"]
			if ok:
				alive_arches += 1
				best_time = minf(best_time, float(r["time"]))
			else:
				all_ok = false

			print("  [%s] %s ｜ %.2f s ｜ 最低能量 %.1f ｜ 终点 %.1f ｜ 冲%d 跳%d 切%d 缺口%d" % [
				ARCH_NAME[arch],
				"通关" if ok else "暴毙",
				r["time"], r["min_energy"], r["energy"],
				r["dashes"], r["jumps"], r["switches"], r["gaps"]
			])
			if arch == Arch.DASH:
				for line in r["log"]:
					print("        ", line)
				for g in r["gates"]:
					print("        · ", g)
			if arch == Arch.HOP and ok:
				print("        （连跳成本按【下界】估算：要求每一跳都落地即按；")
				print("          真人必然更贵，所以“99 点可过”实际是“理论勉强、实战不成立”）")
			for w in r["warnings"]:
				print("        [!] ", w)

		# 判定标准是"至少三型能通"：两型能通仍然像在背答案。
		var verdict := "多解成立"
		if alive_arches == 0:
			verdict = "完全不可通关"
		elif alive_arches == 1:
			verdict = "唯一解 —— 玩家只能背答案，可玩性不足"
		elif alive_arches == 2:
			verdict = "双解（仍偏窄）"
		print("  → %d/%d 原型通关：%s ｜ 理论最优 %.2f s" % [
			alive_arches, arches.size(), verdict, best_time])
		if lv.target_time > 0.0:
			print("  → 二星 %.0f s %s ｜ 三星 %.0f s %s" % [
				lv.target_time, "可达" if best_time <= lv.target_time else "不可达",
				lv.challenge_time, "可达" if best_time <= lv.challenge_time else "不可达"
			])
		else:
			print("  → 星级线未设定（理论最优 %.2f s，建议二星 %.0f 三星 %.0f）" % [
				best_time, best_time * 1.12, best_time * 1.04])

		# ---- 结构性不变量（调用引擎本体，不复刻物理）----
		var escapes := check_forward_escape(lv)
		if escapes.is_empty():
			print("  → 前进可逃离 ✓（每个段末尾都有可落脚的层）")
		else:
			all_ok = false
			for e in escapes:
				print("  → [X] ", e)

	print("\n========================================")
	if all_ok:
		print("全部关卡可通关")
	else:
		print("存在不可通关关卡 —— 不要发布，先改 LevelData")
	print("========================================")
	get_tree().quit(0 if all_ok else 1)

# ------------------------------------------------------------
# 结构性不变量：前进可逃离
# ------------------------------------------------------------
## 【2026-10-10 新增】起因：一次"跳跃按键无效"事故 ——
##   校验器三关全绿（3/3 原型通关），实机却按不出跳、必死。
##   根因是【纸面模型和引擎用了两套落点规则】：
##     校验器按"段边界"解析落点；引擎（旧版）按"当前距离"解析。
##   留空改造后段与段的层不连续，这个分歧就让每一次"上跳到另一层"都失效。
##
## 由此定下的纪律（比这条检查本身更重要）：
##   【凡是要验"物理能不能做到"，一律调用引擎本体，绝不在校验器里复刻一遍。】
##   复刻 = 制造假阳性。这条检查直接调 Player.next_track_layer，所以引擎改了它跟着改。
##
## 不变量：站在任意段末尾的任意可站立层上，至少存在一个方向能落到实体跑道上。
##   违反 = 玩家跑到这里必定坠落，与操作无关。这不是难度，是设计错误。
##   （只验"有没有路"，不验"路是不是同色"—— 异色落脚点是没问题的。）
##
## 【2026-10-10 三次定稿后这条检查的分量变重了】
##   跳跃只够到上一层，"往空层跳"不再自动跳过空层。于是【N → N+2】的衔接
##   第一次变成真正走不通的路 —— 以前它只是"多花 8 点"。这条检查就是它的探测器。
static func check_forward_escape(lv: LevelData) -> Array:
	var problems: Array = []
	var p := Player.new()
	p.setup(lv)
	for i in range(lv.segments.size() - 1):
		var boundary := lv.segment_start(i + 1)      # 段 i 结束 = 段 i+1 开始
		var colors: Array = lv.segments[i]["colors"]
		for L in colors.size():
			if int(colors[L]) == GameConfig.NO_TRACK:
				continue
			# 下一段在同一层还接着 → 不需要任何动作
			if lv.color_at(boundary, int(L)) != GameConfig.NO_TRACK:
				continue
			# 站到段末尾前 0.5m：这是引擎里仍能起跳的最后一刻
			p.distance = boundary - 0.5
			p.layer = int(L)
			if p.next_track_layer(1) < 0 and p.next_track_layer(-1) < 0:
				problems.append(
					"段%d 层%d：段末尾无路可走 —— 下一段只有更高的层（跨两层，跳不上去）"
					% [i, L])
	p.free()
	return problems

enum Arch { DASH, SWITCH, WALK, HOP }

const ARCH_NAME := {
	Arch.DASH: "冲刺流", Arch.SWITCH: "切色流",
	Arch.WALK: "保守流", Arch.HOP: "连跳流",
}

# ------------------------------------------------------------
# 派生成本（含加速带倍率）
# ------------------------------------------------------------
## 硬闯一段的实际成本：时间 = L / (基础速度 × 倍率)，每秒扣 DRAIN_DIFF
static func _walk_cost(L: float, mult: float) -> float:
	return L * GameConfig.ENERGY_DRAIN_DIFF / (GameConfig.SPEED_BASE * mult)

static func _travel_time(L: float, mult: float) -> float:
	return L / (GameConfig.SPEED_BASE * mult)

## 连跳穿过一段【全程异色】跑道的实际成本 —— 用真实引擎逐帧实测，不写公式。
##
## 【为什么必须实测】见 check_forward_escape 的纪律：校验器复刻引擎物理 = 制造假阳性。
##   连跳成本看着像一道算术（L / 6m × 8 点），但真实值里还夹着
##   "落地那一帧的地面损耗"（引擎里 _update_energy 在 _update_jump 之后跑，
##   所以每一跳都至少踩地一帧）。写公式会算出 1.333 点/米，
##   实测是 1.383 —— 差 4%，而门的生死线正好卡在这个量级上。
##
## 策略取最乐观："落地当帧立刻再按跳"。真人不可能每跳都做到，
##   所以这个值是【下界】：实测比它贵，关卡就还是安全的。
static func hop_cost(L: float, mult: float) -> float:
	var seg := {"length": L + 80.0, "colors": [1, -1, -1]}
	if mult > 1.0:
		seg["boost"] = mult
	var lv := LevelData.new("hop-probe", [seg], 0.0, 0.0)
	var p := Player.new()
	p.setup(lv)
	p.player_color = 0            # 跑道是 1 → 全程异色
	p.layer = 0
	p.energy = 100000.0           # 抬高上限，纯粹为了测"单位距离成本"，不让它中途饿死
	var guard := 0
	while p.distance < L and p.alive and guard < 200000:
		guard += 1
		if not p.airborne:
			p.request_jump(1)     # 单层关 → 任何方向都没有实体跑道 → 原地跳
		p.tick(1.0 / 60.0)
	var spent := 100000.0 - p.energy
	var ok := p.alive and p.distance >= L
	p.free()
	return spent if ok else INF

## 脉冲段的最坏相位损失。
## 相位是周期 2h 的方波（h = PULSE_PERIOD/2，敌人相位占 h）。
## 在时长窗口 T 内，敌人相位的最大累计时长：
##   min(ceil(T / 2h) × h, T)
## 取这个上限而不是"整段全异色"，是因为后者物理上不可能达到，
## 会让校验器把一个 26m 的脉冲段当成 39 点伤害（实际最多约 29 点），
## 过度悲观会逼着关卡设计者把脉冲段做得毫无威胁。
static func _pulse_worst_damage(L: float, mult: float) -> float:
	var T := _travel_time(L, mult)
	var h := GameConfig.PULSE_PERIOD * 0.5
	var max_enemy: float = minf(ceil(T / (2.0 * h)) * h, T)
	return max_enemy * GameConfig.ENERGY_DRAIN_DIFF

# ------------------------------------------------------------
static func simulate(level: LevelData, arch: int = Arch.DASH) -> Dictionary:
	var energy := GameConfig.ENERGY_START
	var time := 0.0
	var min_energy := energy
	var pcolor := 0
	var layer := 0
	var dashes := 0
	var jumps := 0
	var switches := 0
	var gaps := 0
	var log_lines: Array = []
	var warnings: Array = []
	var gate_notes: Array = []

	for i in level.segments.size():
		var seg: Dictionary = level.segments[i]
		var L: float = float(seg["length"])
		var colors: Array = seg["colors"]
		var mult: float = float(seg.get("boost", 1.0))
		var is_pulse: bool = bool(seg.get("pulse", false))

		# 硬约束 3：颜色切换段不得短于"当前速度下一次竖直动作的距离"。
		# 加速度带时必须按加速后的速度算，否则冲刺/加速时看不见就撞上。
		#
		# 【2026-10-10 四次定稿】下坠改成自由落体后，一次动作的滞空不再统一：
		#   跳跃 0.58s ／ 掉一层 0.50s ／ **掉两层 0.71s**。取最长的那个 ——
		#   这条约束要防的是"被搬过去而没看见颜色变了"，那就得按最坏情况算。
		#   旧版写死 JUMP_AIR_TIME，等于假设"下坠永远不会比跳跃飞得久"，
		#   而下坠改自由落体之后这个假设正好反了（掉两层比重载跳跃还远 1.5m）。
		var fastest: float = maxf(GameConfig.SPEED_DASH, GameConfig.SPEED_BASE * mult)
		var longest_air: float = maxf(GameConfig.JUMP_AIR_TIME,
			GameConfig.fall_air_time(GameConfig.LAYER_COUNT - 1, 0))
		var min_legible: float = fastest * longest_air
		if L < min_legible:
			warnings.append("段%d 长 %.0fm < %.0fm：高速下无法读清，建议加长" % [i, L, min_legible])
		if is_pulse and L > GameConfig.PULSE_MAX_LEN:
			warnings.append("段%d 脉冲段 %.0fm > 上界 %.0fm：最坏情况会暴毙" % [
				i, L, GameConfig.PULSE_MAX_LEN])

		var note := ""

		# ---- 缺口：当前层此段没有跑道，必须先离开 ----
		# 【2026-10-10 三次定稿】新规则下一个竖直动作只够到【上一层】，
		#   所以"离开"只有两种结局：跳上去（若上一层有跑道），或掉到下面最高的那条。
		#   两者同价 8 点，差别只在滞空时长与前进距离。
		#   ⚠ 三层全缺 → 无路可走，是设计错误，直接判失败。
		if int(colors[layer]) == GameConfig.NO_TRACK:
			var dest := _highest_track_at_or_below(colors, layer + _jump_reach_layers())
			if dest < 0:
				log_lines.append("段%-2d 三层全缺口 —— 关卡设计错误（无路可走）" % i)
				return _fail(level, time, energy, min_energy, dashes, jumps, switches,
					gaps, log_lines, warnings, gate_notes)
			var up_move := dest > layer
			# 【2026-10-10 四次定稿】下坠时长不再查常量，改由落差算（自由落体）。
			#   必须在改 layer 之前算 —— fall_air_time 读的是【出发层】。
			#   掉一层的纸面结果与旧版逐字相同（仍是 0.5s），
			#   只有"缺口一次掉两层"的段会变慢 0.21s，二/三星线可能随之后移。
			var air_t: float = GameConfig.JUMP_AIR_TIME if up_move \
				else GameConfig.fall_air_time(layer, dest)
			energy = maxf(energy - GameConfig.FALL_ENERGY_COST, 0.0)
			var gair := minf(GameConfig.SPEED_BASE * air_t, L)
			time += air_t
			L -= gair
			layer = dest
			gaps += 1
			note = "缺口→层%d" % dest

		# ---- 脉冲段：整段无安全层，只能按最坏相位硬吃 ----
		# 注意这里不能走"同色层搜索"：基础色可能是同色，但相位翻转后就不是了。
		if is_pulse:
			var dmg := _pulse_worst_damage(L, mult)
			energy -= dmg
			time += _travel_time(L, mult)
			note = "脉冲段(最坏-%.0f)" % dmg
			log_lines.append("段%-2d 脉冲 %5.0fm %-16s → 层%d 能量 %5.1f" % [
				i, L, note, layer, energy])
			min_energy = minf(min_energy, energy)
			if energy <= 0.0:
				log_lines.append("段%-2d 能量归零 —— 死亡" % i)
				return _fail(level, time, energy, min_energy, dashes, jumps, switches,
					gaps, log_lines, warnings, gate_notes)
			continue

		var best := _best_same_color_reachable(colors, pcolor, layer)

		if best >= 0:
			# ---- 有够得着的同色层：切过去。一次竖直动作 = 8 点 ----
			# 【2026-10-10 三次定稿】"够得着"被收紧了：跳跃只到上一层，
			#   所以"最近"不再是选择依据 —— 只有 {本层, 本层+1, 底下最高的那条}
			#   三个落点是可达的（见 _best_same_color_reachable）。
			if best != layer:
				var up_move := best > layer
				# 同上：下坠时长由落差算，且要在改 layer 之前算
				var air_t: float = GameConfig.JUMP_AIR_TIME if up_move \
					else GameConfig.fall_air_time(layer, best)
				energy = maxf(energy - GameConfig.JUMP_ENERGY_COST, 0.0)
				jumps += 1
				var air_dist := minf(GameConfig.SPEED_BASE * air_t, L)
				time += air_t
				L -= air_dist
				layer = best
				note = "切层%d(1次)" % layer
			var t := _travel_time(L, mult)
			time += t
			energy = minf(energy + GameConfig.ENERGY_GAIN_SAME * t, GameConfig.ENERGY_MAX)
			if mult > 1.0:
				note += " 加速×%.1f" % mult
			log_lines.append("段%-2d 同色 %5.0fm %-16s → 层%d 能量 %5.1f" % [
				i, L, note, layer, energy])
		else:
			# ---- 三层全异色：门 ----
			#   L ≤ 66.7m        软门：硬闯也能过，不构成挑战
			#   66.7 < L ≤ 100m  冲刺门：硬闯必死，冲刺可过
			#   L > 100m         切色门：冲刺上限 100m 够不到，唯一解是切色
			# 收费口（toll）地形与门完全一样，只有作者的标记能区分 —— 日志里
			#   也必须写"收费口"，否则输出会继续说"段8 门 26m"，读者又会误判。
			var gate_tag := "收费口" if bool(seg.get("toll", false)) else "门"
			var cost_dash := L * GameConfig.COST_PER_METER_DASH
			var cost_walk := _walk_cost(L, mult)
			# 【2026-10-10 新增】连跳穿过同一段的成本，用真实引擎实测。
			#   原地跳合法化之后，"硬闯"不再是唯一的非冲刺解法 ——
			#   旧文案那句"必死"会变成假话。校验器不许撒谎，所以必须把它算出来。
			var cost_hop := hop_cost(L, mult)
			# 本原型"走"的单价：连跳流用连跳成本，其余三型老老实实硬闯。
			# 四型要真的互不相同，比较才有意义 —— 若人人在门里都连跳，
			# 原型就退化成一个了。
			var walk_used := cost_hop if arch == Arch.HOP else cost_walk

			# "toll" 段（收费口）刻意就是"无处可躲、只能硬吃"。它和"软门"地形
			#   完全相同（纯异色段），但意图相反，所以两种处理都不该走：
			#   既不报"冲刺失去意义"（那是误报），也不记进 gate_notes
			#   （gate_notes 是"这道门怎么过"的清单，收费口根本不在其中）。
			#   ⚠ 别只把 not toll 加到下面那条 if 上 —— 那样它会掉进 elif 链，
			#   被当成"连跳可过的冲刺门"记进 gate_notes，把误报换个地方接着撒。
			#   这条豁免不是"消警告"，是把作者的意图读进来：没有标记的短异色段
			#   【仍然】报警，校验的价值一点没少。
			if bool(seg.get("toll", false)):
				pass
			elif L <= GameConfig.DEATH_ZONE_MIN_LEN and mult <= 1.0:
				# 加速带上的软门不报警：加速带本身就是"硬闯异色的解法"，
				# 这类段不是"冲刺失去意义"，是"加速带在这里才对"。
				warnings.append("段%d %.0fm 软门：硬闯只需 %.0f 点，冲刺失去意义" % [i, L, cost_walk])
			elif L > GameConfig.DEATH_ZONE_MAX_LEN:
				gate_notes.append("段%d 切色门 %.0fm：冲刺够不到，切色后回血 %.0f 点" % [
					i, L, L * GameConfig.GAIN_PER_METER_SAME])
			elif cost_hop <= GameConfig.ENERGY_MAX:
				gate_notes.append(("段%d 冲刺门 %.0fm：硬闯 %.0f 点必死，但【连跳 %.0f 点可过】"
					+ "（%.2f 点/米，需 2 次/秒精确落地即按）；冲刺 %.0f 点") % [
						i, L, cost_walk, cost_hop, cost_hop / maxf(L, 0.001), cost_dash])
			else:
				gate_notes.append("段%d 冲刺门 %.0fm：硬闯 %.0f 点必死，连跳 %.0f 点也不够；冲刺 %.0f 点" % [
					i, L, cost_walk, cost_hop, cost_dash])

			# 加速带与冲刺互斥：冲刺期间倍率失效 → 冲刺门的成本不受加速带影响
			var can_dash := energy >= GameConfig.ENERGY_MAX and cost_dash <= energy
			var can_walk := energy > walk_used

			# 切色的真实代价是"当前的全部能量"。所以切色只有在
			# 【不切要付的钱 > 全部能量】时才是划算的 —— 这条对所有原型都成立。
			# 三种原型的区别只在于"几种走法都划算时优先谁"，而不是"谁更不计代价"。
			#
			# 这里修过一个真实的建模错误：早先的版本让"切色流"在任何门前都切，
			# 包括 22m 的软门（硬闯只要 24 点，它却把 92 点全丢了），然后
			# 带着 0 能量撞上下一个脉冲段暴毙 —— 于是校验器误报关卡不可通关。
			# 犯错的是原型不是关卡：真人玩家不会在"24 点 vs 全部能量"里选后者。
			var switch_worth := energy < walk_used

			var picked := Arch.SWITCH
			match arch:
				Arch.DASH:
					if can_dash:
						picked = Arch.DASH
					elif can_walk:
						picked = Arch.WALK
				Arch.WALK:
					if can_walk:
						picked = Arch.WALK
					elif can_dash:
						picked = Arch.DASH
				Arch.HOP:
					if can_walk:
						picked = Arch.WALK
					elif can_dash:
						picked = Arch.DASH
				Arch.SWITCH:
					if switch_worth:
						picked = Arch.SWITCH
					elif can_walk:
						picked = Arch.WALK
					elif can_dash:
						picked = Arch.DASH

			if picked == Arch.DASH:
				energy -= cost_dash
				time += L / GameConfig.SPEED_DASH
				dashes += 1
				log_lines.append("段%-2d %s %5.0fm 冲刺 → 能量 %5.1f" % [
					i, gate_tag, L, energy])
			elif picked == Arch.WALK:
				energy -= walk_used
				time += _travel_time(L, mult)
				if arch == Arch.HOP:
					# 连跳水平速度不变，所以耗时与硬闯一致，省的是能量不是时间
					jumps += int(ceil(L / (GameConfig.SPEED_BASE * mult * GameConfig.JUMP_AIR_TIME)))
					log_lines.append("段%-2d %s %5.0fm 连跳(%.2f点/米) → 能量 %5.1f" % [
						i, gate_tag, L, walk_used / maxf(L, 0.001), energy])
				else:
					log_lines.append("段%-2d %s %5.0fm 硬闯(%.2f点/米) → 能量 %5.1f" % [
						i, gate_tag, L, walk_used / maxf(L, 0.001), energy])
			else:
				# 先跳（进入空中豁免），空中切色，落地时已是同色 → 活。
				energy = maxf(energy - GameConfig.JUMP_ENERGY_COST, 0.0)
				jumps += 1
				energy = 0.0
				switches += 1
				pcolor = 1 - pcolor
				var t := _travel_time(L, mult)
				time += t
				energy = minf(energy + GameConfig.ENERGY_GAIN_SAME * t, GameConfig.ENERGY_MAX)
				log_lines.append("段%-2d %s %5.0fm 跳+切色(转%s) → 能量 %5.1f" % [
					i, gate_tag, L, "橙" if pcolor == 1 else "青", energy])

		min_energy = minf(min_energy, energy)
		if energy <= 0.0:
			log_lines.append("段%-2d 能量归零 —— 死亡" % i)
			return _fail(level, time, energy, min_energy, dashes, jumps, switches,
				gaps, log_lines, warnings, gate_notes)

	return {
		"survive": true, "time": time, "energy": energy, "min_energy": min_energy,
		"dashes": dashes, "jumps": jumps, "switches": switches, "gaps": gaps,
		"log": log_lines, "warnings": warnings, "gates": gate_notes
	}

static func _fail(_l, time, energy, min_energy, dashes, jumps, switches, gaps,
		log_lines, warnings, gate_notes) -> Dictionary:
	return {
		"survive": false, "time": time, "energy": energy, "min_energy": min_energy,
		"dashes": dashes, "jumps": jumps, "switches": switches, "gaps": gaps,
		"log": log_lines, "warnings": warnings, "gates": gate_notes
	}

## 从 from 层移动到 to 层需要几次跳跃。
## 跳跃能够到的层数上限 —— 从 GameConfig 推导，不写死 "+1"。
##
## 【为什么必须推导而不是写字面量】三次定稿把"只能跳一层"变成了几何推论：
##   峰值 = JUMP_APEX_HEIGHT(4.4) → 可落的层只有 本层 与 本层+1。
##   如果哪天有人把这个常量抬到 6.5m，这里必须自动跟着变成 +2；
##   写死的话校验器会继续按 +1 算，于是"关卡通过"变成假话 ——
##   这正是本文件反复强调的那类假阳性。
static func _jump_reach_layers() -> int:
	return int(floor(GameConfig.JUMP_APEX_HEIGHT / GameConfig.LAYER_SPACING))

## 从 top 层往下找，第一块有跑道的层（含 top）。返回 -1 = 一路到底都没有。
##
## 这就是引擎 Player._resolve_landing 的纸面版：峰值高度之下最高的那块实体跑道。
##   本文件的铁律是"物理一律问引擎"，所以这里只服务于【成本估算】——
##   "能不能走"由 check_forward_escape 直接调引擎判定，不算在这里。
static func _highest_track_at_or_below(colors: Array, top: int) -> int:
	var l := mini(top, colors.size() - 1)
	while l >= 0:
		if int(colors[l]) != GameConfig.NO_TRACK:
			return l
		l -= 1
	return -1

## 当前层位下，玩家能落到【同色】的哪一层。返回 -1 = 一个都够不着（那这一段就是门）。
##
## 可达集合只有三个（2026-10-10 三次定稿）：
##   本层（0 点，不用动）
##   本层 + 1（一次跳跃，8 点）—— 跳跃只够到这里
##   本层之下最高的那条（一次坠落，8 点）—— 坠落落点不由玩家选，是"下面最高的那条"
## 偏好顺序 = 本层 → 往上 → 往下：能不动就不动，能往上就不往下
##   （留空关卡的惯例是下一段在自己的上方，往下掉通常是退路而不是正解）。
static func _best_same_color_reachable(colors: Array, pcolor: int, from: int) -> int:
	if int(colors[from]) == pcolor:
		return from
	var up := _highest_track_at_or_below(colors, from + _jump_reach_layers())
	if up > from and int(colors[up]) == pcolor:
		return up
	var down := _highest_track_at_or_below(colors, from - 1)
	if down >= 0 and int(colors[down]) == pcolor:
		return down
	return -1
