#include "playforge_platform.h"

#include "core/config/engine.h"
#include "core/config/project_settings.h"
#include "core/io/file_access.h"
#include "core/io/file_access_pack.h"
#include "core/io/resource_loader.h"
#include "core/object/callable_mp.h"
#include "core/object/class_db.h"
#include "core/object/script_language.h"
#include "core/os/os.h"
#include "scene/3d/camera_3d.h"
#include "scene/3d/light_3d.h"
#include "scene/3d/mesh_instance_3d.h"
#include "scene/3d/node_3d.h"
#include "scene/3d/physics/character_body_3d.h"
#include "scene/3d/physics/collision_shape_3d.h"
#include "scene/3d/physics/spring_arm_3d.h"
#include "scene/3d/physics/static_body_3d.h"
#include "scene/gui/box_container.h"
#include "scene/gui/button.h"
#include "scene/gui/label.h"
#include "scene/gui/panel_container.h"
#include "scene/main/canvas_layer.h"
#include "scene/main/scene_tree.h"
#include "scene/main/window.h"
#include "scene/resources/3d/box_shape_3d.h"
#include "scene/resources/3d/capsule_shape_3d.h"
#include "scene/resources/3d/primitive_meshes.h"
#include "scene/resources/material.h"
#include "scene/resources/style_box_flat.h"

PlayForgePlatform *PlayForgePlatform::singleton = nullptr;

PlayForgePlatform::PlayForgePlatform() {
	singleton = this;
}

PlayForgePlatform::~PlayForgePlatform() {
	if (singleton == this) {
		singleton = nullptr;
	}
}

void PlayForgePlatform::_seal_subtree(Node *p_root, bool p_hide_from_user_tree) {
	if (!p_root) {
		return;
	}
	p_root->set_platform_sealed(true);
	if (p_hide_from_user_tree) {
		p_root->set_platform_hidden_from_user_tree(true);
	}
	for (int i = 0; i < p_root->get_child_count(true); i++) {
		_seal_subtree(p_root->get_child(i, true), p_hide_from_user_tree);
	}
}

bool PlayForgePlatform::_is_3d_world(Node *p_scene) {
	if (!p_scene) {
		return false;
	}
	if (Object::cast_to<Node3D>(p_scene) != nullptr) {
		return true;
	}
	for (int i = 0; i < p_scene->get_child_count(false); i++) {
		if (Object::cast_to<Node3D>(p_scene->get_child(i, false)) != nullptr) {
			return true;
		}
	}
	return false;
}

bool PlayForgePlatform::_has_type_recursive(Node *p_root, const StringName &p_class) {
	if (!p_root) {
		return false;
	}
	if (p_root->is_class(p_class)) {
		return true;
	}
	for (int i = 0; i < p_root->get_child_count(false); i++) {
		if (_has_type_recursive(p_root->get_child(i, false), p_class)) {
			return true;
		}
	}
	return false;
}

Node *PlayForgePlatform::_find_script_path_recursive(Node *p_root, const String &p_suffix) {
	if (!p_root) {
		return nullptr;
	}
	Ref<Script> scr = p_root->get_script();
	if (scr.is_valid() && scr->get_path().ends_with(p_suffix)) {
		return p_root;
	}
	for (int i = 0; i < p_root->get_child_count(false); i++) {
		Node *found = _find_script_path_recursive(p_root->get_child(i, false), p_suffix);
		if (found) {
			return found;
		}
	}
	return nullptr;
}

