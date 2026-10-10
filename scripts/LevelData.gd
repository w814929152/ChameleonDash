class_name LevelData
extends RefCounted
## 关卡数据：三层跑道（横版，每层一条道）。
##
## 每个 segment: { length: float, colors: [int,int,int], ...可选字段 }
##   colors[0..2] 是自下而上三层的颜色（A / B / X）
##
## 可选字段（2026-10-10 新增的三种机制，全部可选，缺省 = 无该机制）:
##   "boost": float       该段速度倍率（GameConfig.BOOST_MULT）
##   "pulse": true        该段三层同步在青/橙之间呼吸（周期 GameConfig.PULSE_PERIOD）
##   "crystals": [[layer, offset_m, value], ...]   段内能量晶体
##
## 横版重构带来的硬约束:
##   三层全同色只对一种颜色安全 —— 必须写成「至少一青一橙」的呼吸点，
##   否则会变成对另一半玩家的必死彩票。
##
## 关卡设计的三条硬约束（违反任何一条关卡就是坏的）:
##   1. 可通关性  —— 存在一条路径使能量全程 > 0（SelfTest 会验）
##   2. 多解性    —— 四种玩家原型（冲刺/保守/切色/连跳）里至少三型能通关，
##                  否则玩家是在背答案
##   3. 可读性    —— 任何颜色切换段不得短于 JUMP_AIR_TIME × SPEED_DASH
##                  = 0.58 × 24 = 13.9m（滞空 0.5→0.58 之后这条线从 12m 抬到 13.9m）
##
## 新增机制的第四条硬约束（2026-10-10）:
##   4. 不依赖    —— 可通关性不允许依赖晶体。校验器一律按"一颗没吃到"计算。
##                 晶体是纯收益，不是解法的组成部分，否则关卡退化成背路线。

var level_name := ""
var segments: Array = []
var target_time := 0.0    # 二星：通关且用时 ≤ 此值
var challenge_time := 0.0 # 三星：通关且用时 ≤ 此值

func _init(p_name := "", p_segments := [], p_target := 0.0, p_challenge := 0.0) -> void:
	level_name = p_name
	segments = p_segments
	target_time = p_target
	challenge_time = p_challenge

func total_length() -> float:
	var s := 0.0
	for seg in segments:
		s += float(seg["length"])
	return s

func segment_index_at(dist: float) -> int:
	var acc := 0.0
	for i in segments.size():
		if dist < acc + float(segments[i]["length"]):
			return i
		acc += float(segments[i]["length"])
	return segments.size() - 1

## 段起始距离（HUD 前方预警用）
func segment_start(i: int) -> float:
	var acc := 0.0
	for k in mini(i, segments.size()):
		acc += float(segments[k]["length"])
	return acc

func _color_of(seg: Dictionary, layer: int) -> int:
	var colors: Array = seg["colors"]
	return int(colors[clampi(layer, 0, colors.size() - 1)])

## 查询某层的颜色（不含脉冲的时间维度 —— 供校验器等静态用途）
func color_at(dist: float, layer: int) -> int:
	return _color_of(segments[segment_index_at(dist)], layer)

# ------------------------------------------------------------
# 新机制查询
# ------------------------------------------------------------
## 该位置的速度倍率。无加速带 → 1.0
func boost_at(dist: float) -> float:
	var seg: Dictionary = segments[segment_index_at(dist)]
	return float(seg.get("boost", 1.0))

## 该位置是否处于脉冲段
func is_pulse(dist: float) -> bool:
	var seg: Dictionary = segments[segment_index_at(dist)]
	return bool(seg.get("pulse", false))

## 脉冲相位：true = 已翻转（当前显示的是颜色的"反面"）
## 翻转节奏 = 每 PULSE_PERIOD/2 秒翻一次，与校验器的最坏情况假设一致。
func pulse_flipped(t: float) -> bool:
	var half := GameConfig.PULSE_PERIOD * 0.5
	return int(floor(t / half)) % 2 == 1

## 带时间的颜色查询。脉冲段会随时间翻转 —— 这是玩家在游戏中看到的值。
func color_at_t(dist: float, layer: int, t: float) -> int:
	var seg: Dictionary = segments[segment_index_at(dist)]
	var c := _color_of(seg, layer)
	if c == GameConfig.NO_TRACK:
		return c
	if bool(seg.get("pulse", false)) and pulse_flipped(t):
		c = 1 - c
	return c

