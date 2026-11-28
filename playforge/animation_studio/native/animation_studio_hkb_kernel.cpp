#include "animation_studio_hkb_kernel.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>

using namespace godot;

namespace {

constexpr float DEG_TO_RAD_F = 3.14159265358979323846f / 180.0f;

static inline float clamp_f(float v, float lo, float hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

static inline Quaternion load_q(const float *p_ptr, int32_t p_bi) {
	const int32_t o = p_bi * 4;
	return Quaternion(p_ptr[o], p_ptr[o + 1], p_ptr[o + 2], p_ptr[o + 3]);
}

static inline void store_q(float *p_ptr, int32_t p_bi, const Quaternion &p_q) {
	const int32_t o = p_bi * 4;
	p_ptr[o] = p_q.x;
	p_ptr[o + 1] = p_q.y;
	p_ptr[o + 2] = p_q.z;
	p_ptr[o + 3] = p_q.w;
}

static inline Quaternion normalize_safe(const Quaternion &p_q) {
	const float len_sq = p_q.x * p_q.x + p_q.y * p_q.y + p_q.z * p_q.z + p_q.w * p_q.w;
	if (len_sq <= 1e-12f) {
		return Quaternion(0.0f, 0.0f, 0.0f, 1.0f);
	}
	const float inv = 1.0f / std::sqrt(len_sq);
	return Quaternion(p_q.x * inv, p_q.y * inv, p_q.z * inv, p_q.w * inv);
}

static inline Quaternion slerp_shortest(const Quaternion &p_a, Quaternion p_b, float p_w) {
	if (p_a.dot(p_b) < 0.0f) {
		p_b = -p_b;
	}
	return normalize_safe(p_a.slerp(p_b, p_w));
}

static inline Quaternion quat_from_to(const Vector3 &p_from, const Vector3 &p_to) {
	const Vector3 c = p_from.cross(p_to);
	const float d = p_from.dot(p_to);
	if (d < -1.0f + 1e-6f) {
		Vector3 ortho = Vector3(1.0f, 0.0f, 0.0f).cross(p_from);
		if (ortho.length_squared() < 1e-6f) {
			ortho = Vector3(0.0f, 1.0f, 0.0f).cross(p_from);
		}
		ortho.normalize();
		return Quaternion(ortho.x, ortho.y, ortho.z, 0.0f);
	}
	const float s = std::sqrt((1.0f + d) * 2.0f);
	const float rs = 1.0f / s;
	return normalize_safe(Quaternion(c.x * rs, c.y * rs, c.z * rs, s * 0.5f));
}

} // namespace

void AnimationStudioHkbKernel::_bind_methods() {
	ClassDB::bind_method(D_METHOD("init_pose_from_skeleton", "skeleton"), &AnimationStudioHkbKernel::init_pose_from_skeleton);
	ClassDB::bind_method(D_METHOD("read_pose_from_skeleton", "skeleton"), &AnimationStudioHkbKernel::read_pose_from_skeleton);
	ClassDB::bind_method(
			D_METHOD("apply_pose_to_skeleton", "skeleton", "pos", "rot_xyzw", "scl", "force_update"),
			&AnimationStudioHkbKernel::apply_pose_to_skeleton,
			DEFVAL(true));
	ClassDB::bind_method(
			D_METHOD("sample_clip_packed", "base_pos", "base_rot_xyzw", "base_scl", "bone_ids", "key_offsets", "key_counts", "key_times", "key_pos", "key_rot_xyzw", "local_time"),
			&AnimationStudioHkbKernel::sample_clip_packed);
	ClassDB::bind_method(
			D_METHOD("blend_poses", "pos_a", "rot_a", "scl_a", "pos_b", "rot_b", "scl_b", "weight", "bone_weights"),
			&AnimationStudioHkbKernel::blend_poses);
	ClassDB::bind_method(
			D_METHOD("apply_additive", "base_pos", "base_rot", "delta_pos", "delta_rot", "ref_pos", "ref_rot", "weight", "bone_weights"),
			&AnimationStudioHkbKernel::apply_additive);
	ClassDB::bind_method(
			D_METHOD("mirror_pose_local", "pos", "rot_xyzw", "pair", "ref_pos", "ref_rot_xyzw"),
			&AnimationStudioHkbKernel::mirror_pose_local);
	ClassDB::bind_method(
			D_METHOD("mirror_skeleton_model_space", "skeleton", "pair"),
			&AnimationStudioHkbKernel::mirror_skeleton_model_space);
	ClassDB::bind_method(
			D_METHOD("apply_look_at", "skel_global", "rot_xyzw", "head_idx", "neck_idx", "target_ws", "prev_smoothed", "has_smoothed", "new_target_gain", "limit_deg", "on_gain", "off_gain", "is_on", "prev_weight"),
			&AnimationStudioHkbKernel::apply_look_at);
	ClassDB::bind_method(
			D_METHOD("apply_twist_chain", "rot_xyzw", "chain_indices", "axis", "twist_deg", "is_additive"),
			&AnimationStudioHkbKernel::apply_twist_chain);
	ClassDB::bind_method(
			D_METHOD("solve_two_bone_ik", "skeleton", "rot_xyzw", "upper_idx", "mid_idx", "end_idx", "target_ws", "weight"),
			&AnimationStudioHkbKernel::solve_two_bone_ik);
	ClassDB::bind_method(
			D_METHOD("step_damping_pid", "raw_val", "damped_val", "err_sum", "prev_err", "raw_vec", "damped_vec", "vec_err_sum", "vec_prev_err", "kp", "ki", "kd", "enable_scalar", "enable_vector"),
			&AnimationStudioHkbKernel::step_damping_pid);
	ClassDB::bind_method(
			D_METHOD("step_jiggler_chain", "rot_xyzw", "bone_indices", "vel_arr", "disp_arr", "actor_accel", "stiffness", "damping", "max_deg", "dt"),
			&AnimationStudioHkbKernel::step_jiggler_chain);
}

Dictionary AnimationStudioHkbKernel::init_pose_from_skeleton(Skeleton3D *p_skeleton) const {
	Dictionary out;
	if (p_skeleton == nullptr) {
		return out;
	}
	const int32_t n = p_skeleton->get_bone_count();
	PackedVector3Array pos;
	PackedFloat32Array rot_xyzw;
	PackedVector3Array scl;
	pos.resize(n);
	rot_xyzw.resize(n * 4);
	scl.resize(n);

	Vector3 *pp = pos.ptrw();
	float *pr = rot_xyzw.ptrw();
	Vector3 *ps = scl.ptrw();
	for (int32_t bi = 0; bi < n; bi++) {
		const Transform3D rest = p_skeleton->get_bone_rest(bi);
		pp[bi] = rest.origin;
		store_q(pr, bi, normalize_safe(rest.basis.get_rotation_quaternion()));
		ps[bi] = rest.basis.get_scale();
	}
	out["bone_count"] = n;
	out["pos"] = pos;
	out["rot_xyzw"] = rot_xyzw;
	out["scl"] = scl;
	return out;
}

Dictionary AnimationStudioHkbKernel::read_pose_from_skeleton(Skeleton3D *p_skeleton) const {
	Dictionary out;
	if (p_skeleton == nullptr) {
		return out;
	}
	const int32_t n = p_skeleton->get_bone_count();
	PackedVector3Array pos;
	PackedFloat32Array rot_xyzw;
	PackedVector3Array scl;
	pos.resize(n);
	rot_xyzw.resize(n * 4);
	scl.resize(n);

	Vector3 *pp = pos.ptrw();
	float *pr = rot_xyzw.ptrw();
	Vector3 *ps = scl.ptrw();
	for (int32_t bi = 0; bi < n; bi++) {
		pp[bi] = p_skeleton->get_bone_pose_position(bi);
		store_q(pr, bi, normalize_safe(p_skeleton->get_bone_pose_rotation(bi)));
		ps[bi] = p_skeleton->get_bone_pose_scale(bi);
	}
	out["bone_count"] = n;
	out["pos"] = pos;
	out["rot_xyzw"] = rot_xyzw;
	out["scl"] = scl;
	return out;
}

void AnimationStudioHkbKernel::apply_pose_to_skeleton(
		Skeleton3D *p_skeleton,
		const PackedVector3Array &p_pos,
		const PackedFloat32Array &p_rot_xyzw,
		const PackedVector3Array &p_scl,
		bool p_force_update) const {
	if (p_skeleton == nullptr) {
		return;
	}
	const int32_t skel_n = p_skeleton->get_bone_count();
	const int32_t rot_n = static_cast<int32_t>(p_rot_xyzw.size() / 4);
	const int32_t n = std::min({ skel_n, static_cast<int32_t>(p_pos.size()), rot_n, static_cast<int32_t>(p_scl.size()) });
	if (n <= 0) {
		return;
	}
	const Vector3 *pp = p_pos.ptr();
	const float *pr = p_rot_xyzw.ptr();
	const Vector3 *ps = p_scl.ptr();
	for (int32_t bi = 0; bi < n; bi++) {
		p_skeleton->set_bone_pose_position(bi, pp[bi]);
		p_skeleton->set_bone_pose_rotation(bi, load_q(pr, bi));
		p_skeleton->set_bone_pose_scale(bi, ps[bi]);
	}
	if (p_force_update) {
		p_skeleton->force_update_all_bone_transforms();
	}
}

Dictionary AnimationStudioHkbKernel::sample_clip_packed(
		const PackedVector3Array &p_base_pos,
		const PackedFloat32Array &p_base_rot_xyzw,
		const PackedVector3Array &p_base_scl,
		const PackedInt32Array &p_bone_ids,
		const PackedInt32Array &p_key_offsets,
		const PackedInt32Array &p_key_counts,
		const PackedFloat32Array &p_key_times,
		const PackedVector3Array &p_key_pos,
		const PackedFloat32Array &p_key_rot_xyzw,
		double p_local_time) const {
	Dictionary out;
	const int32_t bone_count = static_cast<int32_t>(p_base_pos.size());
	PackedVector3Array out_pos = p_base_pos.duplicate();
	PackedFloat32Array out_rot = p_base_rot_xyzw.duplicate();
	PackedVector3Array out_scl = p_base_scl.duplicate();

	const int32_t track_count = std::min({
			static_cast<int32_t>(p_bone_ids.size()),
			static_cast<int32_t>(p_key_offsets.size()),
			static_cast<int32_t>(p_key_counts.size()),
	});
	const int32_t total_keys = static_cast<int32_t>(p_key_times.size());
	if (bone_count <= 0 || track_count <= 0 || total_keys <= 0 ||
			static_cast<int32_t>(p_key_pos.size()) < total_keys ||
			static_cast<int32_t>(p_key_rot_xyzw.size()) < total_keys * 4 ||
			static_cast<int32_t>(out_rot.size()) < bone_count * 4) {
		out["pos"] = out_pos;
		out["rot_xyzw"] = out_rot;
		out["scl"] = out_scl;
		return out;
	}

	const int32_t *bids = p_bone_ids.ptr();
	const int32_t *koffs = p_key_offsets.ptr();
	const int32_t *kcnts = p_key_counts.ptr();
	const float *ktimes = p_key_times.ptr();
	const Vector3 *kpos = p_key_pos.ptr();
	const float *krot = p_key_rot_xyzw.ptr();

	Vector3 *dst_p = out_pos.ptrw();
	float *dst_r = out_rot.ptrw();
	const float lt = static_cast<float>(p_local_time);

	for (int32_t ti = 0; ti < track_count; ti++) {
		const int32_t bi = bids[ti];
		const int32_t off = koffs[ti];
		const int32_t kn = kcnts[ti];
		if (bi < 0 || bi >= bone_count || off < 0 || kn <= 0 || off + kn > total_keys) {
			continue;
		}
		int32_t lo = 0;
		int32_t hi = kn - 1;
		const float *ts = ktimes + off;
		if (lt <= ts[0]) {
			hi = 0;
		} else if (lt >= ts[hi]) {
			lo = hi;
		} else {
			while (lo + 1 < hi) {
				const int32_t mid = (lo + hi) >> 1;
				if (ts[mid] <= lt) {
					lo = mid;
				} else {
					hi = mid;
				}
			}
		}
		const int32_t i0 = off + lo;
		const int32_t i1 = off + hi;
		if (i0 == i1) {
			dst_p[bi] = kpos[i0];
			store_q(dst_r, bi, normalize_safe(load_q(krot, i0)));
		} else {
			const float t0 = ktimes[i0];
			const float t1 = ktimes[i1];
			const float w = (t1 > t0) ? ((lt - t0) / (t1 - t0)) : 0.0f;
			dst_p[bi] = kpos[i0].lerp(kpos[i1], w);
			const Quaternion q0 = normalize_safe(load_q(krot, i0));
			const Quaternion q1 = normalize_safe(load_q(krot, i1));
			store_q(dst_r, bi, slerp_shortest(q0, q1, w));
		}
	}

	out["pos"] = out_pos;
	out["rot_xyzw"] = out_rot;
	out["scl"] = out_scl;
	return out;
}

Dictionary AnimationStudioHkbKernel::blend_poses(
		const PackedVector3Array &p_pos_a,
		const PackedFloat32Array &p_rot_a,
		const PackedVector3Array &p_scl_a,
		const PackedVector3Array &p_pos_b,
		const PackedFloat32Array &p_rot_b,
		const PackedVector3Array &p_scl_b,
		float p_weight,
		const PackedFloat32Array &p_bone_weights) const {
	Dictionary out;
	const int32_t n = std::min({
			static_cast<int32_t>(p_pos_a.size()),
			static_cast<int32_t>(p_pos_b.size()),
			static_cast<int32_t>(p_rot_a.size() / 4),
			static_cast<int32_t>(p_rot_b.size() / 4),
			static_cast<int32_t>(p_scl_a.size()),
			static_cast<int32_t>(p_scl_b.size()),
	});
	PackedVector3Array out_pos = p_pos_a.duplicate();
	PackedFloat32Array out_rot = p_rot_a.duplicate();
	PackedVector3Array out_scl = p_scl_a.duplicate();
	if (n <= 0 || p_weight <= 1e-6f) {
		out["pos"] = out_pos;
		out["rot_xyzw"] = out_rot;
		out["scl"] = out_scl;
		return out;
	}

	const bool has_bw = !p_bone_weights.is_empty();
	const int32_t bw_size = static_cast<int32_t>(p_bone_weights.size());
	const float *bw_ptr = has_bw ? p_bone_weights.ptr() : nullptr;

	const Vector3 *pa = p_pos_a.ptr();
	const float *ra = p_rot_a.ptr();
	const Vector3 *sa = p_scl_a.ptr();
	const Vector3 *pb = p_pos_b.ptr();
	const float *rb = p_rot_b.ptr();
	const Vector3 *sb = p_scl_b.ptr();

	Vector3 *dp = out_pos.ptrw();
	float *dr = out_rot.ptrw();
	Vector3 *ds = out_scl.ptrw();

	for (int32_t bi = 0; bi < n; bi++) {
		float bw = p_weight;
		if (has_bw) {
			const float m = (bi < bw_size) ? bw_ptr[bi] : 1.0f;
			bw = clamp_f(p_weight * m, 0.0f, 1.0f);
		}
		if (bw <= 1e-6f) {
			continue;
		}
		if (bw >= 0.9999f) {
			dp[bi] = pb[bi];
			store_q(dr, bi, load_q(rb, bi));
			ds[bi] = sb[bi];
		} else {
			dp[bi] = pa[bi].lerp(pb[bi], bw);
			store_q(dr, bi, slerp_shortest(load_q(ra, bi), load_q(rb, bi), bw));
			ds[bi] = sa[bi].lerp(sb[bi], bw);
		}
	}

	out["pos"] = out_pos;
	out["rot_xyzw"] = out_rot;
	out["scl"] = out_scl;
	return out;
}

Dictionary AnimationStudioHkbKernel::apply_additive(
		const PackedVector3Array &p_base_pos,
		const PackedFloat32Array &p_base_rot,
		const PackedVector3Array &p_delta_pos,
		const PackedFloat32Array &p_delta_rot,
		const PackedVector3Array &p_ref_pos,
		const PackedFloat32Array &p_ref_rot,
		float p_weight,
		const PackedFloat32Array &p_bone_weights) const {
	Dictionary out;
	const int32_t n = std::min({
			static_cast<int32_t>(p_base_pos.size()),
			static_cast<int32_t>(p_delta_pos.size()),
			static_cast<int32_t>(p_ref_pos.size()),
			static_cast<int32_t>(p_base_rot.size() / 4),
			static_cast<int32_t>(p_delta_rot.size() / 4),
			static_cast<int32_t>(p_ref_rot.size() / 4),
	});
	PackedVector3Array out_pos = p_base_pos.duplicate();
	PackedFloat32Array out_rot = p_base_rot.duplicate();
	if (n <= 0 || p_weight <= 1e-6f) {
		out["pos"] = out_pos;
		out["rot_xyzw"] = out_rot;
		return out;
	}

	const bool has_bw = !p_bone_weights.is_empty();
	const int32_t bw_size = static_cast<int32_t>(p_bone_weights.size());
	const float *bw_ptr = has_bw ? p_bone_weights.ptr() : nullptr;

	const Vector3 *dpos = p_delta_pos.ptr();
	const Vector3 *rpos = p_ref_pos.ptr();
	const float *drot = p_delta_rot.ptr();
	const float *rrot = p_ref_rot.ptr();

	Vector3 *op = out_pos.ptrw();
	float *orot = out_rot.ptrw();
	const Quaternion q_id(0.0f, 0.0f, 0.0f, 1.0f);

	for (int32_t bi = 0; bi < n; bi++) {
		float bw = p_weight;
		if (has_bw) {
			const float m = (bi < bw_size) ? bw_ptr[bi] : 1.0f;
			bw = clamp_f(p_weight * m, 0.0f, 1.0f);
		}
		if (bw <= 1e-6f) {
			continue;
		}
		op[bi] += (dpos[bi] - rpos[bi]) * bw;
		const Quaternion dr = load_q(drot, bi);
		const Quaternion rr = load_q(rrot, bi);
		Quaternion dq = normalize_safe(dr * rr.inverse());
		if (dq.w < 0.0f) {
			dq = -dq;
		}
		const Quaternion scaled_dq = normalize_safe(q_id.slerp(dq, bw));
		store_q(orot, bi, normalize_safe(scaled_dq * load_q(orot, bi)));
	}

	out["pos"] = out_pos;
	out["rot_xyzw"] = out_rot;
	return out;
}

Dictionary AnimationStudioHkbKernel::mirror_pose_local(
		const PackedVector3Array &p_pos,
		const PackedFloat32Array &p_rot_xyzw,
		const PackedInt32Array &p_pair,
		const PackedVector3Array &p_ref_pos,
		const PackedFloat32Array &p_ref_rot_xyzw) const {
	Dictionary out;
	const int32_t n = std::min({
			static_cast<int32_t>(p_pos.size()),
			static_cast<int32_t>(p_rot_xyzw.size() / 4),
			static_cast<int32_t>(p_pair.size()),
			static_cast<int32_t>(p_ref_pos.size()),
			static_cast<int32_t>(p_ref_rot_xyzw.size() / 4),
	});
	PackedVector3Array out_pos;
	PackedFloat32Array out_rot;
	out_pos.resize(n);
	out_rot.resize(n * 4);
	if (n <= 0) {
		out["pos"] = out_pos;
		out["rot_xyzw"] = out_rot;
		return out;
	}

	const Vector3 *sp = p_pos.ptr();
	const float *sr = p_rot_xyzw.ptr();
	const int32_t *pairs = p_pair.ptr();
	const Vector3 *rp = p_ref_pos.ptr();
	const float *rr = p_ref_rot_xyzw.ptr();

	Vector3 *dp = out_pos.ptrw();
	float *dr = out_rot.ptrw();

	for (int32_t bi = 0; bi < n; bi++) {
		const int32_t partner = pairs[bi];
		if (partner < 0 || partner >= n) {
			dp[bi] = sp[bi];
			store_q(dr, bi, load_q(sr, bi));
			continue;
		}
		const Quaternion q_src = load_q(sr, partner);
		const Quaternion q_ref_partner = load_q(rr, partner);
		const Quaternion q_ref_self = load_q(rr, bi);
		const Quaternion q_delta = normalize_safe(q_ref_partner.inverse() * q_src);
		const Quaternion q_delta_m = normalize_safe(Quaternion(q_delta.x, -q_delta.y, -q_delta.z, q_delta.w));
		store_q(dr, bi, normalize_safe(q_ref_self * q_delta_m));
		const Vector3 diff = sp[partner] - rp[partner];
		dp[bi] = rp[bi] + Vector3(-diff.x, diff.y, diff.z);
	}

	out["pos"] = out_pos;
	out["rot_xyzw"] = out_rot;
	return out;
}

void AnimationStudioHkbKernel::mirror_skeleton_model_space(
		Skeleton3D *p_skeleton,
		const PackedInt32Array &p_pair) const {
	if (p_skeleton == nullptr) {
		return;
	}
	p_skeleton->force_update_all_bone_transforms();
	const int32_t n = p_skeleton->get_bone_count();
	if (n <= 0 || static_cast<int32_t>(p_pair.size()) != n) {
		return;
	}

	const int32_t *mp = p_pair.ptr();
	const Basis mirror_b(Vector3(-1.0f, 0.0f, 0.0f), Vector3(0.0f, 1.0f, 0.0f), Vector3(0.0f, 0.0f, 1.0f));

	std::vector<int32_t> parents(static_cast<size_t>(n));
	std::vector<Transform3D> rest_g(static_cast<size_t>(n));
	std::vector<Transform3D> mir_global(static_cast<size_t>(n));

	for (int32_t bi = 0; bi < n; bi++) {
		const int32_t pi = p_skeleton->get_bone_parent(bi);
		parents[bi] = pi;
		const Transform3D rloc = p_skeleton->get_bone_rest(bi);
		rest_g[bi] = (pi < 0) ? rloc : (rest_g[pi] * rloc);
	}

	for (int32_t bi = 0; bi < n; bi++) {
		const int32_t partner = (mp[bi] >= 0 && mp[bi] < n) ? mp[bi] : bi;
		const Transform3D src_g = p_skeleton->get_bone_global_pose(partner);
		const Vector3 o = src_g.origin;
		const Basis skin_delta_b = src_g.basis * rest_g[partner].basis.inverse();
		const Basis mir_b = (mirror_b * skin_delta_b * mirror_b * rest_g[bi].basis).orthonormalized();
		mir_global[bi] = Transform3D(mir_b, Vector3(-o.x, o.y, o.z));
	}

	const Vector3 one(1.0f, 1.0f, 1.0f);
	for (int32_t bi = 0; bi < n; bi++) {
		const int32_t pi = parents[bi];
		const Transform3D loc = (pi < 0) ? mir_global[bi] : (mir_global[pi].affine_inverse() * mir_global[bi]);
		p_skeleton->set_bone_pose_position(bi, loc.origin);
		p_skeleton->set_bone_pose_rotation(bi, normalize_safe(loc.basis.get_rotation_quaternion()));
		p_skeleton->set_bone_pose_scale(bi, one);
	}
	p_skeleton->force_update_all_bone_transforms();
}

Dictionary AnimationStudioHkbKernel::apply_look_at(
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
		float p_prev_weight) const {
	Dictionary out;
	PackedFloat32Array out_rot = p_rot_xyzw.duplicate();
	const int32_t bone_count = static_cast<int32_t>(out_rot.size() / 4);
	Vector3 smoothed = p_has_smoothed
			? p_prev_smoothed.lerp(p_target_ws, clamp_f(p_new_target_gain, 0.01f, 1.0f))
			: p_target_ws;
	float weight = p_prev_weight;
	bool inside_cone = true;

	if (p_head_idx >= 0 && p_head_idx < bone_count) {
		Vector3 head_local_dir = p_skel_global.affine_inverse().xform(smoothed) - Vector3(0.0f, 1.55f, 0.0f);
		if (head_local_dir.length_squared() >= 1e-6f) {
			head_local_dir.normalize();
			// Godot standard right-handed axes (+Y up, -Z forward, +X right):
			// Quaternion(UP, yaw) * Vector3(0, 0, -1) = Vector3(-sin(yaw), 0, -cos(yaw))
			float yaw = std::atan2(-head_local_dir.x, -head_local_dir.z);
			float pitch = std::asin(clamp_f(head_local_dir.y, -0.95f, 0.95f));
			const float max_rad = std::max(5.0f, p_limit_deg) * DEG_TO_RAD_F;
			inside_cone = (std::fabs(yaw) <= max_rad && std::fabs(pitch) <= max_rad);
			const float desired_w = (p_is_on && inside_cone) ? 1.0f : 0.0f;
			const float gain = (desired_w > weight) ? p_on_gain : p_off_gain;
			const float cg = clamp_f(gain, 0.02f, 1.0f);
			weight = weight + (desired_w - weight) * cg;

			if (weight > 1e-4f) {
				yaw = clamp_f(yaw, -max_rad, max_rad) * weight;
				pitch = clamp_f(pitch, -max_rad * 0.65f, max_rad * 0.65f) * weight;
				float *dr = out_rot.ptrw();
				if (p_neck_idx >= 0 && p_neck_idx < bone_count) {
					const Quaternion qn = normalize_safe(
							Quaternion(Vector3(0.0f, 1.0f, 0.0f), yaw * 0.4f) *
							Quaternion(Vector3(1.0f, 0.0f, 0.0f), pitch * 0.35f));
					store_q(dr, p_neck_idx, normalize_safe(qn * load_q(dr, p_neck_idx)));
				}
				const Quaternion qh = normalize_safe(
						Quaternion(Vector3(0.0f, 1.0f, 0.0f), yaw * 0.6f) *
						Quaternion(Vector3(1.0f, 0.0f, 0.0f), pitch * 0.65f));
				store_q(dr, p_head_idx, normalize_safe(qh * load_q(dr, p_head_idx)));
			}
		}
	}

	out["rot_xyzw"] = out_rot;
	out["smoothed_target"] = smoothed;
	out["weight"] = weight;
	out["inside_cone"] = inside_cone;
	return out;
}

PackedFloat32Array AnimationStudioHkbKernel::apply_twist_chain(
		const PackedFloat32Array &p_rot_xyzw,
		const PackedInt32Array &p_chain_indices,
		const Vector3 &p_axis,
		float p_twist_deg,
		bool p_is_additive) const {
	PackedFloat32Array out_rot = p_rot_xyzw.duplicate();
	const int32_t bone_count = static_cast<int32_t>(out_rot.size() / 4);
	const int32_t chain_len = static_cast<int32_t>(p_chain_indices.size());
	if (bone_count <= 0 || chain_len <= 0 || std::fabs(p_twist_deg) < 1e-4f) {
		return out_rot;
	}

	const Vector3 ax = (p_axis.length_squared() > 1e-6f) ? p_axis.normalized() : Vector3(0.0f, 1.0f, 0.0f);
	const float per_bone_rad = (p_twist_deg * DEG_TO_RAD_F) / static_cast<float>(chain_len);
	const Quaternion dq = normalize_safe(Quaternion(ax, per_bone_rad));

	const int32_t *chain = p_chain_indices.ptr();
	float *dr = out_rot.ptrw();
	for (int32_t i = 0; i < chain_len; i++) {
		const int32_t bi = chain[i];
		if (bi < 0 || bi >= bone_count) {
			continue;
		}
		if (p_is_additive) {
			store_q(dr, bi, normalize_safe(dq * load_q(dr, bi)));
		} else {
			store_q(dr, bi, dq);
		}
	}
	return out_rot;
}

PackedFloat32Array AnimationStudioHkbKernel::solve_two_bone_ik(
		Skeleton3D *p_skeleton,
		const PackedFloat32Array &p_rot_xyzw,
		int32_t p_upper_idx,
		int32_t p_mid_idx,
		int32_t p_end_idx,
		const Vector3 &p_target_ws,
		float p_weight) const {
	PackedFloat32Array out_rot = p_rot_xyzw.duplicate();
	if (p_skeleton == nullptr) {
		return out_rot;
	}
	const int32_t bone_count = static_cast<int32_t>(out_rot.size() / 4);
	if (p_upper_idx < 0 || p_upper_idx >= bone_count ||
			p_mid_idx < 0 || p_mid_idx >= bone_count ||
			p_end_idx < 0 || p_end_idx >= bone_count) {
		return out_rot;
	}

	const Transform3D skel_xf = p_skeleton->get_global_transform();
	const Transform3D g_up = p_skeleton->get_bone_global_pose(p_upper_idx);
	const Transform3D g_mid = p_skeleton->get_bone_global_pose(p_mid_idx);
	const Transform3D g_end = p_skeleton->get_bone_global_pose(p_end_idx);

	const Vector3 a = skel_xf.xform(g_up.origin);
	const Vector3 b = skel_xf.xform(g_mid.origin);
	const Vector3 c = skel_xf.xform(g_end.origin);
	const float l1 = a.distance_to(b);
	const float l2 = b.distance_to(c);
	if (l1 < 1e-4f || l2 < 1e-4f) {
		return out_rot;
	}

	const Vector3 tgt = c.lerp(p_target_ws, clamp_f(p_weight, 0.0f, 1.0f));
	const Vector3 ac = c - a;
	const Vector3 at = tgt - a;
	if (ac.length_squared() < 1e-6f || at.length_squared() < 1e-6f) {
		return out_rot;
	}

	const float dist = clamp_f(at.length(), std::fabs(l1 - l2) + 0.01f, l1 + l2 - 0.005f);
	const Quaternion q_align_ws = quat_from_to(ac.normalized(), at.normalized());

	const float denom = 2.0f * l1 * l2;
	const float cur_cos = clamp_f((l1 * l1 + l2 * l2 - ac.length_squared()) / denom, -1.0f, 1.0f);
	const float des_cos = clamp_f((l1 * l1 + l2 * l2 - dist * dist) / denom, -1.0f, 1.0f);
	const float d_knee = std::acos(des_cos) - std::acos(cur_cos);

	Vector3 bend_axis_ws = (b - a).cross(c - b);
	if (bend_axis_ws.length_squared() < 1e-6f) {
		bend_axis_ws = skel_xf.basis.get_column(0);
	} else {
		bend_axis_ws.normalize();
	}

	float *dr = out_rot.ptrw();

	const int32_t up_p = p_skeleton->get_bone_parent(p_upper_idx);
	const Basis up_parent_b = (up_p >= 0)
			? (skel_xf * p_skeleton->get_bone_global_pose(up_p)).basis.orthonormalized()
			: skel_xf.basis.orthonormalized();
	const Quaternion q_up_pb = normalize_safe(up_parent_b.get_rotation_quaternion());
	const Quaternion q_up_local = normalize_safe(q_up_pb.inverse() * q_align_ws * q_up_pb);
	store_q(dr, p_upper_idx, normalize_safe(q_up_local * load_q(dr, p_upper_idx)));

	if (std::fabs(d_knee) > 1e-4f) {
		const Basis mid_parent_b = (skel_xf * g_up).basis.orthonormalized();
		const Quaternion q_mid_pb = normalize_safe(mid_parent_b.get_rotation_quaternion());
		const Quaternion q_knee_ws = normalize_safe(Quaternion(bend_axis_ws, d_knee * 0.5f));
		const Quaternion q_mid_local = normalize_safe(q_mid_pb.inverse() * q_knee_ws * q_mid_pb);
		store_q(dr, p_mid_idx, normalize_safe(q_mid_local * load_q(dr, p_mid_idx)));
	}

	return out_rot;
}

Dictionary AnimationStudioHkbKernel::step_damping_pid(
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
		bool p_enable_vector) const {
	float damped_val = p_damped_val;
	float err_sum = p_err_sum;
	float prev_err = p_prev_err;
	Vector3 damped_vec = p_damped_vec;
	Vector3 vec_err_sum = p_vec_err_sum;
	Vector3 vec_prev_err = p_vec_prev_err;

	if (p_enable_scalar) {
		const float err = p_raw_val - damped_val;
		err_sum = clamp_f(err_sum + err, -100.0f, 100.0f);
		const float delta = p_kp * err + p_ki * err_sum + p_kd * (err - prev_err);
		damped_val += delta;
		prev_err = err;
	}
	if (p_enable_vector) {
		const Vector3 verr = p_raw_vec - damped_vec;
		vec_err_sum += verr;
		const Vector3 vdelta = verr * p_kp + vec_err_sum * p_ki + (verr - vec_prev_err) * p_kd;
		damped_vec += vdelta;
		vec_prev_err = verr;
	}

	Dictionary out;
	out["damped_val"] = damped_val;
	out["err_sum"] = err_sum;
	out["prev_err"] = prev_err;
	out["damped_vec"] = damped_vec;
	out["vec_err_sum"] = vec_err_sum;
	out["vec_prev_err"] = vec_prev_err;
	return out;
}

Dictionary AnimationStudioHkbKernel::step_jiggler_chain(
		const PackedFloat32Array &p_rot_xyzw,
		const PackedInt32Array &p_bone_indices,
		const PackedVector3Array &p_vel_arr,
		const PackedVector3Array &p_disp_arr,
		const Vector3 &p_actor_accel,
		float p_stiffness,
		float p_damping,
		float p_max_deg,
		float p_dt) const {
	PackedFloat32Array out_rot = p_rot_xyzw.duplicate();
	PackedVector3Array out_vel = p_vel_arr.duplicate();
	PackedVector3Array out_disp = p_disp_arr.duplicate();

	const int32_t bone_count = static_cast<int32_t>(out_rot.size() / 4);
	const int32_t n = std::min({
			static_cast<int32_t>(p_bone_indices.size()),
			static_cast<int32_t>(out_vel.size()),
			static_cast<int32_t>(out_disp.size()),
	});
	const float rad_lim = p_max_deg * DEG_TO_RAD_F;
	const int32_t *bids = p_bone_indices.ptr();
	Vector3 *vels = out_vel.ptrw();
	Vector3 *disps = out_disp.ptrw();
	float *dr = out_rot.ptrw();

	for (int32_t i = 0; i < n; i++) {
		const int32_t bi = bids[i];
		if (bi < 0 || bi >= bone_count) {
			continue;
		}
		const Vector3 force = -p_actor_accel * 0.15f - disps[i] * p_stiffness - vels[i] * p_damping;
		vels[i] += force * p_dt;
		disps[i] += vels[i] * p_dt;
		const float rx = clamp_f(disps[i].z, -rad_lim, rad_lim);
		const float rz = clamp_f(-disps[i].x, -rad_lim, rad_lim);
		const Quaternion qj = normalize_safe(
				Quaternion(Vector3(1.0f, 0.0f, 0.0f), rx) *
				Quaternion(Vector3(0.0f, 0.0f, -1.0f), rz));
		store_q(dr, bi, normalize_safe(qj * load_q(dr, bi)));
	}

	Dictionary out;
	out["rot_xyzw"] = out_rot;
	out["vel"] = out_vel;
	out["disp"] = out_disp;
	return out;
}