void PlayForgePlatform::_ensure_hud(SceneTree *p_tree) {
	if (!p_tree || !p_tree->get_root() || Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	if (hud_layer_id.is_valid() && ObjectDB::get_instance<CanvasLayer>(hud_layer_id) != nullptr) {
		return;
	}

	Object::PlatformSealScope seal_scope;

	CanvasLayer *hud = memnew(CanvasLayer);
	hud->set_name("PlayForgeCoreHUD");
	hud->set_layer(128);
	hud->set_process_mode(Node::PROCESS_MODE_ALWAYS);

	Control *root_ctrl = memnew(Control);
	root_ctrl->set_name("CoreHudRoot");
	root_ctrl->set_anchors_preset(Control::PRESET_FULL_RECT);
	root_ctrl->set_mouse_filter(Control::MOUSE_FILTER_IGNORE);
	hud->add_child(root_ctrl);

	// Top-left unremovable Platform Bar (Roblox CoreGui / OVERDARE / Sandbox style)
	PanelContainer *topbar = memnew(PanelContainer);
	topbar->set_name("TopLeftPlatformBar");
	topbar->set_position(Vector2(12.0f, 12.0f));
	topbar->set_custom_minimum_size(Size2(224.0f, 44.0f));

	Ref<StyleBoxFlat> bar_style;
	bar_style.instantiate();
	bar_style->set_bg_color(Color(0.078f, 0.173f, 0.145f, 0.92f)); // PlayHub #142c25
	bar_style->set_border_color(Color(0.871f, 0.925f, 0.651f, 0.45f)); // PlayHub #deeca6
	bar_style->set_border_width_all(1);
	bar_style->set_corner_radius_all(12);
	bar_style->set_content_margin_all(6.0f);
	topbar->add_theme_style_override("panel", bar_style);
	root_ctrl->add_child(topbar);

	HBoxContainer *hbox = memnew(HBoxContainer);
	hbox->set_name("TopBarButtons");
	topbar->add_child(hbox);

	Button *menu_btn = memnew(Button);
	menu_btn->set_name("PlayHubMenuButton");
	menu_btn->set_text("PLAY HUB");
	menu_btn->connect("pressed", callable_mp(this, &PlayForgePlatform::_on_menu_toggle_pressed));
	hbox->add_child(menu_btn);

	Button *cam_btn = memnew(Button);
	cam_btn->set_name("CameraCycleButton");
	cam_btn->set_text("TPS/FPS");
	cam_btn->connect("pressed", callable_mp(this, &PlayForgePlatform::_on_camera_cycle_pressed));
	hbox->add_child(cam_btn);

	Button *ragdoll_btn = memnew(Button);
	ragdoll_btn->set_name("RagdollButton");
	ragdoll_btn->set_text("Ragdoll");
	ragdoll_btn->connect("pressed", callable_mp(this, &PlayForgePlatform::_on_ragdoll_pressed));
	hbox->add_child(ragdoll_btn);

	// Collapsible Platform System Menu (below top-left bar)
	PanelContainer *menu_panel = memnew(PanelContainer);
	menu_panel->set_name("PlatformSystemMenu");
	menu_panel->set_position(Vector2(12.0f, 64.0f));
	menu_panel->set_custom_minimum_size(Size2(248.0f, 180.0f));
	menu_panel->set_visible(false);
	menu_panel->add_theme_style_override("panel", bar_style);
	root_ctrl->add_child(menu_panel);

	VBoxContainer *menu_vbox = memnew(VBoxContainer);
	menu_panel->add_child(menu_vbox);

	Label *menu_title = memnew(Label);
	menu_title->set_text("PlayHub Platform Menu (Engine Sealed)");
	menu_vbox->add_child(menu_title);

	HBoxContainer *emote_row = memnew(HBoxContainer);
	menu_vbox->add_child(emote_row);
	for (int s = 0; s < 4; s++) {
		Button *eb = memnew(Button);
		eb->set_text(vformat("Emote %d", s + 1));
		eb->connect("pressed", callable_mp(this, &PlayForgePlatform::_on_emote_pressed).bind(s));
		emote_row->add_child(eb);
	}

	Button *resume_btn = memnew(Button);
	resume_btn->set_text("Resume");
	resume_btn->connect("pressed", callable_mp(this, &PlayForgePlatform::_on_menu_toggle_pressed));
	menu_vbox->add_child(resume_btn);

	Button *leave_btn = memnew(Button);
	leave_btn->set_text("Leave Experience");
	leave_btn->connect("pressed", callable_mp(this, &PlayForgePlatform::_on_leave_pressed));
	menu_vbox->add_child(leave_btn);

	p_tree->get_root()->add_child(hud, false, Node::INTERNAL_MODE_BACK);
	_seal_subtree(hud, true);

	hud_layer_id = hud->get_instance_id();
	menu_panel_id = menu_panel->get_instance_id();
	menu_open = false;
}

void PlayForgePlatform::_seal_avatar_instance(Node *p_avatar) {
	if (!p_avatar) {
		return;
	}
	Object::PlatformSealScope seal_scope;
	// Root avatar is sealed (cannot free/hide/rescale/re-script/remove/reparent),
	// while remaining discoverable via PlayForgePlatform.get_local_avatar() for safe API calls.
	p_avatar->set_platform_sealed(true);
	// Hide & seal direct internal rig/skeleton/ragdoll/camera/bridge containers from user scripts.
	// Because Node::_is_hidden_from_caller() walks up ancestors, everything inside SealedAvatarRig
	// (Skeleton3D, GLB meshes, EmojiBadge) is completely unreachable from user GDScript while
	// avatar_rig.gd can still manage its own internal GLB skin swaps and emoji badge visibility.
	for (int i = 0; i < p_avatar->get_child_count(true); i++) {
		Node *child = p_avatar->get_child(i, true);
		String cname = child->get_name();
		if (cname.begins_with("Sealed") || child->get_meta("_playforge_avatar_sealed", false).booleanize()) {
			child->set_platform_sealed(true);
			child->set_platform_hidden_from_user_tree(true);
			if (cname == "SealedCameraPivot" || cname == "SealedCapsule") {
				_seal_subtree(child, false);
				child->set_platform_hidden_from_user_tree(true);
			}
		}
	}
	local_avatar_id = p_avatar->get_instance_id();
	if (!p_avatar->is_ready()) {
		Callable cb = callable_mp(this, &PlayForgePlatform::_on_avatar_ready).bind((uint64_t)local_avatar_id);
		if (!p_avatar->is_connected(SNAME("ready"), cb)) {
			p_avatar->connect(SNAME("ready"), cb, CONNECT_ONE_SHOT);
		}
	}
}

void PlayForgePlatform::_on_avatar_ready(uint64_t p_avatar_id) {
	Node *avatar = ObjectDB::get_instance<Node>(ObjectID(p_avatar_id));
	if (avatar) {
		_seal_avatar_instance(avatar);
	}
}

Node *PlayForgePlatform::_find_node_by_name_recursive(Node *p_root, const String &p_name) {
	if (!p_root) {
		return nullptr;
	}
	if (String(p_root->get_name()) == p_name) {
		return p_root;
	}
	for (int i = 0; i < p_root->get_child_count(true); i++) {
		Node *found = _find_node_by_name_recursive(p_root->get_child(i, true), p_name);
		if (found) {
			return found;
		}
	}
	return nullptr;
}

Size2 PlayForgePlatform::get_portrait_min_size(int p_framing) const {
	// C++ Engine hard minimum UI size floor so creators cannot shrink/hide the Avatar Portrait UI.
	// 0 = UPPER_BODY (128x128), 1 = FULL_BODY (160x240)
	return p_framing == 1 ? Size2(160.0f, 240.0f) : Size2(128.0f, 128.0f);
}

void PlayForgePlatform::_resolve_presentation_config(Node *p_scene, int &r_mode, Size2 &r_size, int &r_corner, Vector2 &r_custom_pos, Vector3 &r_spawn_pos, int &r_camera_mode, String &r_world_binding) {
	bool is_3d = _is_3d_world(p_scene);
	r_mode = is_3d ? 0 : 1; // 3D default: WORLD_3D, 2D default: mandatory PORTRAIT_UPPER_BODY
	r_size = is_3d ? Size2() : Size2(144.0f, 144.0f);
	r_corner = 0; // BOTTOM_LEFT
	r_custom_pos = Vector2(-1.0f, -1.0f);
	r_spawn_pos = Vector3(0.0f, 0.2f, 0.0f);
	r_camera_mode = 0;
	r_world_binding = "standalone";

	// 1. ProjectSettings defaults (game mode configured in project.godot [playforge])
	if (ProjectSettings::get_singleton()) {
		if (ProjectSettings::get_singleton()->has_setting("playforge/avatar/presentation_mode")) {
			r_mode = CLAMP((int)ProjectSettings::get_singleton()->get_setting("playforge/avatar/presentation_mode"), 0, 3);
		}
		if (ProjectSettings::get_singleton()->has_setting("playforge/avatar/portrait_size")) {
			Variant sz = ProjectSettings::get_singleton()->get_setting("playforge/avatar/portrait_size");
			if (sz.get_type() == Variant::VECTOR2) {
				r_size = sz;
			}
		}
		if (ProjectSettings::get_singleton()->has_setting("playforge/avatar/portrait_corner")) {
			r_corner = CLAMP((int)ProjectSettings::get_singleton()->get_setting("playforge/avatar/portrait_corner"), 0, 4);
		}
		if (ProjectSettings::get_singleton()->has_setting("playforge/avatar/portrait_custom_position")) {
			Variant cp = ProjectSettings::get_singleton()->get_setting("playforge/avatar/portrait_custom_position");
			if (cp.get_type() == Variant::VECTOR2) {
				r_custom_pos = cp;
			}
		}
		if (ProjectSettings::get_singleton()->has_setting("playforge/avatar/spawn_position")) {
			Variant sp = ProjectSettings::get_singleton()->get_setting("playforge/avatar/spawn_position");
			if (sp.get_type() == Variant::VECTOR3) {
				r_spawn_pos = sp;
			}
		}
		if (ProjectSettings::get_singleton()->has_setting("playforge/avatar/camera_mode")) {
			r_camera_mode = CLAMP((int)ProjectSettings::get_singleton()->get_setting("playforge/avatar/camera_mode"), 0, 2);
		}
		if (ProjectSettings::get_singleton()->has_setting("playforge/avatar/world_binding")) {
			r_world_binding = String(ProjectSettings::get_singleton()->get_setting("playforge/avatar/world_binding")).strip_edges().to_lower();
		}
	}

	// 2. Scene PlayForgeAvatarSpawn override
	Node *spawn_node = _find_script_path_recursive(p_scene, "addons/playforge_avatar/avatar_spawn.gd");
	if (spawn_node) {
		bool valid = false;
		Variant pm = spawn_node->get("presentation_mode", &valid);
		if (valid && pm.get_type() == Variant::INT) {
			r_mode = CLAMP((int)pm, 0, 3);
		}
		Variant ps = spawn_node->get("portrait_size", &valid);
		if (valid && ps.get_type() == Variant::VECTOR2) {
			r_size = ps;
		}
		Variant pc = spawn_node->get("portrait_corner", &valid);
		if (valid && pc.get_type() == Variant::INT) {
			r_corner = CLAMP((int)pc, 0, 4);
		}
		Variant cm = spawn_node->get("camera_mode", &valid);
		if (valid && cm.get_type() == Variant::INT) {
			r_camera_mode = CLAMP((int)cm, 0, 2);
		}
		Node3D *spawn_3d = Object::cast_to<Node3D>(spawn_node);
		if (spawn_3d) {
			r_spawn_pos = spawn_3d->get_position();
		}
	}

	// 3. CLI / launcher preview override (highest priority for automated tests & launcher)
	if (OS::get_singleton()) {
		List<String> args = OS::get_singleton()->get_cmdline_user_args();
		for (const String &arg : args) {
			if (arg.begins_with("--avatar-presentation-mode=")) {
				String val = arg.substr(String("--avatar-presentation-mode=").length()).strip_edges().to_lower();
				if (val == "world_3d" || val == "0") {
					r_mode = 0;
				} else if (val == "upper_body" || val == "portrait_upper_body" || val == "1") {
					r_mode = 1;
				} else if (val == "full_body" || val == "portrait_full_body" || val == "2") {
					r_mode = 2;
				} else if (val == "hybrid" || val == "world_3d_with_portrait" || val == "3") {
					r_mode = 3;
				}
			} else if (arg.begins_with("--avatar-portrait-size=")) {
				String val = arg.substr(String("--avatar-portrait-size=").length()).strip_edges().to_lower();
				int x_idx = val.find_char('x');
				if (x_idx > 0) {
					r_size = Size2(val.substr(0, x_idx).to_float(), val.substr(x_idx + 1).to_float());
				}
			} else if (arg.begins_with("--avatar-portrait-corner=")) {
				String val = arg.substr(String("--avatar-portrait-corner=").length()).strip_edges().to_lower();
				if (val == "bottom_left" || val == "0") {
					r_corner = 0;
				} else if (val == "top_right" || val == "1") {
					r_corner = 1;
				} else if (val == "bottom_right" || val == "2") {
					r_corner = 2;
				} else if (val == "top_left" || val == "top_left_below_hud" || val == "3") {
					r_corner = 3;
				} else if (val == "custom" || val == "4") {
					r_corner = 4;
				}
			}
		}
	}
}

void PlayForgePlatform::_seal_portrait_instance(Control *p_portrait, const Size2 &p_min_size) {
	if (!p_portrait) {
		return;
	}
	Object::PlatformSealScope seal_scope;
	p_portrait->set_platform_min_size(p_min_size);
	p_portrait->set_platform_sealed(true);
	for (int i = 0; i < p_portrait->get_child_count(true); i++) {
		Node *child = p_portrait->get_child(i, true);
		String cname = child->get_name();
		if (cname.begins_with("Sealed") || child->get_meta("_playforge_avatar_sealed", false).booleanize()) {
			child->set_platform_sealed(true);
			child->set_platform_hidden_from_user_tree(true);
		}
	}
	portrait_ui_id = p_portrait->get_instance_id();
	if (!p_portrait->is_ready()) {
		Callable cb = callable_mp(this, &PlayForgePlatform::_on_portrait_ready).bind((uint64_t)portrait_ui_id);
		if (!p_portrait->is_connected(SNAME("ready"), cb)) {
			p_portrait->connect(SNAME("ready"), cb, CONNECT_ONE_SHOT);
		}
	}
}

void PlayForgePlatform::_on_portrait_ready(uint64_t p_portrait_id) {
	Control *portrait = ObjectDB::get_instance<Control>(ObjectID(p_portrait_id));
	if (portrait) {
		_seal_portrait_instance(portrait, get_portrait_min_size(portrait_framing));
	}
}

Control *PlayForgePlatform::_ensure_portrait_ui(SceneTree *p_tree, int p_framing, const Size2 &p_requested_size, int p_corner, const Vector2 &p_custom_pos) {
	if (!p_tree || !p_tree->get_root() || Engine::get_singleton()->is_editor_hint()) {
		return nullptr;
	}
	Object::PlatformSealScope seal_scope;

	portrait_framing = CLAMP(p_framing, 0, 1);
	portrait_corner = CLAMP(p_corner, 0, 4);
	if (p_custom_pos.x >= 0.0f && p_custom_pos.y >= 0.0f) {
		portrait_custom_pos = p_custom_pos;
	}
	Size2 min_size = get_portrait_min_size(portrait_framing);
	Size2 default_size = portrait_framing == 1 ? Size2(220.0f, 320.0f) : Size2(192.0f, 192.0f);
	Size2 desired = (p_requested_size.x > 0.0f && p_requested_size.y > 0.0f) ? p_requested_size : default_size;
	// Minimum size only (>= min_size) is mandatory; no artificial upper size cap (supports full-screen/lobby portraits).
	Size2 target_size(
			MAX(desired.x, min_size.x),
			MAX(desired.y, min_size.y));

	CanvasLayer *layer = ObjectDB::get_instance<CanvasLayer>(portrait_layer_id);
	if (!layer) {
		layer = memnew(CanvasLayer);
		layer->set_name("PlayForgePortraitLayer");
		layer->set_layer(115); // Above user UI (<=100), below CoreHUD (128)
		layer->set_process_mode(Node::PROCESS_MODE_ALWAYS);
		p_tree->get_root()->add_child(layer, false, Node::INTERNAL_MODE_BACK);
		layer->set_platform_sealed(true);
		layer->set_platform_hidden_from_user_tree(true);
		portrait_layer_id = layer->get_instance_id();
	}

	Control *portrait = ObjectDB::get_instance<Control>(portrait_ui_id);
	if (!portrait) {
		const String portrait_script_path = "res://addons/playforge_avatar/avatar_portrait_ui.gd";
		PanelContainer *panel = memnew(PanelContainer);
		panel->set_name("PlayForgeAvatarPortraitUI");
		if (ResourceLoader::exists(portrait_script_path)) {
			Ref<Script> scr = ResourceLoader::load(portrait_script_path);
			if (scr.is_valid()) {
				panel->set_script(scr);
			}
		}
		panel->set_platform_min_size(min_size);
		panel->set_custom_minimum_size(target_size);
		panel->set_size(target_size);
		layer->add_child(panel);
		portrait = panel;
	}

	portrait->set_platform_min_size(min_size);
	if (portrait->has_method("configure_portrait")) {
		portrait->call("configure_portrait", portrait_framing, target_size, portrait_corner, portrait_custom_pos);
	} else {
		portrait->set_custom_minimum_size(target_size);
		portrait->set_size(target_size);
		portrait->set_position(Vector2(16.0f, 76.0f));
	}
	_seal_portrait_instance(portrait, min_size);
	return portrait;
}

void PlayForgePlatform::_remove_portrait_ui() {
	Object::PlatformSealScope seal_scope;
	CanvasLayer *layer = ObjectDB::get_instance<CanvasLayer>(portrait_layer_id);
	if (layer) {
		layer->queue_free();
	}
	portrait_layer_id = ObjectID();
	portrait_ui_id = ObjectID();
}

Control *PlayForgePlatform::get_avatar_portrait_ui() const {
	return ObjectDB::get_instance<Control>(portrait_ui_id);
}

Node *PlayForgePlatform::set_avatar_presentation_mode(int p_mode, const Size2 &p_portrait_size, int p_corner) {
	SceneTree *tree = SceneTree::get_singleton();
	if (!tree || Engine::get_singleton()->is_editor_hint()) {
		return nullptr;
	}
	_ensure_hud(tree);
	presentation_mode = CLAMP(p_mode, 0, 3);
	if (presentation_mode == 0) {
		_remove_portrait_ui();
		Node *scene = tree->get_current_scene();
		if (scene && _is_3d_world(scene)) {
			Node *existing = get_local_avatar();
			if (existing) {
				return existing;
			}
			return ensure_scene_avatar(scene);
		}
		return get_local_avatar();
	}
	int framing = (presentation_mode == 2) ? 1 : 0;
	Control *portrait = _ensure_portrait_ui(tree, framing, p_portrait_size, p_corner);
	if (presentation_mode == 3) {
		Node *scene = tree->get_current_scene();
		if (scene && _is_3d_world(scene) && !get_local_avatar()) {
			ensure_scene_avatar(scene);
		}
	}
	return portrait;
}

Control *PlayForgePlatform::set_portrait_framing(int p_framing, const Size2 &p_portrait_size) {
	SceneTree *tree = SceneTree::get_singleton();
	if (!tree || Engine::get_singleton()->is_editor_hint()) {
		return nullptr;
	}
	int next_framing = CLAMP(p_framing, 0, 1);
	if (presentation_mode == 1 || presentation_mode == 2) {
		presentation_mode = next_framing == 1 ? 2 : 1;
	}
	return _ensure_portrait_ui(tree, next_framing, p_portrait_size, portrait_corner);
}

Node *PlayForgePlatform::_attach_avatar_to_player_character(Node *p_scene) {
	if (!p_scene) {
		return nullptr;
	}
	Node *target = _find_node_by_name_recursive(p_scene, "PlayerCharacter");
	Node3D *char_node = Object::cast_to<Node3D>(target);
	if (!char_node) {
		return nullptr;
	}
	Node *existing = char_node->get_node_or_null(NodePath("PlayForgePlayerAvatar"));
	if (existing) {
		_seal_avatar_instance(existing);
		return existing;
	}
	const String rig_path = "res://addons/playforge_avatar/avatar_rig.gd";
	const String bridge_path = "res://addons/playforge_avatar/avatar_bridge.gd";
	if (!ResourceLoader::exists(rig_path) || !ResourceLoader::exists(bridge_path)) {
		return nullptr;
	}
	Ref<Script> rig_script = ResourceLoader::load(rig_path);
	Ref<Script> bridge_script = ResourceLoader::load(bridge_path);
	if (rig_script.is_null() || bridge_script.is_null()) {
		return nullptr;
	}
	Object::PlatformSealScope seal_scope;
	Node3D *rig = memnew(Node3D);
	rig->set_name("PlayForgePlayerAvatar");
	rig->set_position(Vector3(0.0f, -0.75f, 0.0f));
	rig->set_script(rig_script);
	char_node->add_child(rig);

	Node *bridge = memnew(Node);
	bridge->set_name("SealedAttachBridge");
	bridge->set_script(bridge_script);
	rig->add_child(bridge);
	if (bridge->has_method("request_player_loadout")) {
		bridge->connect(SNAME("loadout_resolved"), Callable(rig, SNAME("apply_sealed_loadout")));
		bridge->call("request_player_loadout");
	}
	for (int i = 0; i < char_node->get_child_count(); i++) {
		MeshInstance3D *mi = Object::cast_to<MeshInstance3D>(char_node->get_child(i));
		if (mi && !mi->is_platform_sealed() && Object::cast_to<CapsuleMesh>(mi->get_mesh().ptr())) {
			mi->set_visible(false);
		}
	}
	_seal_avatar_instance(rig);
	return rig;
}

void PlayForgePlatform::_deferred_attach_player_character(uint64_t p_scene_id) {
	Node *scene = ObjectDB::get_instance<Node>(ObjectID(p_scene_id));
	if (scene && scene->is_inside_tree()) {
		_attach_avatar_to_player_character(scene);
	}
}

Node *PlayForgePlatform::ensure_scene_avatar(Node *p_scene) {
	if (!p_scene || Engine::get_singleton()->is_editor_hint()) {
		return nullptr;
	}
	SceneTree *tree = SceneTree::get_singleton();
	if (tree) {
		_ensure_hud(tree);
	}

	int mode = 0;
	Size2 portrait_size;
	int corner = 0;
	Vector2 custom_pos(-1.0f, -1.0f);
	Vector3 spawn_pos(0.0f, 0.2f, 0.0f);
	int camera_mode = 0;
	String world_binding = "standalone";
	_resolve_presentation_config(p_scene, mode, portrait_size, corner, custom_pos, spawn_pos, camera_mode, world_binding);
	presentation_mode = mode;

	// Portrait-only modes (1 = UPPER_BODY, 2 = FULL_BODY) work in BOTH 2D and 3D scenes!
	if (mode == 1 || mode == 2) {
		int framing = (mode == 2) ? 1 : 0;
		return _ensure_portrait_ui(tree, framing, portrait_size, corner, custom_pos);
	}

	// Hybrid mode (3 = WORLD_3D_WITH_PORTRAIT) mounts both portrait UI and 3D world avatar!
	if (mode == 3) {
		_ensure_portrait_ui(tree, 0, portrait_size, corner, custom_pos);
	} else {
		_remove_portrait_ui();
	}

	if (!_is_3d_world(p_scene)) {
		return get_avatar_portrait_ui();
	}

	if (world_binding == "attach_player_character") {
		Node *attached = _attach_avatar_to_player_character(p_scene);
		if (!attached) {
			call_deferred(SNAME("_deferred_attach_player_character"), (uint64_t)p_scene->get_instance_id());
		}
		return attached ? attached : (Node *)get_avatar_portrait_ui();
	}

	// 1. Existing PlayForgeAvatarController in scene?
	Node *existing_ctrl = _find_script_path_recursive(p_scene, "addons/playforge_avatar/avatar_controller.gd");
	if (existing_ctrl) {
		_seal_avatar_instance(existing_ctrl);
		return existing_ctrl;
	}

	// 2. Existing PlayForgeAvatarSpawn in scene? Spawn synchronously and seal.
	Node *spawn_node = _find_script_path_recursive(p_scene, "addons/playforge_avatar/avatar_spawn.gd");
	if (spawn_node && spawn_node->has_method("spawn_avatar")) {
		Object::PlatformSealScope seal_scope;
		Variant spawned_var = spawn_node->call("spawn_avatar");
		Node *spawned = Object::cast_to<Node>(spawned_var.get_validated_object());
		if (spawned) {
			_seal_avatar_instance(spawned);
			return spawned;
		}
	}

	// 3. Blank / minimal 3D project (no spawn, no avatar) -> auto-inject fallback floor/light if missing + TPS Avatar!
	Object::PlatformSealScope seal_scope;

	if (!_has_type_recursive(p_scene, SNAME("CollisionObject3D"))) {
		StaticBody3D *floor_body = memnew(StaticBody3D);
		floor_body->set_name("PlayForgeBaseplateFloor");

		CollisionShape3D *col = memnew(CollisionShape3D);
		Ref<BoxShape3D> box_shape;
		box_shape.instantiate();
		box_shape->set_size(Vector3(48.0f, 1.0f, 48.0f));
		col->set_shape(box_shape);
		col->set_position(Vector3(0.0f, -0.5f, 0.0f));
		floor_body->add_child(col);

		if (!_has_type_recursive(p_scene, SNAME("MeshInstance3D"))) {
			MeshInstance3D *mi = memnew(MeshInstance3D);
			Ref<BoxMesh> box_mesh;
			box_mesh.instantiate();
			box_mesh->set_size(Vector3(48.0f, 1.0f, 48.0f));
			Ref<StandardMaterial3D> mat;
			mat.instantiate();
			mat->set_albedo(Color(0.24f, 0.30f, 0.34f));
			mat->set_roughness(0.85f);
			box_mesh->set_material(mat);
			mi->set_mesh(box_mesh);
			mi->set_position(Vector3(0.0f, -0.5f, 0.0f));
			floor_body->add_child(mi);
		}

		p_scene->add_child(floor_body);
	}

	if (!_has_type_recursive(p_scene, SNAME("Light3D"))) {
		DirectionalLight3D *sun = memnew(DirectionalLight3D);
		sun->set_name("PlayForgeDefaultLight");
		sun->set_rotation_degrees(Vector3(-48.0f, -32.0f, 0.0f));
		p_scene->add_child(sun);
	}

	const String ctrl_path = "res://addons/playforge_avatar/avatar_controller.gd";
	Node *avatar = nullptr;
	if (ResourceLoader::exists(ctrl_path)) {
		Ref<Script> ctrl_script = ResourceLoader::load(ctrl_path);
		if (ctrl_script.is_valid()) {
			CharacterBody3D *body = memnew(CharacterBody3D);
			body->set_name("PlayForgePlayerAvatar");
			body->set_position(spawn_pos);
			body->set_script(ctrl_script);
			body->set("camera_mode", camera_mode);
			p_scene->add_child(body);
			avatar = body;
		}
	}

	// Engine-native TPS fallback avatar if core pack is not mounted
	if (!avatar) {
		CharacterBody3D *fallback = memnew(CharacterBody3D);
		fallback->set_name("PlayForgePlayerAvatar");
		fallback->set_position(spawn_pos);

		CollisionShape3D *cap_col = memnew(CollisionShape3D);
		cap_col->set_name("SealedCapsule");
		Ref<CapsuleShape3D> cap_shape;
		cap_shape.instantiate();
		cap_shape->set_radius(0.38f);
		cap_shape->set_height(1.85f);
		cap_col->set_shape(cap_shape);
		cap_col->set_position(Vector3(0.0f, 0.925f, 0.0f));
		fallback->add_child(cap_col);

		MeshInstance3D *mesh = memnew(MeshInstance3D);
		mesh->set_name("SealedFallbackBody");
		Ref<CapsuleMesh> cap_mesh;
		cap_mesh.instantiate();
		cap_mesh->set_radius(0.35f);
		cap_mesh->set_height(1.75f);
		mesh->set_mesh(cap_mesh);
		mesh->set_position(Vector3(0.0f, 0.9f, 0.0f));
		fallback->add_child(mesh);

		Node3D *pivot = memnew(Node3D);
		pivot->set_name("SealedCameraPivot");
		pivot->set_position(Vector3(0.45f, 1.5f, 0.0f));
		pivot->set_rotation_degrees(Vector3(-14.0f, 0.0f, 0.0f));
		fallback->add_child(pivot);

		SpringArm3D *arm = memnew(SpringArm3D);
		arm->set_name("SealedSpringArm");
		arm->set_length(4.4f);
		pivot->add_child(arm);

		Camera3D *cam = memnew(Camera3D);
		cam->set_name("SealedCamera");
		cam->set_current(true);
		arm->add_child(cam);

		p_scene->add_child(fallback);
		avatar = fallback;
	}

	_seal_avatar_instance(avatar);
	return avatar;
}

void PlayForgePlatform::_apply_avatar_visibility(bool p_visible) {
	Object::PlatformSealScope seal_scope;
	Node *avatar = get_local_avatar();
	if (avatar) {
		Node3D *avatar_3d = Object::cast_to<Node3D>(avatar);
		if (avatar_3d && avatar_3d->is_visible() != p_visible) {
			avatar_3d->set_visible(p_visible);
		}
	}
	CanvasLayer *portrait_layer = ObjectDB::get_instance<CanvasLayer>(portrait_layer_id);
	if (portrait_layer && portrait_layer->is_visible() != p_visible) {
		portrait_layer->set_visible(p_visible);
	}
	Control *portrait = get_avatar_portrait_ui();
	if (portrait) {
		if (portrait->has_method("set_authorized_hidden")) {
			portrait->call("set_authorized_hidden", !p_visible);
		}
		if (portrait->is_visible() != p_visible) {
			portrait->set_visible(p_visible);
		}
	}
}

void PlayForgePlatform::_apply_hud_visibility(bool p_visible) {
	Object::PlatformSealScope seal_scope;
	CanvasLayer *hud = ObjectDB::get_instance<CanvasLayer>(hud_layer_id);
	if (hud && hud->is_visible() != p_visible) {
		hud->set_visible(p_visible);
	}
	if (!p_visible && menu_open) {
		set_platform_menu_open(false);
	}
}

void PlayForgePlatform::_tick_temporary_hide() {
	if (!OS::get_singleton() || Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	uint64_t now_usec = OS::get_singleton()->get_ticks_usec();
	if (hide_last_tick_usec == 0) {
		hide_last_tick_usec = now_usec;
	}
	double dt = (now_usec >= hide_last_tick_usec) ? double(now_usec - hide_last_tick_usec) / 1000000.0 : 0.0;
	hide_last_tick_usec = now_usec;

	if (avatar_temp_hidden) {
		hide_budget_sec = MAX(0.0, hide_budget_sec - dt);
		hide_remaining_sec = MAX(0.0, hide_remaining_sec - dt);
		if (hide_remaining_sec <= 0.0 || hide_budget_sec <= 0.0) {
			avatar_temp_hidden = false;
			hide_remaining_sec = 0.0;
			_apply_avatar_visibility(true);
		} else {
			_apply_avatar_visibility(false);
		}
	} else {
		hide_budget_sec = MIN(AVATAR_HIDE_MAX_BUDGET_SEC, hide_budget_sec + dt * AVATAR_HIDE_RECHARGE_RATE);
		hide_remaining_sec = 0.0;
		_apply_avatar_visibility(true);
	}

	if (hud_temp_hidden) {
		hud_hide_budget_sec = MAX(0.0, hud_hide_budget_sec - dt);
		hud_hide_remaining_sec = MAX(0.0, hud_hide_remaining_sec - dt);
		if (hud_hide_remaining_sec <= 0.0 || hud_hide_budget_sec <= 0.0) {
			hud_temp_hidden = false;
			hud_hide_remaining_sec = 0.0;
			_apply_hud_visibility(true);
		} else {
			_apply_hud_visibility(false);
		}
	} else {
		hud_hide_budget_sec = MIN(AVATAR_HIDE_MAX_BUDGET_SEC, hud_hide_budget_sec + dt * AVATAR_HIDE_RECHARGE_RATE);
		hud_hide_remaining_sec = 0.0;
		_apply_hud_visibility(true);
	}
}

void PlayForgePlatform::_on_process_frame() {
	_tick_temporary_hide();
}

bool PlayForgePlatform::request_temporary_avatar_hide(double p_duration_sec) {
	if (Engine::get_singleton()->is_editor_hint()) {
		return false;
	}
	_tick_temporary_hide();
	if (!Math::is_finite(p_duration_sec) || p_duration_sec <= 0.0) {
		return false;
	}
	double clamped_req = CLAMP(p_duration_sec, 0.0, AVATAR_HIDE_MAX_BUDGET_SEC);
	if (!avatar_temp_hidden) {
		if (hide_budget_sec < AVATAR_HIDE_MIN_START_BUDGET_SEC) {
			_apply_avatar_visibility(true);
			return false;
		}
		double granted = MIN(clamped_req, hide_budget_sec);
		if (granted <= 0.0) {
			_apply_avatar_visibility(true);
			return false;
		}
		avatar_temp_hidden = true;
		hide_remaining_sec = granted;
		_apply_avatar_visibility(false);
		return true;
	}
	// Already hidden: cap strictly to remaining budget and <= 30.0s (cannot exceed budget or stretch past 30s).
	double next_rem = MIN(clamped_req, hide_budget_sec);
	if (next_rem <= 0.0) {
		avatar_temp_hidden = false;
		hide_remaining_sec = 0.0;
		_apply_avatar_visibility(true);
		return false;
	}
	hide_remaining_sec = next_rem;
	_apply_avatar_visibility(false);
	return true;
}

void PlayForgePlatform::end_temporary_avatar_hide() {
	_tick_temporary_hide();
	avatar_temp_hidden = false;
	hide_remaining_sec = 0.0;
	_apply_avatar_visibility(true);
}

bool PlayForgePlatform::is_avatar_temporarily_hidden() {
	_tick_temporary_hide();
	return avatar_temp_hidden;
}

double PlayForgePlatform::get_avatar_hide_budget_seconds() {
	_tick_temporary_hide();
	return hide_budget_sec;
}

double PlayForgePlatform::get_avatar_hide_remaining_seconds() {
	_tick_temporary_hide();
	return hide_remaining_sec;
}

Dictionary PlayForgePlatform::get_avatar_hide_state() {
	_tick_temporary_hide();
	Dictionary state;
	state["hidden"] = avatar_temp_hidden;
	state["remainingSeconds"] = hide_remaining_sec;
	state["budgetSeconds"] = hide_budget_sec;
	state["maxBudgetSeconds"] = AVATAR_HIDE_MAX_BUDGET_SEC;
	state["rechargeRatePerSecond"] = AVATAR_HIDE_RECHARGE_RATE;
	state["minStartBudgetSeconds"] = AVATAR_HIDE_MIN_START_BUDGET_SEC;
	return state;
}

bool PlayForgePlatform::request_temporary_hud_hide(double p_duration_sec) {
	if (Engine::get_singleton()->is_editor_hint()) {
		return false;
	}
	_tick_temporary_hide();
	if (!Math::is_finite(p_duration_sec) || p_duration_sec <= 0.0) {
		return false;
	}
	double clamped_req = CLAMP(p_duration_sec, 0.0, AVATAR_HIDE_MAX_BUDGET_SEC);
	if (!hud_temp_hidden) {
		if (hud_hide_budget_sec < AVATAR_HIDE_MIN_START_BUDGET_SEC) {
			_apply_hud_visibility(true);
			return false;
		}
		double granted = MIN(clamped_req, hud_hide_budget_sec);
		if (granted <= 0.0) {
			_apply_hud_visibility(true);
			return false;
		}
		hud_temp_hidden = true;
		hud_hide_remaining_sec = granted;
		_apply_hud_visibility(false);
		return true;
	}
	double next_rem = MIN(clamped_req, hud_hide_budget_sec);
	if (next_rem <= 0.0) {
		hud_temp_hidden = false;
		hud_hide_remaining_sec = 0.0;
		_apply_hud_visibility(true);
		return false;
	}
	hud_hide_remaining_sec = next_rem;
	_apply_hud_visibility(false);
	return true;
}

void PlayForgePlatform::end_temporary_hud_hide() {
	_tick_temporary_hide();
	hud_temp_hidden = false;
	hud_hide_remaining_sec = 0.0;
	_apply_hud_visibility(true);
}

bool PlayForgePlatform::is_hud_temporarily_hidden() {
	_tick_temporary_hide();
	return hud_temp_hidden;
}

double PlayForgePlatform::get_hud_hide_budget_seconds() {
	_tick_temporary_hide();
	return hud_hide_budget_sec;
}

double PlayForgePlatform::get_hud_hide_remaining_seconds() {
	_tick_temporary_hide();
	return hud_hide_remaining_sec;
}

Dictionary PlayForgePlatform::get_hud_hide_state() {
	_tick_temporary_hide();
	Dictionary state;
	state["hidden"] = hud_temp_hidden;
	state["remainingSeconds"] = hud_hide_remaining_sec;
	state["budgetSeconds"] = hud_hide_budget_sec;
	state["maxBudgetSeconds"] = AVATAR_HIDE_MAX_BUDGET_SEC;
	state["rechargeRatePerSecond"] = AVATAR_HIDE_RECHARGE_RATE;
	state["minStartBudgetSeconds"] = AVATAR_HIDE_MIN_START_BUDGET_SEC;
	return state;
}

bool PlayForgePlatform::request_temporary_platform_ui_hide(double p_duration_sec) {
	bool av_ok = request_temporary_avatar_hide(p_duration_sec);
	bool hud_ok = request_temporary_hud_hide(p_duration_sec);
	return av_ok || hud_ok;
}

void PlayForgePlatform::end_temporary_platform_ui_hide() {
	end_temporary_avatar_hide();
	end_temporary_hud_hide();
}

void PlayForgePlatform::on_tree_initialized(SceneTree *p_tree) {
	if (singleton) {
		if (p_tree && !Engine::get_singleton()->is_editor_hint() && !singleton->process_frame_connected) {
			Callable cb = callable_mp(singleton, &PlayForgePlatform::_on_process_frame);
			if (!p_tree->is_connected(SNAME("process_frame"), cb)) {
				p_tree->connect(SNAME("process_frame"), cb);
			}
			singleton->process_frame_connected = true;
			if (OS::get_singleton() && singleton->hide_last_tick_usec == 0) {
				singleton->hide_last_tick_usec = OS::get_singleton()->get_ticks_usec();
			}
		}
		singleton->_ensure_hud(p_tree);
		Node *avatar = singleton->get_local_avatar();
		if (avatar) {
			singleton->_seal_avatar_instance(avatar);
		}
		Control *portrait = singleton->get_avatar_portrait_ui();
		if (portrait) {
			singleton->_seal_portrait_instance(portrait, singleton->get_portrait_min_size(singleton->portrait_framing));
		}
		singleton->_tick_temporary_hide();
	}
}

void PlayForgePlatform::on_scene_loaded(SceneTree *p_tree, Node *p_scene) {
	if (singleton) {
		singleton->_ensure_hud(p_tree);
		singleton->ensure_scene_avatar(p_scene);
		singleton->_tick_temporary_hide();
	}
}

bool PlayForgePlatform::is_platform_hud_active() const {
	CanvasLayer *hud = ObjectDB::get_instance<CanvasLayer>(hud_layer_id);
	return hud != nullptr && hud->is_inside_tree() && hud->is_visible() && hud->get_layer() == 128;
}

Node *PlayForgePlatform::get_local_avatar() const {
	return ObjectDB::get_instance<Node>(local_avatar_id);
}

PackedStringArray PlayForgePlatform::get_sealed_prefixes() const {
	if (PackedData::get_singleton()) {
		return PackedData::get_singleton()->get_sealed_prefixes();
	}
	return PackedStringArray();
}

int64_t PlayForgePlatform::get_violation_count() const {
	return (int64_t)Object::get_platform_seal_violation_count();
}

void PlayForgePlatform::set_platform_menu_open(bool p_open) {
	menu_open = p_open;
	Control *panel = ObjectDB::get_instance<Control>(menu_panel_id);
	if (panel) {
		Object::PlatformSealScope seal_scope;
		panel->set_visible(menu_open);
	}
}

void PlayForgePlatform::_on_menu_toggle_pressed() {
	set_platform_menu_open(!menu_open);
}

void PlayForgePlatform::_on_camera_cycle_pressed() {
	Node *avatar = get_local_avatar();
	if (avatar && avatar->has_method("cycle_camera_mode")) {
		avatar->call("cycle_camera_mode");
	}
}

void PlayForgePlatform::_on_ragdoll_pressed() {
	Node *avatar = get_local_avatar();
	if (!avatar) {
		return;
	}
	if (avatar->has_method("is_ragdoll_active") && avatar->call("is_ragdoll_active").booleanize()) {
		if (avatar->has_method("recover_from_ragdoll")) {
			avatar->call("recover_from_ragdoll");
		}
	} else if (avatar->has_method("trigger_ragdoll")) {
		avatar->call("trigger_ragdoll", Vector3(0.0f, 2.5f, -5.0f), String("chest"));
	}
}

void PlayForgePlatform::_on_emote_pressed(int p_slot) {
	Node *avatar = get_local_avatar();
	if (avatar && avatar->has_method("play_emote_slot")) {
		avatar->call("play_emote_slot", p_slot);
	}
	Control *portrait = get_avatar_portrait_ui();
	if (portrait && portrait->has_method("play_emote_slot")) {
		portrait->call("play_emote_slot", p_slot);
	}
}

void PlayForgePlatform::_on_leave_pressed() {
	SceneTree *tree = SceneTree::get_singleton();
	if (tree) {
		tree->quit(0);
	}
}

void PlayForgePlatform::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_engine_sealed"), &PlayForgePlatform::is_engine_sealed);
	ClassDB::bind_method(D_METHOD("is_platform_hud_active"), &PlayForgePlatform::is_platform_hud_active);
	ClassDB::bind_method(D_METHOD("get_topbar_safe_inset"), &PlayForgePlatform::get_topbar_safe_inset);
	ClassDB::bind_method(D_METHOD("get_local_avatar"), &PlayForgePlatform::get_local_avatar);
	ClassDB::bind_method(D_METHOD("get_avatar_portrait_ui"), &PlayForgePlatform::get_avatar_portrait_ui);
	ClassDB::bind_method(D_METHOD("get_avatar_presentation_mode"), &PlayForgePlatform::get_avatar_presentation_mode);
	ClassDB::bind_method(D_METHOD("get_portrait_min_size", "framing"), &PlayForgePlatform::get_portrait_min_size);
	ClassDB::bind_method(D_METHOD("set_avatar_presentation_mode", "mode", "portrait_size", "corner"), &PlayForgePlatform::set_avatar_presentation_mode, DEFVAL(Size2()), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_portrait_framing", "framing", "portrait_size"), &PlayForgePlatform::set_portrait_framing, DEFVAL(Size2()));
	ClassDB::bind_method(D_METHOD("get_sealed_prefixes"), &PlayForgePlatform::get_sealed_prefixes);
	ClassDB::bind_method(D_METHOD("get_violation_count"), &PlayForgePlatform::get_violation_count);
	ClassDB::bind_method(D_METHOD("is_platform_menu_open"), &PlayForgePlatform::is_platform_menu_open);
	ClassDB::bind_method(D_METHOD("set_platform_menu_open", "open"), &PlayForgePlatform::set_platform_menu_open);
	ClassDB::bind_method(D_METHOD("request_temporary_avatar_hide", "duration_sec"), &PlayForgePlatform::request_temporary_avatar_hide, DEFVAL(AVATAR_HIDE_MAX_BUDGET_SEC));
	ClassDB::bind_method(D_METHOD("end_temporary_avatar_hide"), &PlayForgePlatform::end_temporary_avatar_hide);
	ClassDB::bind_method(D_METHOD("is_avatar_temporarily_hidden"), &PlayForgePlatform::is_avatar_temporarily_hidden);
	ClassDB::bind_method(D_METHOD("get_avatar_hide_budget_seconds"), &PlayForgePlatform::get_avatar_hide_budget_seconds);
	ClassDB::bind_method(D_METHOD("get_avatar_hide_remaining_seconds"), &PlayForgePlatform::get_avatar_hide_remaining_seconds);
	ClassDB::bind_method(D_METHOD("get_avatar_hide_state"), &PlayForgePlatform::get_avatar_hide_state);
	ClassDB::bind_method(D_METHOD("request_temporary_hud_hide", "duration_sec"), &PlayForgePlatform::request_temporary_hud_hide, DEFVAL(AVATAR_HIDE_MAX_BUDGET_SEC));
	ClassDB::bind_method(D_METHOD("end_temporary_hud_hide"), &PlayForgePlatform::end_temporary_hud_hide);
	ClassDB::bind_method(D_METHOD("is_hud_temporarily_hidden"), &PlayForgePlatform::is_hud_temporarily_hidden);
	ClassDB::bind_method(D_METHOD("get_hud_hide_budget_seconds"), &PlayForgePlatform::get_hud_hide_budget_seconds);
	ClassDB::bind_method(D_METHOD("get_hud_hide_remaining_seconds"), &PlayForgePlatform::get_hud_hide_remaining_seconds);
	ClassDB::bind_method(D_METHOD("get_hud_hide_state"), &PlayForgePlatform::get_hud_hide_state);
	ClassDB::bind_method(D_METHOD("request_temporary_platform_ui_hide", "duration_sec"), &PlayForgePlatform::request_temporary_platform_ui_hide, DEFVAL(AVATAR_HIDE_MAX_BUDGET_SEC));
	ClassDB::bind_method(D_METHOD("end_temporary_platform_ui_hide"), &PlayForgePlatform::end_temporary_platform_ui_hide);
	ClassDB::bind_method(D_METHOD("ensure_scene_avatar", "scene"), &PlayForgePlatform::ensure_scene_avatar);
	ClassDB::bind_method(D_METHOD("_deferred_attach_player_character", "scene_id"), &PlayForgePlatform::_deferred_attach_player_character);
}
