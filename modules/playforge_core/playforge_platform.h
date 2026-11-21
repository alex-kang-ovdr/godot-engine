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
	bool menu_open = false;
	Rect2 topbar_safe_inset = Rect2(12.0f, 12.0f, 224.0f, 44.0f);

	static void _seal_subtree(Node *p_root, bool p_hide_from_user_tree);
	static bool _is_3d_world(Node *p_scene);
	static bool _has_type_recursive(Node *p_root, const StringName &p_class);
	static Node *_find_script_path_recursive(Node *p_root, const String &p_suffix);

	void _ensure_hud(SceneTree *p_tree);
	void _seal_avatar_instance(Node *p_avatar);
	void _on_avatar_ready(uint64_t p_avatar_id);
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
	PackedStringArray get_sealed_prefixes() const;
	int64_t get_violation_count() const;
	bool is_platform_menu_open() const { return menu_open; }
	void set_platform_menu_open(bool p_open);
	Node *ensure_scene_avatar(Node *p_scene);

	PlayForgePlatform();
	~PlayForgePlatform();
};
