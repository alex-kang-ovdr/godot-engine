@tool
class_name AnimationStudioTheme
extends RefCounted
## Shared PlayForge Animation Studio v3 design tokens, StyleBoxFlat builders,
## and 16x16 vector SVG icon cache (loaded directly via Image.load_svg_from_string
## so icons work identically in Godot Editor, Web Editor WASM, and headless tests
## without requiring .svg.import sidecar files).

const ICONS_DIR := "res://addons/animation_studio/icons"

# Exact palette from design-tokens.json
const BG_EDITOR := Color("#12151b")
const BG_TOPBAR := Color("#181d26")
const BG_CANVAS := Color("#151a22")
const SURFACE_CARD := Color("#1a202b")
const SURFACE_NODE := Color("#1e2430")
const SURFACE_NODE_HOVER := Color("#253042")
const SURFACE_NODE_ACTIVE := Color("#1c3638")
const SURFACE_INPUT := Color("#141922")

const BORDER_BASE := Color("#2b3344")
const BORDER_NODE := Color("#3c4a60")
const BORDER_CONTROL := Color("#3c465a")

const TEXT_PRIMARY := Color("#e8f0f8")
const TEXT_SECONDARY := Color("#dce6f4")
const TEXT_MUTED := Color("#9eb0c7")
const TEXT_DIM := Color("#788ba3")

const ACCENT_AMBER := Color("#f39c2b")
const ACCENT_AMBER_DIM := Color("#2e2315")
const ACCENT_AMBER_TEXT := Color("#ffd08a")

const ACCENT_TEAL := Color("#2cc7b8")
const ACCENT_TEAL_DIM := Color("#1d2b2a")
const ACCENT_TEAL_TEXT := Color("#62e6d8")

const SEMANTIC_DANGER := Color("#d96b6b")
const SEMANTIC_DANGER_DIM := Color("#2a171b")
const SEMANTIC_SUCCESS := Color("#3dd68c")
const SEMANTIC_SUCCESS_DIM := Color("#172d25")
const SEMANTIC_INFO := Color("#58a6ff")
const SEMANTIC_VIOLET := Color("#a78bfa")

# Havok Traversal Annotation colors
const TRAV_VAULT := Color("#f59e0b")
const TRAV_CLIMB := Color("#38bdf8")
const TRAV_LEAP := Color("#e879f9")
const TRAV_DROP := Color("#4ade80")
const TRAV_COVER := Color("#ef4444")

static var _icon_cache: Dictionary = {}


static func get_icon(icon_id: String, tint: Color = Color.WHITE, size_px: int = 16) -> Texture2D:
	var key := "%s|%s|%d" % [icon_id, tint.to_html(false), size_px]
	if _icon_cache.has(key):
		return _icon_cache[key] as Texture2D

	var path := "%s/%s.svg" % [ICONS_DIR, icon_id]
	if not FileAccess.file_exists(path):
		return null
	var svg_text := FileAccess.get_file_as_string(path)
	if svg_text.is_empty():
		return null
	var hex := "#" + tint.to_html(false)
	svg_text = svg_text.replace("#ffffff", hex).replace("currentColor", hex)
	var img := Image.new()
	var scale := maxf(0.5, float(size_px) / 16.0)
	if img.load_svg_from_string(svg_text, scale) != OK:
		return null
	var tex := ImageTexture.create_from_image(img)
	_icon_cache[key] = tex
	return tex


static func make_box(
	bg: Color = SURFACE_CARD,
	border: Color = BORDER_BASE,
	radius: int = 6,
	border_w: int = 1,
	pad_x: int = 8,
	pad_y: int = 6,
	left_accent_w: int = 0
) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_left = left_accent_w if left_accent_w > 0 else border_w
	sb.border_width_top = border_w
	sb.border_width_right = border_w
	sb.border_width_bottom = border_w
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	sb.content_margin_left = float(pad_x)
	sb.content_margin_right = float(pad_x)
	sb.content_margin_top = float(pad_y)
	sb.content_margin_bottom = float(pad_y)
	return sb


static func style_card(panel: PanelContainer, selected: bool = false, accent: Color = ACCENT_AMBER) -> void:
	if selected:
		var bg := Color(accent.r * 0.14 + 0.10, accent.g * 0.14 + 0.12, accent.b * 0.14 + 0.15, 1.0)
		panel.add_theme_stylebox_override("panel", make_box(bg, accent, 5, 1, 8, 6, 3))
	else:
		panel.add_theme_stylebox_override("panel", make_box(SURFACE_NODE, BORDER_BASE, 5, 1, 8, 6, 0))


static func style_section_card(panel: PanelContainer, border: Color = BORDER_BASE, bg: Color = SURFACE_CARD) -> void:
	panel.add_theme_stylebox_override("panel", make_box(bg, border, 6, 1, 8, 8, 0))


static func style_pill_label(lbl: Label, bg: Color, border: Color, text_col: Color) -> void:
	lbl.add_theme_stylebox_override("normal", make_box(bg, border, 999, 1, 7, 2, 0))
	lbl.add_theme_color_override("font_color", text_col)
	lbl.add_theme_font_size_override("font_size", 11)


