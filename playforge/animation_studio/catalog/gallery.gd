extends Control

const CATALOG := "res://catalog/catalog.json"
const BASE := "res://catalog/"

var entries: Array = []
var visible_indices: Array[int] = []
var stage := Node3D.new()
var listing := ItemList.new()
var search := LineEdit.new()
var back := Button.new()
var products := OptionButton.new()
var families := OptionButton.new()
var heading := Label.new()
var source_path := Label.new()
var measurements := Label.new()
var count_text := Label.new()
var scope_text := Label.new()
var probe: Node3D
var selected_index := -1


func _ready() -> void:
	var skin := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans"])
	skin.default_font = font
	skin.default_font_size = 16
	theme = skin
	var background := ColorRect.new()
	background.color = Color("#152626")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	if parsed is Array:
		entries = parsed
	_build_controls()
	_filter("")


func _build_controls() -> void:
	var padding := MarginContainer.new()
	add_child(padding)
	padding.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		padding.add_theme_constant_override("margin_" + side, 12)
	var row := HSplitContainer.new()
	padding.add_child(row)
	var sidebar := VBoxContainer.new()
	row.add_child(sidebar)
	sidebar.custom_minimum_size.x = 310
	if Engine.has_singleton("PlayForgePlatform"):
		var spacer := Control.new()
		spacer.custom_minimum_size.y = 58
		sidebar.add_child(spacer)
	back.text = "← 모션 실험실"
	sidebar.add_child(back)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://demo/animation_lab.tscn"))
	products.add_item("전체 제품 (Animation + Behavior)")
	products.add_item("Animation")
	products.add_item("Behavior")
	sidebar.add_child(products)
	products.item_selected.connect(func(_index: int): _filter(search.text))
	families.add_item("전체 분야")
	var categories: Array[String] = []
	for entry in entries:
		var group := _family(str(entry.path))
		if not categories.has(group):
			categories.append(group)
	categories.sort()
	for group in categories:
		families.add_item(group)
	sidebar.add_child(families)
	families.item_selected.connect(func(_index: int): _filter(search.text))
	search.placeholder_text = "Animation · Behavior 사례 검색"
	sidebar.add_child(search)
	sidebar.add_child(count_text)
	sidebar.add_child(listing)
	listing.size_flags_vertical = Control.SIZE_EXPAND_FILL
	listing.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	listing.item_selected.connect(func(index: int): select_entry(visible_indices[index]))
	search.text_changed.connect(_filter)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(body)
	for label in [heading, source_path, scope_text, measurements]:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(label)
	heading.add_theme_font_size_override("font_size", 24)
	source_path.modulate = Color("#a5c8ba")
	var view := SubViewportContainer.new()
	view.stretch = true
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(view)
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.add_child(viewport)
	viewport.add_child(stage)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(3.5, 2.2, 5.0)
	camera.look_at(Vector3.UP)
	camera.fov = 39
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-1, -0.6, 0)
	light.shadow_enabled = true
	stage.add_child(light)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("#344b4b")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.65
	stage.add_child(world)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(26, 26)
	var material := ShaderMaterial.new()
	material.shader = preload("../demo/floor.gdshader")
	plane.material = material
	floor_mesh.mesh = plane
	stage.add_child(floor_mesh)
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	ground.add_child(shape)
	stage.add_child(ground)


func _family(path: String) -> String:
	var parts := path.split("/")
	var prefix := parts[0] if not parts.is_empty() else "Animation"
	var api := parts.find("Api")
	if api >= 0 and api + 1 < parts.size():
		return "%s / %s" % [prefix, parts[api + 1]]
	if prefix == "Behavior" and parts.size() >= 2:
		return "Behavior / %s" % parts[1]
	return "%s / Compression timings" % prefix


func _filter(query: String) -> void:
	listing.clear()
	visible_indices.clear()
	var selected_product := ""
	if products.selected == 1:
		selected_product = "animation"
	elif products.selected == 2:
		selected_product = "behavior"
	for i in entries.size():
		var entry: Dictionary = entries[i]
		var prod := str(entry.get("product", "animation")).to_lower()
		if not selected_product.is_empty() and prod != selected_product:
			continue
		if families.selected > 0 and _family(str(entry.path)) != families.get_item_text(families.selected):
			continue
		if query.is_empty() or query.to_lower() in (str(entry.name) + " " + str(entry.path)).to_lower():
			visible_indices.append(i)
			listing.add_item(_title(entry))
			listing.set_item_tooltip(listing.item_count - 1, str(entry.path))
	count_text.text = "%d / %d 사례" % [visible_indices.size(), entries.size()]
	if visible_indices.is_empty():
		_clear_probe()
		heading.text = "검색 결과 없음"
		source_path.text = ""
		scope_text.text = ""
		measurements.text = ""
	else:
		listing.select(0)
		select_entry(visible_indices[0])


func _title(entry: Dictionary) -> String:
	var parent_name := str(entry.get("case", "")).trim_suffix("Demo")
	var variant := str(entry.name).trim_suffix("Demo")
	return parent_name if parent_name == variant else "%s · %s" % [parent_name, variant]


func _clear_probe() -> void:
	if is_instance_valid(probe):
		stage.remove_child(probe)
		probe.free()
	probe = null
	selected_index = -1


func select_entry(index: int) -> void:
	_clear_probe()
	if index < 0 or index >= entries.size():
		return
	var entry: Dictionary = entries[index]
	var path := str(entry.path)
	var lower := path.to_lower()
	var prod := str(entry.get("product", "animation")).to_lower()
	var filename := "runtime_cases.gd"
	if prod == "behavior" or lower.begins_with("behavior/"):
		filename = "behavior_cases.gd"
	elif "/compression/timings/" in lower:
		filename = "timing_cases.gd"
	elif not "multithread" in lower:
		if "/ragdoll/" in lower or "/inversekinematics/" in lower or "/skeletalmapping/" in lower or "/retargeting/" in lower:
			filename = "rig_cases.gd"
		elif "/compression/" in lower or "/blending/" in lower or "/playback/" in lower or "/layeringandpartitions/" in lower:
			filename = "clip_cases.gd"
	var script := load(BASE + filename) as Script
	heading.text = _title(entry)
	source_path.text = "%s · %s" % [entry.get("case", ""), path.get_base_dir()]
	scope_text.text = "원본 사례의 핵심 동작을 재현합니다. SDK 고유 코덱·벤치마크 설정은 같은 계열의 Godot 실험을 공유합니다."
	if entry.get("registration") == "source_only_unregistered":
		scope_text.text += "  ·  SDK 미등록 소스"
	elif str(entry.get("registration", "")).begins_with("conditional"):
		scope_text.text += "  ·  SDK 조건부 등록"
	if script == null or not script.can_instantiate():
		measurements.text = "이 사례의 실행 스크립트를 불러올 수 없습니다."
		return
	probe = script.new()
	stage.add_child(probe)
	probe.call("start_case", path, str(entry.name))
	selected_index = index
	_refresh()


func _process(_delta: float) -> void:
	if is_instance_valid(probe):
		_refresh()


func _refresh() -> void:
	measurements.text = "Godot 재현 범위 · " + str(probe.call("status_text"))
