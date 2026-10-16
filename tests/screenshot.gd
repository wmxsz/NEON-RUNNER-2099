extends Node
## 视觉实证：菜单/游戏内/BOSS/超频四态截图（配合 Xvfb+VLM 走画面验收）

func _ready() -> void:
    var ps: PackedScene = load("res://scenes/main.tscn")
    var main: Node = ps.instantiate()
    get_tree().root.add_child.call_deferred(main)
    await get_tree().process_frame
    await get_tree().process_frame
    main._start_run()
    await get_tree().create_timer(2.5).timeout
    _shot("/tmp/v110_game.png")
    # BOSS 哨戒机 3D
    main.game.boss_event.next_at = 0.0
    await get_tree().create_timer(1.5).timeout
    _shot("/tmp/v110_boss.png")
    # 超频 + 冲击波
    main.game.boss_event.active = false
    main.world.boss_show(false)
    main.game.overclock.charge = 12
    main._activate_overclock()
    await get_tree().create_timer(0.25).timeout
    _shot("/tmp/v110_oc.png")
    print("[shot] 三张完成")
    get_tree().quit(0)

func _shot(path: String) -> void:
    var img: Image = get_viewport().get_texture().get_image()
    img.save_png(path)
    print("[shot] %s" % path)
