#include "playforge_platform.h"

#include "core/config/engine.h"
#include "core/io/file_access.h"
#include "core/io/file_access_pack.h"
#include "core/io/resource_loader.h"
#include "core/object/callable_mp.h"
#include "core/object/class_db.h"
#include "core/object/script_language.h"
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

Node *PlayForgePlatform::ensure_scene_avatar(Node *p_scene) {
	if (!p_scene || Engine::get_singleton()->is_editor_hint()) {
		return nullptr;
	}
	SceneTree *tree = SceneTree::get_singleton();
	if (tree) {
		_ensure_hud(tree);
	}
	if (!_is_3d_world(p_scene)) {
		return nullptr;
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

	// 3. Blank 3D project (no spawn, no avatar) -> auto-inject fallback floor/light if missing + TPS Avatar!
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
			body->set_position(Vector3(0.0f, 0.2f, 0.0f));
			body->set_script(ctrl_script);
			p_scene->add_child(body);
			avatar = body;
		}
	}

	// Engine-native TPS fallback avatar if core pack is not mounted
	if (!avatar) {
		CharacterBody3D *fallback = memnew(CharacterBody3D);
		fallback->set_name("PlayForgePlayerAvatar");
		fallback->set_position(Vector3(0.0f, 0.2f, 0.0f));

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

void PlayForgePlatform::on_tree_initialized(SceneTree *p_tree) {
	if (singleton) {
		singleton->_ensure_hud(p_tree);
		Node *avatar = singleton->get_local_avatar();
		if (avatar) {
			singleton->_seal_avatar_instance(avatar);
		}
	}
}

void PlayForgePlatform::on_scene_loaded(SceneTree *p_tree, Node *p_scene) {
	if (singleton) {
		singleton->_ensure_hud(p_tree);
		singleton->ensure_scene_avatar(p_scene);
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
	ClassDB::bind_method(D_METHOD("get_sealed_prefixes"), &PlayForgePlatform::get_sealed_prefixes);
	ClassDB::bind_method(D_METHOD("get_violation_count"), &PlayForgePlatform::get_violation_count);
	ClassDB::bind_method(D_METHOD("is_platform_menu_open"), &PlayForgePlatform::is_platform_menu_open);
	ClassDB::bind_method(D_METHOD("set_platform_menu_open", "open"), &PlayForgePlatform::set_platform_menu_open);
	ClassDB::bind_method(D_METHOD("ensure_scene_avatar", "scene"), &PlayForgePlatform::ensure_scene_avatar);
}