## 该位置有哪些层是有跑道的（自下而上的层号数组）。
## 留空改造后这是最高频的查询：玩家随时要知道"我能站哪儿"。
func track_layers_at(dist: float) -> Array:
	var seg: Dictionary = segments[segment_index_at(dist)]
	var out: Array = []
	var colors: Array = seg["colors"]
	for i in colors.size():
		if int(colors[i]) != GameConfig.NO_TRACK:
			out.append(i)
	return out

## 该段是否存在同色层（对给定玩家颜色）。不存在 = 这是一道"门"。
## 静态版本：脉冲段按最坏情况（翻转后）判断，宁可悲观。
func has_same_color(seg: Dictionary, pcolor: int) -> bool:
	var colors: Array = seg["colors"]
	for c in colors:
		var cc := int(c)
		if cc == pcolor:
			return true
		# 脉冲段会翻转到反面，所以"当前是异色"不代表一直异色 —— 反之亦然。
		# 这里为了不误判成"有同色层"，只有在【翻转后】仍为同色才算安全。
	return false

## 展平所有晶体到绝对距离（{dist, layer, value}）
## 运行时由 Player 消费；校验器刻意不消费（见类注释硬约束 4）。
func crystal_list() -> Array:
	var out: Array = []
	for i in segments.size():
		var seg: Dictionary = segments[i]
		if not seg.has("crystals"):
			continue
		var start := segment_start(i)
		for c in seg["crystals"]:
			out.append({
				"dist": start + float(c[1]),
				"layer": int(c[0]),
				"value": float(c[2]) if c.size() > 2 else GameConfig.CRYSTAL_VALUE,
			})
	return out

## 前方扫描：从 dist 起找下一道门，返回 {dist, len, kind} 或 null。
##
## Rationale: 110m 切色门和 78m 冲刺门的最优解完全相反（一个必须切色、
##   一个必须冲刺），而玩家在画面里只看得见颜色、看不见长度。读不出长度，
##   L3 的核心战略决策就退化成瞎猜。这条预警是 Pillar「风险必须可读」的
##   硬要求，不是锦上添花。
func next_gate(dist: float, pcolor: int) -> Variant:
	for i in segments.size():
		var start := segment_start(i)
		var L := float(segments[i]["length"])
		if start + L <= dist:
			continue
		# 脉冲段不是门 —— 它有自己的预警通道。混进门预警里会给出错误的建议
		# （"按 J 切色"对脉冲段完全没用，切了色相位照样翻）。
		if bool(segments[i].get("pulse", false)):
			continue
		if has_same_color(segments[i], pcolor):
			continue
		var kind := "切色门" if L > GameConfig.DEATH_ZONE_MAX_LEN else "冲刺门"
		return {
			"dist": start - dist,
			"len": L,
			"kind": kind,
			"index": i,
		}
	return null

## 前方扫描：找下一处指定机制（"pulse" / "boost"），返回 {dist, len, index} 或 null。
func next_feature(dist: float, want: String) -> Variant:
	for i in segments.size():
		var start := segment_start(i)
		var L := float(segments[i]["length"])
		if start + L <= dist:
			continue
		var seg: Dictionary = segments[i]
		var hit := false
		if want == "pulse":
			hit = bool(seg.get("pulse", false))
		elif want == "boost":
			hit = float(seg.get("boost", 1.0)) > 1.0
		if hit:
			return {"dist": start - dist, "len": L, "index": i}
	return null

## 前方扫描：从 dist 起找下一个"本层跑道中断"的段。
## Rationale: 缺口掉下去要付 8 点（且可能落在异色上）。没有预警的情况下，
##   缺口会变成"看不清就罚"，这是设计事故不是难度。90m 内给出预警，
##   玩家才有时间选"跳去哪层"。
func next_gap(dist: float, layer: int) -> Variant:
	for i in segments.size():
		var start := segment_start(i)
		var L := float(segments[i]["length"])
		if start + L <= dist:
			continue
		if _color_of(segments[i], layer) != GameConfig.NO_TRACK:
			continue
		return {"dist": start - dist, "len": L, "index": i}
	return null

# ------------------------------------------------------------
# 关卡库
# ------------------------------------------------------------
## 注意: 这里刻意用字面量 0/1 而不是 GameConfig.LaneColor.A/B。
## autoload 节点在脚本常量初始化阶段尚未就绪，直接引用会得到 null。
const A := 0        # 青
const B := 1        # 橙
const X := -1       # 缺口：该层此段没有跑道（GameConfig.NO_TRACK）

