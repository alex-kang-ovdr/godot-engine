#include <cmath>
#include <cstdint>

#include "animation_studio_crowd_evaluator.h"

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

using namespace godot;

class AnimationStudioPoseSampler : public RefCounted {
	GDCLASS(AnimationStudioPoseSampler, RefCounted);

	Ref<Animation> snapshot;
	Vector<int32_t> track_indices;
	Vector<StringName> bone_names;
	Vector<int32_t> bone_indices;
	uint64_t cached_skeleton_id = 0;
	uint64_t cached_skeleton_version = UINT64_MAX;

	void _clear_configuration() {
		snapshot.unref();
		track_indices.clear();
		bone_names.clear();
		bone_indices.clear();
		cached_skeleton_id = 0;
		cached_skeleton_version = UINT64_MAX;
	}

	void _refresh_bone_indices(Skeleton3D *p_skeleton) {
		bone_indices.resize(bone_names.size());
		for (int32_t i = 0; i < bone_names.size(); i++) {
			bone_indices.write[i] = p_skeleton->find_bone(String(bone_names[i]));
		}
		cached_skeleton_id = p_skeleton->get_instance_id();
		cached_skeleton_version = p_skeleton->get_version();
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("configure", "snapshot", "track_indices", "bone_names"), &AnimationStudioPoseSampler::configure);
		ClassDB::bind_method(D_METHOD("apply_pose", "skeleton", "time", "backwards"), &AnimationStudioPoseSampler::apply_pose);
	}

public:
	void configure(const Ref<Animation> &p_snapshot, const PackedInt32Array &p_track_indices, const PackedStringArray &p_bone_names) {
		_clear_configuration();

		if (p_snapshot.is_null() || p_track_indices.is_empty() || p_track_indices.size() != p_bone_names.size()) {
			return;
		}

		Vector<int32_t> validated_tracks;
		Vector<StringName> validated_bones;
		validated_tracks.resize(p_track_indices.size());
		validated_bones.resize(p_bone_names.size());

		for (int32_t i = 0; i < p_track_indices.size(); i++) {
			const int32_t track_index = p_track_indices[i];
			const StringName bone_name(p_bone_names[i]);
			if (track_index < 0 || track_index >= p_snapshot->get_track_count() || bone_name.is_empty()) {
				return;
			}

			const Animation::TrackType track_type = p_snapshot->track_get_type(track_index);
			if (track_type != Animation::TYPE_POSITION_3D && track_type != Animation::TYPE_ROTATION_3D && track_type != Animation::TYPE_SCALE_3D) {
				return;
			}
			if (!p_snapshot->track_is_enabled(track_index) || p_snapshot->track_get_key_count(track_index) == 0) {
				return;
			}

			const NodePath track_path = p_snapshot->track_get_path(track_index);
			if (track_path.get_subname_count() != 1 || track_path.get_subname(0) != bone_name) {
				return;
			}

			for (int32_t j = 0; j < i; j++) {
				if (validated_tracks[j] == track_index ||
						(validated_bones[j] == bone_name && p_snapshot->track_get_type(validated_tracks[j]) == track_type)) {
					return;
				}
			}

			validated_tracks.write[i] = track_index;
			validated_bones.write[i] = bone_name;
		}

		snapshot = p_snapshot;
		track_indices = validated_tracks;
		bone_names = validated_bones;
	}

	void apply_pose(Skeleton3D *p_skeleton, double p_time, bool p_backwards) {
		if (snapshot.is_null() || p_skeleton == nullptr || !std::isfinite(p_time)) {
			return;
		}

		const uint64_t skeleton_id = p_skeleton->get_instance_id();
		const uint64_t skeleton_version = p_skeleton->get_version();
		if (cached_skeleton_id != skeleton_id || cached_skeleton_version != skeleton_version || bone_indices.size() != bone_names.size()) {
			_refresh_bone_indices(p_skeleton);
		}

		const float motion_scale = p_skeleton->get_motion_scale();
		for (int32_t i = 0; i < track_indices.size(); i++) {
			const int32_t track_index = track_indices[i];
			const int32_t bone_index = bone_indices[i];
			if (bone_index < 0 || track_index < 0 || track_index >= snapshot->get_track_count() || !snapshot->track_is_enabled(track_index)) {
				continue;
			}

			if (snapshot->track_get_key_count(track_index) == 0) {
				continue;
			}

			switch (snapshot->track_get_type(track_index)) {
				case Animation::TYPE_POSITION_3D:
					p_skeleton->set_bone_pose_position(bone_index, snapshot->position_track_interpolate(track_index, p_time, p_backwards) * motion_scale);
					break;
				case Animation::TYPE_ROTATION_3D:
					p_skeleton->set_bone_pose_rotation(bone_index, snapshot->rotation_track_interpolate(track_index, p_time, p_backwards));
					break;
				case Animation::TYPE_SCALE_3D:
					p_skeleton->set_bone_pose_scale(bone_index, snapshot->scale_track_interpolate(track_index, p_time, p_backwards));
					break;
				default:
					break;
			}
		}
	}
};

void initialize_animation_studio_module(ModuleInitializationLevel p_level) {
	if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_CLASS(AnimationStudioPoseSampler);
		GDREGISTER_CLASS(AnimationStudioCrowdEvaluator);
	}
}

void uninitialize_animation_studio_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT animation_studio_pose_sampler_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_object(p_get_proc_address, p_library, r_initialization);
	init_object.register_initializer(initialize_animation_studio_module);
	init_object.register_terminator(uninitialize_animation_studio_module);
	init_object.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_object.init();
}
}
