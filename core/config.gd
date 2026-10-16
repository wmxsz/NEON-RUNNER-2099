extends Node
## 全局配置（autoload: Config）
## 单一配置来源：配色、车道与物理、速度曲线、设备预算、章节主题、计分、道具、复活、任务和默认设置。
## 运行时改动优先在此定义，并通过统一契约接入实际消费方；不要在多个系统重复硬编码同一参数。

const PALETTE := {
        "yellow": Color("FCEE0A"),
        "magenta": Color("FF003C"),
        "cyan": Color("00F0FF"),
        "purple": Color("8B2FFF"),
        "blue": Color("2255FF"),
        "bg": Color("0B0812"),
        "fog": Color("3A1C10"),        # 暖橙雾色用于构建琥珀色远景层次。
        "buildingDark": Color("0B0B22"),
        "gold": Color("FFD166"),
        "dark": Color("15131F"),
        "white": Color("FFFFFF"),
}

const LANES: PackedFloat32Array = [-2.3, 0.0, 2.3]  # 三车道 x 坐标

const PHYSICS := {
        "gravity": -46.0,
        "jumpVel": 14.2,
        "slideTime": 0.68,
        # 横向真物理：脉冲-惯性-摩擦（车道=参考系非轨道）
        "laneImpulse": 10.5,       # swipe 冲量（m/s）
        "laneFriction": 9.5,        # 横向阻尼（与目标车道引导共同控制侧滑惯性）
        "laneWallBounce": 0.42,     # 边界反弹系数（撞墙回弹，物理感）
        "laneMaxV": 13.0,           # 横向速度上限
        # Coyote time 与独立换道窗口不单独配置；跳跃预输入缓冲统一由 Player 管理。
}

const SPEED := {
        "base": 13.0,
        "max": 33.0,
        "accel": 0.22,             #：0.16→0.22（125s 到极速太拖，91s 更符合跑酷节奏）
        "menu": 6.0,               # 菜单怠速
        "overclockMult": 1.42,     # 超频倍率
}

const RUNTIME := {
        # Match the established camera clipping distance; one source of truth now drives Camera3D.far.
        "viewDistance": 260.0,
        "bloomStrength": 0.48,      # Environment.glow_intensity
        "glowSpread": 0.92,         # Environment.glow_strength (not a literal pixel radius)
        "glowThreshold": 0.82,      # Environment.glow_hdr_threshold
        # Explicit frame caps avoid an unlimited high-tier loop on high-refresh phones.
        "targetFpsLow": 60,
        "targetFpsMid": 90,
        "targetFpsHigh": 120,
        "targetFpsUnknownRefresh": 60,
        # Target-refresh pacing guard: begin a sustained downshift near 80% of the
        # selected tier's frame budget rather than letting a 120 Hz target coast at ~70 Hz.
        # Two bad 2-second windows are still required, preserving hysteresis against spikes.
        "qualityBudgetMultiplier": 1.25,
        # Theme material/environment changes are capped to 30Hz during chapter blends.
        "themeUpdateHz": 30.0,
}