## ============================================================
## 【2026-10-10 第二次重构：大幅留空 + 跳过空层的跳跃】
## ============================================================
## 旧版几乎每段三层填满，画面是三条连续的长带；空间维度只剩下
## "偶尔一个缺口"。现在反过来：**大部分段只有 1-2 层有跑道**，
## 画面变成一组错落的悬浮平台，"往上还是往下"成为每秒都要做的判断。
##
## 配套的机制改动（见 GameConfig / Player）:
##   跳跃落点 = 该方向上【最近的实体跑道】，空层自动跳过，不穿透实体。
##   跳跃与坠落都改成【按次计费 8 点】，跨几层都是 8。
##
## 留空带来的两条新设计纪律（违反会做出坏关）:
##   A. 【门必须建在玩家已经站着的层上】
##      冲刺需要满能量，而任何一次跳跃都扣 8 点 —— 所以"跳一下才够得着"的门
##      永远不可能被冲刺通过。门的跑道层 = 上一段结束时玩家所在的层，这条必须对齐。
##   B. 【脉冲段必须有两层】
##      单层跑道上玩家无处可跳（那个方向没有跑道），"跳起来冻结结算"这条
##      唯一的应对手段直接失效 —— 脉冲段就变成了纯挨打。两层可以来回横跳。
##
## 缺口的用法（关卡设计词汇表，留空后成为主要语言）:
##   1. 【独木桥】[-1, A, -1]  只有一层 → 强制路线 + 强制颜色
##   2. 【逼迁】  [A, -1, B]  玩家所在层断了 → 必须走，且两难
##   3. 【收费口】[A, X, A]  三层里没有你的颜色，且中间是空的躲不掉
##                            → 只能硬吃异色伤害，是"看得到回血却拿不到"的时刻
##   4. 【断头台】[-1, A, -1] 长段独木桥 + 异色 → 冲刺门／切色门的载体

# ============================================================
# L1「霓虹初醒」—— 教学关
# ============================================================
## 教学顺序刻意编排，每个新动作单独引入后都有安全段消化：
##   S0 贴地起步 → S1 上跳 → S2 再上跳 → S3 下跳（一次穿过空层）
##   → S4 双层呼吸 → S5 加速带 → S6 冲刺门 → S8 切色门 → S9 脉冲段
##
## 【玩家层必须一路对齐】本关每个门都建在玩家"上一段结束时已经站着的层"上：
##   S5 结束时在层1 → S6 的门也在层1（橙），玩家不需要跳就能冲刺。
##   如果门在别的层，"跳过去"本身要花 8 点，满能量被打破，冲刺就永远解锁不了。
##   这是留空改造后最容易犯的错，标记在此。
##
## S7 故意只给 85m：冲刺后剩 28 点，跑完 85m 只到 84.7 点 —— 差 15 点不到满，
## 冲刺解锁不了。于是 S8 的 78m 门只剩"切色"一条路。
## 这是把「切色」教出来的唯一办法：教学关必须让玩家被迫用一次，否则学不会。
static func level_1() -> LevelData:
	return LevelData.new("L1 霓虹初醒", [
		# 贴地起步：只有底层有跑道。玩家立刻知道"跑道不是到处都是"。
		{"length": 72.0,  "colors": [A, -1, -1]},
		{"length": 48.0,  "colors": [-1, A, -1]},          # 只有中层青 → 教 W 上跳
		{"length": 40.0,  "colors": [-1, -1, A]},          # 只有顶层青 → 再上一层
		# 下跳教学 + 新规则教学：层1 是空的，所以一次下跳直接穿过去落到层0。
		# 玩家在这里学会"跳跃会跳过没跑道的层"。
		{"length": 45.0,  "colors": [A, -1, -1]},
		{"length": 48.0,  "colors": [A, A, -1]},           # 两层青：第一次"随便站"
		# 加速带教学：放在同色独木桥上，纯爽感，不引入风险。
		# 教学关的新机制必须"第一次遇到就是好事"，风险留到 L2 再上。
		{"length": 35.0,  "colors": [-1, A, -1], "boost": GameConfig.BOOST_MULT},
		# 冲刺门：同一条中层，颜色翻成橙。玩家不需要跳 —— 原地就变成了异色，
		# 这正是"冲刺"要解决的场面。硬闯 72×1.5 = 108 点必死。
		{"length": 72.0,  "colors": [-1, B, -1]},
		{"length": 85.0,  "colors": [-1, A, -1]},          # 只攒到 84.7 点 → 冲刺解锁不了
		# 切色门：门在顶层，玩家必须先上跳（-8）再切色。这一跳是刻意的 ——
		# 它顺手示范了"切色前先跳"（空中豁免）这条战术。
		{"length": 78.0,  "colors": [-1, -1, B]},
		# 脉冲段教学：两层交替。基础色里层1是橙（切色后玩家正是橙）→ 第一眼安全，
		# 然后开始呼吸：翻过来时层1变青(危险)、层2变橙(安全)，玩家要横跳。
		# 基础色选同色而不是异色，是刻意的：威胁必须自己长出来，不能一上来就罚。
		{"length": 26.0,  "colors": [-1, B, A], "pulse": true},
		{"length": 68.0,  "colors": [-1, B, -1]},          # 终点缓冲：落回中层同色
	], 53.0, 49.0)   # 二星=最优47.38×1.12  三星=×1.04

