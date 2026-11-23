#include "register_types.h"

#include "playforge_physics_batch.h"
#include "playforge_platform.h"

#include "core/config/engine.h"
#include "core/object/class_db.h"
#include "scene/main/scene_tree.h"

static PlayForgePlatform *playforge_platform_singleton = nullptr;

void initialize_playforge_core_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	GDREGISTER_CLASS(PlayForgePlatform);
	GDREGISTER_CLASS(PlayForgePhysicsBatch);
	playforge_platform_singleton = memnew(PlayForgePlatform);
	Engine::get_singleton()->add_singleton(Engine::Singleton("PlayForgePlatform", playforge_platform_singleton));
	SceneTree::set_playforge_hooks(&PlayForgePlatform::on_tree_initialized, &PlayForgePlatform::on_scene_loaded);
}

void uninitialize_playforge_core_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	PlayForgePhysicsBatch::clear_cache();
	SceneTree::set_playforge_hooks(nullptr, nullptr);
	if (playforge_platform_singleton) {
		Engine::get_singleton()->remove_singleton("PlayForgePlatform");
		memdelete(playforge_platform_singleton);
		playforge_platform_singleton = nullptr;
	}
}
