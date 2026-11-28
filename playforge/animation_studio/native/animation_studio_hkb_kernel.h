#pragma once

#include <cstdint>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// High-performance C++ GDExtension kernel accelerating performance-critical
// Havok Behavior (`hkb*`) pose operations and modifiers with zero engine edits.
// All rotation buffers use tightly packed xyzw float32 arrays (4 floats per bone)
// for L1-cache-friendly execution without per-bone Variant boxing overhead.
class AnimationStudioHkbKernel : public RefCounted {
	GDCLASS(AnimationStudioHkbKernel, RefCounted);

protected:
	static void _bind_methods();

public:
	AnimationStudioHkbKernel() = default;
	~AnimationStudioHkbKernel() override = default;

	// Skeleton <-> Packed pose buffer transfers (eliminates 3*B GDScript bridge calls/tick)
	Dictionary init_pose_from_skeleton(Skeleton3D *p_skeleton) const;
	Dictionary read_pose_from_skeleton(Skeleton3D *p_skeleton) const;
	void apply_pose_to_skeleton(
			Skeleton3D *p_skeleton,
			const PackedVector3Array &p_pos,
			const PackedFloat32Array &p_rot_xyzw,
			const PackedVector3Array &p_scl,
			bool p_force_update = true) const;

	// Packed clip track sampling (`hkbClipGenerator`) with O(log K) binary search + SLERP
	Dictionary sample_clip_packed(
			const PackedVector3Array &p_base_pos,
			const PackedFloat32Array &p_base_rot_xyzw,
			const PackedVector3Array &p_base_scl,
			const PackedInt32Array &p_bone_ids,
			const PackedInt32Array &p_key_offsets,
			const PackedInt32Array &p_key_counts,
			const PackedFloat32Array &p_key_times,
			const PackedVector3Array &p_key_pos,
			const PackedFloat32Array &p_key_rot_xyzw,
			double p_local_time) const;

	// Full-skeleton weighted SLERP pose blend (`hkbBlenderGenerator`, `hkbLayerGenerator`, `hkbStateMachine`)
	Dictionary blend_poses(
			const PackedVector3Array &p_pos_a,
			const PackedFloat32Array &p_rot_a,
			const PackedVector3Array &p_scl_a,
			const PackedVector3Array &p_pos_b,
			const PackedFloat32Array &p_rot_b,
			const PackedVector3Array &p_scl_b,
			float p_weight,
			const PackedFloat32Array &p_bone_weights) const;

	// Full-skeleton additive pose delta application (`hkbLayerGenerator` additive, aim overlays)
	Dictionary apply_additive(
			const PackedVector3Array &p_base_pos,
			const PackedFloat32Array &p_base_rot,
			const PackedVector3Array &p_delta_pos,
			const PackedFloat32Array &p_delta_rot,
			const PackedVector3Array &p_ref_pos,
			const PackedFloat32Array &p_ref_rot,
			float p_weight,
			const PackedFloat32Array &p_bone_weights) const;

	// Exact `hkbMirrorModifier` / `hkaMirroredSkeleton` local-space sagittal reflection
	Dictionary mirror_pose_local(
			const PackedVector3Array &p_pos,
			const PackedFloat32Array &p_rot_xyzw,
			const PackedInt32Array &p_pair,
			const PackedVector3Array &p_ref_pos,
			const PackedFloat32Array &p_ref_rot_xyzw) const;

	// Exact model-space `hkaMirroredSkeleton` reflection directly on Skeleton3D
	//   G_mir[b].basis = M * (G[m(b)].basis * R[m(b)]^-1) * M * R[b]
	void mirror_skeleton_model_space(
			Skeleton3D *p_skeleton,
			const PackedInt32Array &p_pair) const;

	// `hkbLookAtModifier`: smoothed target tracking + limit cone + Neck/Head aim composition
	Dictionary apply_look_at(
			const Transform3D &p_skel_global,
			const PackedFloat32Array &p_rot_xyzw,
			int32_t p_head_idx,
			int32_t p_neck_idx,
			const Vector3 &p_target_ws,
			const Vector3 &p_prev_smoothed,
			bool p_has_smoothed,
			float p_new_target_gain,
			float p_limit_deg,
			float p_on_gain,
			float p_off_gain,
			bool p_is_on,
			float p_prev_weight) const;

	// `hkbTwistModifier`: distributed chain twist
	PackedFloat32Array apply_twist_chain(
			const PackedFloat32Array &p_rot_xyzw,
			const PackedInt32Array &p_chain_indices,
			const Vector3 &p_axis,
			float p_twist_deg,
			bool p_is_additive) const;

	// `hkaTwoJointsIkSolver` (`hkbFootIkDriver` + `hkbHandIkControlsModifier`)
	PackedFloat32Array solve_two_bone_ik(
			Skeleton3D *p_skeleton,
			const PackedFloat32Array &p_rot_xyzw,
			int32_t p_upper_idx,
			int32_t p_mid_idx,
			int32_t p_end_idx,
			const Vector3 &p_target_ws,
			float p_weight) const;

	// `hkbDampingModifier`: scalar + vector PID damping step
	Dictionary step_damping_pid(
			float p_raw_val,
			float p_damped_val,
			float p_err_sum,
			float p_prev_err,
			const Vector3 &p_raw_vec,
			const Vector3 &p_damped_vec,
			const Vector3 &p_vec_err_sum,
			const Vector3 &p_vec_prev_err,
			float p_kp,
			float p_ki,
			float p_kd,
			bool p_enable_scalar,
			bool p_enable_vector) const;

	// `hkbJigglerModifier`: single or multi-bone secondary spring-damper chain
	Dictionary step_jiggler_chain(
			const PackedFloat32Array &p_rot_xyzw,
			const PackedInt32Array &p_bone_indices,
			const PackedVector3Array &p_vel_arr,
			const PackedVector3Array &p_disp_arr,
			const Vector3 &p_actor_accel,
			float p_stiffness,
			float p_damping,
			float p_max_deg,
			float p_dt) const;
};

} // namespace godot