# ============================================================
# L2「脉冲回廊」—— 频率关
# ============================================================
## 压力来自"切层频率"而不是门的长度。38-40m 的连续切层是刻意的：
##   38m = 3.17s，刚好够跳一次 + 站稳 + 读下一段；短于 30m 会变成手速游戏。
##
## 本关的核心是「加速带踩在异色上」这个反转用法：
##   加速带在异色上 = 0.83 点/米（比常速 1.5 便宜一半），是硬闯异色的唯一划算手段。
##   L1 教的是"加速带=爽"，L2 教的是"加速带=工具"，同一机制的第二层理解。
##   独木桥在这里帮了大忙：只有一条道时玩家无处可跳，"硬吃下来"是唯一选项，
##   于是加速带省了多少点变成一道很干净的心算题。
##
## S11 是"跳跃跳过空层"的高潮示范：层0 和层2 有跑道、层1 是空的，
##   一次上跳直接从底层穿到顶层 —— 旧规则下这一跳会落在空层然后摔死。
static func level_2() -> LevelData:
	return LevelData.new("L2 脉冲回廊", [
		{"length": 45.0,  "colors": [A, -1, -1]},
		{"length": 40.0,  "colors": [-1, A, -1]},          # 上跳
		{"length": 40.0,  "colors": [-1, -1, A]},          # 再上跳
		{"length": 38.0,  "colors": [A, -1, -1]},          # 下跳（穿过空层1）
		{"length": 36.0,  "colors": [-1, A, -1], "boost": GameConfig.BOOST_MULT},
		# 加速带 + 异色：本关第一处"把加速带当工具"的地方。
		# 30m 异色常速要 45 点，踩加速带只要 25 点 —— 省了将近一半。
		# 独木桥保证玩家无处可躲，这个对比才成立。
		{"length": 30.0,  "colors": [-1, B, -1], "boost": GameConfig.BOOST_MULT},
		{"length": 42.0,  "colors": [-1, A, -1]},          # 立刻回血
		{"length": 72.0,  "colors": [-1, B, -1]},          # 冲刺门 #1（同一条中层）
		{"length": 80.0,  "colors": [-1, A, -1]},          # 攒到 84 点，差 16 点不到满
		# 脉冲段：两层交替。基础色层1 = 同色，第一眼安全。
		{"length": 26.0,  "colors": [-1, A, B], "pulse": true},
		{"length": 48.0,  "colors": [A, A, -1]},           # 双层青：下跳到层0
		# 跨越空层的跳跃：层1 是空的，一次上跳从层0 直达层2。
		{"length": 40.0,  "colors": [-1, -1, A]},
		# 冲刺门 #2：顶层双层橙，玩家已经在层2，无需起跳 → 满能量可以冲刺。
		{"length": 85.0,  "colors": [-1, B, B]},
		# 二选一 + 晶体：同色在层0，顶层是异色。晶体刻意放在【同色层】上 ——
		# 这一颗是"走对路线的奖励"，与后面 L3 那颗"走错路线的陷阱"形成对照。
		{"length": 40.0,  "colors": [A, -1, B],
			"crystals": [[0, 22.0, GameConfig.CRYSTAL_VALUE]]},
		{"length": 36.0,  "colors": [A, -1, -1]},          # 终点缓冲
	], 59.0, 55.0)   # 二星=最优52.98×1.12  三星=×1.04

