extends Node3D
## 아바타·CoreHUD 임시 숨김 예산 시험 (ed003ce5).
## 규칙: 최대 30초, 보이는 동안 실시간 1초당 0.2초 충전, 만료 시 자동 표시, 시작에 최소 0.1초 예산 필요.
## 실시간(OS ticks) 기준이므로 Engine.time_scale=0 으로도 소모를 멈출 수 없어야 한다.
## 사용자 인자 `--quick` 이면 30초 소진 시험을 건너뛴다(NOT_COVERED로 기록).

const PFTest = preload("res://lib/pf_test.gd")
const C := "ed003ce5"

var t: PFTest
var pf: Object
var avatar: Node3D


func _init() -> void:
	t = PFTest.new("hide_budget")


func _wait(sec: float) -> void:
	# process_always=true, ignore_time_scale=true: time_scale=0 이어도 실시간으로 기다린다.
	await get_tree().create_timer(sec, true, false, true).timeout


func _ready() -> void:
	await PFTest.frames(get_tree(), 2)
	pf = PFTest.pf()
	avatar = (pf.get_local_avatar() if pf else null) as Node3D
	if not t.check("setup_avatar_and_hud", C, pf != null and avatar != null and avatar.visible and pf.is_platform_hud_active()):
		t.finish(get_tree())
		return

	var s: Dictionary = pf.get_avatar_hide_state()
	t.check("initial_state", C, s.get("hidden") == false and is_equal_approx(s.get("maxBudgetSeconds", 0.0), 30.0) and is_equal_approx(s.get("rechargeRatePerSecond", 0.0), 0.2) and is_equal_approx(s.get("minStartBudgetSeconds", 0.0), 0.1) and absf(s.get("budgetSeconds", 0.0) - 30.0) < 0.01, str(s))

	# 잘못된 요청은 거부
	t.check("reject_nonpositive_or_nan", C, not pf.request_temporary_avatar_hide(-1.0) and not pf.request_temporary_avatar_hide(0.0) and not pf.request_temporary_avatar_hide(NAN) and not pf.request_temporary_avatar_hide(INF) and not pf.is_avatar_temporarily_hidden())

	# 30초 초과 요청은 30초로 제한
	var ok: bool = pf.request_temporary_avatar_hide(1000.0)
	var rem: float = pf.get_avatar_hide_remaining_seconds()
	t.check("request_capped_at_30s", C, ok and rem <= 30.0 + 1e-6 and rem > 29.5, "ok=%s remaining=%.4f" % [ok, rem])
	await PFTest.frames(get_tree(), 1)
	t.check("avatar_hidden_by_engine", C, pf.is_avatar_temporarily_hidden() and not avatar.visible)
	# 숨김 중 사용자 스크립트가 visible을 되돌릴 수 없다(봉인). 엔진만 바꾼다.
	avatar.visible = true
	t.check("user_cannot_toggle_during_hide", C, not avatar.visible)

	# time_scale=0 에서도 실시간으로 소모
	Engine.time_scale = 0.0
	var b0: float = pf.get_avatar_hide_budget_seconds()
	await _wait(1.0)
	var b1: float = pf.get_avatar_hide_budget_seconds()
	Engine.time_scale = 1.0
	t.check("budget_drains_in_real_time_even_with_time_scale_0", C, b0 - b1 > 0.85 and b0 - b1 < 1.6, "drained=%.3f over ~1.0s" % (b0 - b1))

	pf.end_temporary_avatar_hide()
	await PFTest.frames(get_tree(), 1)
	t.check("end_hide_restores_visibility", C, not pf.is_avatar_temporarily_hidden() and avatar.visible)

	# 충전: 보이는 동안 1초당 0.2초
	var r0: float = pf.get_avatar_hide_budget_seconds()
	await _wait(1.5)
	var r1: float = pf.get_avatar_hide_budget_seconds()
	var rate := (r1 - r0) / 1.5
	t.check("recharge_0_2_per_second", C, rate > 0.15 and rate < 0.3 and r1 < 30.0, "rate=%.3f/s budget %.3f->%.3f" % [rate, r0, r1])

	# 다시 요청하면 남은 예산까지만 허용(30초 미만)
	var b_before: float = pf.get_avatar_hide_budget_seconds()
	pf.request_temporary_avatar_hide(1000.0)
	var rem2: float = pf.get_avatar_hide_remaining_seconds()
	t.check("request_capped_by_remaining_budget", C, rem2 <= b_before + 0.05 and rem2 < 29.9, "remaining=%.3f budget=%.3f" % [rem2, b_before])
	# 숨김 중 재요청으로 늘릴 수 없음
	pf.request_temporary_avatar_hide(1000.0)
	t.check("rerequest_cannot_exceed_budget", C, pf.get_avatar_hide_remaining_seconds() <= pf.get_avatar_hide_budget_seconds() + 1e-6)
	pf.end_temporary_avatar_hide()

	# 짧은 숨김은 만료 시 자동 표시
	pf.request_temporary_avatar_hide(0.3)
	await _wait(0.7)
	await PFTest.frames(get_tree(), 1)
	t.check("auto_show_on_expiry", C, not pf.is_avatar_temporarily_hidden() and avatar.visible)

	# CoreHUD 예산(별도 계정)
	var hb0: float = pf.get_hud_hide_budget_seconds()
	var hok: bool = pf.request_temporary_hud_hide(1000.0)
	await PFTest.frames(get_tree(), 1)
	t.check("hud_hide_capped_and_applied", C, hok and pf.get_hud_hide_remaining_seconds() <= 30.0 + 1e-6 and pf.is_hud_temporarily_hidden() and not pf.is_platform_hud_active(),
			"hud_active=%s remaining=%.3f" % [pf.is_platform_hud_active(), pf.get_hud_hide_remaining_seconds()])
	t.check("hud_budget_independent_of_avatar", C, absf(hb0 - 30.0) < 0.05, "hud budget before=%.3f" % hb0)
	pf.end_temporary_hud_hide()
	await PFTest.frames(get_tree(), 1)
	t.check("hud_end_restores", C, not pf.is_hud_temporarily_hidden() and pf.is_platform_hud_active())

	# 통합 API
	var both: bool = pf.request_temporary_platform_ui_hide(2.0)
	await PFTest.frames(get_tree(), 1)
	t.check("platform_ui_hide_hides_both", C, both and pf.is_avatar_temporarily_hidden() and pf.is_hud_temporarily_hidden() and not avatar.visible and not pf.is_platform_hud_active())
	pf.end_temporary_platform_ui_hide()
	await PFTest.frames(get_tree(), 1)
	t.check("platform_ui_end_restores_both", C, not pf.is_avatar_temporarily_hidden() and not pf.is_hud_temporarily_hidden() and avatar.visible and pf.is_platform_hud_active())

	if OS.get_cmdline_user_args().has("--quick"):
		t.not_covered("budget_exhaustion_30s", C, "--quick 로 건너뜀(실시간 약 30초 필요)")
	else:
		# 예산 전부 소진 → 자동 표시 → 0.1초 미만이면 재시작 거부 → 충전 후 다시 허용
		var full: float = pf.get_avatar_hide_budget_seconds()
		pf.request_temporary_avatar_hide(30.0)
		var granted: float = pf.get_avatar_hide_remaining_seconds()
		await _wait(granted + 0.15)
		await PFTest.frames(get_tree(), 1)
		var after: float = pf.get_avatar_hide_budget_seconds()
		t.check("exhaustion_auto_shows", C, not pf.is_avatar_temporarily_hidden() and avatar.visible and after < 0.1,
				"granted=%.3f (budget %.3f) budget_after=%.3f" % [granted, full, after])
		var denied: bool = not pf.request_temporary_avatar_hide(5.0)
		t.check("exhausted_budget_denies_restart", C, denied and avatar.visible, "budget=%.3f" % pf.get_avatar_hide_budget_seconds())
		await _wait(1.0)
		var again: bool = pf.request_temporary_avatar_hide(5.0)
		var rem3: float = pf.get_avatar_hide_remaining_seconds()
		t.check("recharged_budget_allows_short_hide", C, again and rem3 < 0.4, "remaining=%.3f" % rem3)
		pf.end_temporary_avatar_hide()
	t.finish(get_tree())
