#pragma once

#include "core/object/object.h"
#include "core/math/rect2.h"
#include "core/variant/typed_array.h"

class SceneTree;
class Node;
class CanvasLayer;
class Control;

class PlayForgePlatform : public Object {
	GDCLASS(PlayForgePlatform, Object);

	static PlayForgePlatform *singleton;

	ObjectID hud_layer_id;
	ObjectID menu_panel_id;
	ObjectID local_avatar_id;
	ObjectID portrait_layer_id;
	ObjectID portrait_ui_id;
	bool menu_open = false;
	int presentation_mode = 0; // 0=WORLD_3D, 1=PORTRAIT_UPPER_BODY, 2=PORTRAIT_FULL_BODY, 3=WORLD_3D_WITH_PORTRAIT
	int portrait_framing = 0; // 0=UPPER_BODY, 1=FULL_BODY
	int portrait_corner = 0; // 0=BOTTOM_LEFT, 1=TOP_RIGHT, 2=BOTTOM_RIGHT, 3=TOP_LEFT_BELOW_HUD
	Rect2 topbar_safe_inset = Rect2(12.0f, 12.0f, 224.0f, 44.0f);

	static void _seal_subtree(Node *p_root, bool p_hide_from_user_tree);
	static bool _is_3d_world(Node *p_scene);
	static bool _has_type_recursive(Node *p_root, const StringName &p_class);
	static Node *_find_script_path_recursive(Node *p_root, const String &p_suffix);
	static void _resolve_presentation_config(Node *p_scene, int &r_mode, Size2 &r_size, int &r_corner);

	void _ensure_hud(SceneTree *p_tree);
	void _seal_avatar_instance(Node *p_avatar);
	void _on_avatar_ready(uint64_t p_avatar_id);
	Control *_ensure_portrait_ui(SceneTree *p_tree, int p_framing, const Size2 &p_requested_size, int p_corner);
	void _remove_portrait_ui();
	void _seal_portrait_instance(Control *p_portrait, const Size2 &p_min_size);
	void _on_portrait_ready(uint64_t p_portrait_id);
	void _on_menu_toggle_pressed();
	void _on_camera_cycle_pressed();
	void _on_ragdoll_pressed();
	void _on_leave_pressed();
	void _on_emote_pressed(int p_slot);

protected:
	static void _bind_methods();

public:
	static PlayForgePlatform *get_singleton() { return singleton; }

	static void on_tree_initialized(SceneTree *p_tree);
	static void on_scene_loaded(SceneTree *p_tree, Node *p_scene);

	bool is_engine_sealed() const { return true; }
	bool is_platform_hud_active() const;
	Rect2 get_topbar_safe_inset() const { return topbar_safe_inset; }
	Node *get_local_avatar() const;
	Control *get_avatar_portrait_ui() const;
	int get_avatar_presentation_mode() const { return presentation_mode; }
	Size2 get_portrait_min_size(int p_framing) const;
	Node *set_avatar_presentation_mode(int p_mode, const Size2 &p_portrait_size = Size2(), int p_corner = 0);
	Control *set_portrait_framing(int p_framing, const Size2 &p_portrait_size = Size2());
	PackedStringArray get_sealed_prefixes() const;
	int64_t get_violation_count() const;
	bool is_platform_menu_open() const { return menu_open; }
	void set_platform_menu_open(bool p_open);
	Node *ensure_scene_avatar(Node *p_scene);

	PlayForgePlatform();
	~PlayForgePlatform();
};