## ================ · 章节主题（每 1000m 渐变切换）================
## 对标大跑酷"场景变化"体验：雾色/天幕/霓虹基调/赛博甲板反射整体渐变
## 闹市(琥珀) → 工业区(毒绿) → 天港(深蓝紫) → 循环
const THEMES := [
        {
                "name": "霓虹闹市", "fog": Color("3A1C10"), "backdrop": Color("3A1C10"),
                "hemi": Color("552A16"), "neon": Color("00F0FF"), "grid": Color("00F0FF"),
                "fogDensity": 0.027, "landmark": "billboard", "mech": null,
        },
        {
                "name": "酸雨工业区", "fog": Color("14301A"), "backdrop": Color("1A3A22"),
                "hemi": Color("1E4A2A"), "neon": Color("39FF6A"), "grid": Color("39FF6A"),
                "fogDensity": 0.036, "landmark": null, "mech": "rain",
        },
        {
                "name": "云端天港", "fog": Color("101C3E"), "backdrop": Color("182A52"),
                "hemi": Color("1E3666"), "neon": Color("5E8BFF"), "grid": Color("8B9DFF"),
                "fogDensity": 0.021, "landmark": "platform", "mech": "lowg",
        },
        {
                "name": "电磁禁区", "fog": Color("26103A"), "backdrop": Color("2A1442"),
                "hemi": Color("36185A"), "neon": Color("B44BFF"), "grid": Color("B44BFF"),
                "fogDensity": 0.030, "landmark": "tesla", "mech": "laser",
        },
        {
                "name": "黄金金融区", "fog": Color("0E1E2E"), "backdrop": Color("142838"),
                "hemi": Color("1A3246"), "neon": Color("FFD166"), "grid": Color("FFD166"),
                "fogDensity": 0.024, "landmark": "towers", "mech": null,
        },
        ## 新章（画质细腻轮）：深海/极地/日落
        {
                "name": "深海隧道", "fog": Color("05202E"), "backdrop": Color("0A2E3E"),
                "hemi": Color("0E3A4A"), "neon": Color("18E0C8"), "grid": Color("18E0C8"),
                "fogDensity": 0.042, "landmark": null, "mech": "float",
        },
        {
                "name": "极地禁区", "fog": Color("1A2833"), "backdrop": Color("22323F"),
                "hemi": Color("2E4254"), "neon": Color("BFE8FF"), "grid": Color("8FD4FF"),
                "fogDensity": 0.033, "landmark": null, "mech": "ice",
        },
        {
                "name": "日落天台", "fog": Color("3A1B26"), "backdrop": Color("45202B"),
                "hemi": Color("5A2836"), "neon": Color("FF7A5C"), "grid": Color("FFB36B"),
                "fogDensity": 0.026, "landmark": null, "mech": null,
        },
]
const THEME_LEN := 1000.0  # 每章距离（米）

## 章节机制做实（引擎红利 B 半包）：THEMES[].mech 字段兑现
const MECH_CFG := {
        "rainSpeedMult": 0.94,   # 酸雨工业区：湿滑路面减速 6%
        "lowGravMult": 0.72,     # 云端天港：低重力（滞空跳）
        "lowJumpMult": 1.12,     # 天港起跳增幅（低重力下更高更飘）
        "laserWeightMult": 3.0,  # 电磁禁区：激光类候选池权重 ×3（不是最终概率精确 ×3）
        "floatGravMult": 0.85,   # 深海隧道：浮力（轻度滞空）
        "iceFrictionMult": 0.75, # 极地禁区：冰面横滑（摩擦衰减变慢）
}

const OVERCLOCK := {
        "chipsNeeded": 12,
        "duration": 5.0,
        "smashScore": 120,
}

const SCORING := {
        "perMeter": 1.0,
        "perChip": 50.0,
}

const WORLD := {
        "roadCycleLength": 42.0,  # 路面滚动周期；同时驱动 GDScript 与 Shader
        "buildingMinH": 6.0,
        "buildingMaxH": 30.0,
        "rainCount": 1200,        # 雨效默认粒子预算；设备档位可下调
}

const CAMERA := {
        "fovPortrait": 78.0,
        "fovLandscape": 66.0,
        "fovOverclockBoost": 9.0,
        "pos": {"x": 0.0, "y": 3.55, "z": 7.4},
        "lookAt": {"x": 0.0, "y": 1.1, "z": -10.0},
        "followX": 0.32,          # 跟随玩家横向位移比例
        "followY": 0.24,
}

## ================ · 道具系统 ================
const POWERUPS := {
        "magnet": {"duration": 9.0,  "color": Color("FF2E88"), "name": "磁暴核心", "desc": "大幅扩展芯片拾取范围"},  # 磁吸已移除，效果=宽判定框
        "shield": {"duration": 0.0,  "color": Color("3D7BFF"), "name": "离子护盾", "desc": "抵挡一次撞击"},
        "double": {"duration": 11.0, "color": Color("FCEE0A"), "name": "算力翻倍", "desc": "得分 ×2"},
        "board":  {"duration": 14.0, "color": Color("39FF6A"), "name": "悬浮滑板", "desc": "碾压低障碍 + 二段跳"},  #：骑乘形态
}
const POWERUP_CFG := {
        "spawnChance": 0.16,        # 每个模式的道具出现概率
        "minInterval": 5,          # 两次道具之间至少间隔的模式数
}

