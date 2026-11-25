extends Node3D
## CoreHUD(좌상단 플랫폼 바, CanvasLayer 128) 변조 차단과 사용자 CanvasLayer.layer <= 100 강제 시험.
## CoreHUD는 사용자 트리 조회에서 숨겨지므로 SceneTree.node_added 로 참조를 잡는다(잡히지 않으면 setup FAIL).
## 가드 커밋: a18fb005(CanvasLayer·Node 봉인, layer 클램프), fe0b4fe1(Control 축소·알파 하한)

const PFTest = preload("res://lib/pf_test.gd")
const EvilLayer = preload("res://lib/evil_canvas_layer.gd")
const C_SEAL := "a18fb005"
const C_UI := "fe0b4fe1"

var t: PFTest
var captured := {}


func _init() -> void:
	t = PFTest.new("corehud_seal")
	(Engine.get_main_loop() as SceneTree).node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if not captured.has(n.name):
		captured[n.name] = n


func _ready() -> void:
	await PFTest.frames(get_tree(), 2)
	var pf := PFTest.pf()
	var hud := captured.get("PlayForgeCoreHUD") as CanvasLayer
	var bar := captured.get("TopLeftPlatformBar") as Control
	var menu_btn := captured.get("PlayHubMenuButton") as Control
	if not t.check("setup_corehud_captured_and_sealed", C_SEAL, pf != null and hud != null and bar != null and menu_btn != null and PFTest.sealed(hud) and PFTest.sealed(bar) and PFTest.sealed(menu_btn)):
		t.finish(get_tree())
		return
	var root := get_tree().root
	var holder := Node.new()
	add_child(holder)
	var new_layer := func(): return CanvasLayer.new()
	var new_panel := func(): return PanelContainer.new()

	# --- CanvasLayer(CoreHUD) ---
	await t.attempt(get_tree(), "hud_visible_false_blocked", C_SEAL, hud,
			func(n): n.visible = false,
			func(n): return n.visible, new_layer, root)
	t.check("hud_still_active_after_hide_attempts", C_SEAL, pf.is_platform_hud_active())
	await t.attempt(get_tree(), "hud_layer_change_blocked", C_SEAL, hud,
			func(n): n.layer = 5,
			func(n): return n.layer == (128 if n == hud else 1), new_layer, root)
	await t.attempt(get_tree(), "hud_offset_blocked", C_SEAL, hud,
			func(n): n.offset = Vector2(5000, 5000),
			func(n): return n.offset == Vector2.ZERO, new_layer, root)
	await t.attempt(get_tree(), "hud_scale_blocked", C_SEAL, hud,
			func(n): n.scale = Vector2(0.01, 0.01),
			func(n): return n.scale == Vector2.ONE, new_layer, root)
	await t.attempt(get_tree(), "hud_transform_blocked", C_SEAL, hud,
			func(n): n.transform = Transform2D(0.0, Vector2(0.01, 0.01), 0.0, Vector2(-9000, -9000)),
			func(n): return n.transform == Transform2D.IDENTITY, new_layer, root)
	await t.attempt(get_tree(), "hud_queue_free_blocked", C_SEAL, hud,
			func(n): n.queue_free(),
			func(n): return n.is_inside_tree(), new_layer, root)
	await t.attempt(get_tree(), "hud_remove_child_blocked", C_SEAL, hud,
			func(n): n.get_parent().remove_child(n),
			func(n): return n.get_parent() == root, new_layer, root)
	await t.attempt(get_tree(), "hud_reparent_blocked", C_SEAL, hud,
			func(n): n.reparent(holder),
			func(n): return n.get_parent() == root, new_layer, root)
	await t.attempt(get_tree(), "hud_set_script_blocked", C_SEAL, hud,
			func(n): n.set_script(EvilLayer),
			func(n): return n.get_script() == null, new_layer, root)

	# --- 플랫폼 바 Control ---
	await t.attempt(get_tree(), "bar_visible_false_blocked", C_SEAL, bar,
			func(n): n.visible = false,
			func(n): return n.visible, new_panel, holder_canvas())
	await t.attempt(get_tree(), "bar_scale_below_1_blocked", C_UI, bar,
			func(n): n.scale = Vector2(0.2, 0.2),
			func(n): return n.scale == Vector2.ONE, new_panel, holder_canvas())
	await t.attempt(get_tree(), "bar_modulate_alpha_floor_085", C_UI, bar,
			func(n): n.modulate = Color(1, 1, 1, 0.0),
			func(n): return is_equal_approx(n.modulate.a, 0.85), new_panel, holder_canvas())
	await t.attempt(get_tree(), "bar_self_modulate_alpha_floor_085", C_UI, bar,
			func(n): n.self_modulate = Color(1, 1, 1, 0.1),
			func(n): return is_equal_approx(n.self_modulate.a, 0.85), new_panel, holder_canvas())
	await t.attempt(get_tree(), "bar_queue_free_blocked", C_SEAL, bar,
			func(n): n.queue_free(),
			func(n): return n.is_inside_tree(), new_panel, holder_canvas())
	await t.attempt(get_tree(), "menu_button_reparent_blocked", C_SEAL, menu_btn,
			func(n): n.reparent(holder),
			func(n): return n.get_parent() != holder, new_panel, holder_canvas())
	await t.attempt(get_tree(), "bar_process_mode_blocked", C_SEAL, bar,
			func(n): n.process_mode = Node.PROCESS_MODE_DISABLED,
			func(n): return n.process_mode != Node.PROCESS_MODE_DISABLED, new_panel, holder_canvas())
	# 알파 하한 경계: 0.85 이상은 사용자 값 그대로 허용
	bar.modulate = Color(1, 1, 1, 0.9)
	t.check("bar_modulate_alpha_above_floor_allowed", C_UI, is_equal_approx(bar.modulate.a, 0.9), "a=%s" % bar.modulate.a)
	t.check("hud_still_active_at_end", C_SEAL, pf.is_platform_hud_active() and hud.layer == 128)

	# --- 사용자 CanvasLayer.layer <= 100 강제 (a18fb005 canvas_layer.cpp) ---
	var cases := [[500, 100], [129, 100], [101, 100], [100, 100], [7, 7], [-20, -20]]
	for c in cases:
		var cl := CanvasLayer.new()
		add_child(cl)
		var v0 := PFTest.violations()
		cl.layer = c[0]
		var dv := PFTest.violations() - v0
		var want_violation: bool = c[0] > 100
		t.check("user_canvaslayer_layer_%d_becomes_%d" % [c[0], c[1]], C_SEAL, cl.layer == c[1] and (dv >= 1) == want_violation,
				"layer=%d violations+%d" % [cl.layer, dv])
		cl.queue_free()
	# 트리에 넣기 전에 설정해도 클램프돼야 한다
	var pre := CanvasLayer.new()
	pre.layer = 1000
	t.check("user_canvaslayer_clamped_before_enter_tree", C_SEAL, pre.layer == 100, "layer=%d" % pre.layer)
	pre.free()
	t.finish(get_tree())


var _canvas: CanvasLayer


func holder_canvas() -> CanvasLayer:
	if _canvas == null:
		_canvas = CanvasLayer.new()
		_canvas.name = "UserCanvas"
		add_child(_canvas)
	return _canvas
