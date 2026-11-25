extends Node3D
## 아바타 초상 UI(표현 모드 1·2) 최소 크기 봉인 시험 (fe0b4fe1).
## 초상 UI는 PlayForgePlatform.get_avatar_portrait_ui() 로 사용자 스크립트에 노출되는 봉인 Control 이다.

const PFTest = preload("res://lib/pf_test.gd")
const C_UI := "fe0b4fe1"
const C_SEAL := "a18fb005"

var t: PFTest


func _init() -> void:
	t = PFTest.new("portrait_seal")


func _ready() -> void:
	await PFTest.frames(get_tree(), 2)
	var pf := PFTest.pf()
	if not t.check("setup_singleton", C_UI, pf != null):
		t.finish(get_tree())
		return
	t.check("portrait_min_size_upper_body", C_UI, pf.get_portrait_min_size(0) == Vector2(128, 128), str(pf.get_portrait_min_size(0)))
	t.check("portrait_min_size_full_body", C_UI, pf.get_portrait_min_size(1) == Vector2(160, 240), str(pf.get_portrait_min_size(1)))
	# 사용자 스크립트가 최소 크기 하한 자체를 낮출 수 없어야 한다(바인딩 없음).
	t.check("set_platform_min_size_not_script_visible", C_UI, not ClassDB.class_has_method("Control", "set_platform_min_size") and ClassDB.class_has_method("Control", "get_platform_min_size"))

	var ret: Variant = pf.set_avatar_presentation_mode(1, Vector2(150, 150), 0)
	await PFTest.frames(get_tree(), 2)
	var p := pf.get_avatar_portrait_ui() as Control
	if not t.check("setup_portrait_mode1_sealed", C_UI, p != null and ret == p and p.is_inside_tree() and PFTest.sealed(p) and pf.get_avatar_presentation_mode() == 1,
			"portrait=%s mode=%d" % [p, pf.get_avatar_presentation_mode()]):
		t.finish(get_tree())
		return
	t.check("portrait_platform_min_size_128", C_UI, PFTest.platform_min_size(p) == Vector2(128, 128), str(PFTest.platform_min_size(p)))
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var new_panel := func():
		var c := PanelContainer.new()
		c.size = Vector2(200, 200)
		return c

	await t.attempt(get_tree(), "set_size_below_min_clamped", C_UI, p,
			func(n): n.size = Vector2(10, 10),
			func(n): return n.size.x >= 128 and n.size.y >= 128, new_panel, canvas)
	await t.attempt(get_tree(), "custom_minimum_size_below_min_clamped", C_UI, p,
			func(n): n.custom_minimum_size = Vector2(1, 1),
			func(n): return n.custom_minimum_size.x >= 128 and n.custom_minimum_size.y >= 128 if n == p else n.custom_minimum_size != Vector2(1, 1),
			new_panel, canvas)
	await t.attempt(get_tree(), "custom_maximum_size_below_min_rejected", C_UI, p,
			func(n): n.custom_maximum_size = Vector2(40, 40),
			func(n): return n.custom_maximum_size != Vector2(40, 40), new_panel, canvas)
	await t.attempt(get_tree(), "scale_below_1_blocked", C_UI, p,
			func(n): n.scale = Vector2(0.5, 0.5),
			func(n): return n.scale == Vector2.ONE, new_panel, canvas)
	await t.attempt(get_tree(), "modulate_alpha_floor_085", C_UI, p,
			func(n): n.modulate = Color(1, 1, 1, 0.0),
			func(n): return is_equal_approx(n.modulate.a, 0.85), new_panel, canvas)
	await t.attempt(get_tree(), "visible_false_blocked", C_SEAL, p,
			func(n): n.visible = false,
			func(n): return n.visible, new_panel, canvas)
	await t.attempt(get_tree(), "queue_free_blocked", C_SEAL, p,
			func(n): n.queue_free(),
			func(n): return n.is_inside_tree(), new_panel, canvas)
	t.check("size_still_ge_min", C_UI, p.size.x >= 128 and p.size.y >= 128, str(p.size))
	# 확대(>= 1.0)는 허용
	p.scale = Vector2(1.25, 1.25)
	t.check("scale_up_allowed", C_UI, p.scale == Vector2(1.25, 1.25), str(p.scale))

	# 전신(모드 2) 하한은 160x240
	var p2: Variant = pf.set_avatar_presentation_mode(2, Vector2(50, 50), 0)
	await PFTest.frames(get_tree(), 2)
	var pp := pf.get_avatar_portrait_ui() as Control
	t.check("mode2_full_body_min_160x240", C_UI, pp != null and PFTest.platform_min_size(pp) == Vector2(160, 240) and pp.size.x >= 160 and pp.size.y >= 240,
			"min=%s size=%s" % [PFTest.platform_min_size(pp) if pp else null, pp.size if pp else null])
	t.check("mode2_requested_small_size_raised", C_UI, pp != null and pp.custom_minimum_size.x >= 160 and pp.custom_minimum_size.y >= 240, str(pp.custom_minimum_size if pp else null))
	pp.size = Vector2(100, 100)
	await PFTest.frames(get_tree(), 1)
	t.check("mode2_size_below_min_clamped", C_UI, pp.size.x >= 160 and pp.size.y >= 240, str(pp.size))

	# 모드 0 복귀(초상 UI 제거)는 엔진을 중단시키므로 portrait_mode_switch 스위트로 분리했다.
	t.finish(get_tree())