## ================ · 复活 ================
const REVIVE := {
        "countdown": 5.0,           # 复活决策倒计时（秒）
        "invincible": 2.6,          # 复活后无敌时间（秒）
        "clearRadius": 46.0,        # 复活时清除前方障碍的深度
}

## ================ · 成就 ================
const ACHIEVEMENTS := [
        {"id": "first_run",  "name": "初入夜之城", "desc": "完成第一局"},
        {"id": "dist_500",   "name": "街头新秀",   "desc": "单局奔跑 500m"},
        {"id": "dist_1500",  "name": "夜行传说",   "desc": "单局奔跑 1500m"},
        {"id": "dist_3000",  "name": "边缘行者",   "desc": "单局奔跑 3000m"},
        {"id": "combo_24",   "name": "数据链大师", "desc": "单链同步 24 次"},
        {"id": "combo_48",   "name": "赛博禅境",   "desc": "单链同步 48 次"},
        {"id": "oc_first",   "name": "初次超频",   "desc": "引爆一次超频"},
        {"id": "oc_smash10", "name": "拆迁队长",   "desc": "单局超频击碎 10 个障碍"},
        {"id": "shield_save","name": "死里逃生",   "desc": "离子护盾抵挡一次致命撞击"},
        {"id": "revived",    "name": "系统重启",   "desc": "复活一次并继续奔跑"},
        {"id": "chips_50",   "name": "芯片猎人",   "desc": "单局收集 50 枚芯片"},
        {"id": "power_all",  "name": "全副武装",   "desc": "单局集齐四种道具"},
        {"id": "boss_1",     "name": "头号通缉",   "desc": "首次从警用拦截中突围"},
]

## ================ · 每日任务 ================
const MISSION_DEFS := [
        # —— 今日累计（3 条常驻）——
        {"id": "m_dist",   "name": "街头马拉松", "desc": "今日累计奔跑 2000m",    "target": 2000.0, "unit": "m", "reward": 100},
        {"id": "m_chips",  "name": "数据收割",   "desc": "今日累计收集 80 枚芯片", "target": 80.0,   "unit": "",   "reward": 100},
        {"id": "m_smash",  "name": "暴力破解",   "desc": "今日累计击碎 15 个障碍", "target": 15.0,   "unit": "",   "reward": 100},
        # —— 单局池（v11：每日按日期轮换 3 条，完成领币）——
        {"id": "q_chips50", "name": "单局收割", "desc": "单局收集 50 枚芯片", "target": 50.0,   "unit": "", "reward": 200, "run": "chips"},
        {"id": "q_slide8",  "name": "贴地飞行", "desc": "单局滑铲闪避 8 次",   "target": 8.0,    "unit": "", "reward": 150, "run": "slide"},
        {"id": "q_800",     "name": "无伤奔袭", "desc": "单局狂奔 800m",      "target": 800.0,  "unit": "m", "reward": 150, "run": "dist"},
        {"id": "q_combo15", "name": "数据洪流", "desc": "单局最高连击 15",     "target": 15.0,   "unit": "", "reward": 200, "run": "combo"},
        {"id": "q_jump30",  "name": "弹跳引擎", "desc": "单局起跳 30 次",      "target": 30.0,   "unit": "", "reward": 150, "run": "jumps"},
        {"id": "q_2000",    "name": "深入禁区", "desc": "单局狂奔 2000m",     "target": 2000.0, "unit": "m", "reward": 300, "run": "dist"},
]

## ================ · 设置默认值 ================
const DEFAULT_SETTINGS := {
        "musicVol": 0.8,
        "sfxVol": 1.0,
        "haptics": true,
        "cameraShake": 0.75,
        "showFps": false,
        "dda": true,           #：动态难度（连败护航/连胜加压，仅无尽局）
}