static func style_button(btn: Button, variant: String = "default", accent: Color = ACCENT_TEAL) -> void:
	var normal_bg := Color("#232936")
	var hover_bg := Color("#303849")
	var pressed_bg := Color("#1c3638")
	var border_col := BORDER_CONTROL
	var pressed_border := accent
	var text_col := TEXT_SECONDARY

	match variant:
		"amber":
			normal_bg = ACCENT_AMBER_DIM
			hover_bg = Color("#3e2f1c")
			pressed_bg = Color("#4a361b")
			border_col = ACCENT_AMBER
			pressed_border = ACCENT_AMBER
			text_col = ACCENT_AMBER_TEXT
		"teal":
			normal_bg = ACCENT_TEAL_DIM
			hover_bg = Color("#213b3a")
			pressed_bg = Color("#1e4442")
			border_col = ACCENT_TEAL
			pressed_border = ACCENT_TEAL
			text_col = ACCENT_TEAL_TEXT
		"green":
			normal_bg = SEMANTIC_SUCCESS_DIM
			hover_bg = Color("#1e3d32")
			pressed_bg = Color("#22493b")
			border_col = SEMANTIC_SUCCESS
			pressed_border = SEMANTIC_SUCCESS
			text_col = Color("#98f5c7")
		"chip":
			normal_bg = Color("#1b212c")
			hover_bg = SURFACE_NODE_HOVER
			pressed_bg = Color(accent.r * 0.22 + 0.08, accent.g * 0.22 + 0.09, accent.b * 0.22 + 0.12, 1.0)
			border_col = BORDER_BASE
			pressed_border = accent
			text_col = TEXT_MUTED
		"tab":
			normal_bg = Color("#181e28")
			hover_bg = Color("#242c3b")
			pressed_bg = ACCENT_TEAL_DIM
			border_col = BORDER_BASE
			pressed_border = ACCENT_TEAL
			text_col = TEXT_MUTED
		"pill":
			normal_bg = Color(0.09, 0.11, 0.15, 0.88)
			hover_bg = Color(0.14, 0.18, 0.24, 0.94)
			pressed_bg = Color(accent.r * 0.24 + 0.07, accent.g * 0.24 + 0.09, accent.b * 0.24 + 0.12, 0.96)
			border_col = Color("#364256")
			pressed_border = accent
			text_col = TEXT_SECONDARY

	var rad := 999 if variant in ["chip", "pill"] else 4
	var py := 3 if variant in ["chip", "pill", "tab"] else 4
	var px := 8 if variant in ["chip", "pill"] else 9

	btn.add_theme_stylebox_override("normal", make_box(normal_bg, border_col, rad, 1, px, py, 0))
	btn.add_theme_stylebox_override("hover", make_box(hover_bg, pressed_border if variant != "default" else Color("#566680"), rad, 1, px, py, 0))
	btn.add_theme_stylebox_override("pressed", make_box(pressed_bg, pressed_border, rad, 1, px, py, 0))
	btn.add_theme_stylebox_override("focus", make_box(hover_bg, pressed_border, rad, 1, px, py, 0))
	btn.add_theme_color_override("font_color", text_col)
	btn.add_theme_color_override("font_hover_color", TEXT_PRIMARY)
	btn.add_theme_color_override("font_pressed_color", TEXT_PRIMARY)
	btn.add_theme_font_size_override("font_size", 11 if variant in ["chip", "pill", "tab"] else 12)


static func style_kpi_card(panel: PanelContainer, accent: Color = ACCENT_TEAL) -> void:
	panel.add_theme_stylebox_override("panel", make_box(SURFACE_NODE, BORDER_BASE, 5, 1, 8, 6, 2))
	var sb := panel.get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.border_color = BORDER_BASE
		sb.border_width_left = 2
		# Keep subtle top/right/bottom border while hinting with accent bg tint
		sb.bg_color = Color(accent.r * 0.05 + 0.11, accent.g * 0.05 + 0.13, accent.b * 0.05 + 0.17, 1.0)


static func style_foot_card(panel: PanelContainer, planted: bool) -> void:
	if planted:
		panel.add_theme_stylebox_override("panel", make_box(ACCENT_TEAL_DIM, ACCENT_TEAL, 5, 1, 8, 6, 0))
	else:
		panel.add_theme_stylebox_override("panel", make_box(ACCENT_AMBER_DIM, ACCENT_AMBER, 5, 1, 8, 6, 0))


static func style_banner(panel: PanelContainer, accent: Color, bg: Color) -> void:
	panel.add_theme_stylebox_override("panel", make_box(bg, accent, 5, 1, 8, 5, 3))


static func make_section_header(title_text: String, icon_id: String = "", accent: Color = TEXT_PRIMARY) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	if not icon_id.is_empty():
		var tex := get_icon(icon_id, accent, 14)
		if tex != null:
			var tr := TextureRect.new()
			tr.texture = tex
			tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
			tr.custom_minimum_size = Vector2(14, 14)
			row.add_child(tr)
	var lbl := Label.new()
	lbl.text = title_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", accent)
	lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(lbl)
	return row
