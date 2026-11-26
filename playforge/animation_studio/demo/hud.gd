extends CanvasLayer

const FG := Color("#e3f1e9")
const DIM := Color("#acbfb8")
const FOCUS_NAMES := ["루트 이동", "발 디딤", "손 소켓"]

var lab
var _views: Array[Button] = []
var _rates: Array[Button] = []


func _ready() -> void:
	# The engine fork reserves the upper-left corner for its platform controls.
	if Engine.has_singleton("PlayForgePlatform"):
		$Layout/Header.position.y = 68
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans"])
	var skin := Theme.new()
	skin.default_font = font
	skin.default_font_size = 16
	skin.set_color("font_color", "Label", FG)
	skin.set_color("font_color", "Button", FG)
	skin.set_color("font_pressed_color", "Button", Color("#143732"))
	skin.set_stylebox("normal", "Button", _box(Color("#293d3c"), 6, 12, 6))
	skin.set_stylebox("hover", "Button", _box(Color("#38504b"), 6, 12, 6))
	skin.set_stylebox("pressed", "Button", _box(Color("#94d9be"), 6, 12, 6))
	skin.set_stylebox("panel", "PanelContainer", _box(Color("#152626f5"), 10, 18, 12))
	$Layout.theme = skin
	%Title.add_theme_font_size_override("font_size", 25)
	%Description.modulate = DIM


func _box(color: Color, radius: int, horizontal: int, vertical: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.content_margin_left = horizontal
	box.content_margin_right = horizontal
	box.content_margin_top = vertical
	box.content_margin_bottom = vertical
	return box


func bind(director: Node3D) -> void:
	lab = director
	%HeroSample.pressed.connect(func(): get_tree().change_scene_to_file("res://hero/hero.tscn"))
	%Gallery.pressed.connect(func(): get_tree().change_scene_to_file("res://catalog/gallery.tscn"))
	for i in FOCUS_NAMES.size():
		var button := _choice(FOCUS_NAMES[i], %Views)
		button.pressed.connect(lab.set_focus.bind(i))
		_views.append(button)
	for rate in [0.5, 1.0, 2.0]:
		var button := _choice("%s×" % str(rate).trim_suffix(".0"), %Rates)
		button.pressed.connect(lab.set_speed.bind(rate))
		_rates.append(button)
	%Play.pressed.connect(func(): lab.set_running(not lab.running))
	%Step.pressed.connect(func():
		lab.set_running(false)
		lab.step_tick()
	)
	%Reset.pressed.connect(lab.reset_demo)
	%Turn.pressed.connect(lab.turn_character)


func _choice(label: String, parent: Container) -> Button:
	var button := Button.new()
	button.text = label
	button.toggle_mode = true
	parent.add_child(button)
	return button


func refresh() -> void:
	if not lab or _views.is_empty():
		return
	var phase: float = lab.player.current_animation_position if lab.player.is_animation_active() else 0.0
	%Phase.phase = phase
	%Phase.queue_redraw()
	%Clock.text = "%.2f / 1.00 s" % phase
	%Play.text = "일시정지" if lab.running else "재생"
	%Distance.text = "%.2f m" % lab.distance_traveled
	%Contacts.text = "L  %d     R  %d" % [lab.left_steps, lab.right_steps]
	%Contacts.modulate = lab.STEP_LEFT if lab.last_step == "L" else (lab.STEP_RIGHT if lab.last_step == "R" else FG)
	%SocketLabel.visible = lab.focus == 2
	%SocketError.visible = lab.focus == 2
	%SocketError.text = "%.3f mm" % lab.socket_error_mm
	var forward: Vector3 = lab.character.global_basis.x
	%Heading.text = "%d°" % posmod(roundi(rad_to_deg(atan2(-forward.z, forward.x))), 360)
	for i in _views.size():
		_views[i].set_pressed_no_signal(i == lab.focus)
	for i in _rates.size():
		_rates[i].set_pressed_no_signal(is_equal_approx(lab.speed, [0.5, 1.0, 2.0][i]))
	%Description.text = [
		"진행 방향을 돌려 루트 변위가 적용되는 축을 확인하세요.",
		"왼발과 오른발 이벤트가 발생한 위치에 색 표식이 남습니다.",
		"손이 회전할 때 공구가 소켓의 위치와 각도를 유지합니다.",
	][lab.focus]