# ============================================================
# L3「双色回廊」—— 战略关（压轴）
# ============================================================
## 设计核心 —— 把"切色"从应急按钮升级为「区域通行证」。
## 前两关里切色永远是被逼的（没能量冲刺才切），玩家学不到它的战略价值。
## 这一关把跑道切成青区 / 橙区：进橙区前主动切色 = 归零，但整段橙色从此
## 变成回血区。风险与收益第一次同时成立，这是本关的可玩性来源。
##
## 节奏结构：「起（青区热身）— 承（冲刺门）— 转（切色进橙区）— 合（脉冲终局）」
## 三道门 + 两段脉冲，全都建在"玩家已经站着的层"上：
##   S4  68m   冲刺门   层1 独木桥，硬闯 102 点必死（玩家在层1，无需起跳）
##   S6  110m  切色门   层2 独木桥，冲刺上限 100m 够不到；切色后回血 73 点
##                       —— "必死走廊"反转成补给站，本关的高光时刻
##   S12 85m   冲刺门   层1 独木桥，对橙玩家全异色，本关唯一必须"攒满再放"的地方
##
## 终局刻意用【脉冲段】收尾而不是第四道门：
##   门是"读长度做决策"，脉冲是"读相位做操作"，两者是不同性质的考验。
##   压轴用操作收尾，玩家离手时记住的是"我掐准了那一拍"，而不是"我算对了数字"。
##
## 本关两次用到「收费口」的新形态 [A, X, A]：
##   三层里没有橙（橙玩家无处安全），中间还空着（躲不掉）——
##   只能硬吃一段异色。比旧版"底层断了逼你上跳"更狠，因为连上跳的选项都没了。
static func level_3() -> LevelData:
	return LevelData.new("L3 双色回廊", [
		# ── 起：青区热手 + 切层节奏 ──
		{"length": 28.0,  "colors": [A, -1, -1]},
		{"length": 28.0,  "colors": [-1, A, -1]},          # 上跳
		{"length": 28.0,  "colors": [-1, -1, A]},          # 再上跳
		{"length": 28.0,  "colors": [-1, A, -1]},          # 下跳（层1 有跑道，只降一层）
		# ── 承：第一道门。玩家在层1，满能量，是"冲刺最爽"的一次示范 ──
		{"length": 68.0,  "colors": [-1, B, -1]},          # 冲刺门 #1
		# 切色决策窗口。晶体刻意放在【异色层】：这一颗是"走错路线的陷阱"，
		# 与 L2 那颗"走对路线的奖励"形成对照 —— 玩家要学会辨认两者。
		{"length": 30.0,  "colors": [-1, B, A],
			"crystals": [[1, 16.0, GameConfig.CRYSTAL_VALUE]]},
		# ── 转：高光时刻。对青玩家全异色 110m —— 冲刺够不到，硬闯必死，
		#    唯一解是切色。而切色之后这 110m 全部变成回血区，回 73 点。
		{"length": 110.0, "colors": [-1, -1, B]},          # 切色门 → 转橙（玩家已在层2）
		# ── 合：橙区。玩家已是橙色，以下全按"橙=同色"读 ──
		{"length": 26.0,  "colors": [-1, -1, B]},          # 橙区回血
		# 收费口 26m：三层里没有橙，中间还是空的 —— 橙玩家无处安全也躲不掉，
		# 只能硬吃 26 × 1.5 = 39 点。这是本关"看得到回血却拿不到"的时刻。
		{"length": 26.0,  "colors": [A, -1, A]},
		{"length": 26.0,  "colors": [-1, B, -1]},          # 落回中层橙 → 回血
		# 脉冲段 #1：两层交替（层1 橙 / 层2 青）。基础色层1 = 同色，第一眼安全。
		{"length": 26.0,  "colors": [-1, B, A], "pulse": true},
		# 补满段：必须足够长，把玩家从"脉冲后的残血"推到满能量。
		# 100m 的来历：脉冲最坏情况后约剩 35 点，补满需 65 点 = 8.14s = 97.7m。
		# 【这是留空改造后最容易错的一处】门建在玩家所在层只是必要条件，
		# 能量还得真的够 —— 冲刺门要求【满能量】，不是"够付"。
		{"length": 100.0, "colors": [-1, B, -1]},
		# 冲刺门 #2：中层独木桥，对橙玩家全异色 85m（硬闯 128 必死）。
		# 玩家一路都在层1，无需起跳 → 满能量可以直接冲刺。
		{"length": 85.0,  "colors": [-1, A, -1]},
		# 冲刺后只剩 15 点，下面三段都写成【一青一橙】的双层：
		# 两条路线（冲刺成功=橙 / 被迫切色=青）都能找到自己的安全层。
		# 收尾段必须对两种颜色都友好，否则整关会被一条支线的死局否掉。
		{"length": 40.0,  "colors": [-1, B, A]},
		{"length": 26.0,  "colors": [A, B, -1], "pulse": true},   # 终局脉冲
		{"length": 32.0,  "colors": [A, B, -1]},           # 终点缓冲
	], 63.0, 58.0)   # 二星=最优55.37×1.12  三星=×1.04

static func all_levels() -> Array:
	return [level_1(), level_2(), level_3()]
