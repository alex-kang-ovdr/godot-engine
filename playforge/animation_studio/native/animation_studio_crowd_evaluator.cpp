#include "animation_studio_crowd_evaluator.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

AnimationStudioCrowdEvaluator::~AnimationStudioCrowdEvaluator() {
	_stop_pool();
}

void AnimationStudioCrowdEvaluator::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD("configure", "bone_count", "key_count", "duration", "sample_rate", "pos_min", "pos_range", "pos_q", "rot_q", "agent_count", "thread_count"),
			&AnimationStudioCrowdEvaluator::configure,
			DEFVAL(0));
	ClassDB::bind_method(
			D_METHOD("step_parallel", "delta", "skeletons"),
			&AnimationStudioCrowdEvaluator::step_parallel);
	ClassDB::bind_method(
			D_METHOD("get_worker_count"),
			&AnimationStudioCrowdEvaluator::get_worker_count);
}

void AnimationStudioCrowdEvaluator::_start_pool(int32_t p_thread_count) {
	_stop_pool();
	int32_t count = p_thread_count;
	if (count <= 0) {
		const unsigned int hw = std::thread::hardware_concurrency();
		count = static_cast<int32_t>(std::max(2u, std::min(8u, hw > 1u ? hw - 1u : 2u)));
	}
	count = std::max<int32_t>(1, std::min<int32_t>(16, count));

	stop_pool = false;
	job_generation = 0;
	workers_remaining = 0;
	worker_ns.assign(count, 0);
	workers.reserve(count);
	for (int32_t i = 0; i < count; i++) {
		workers.emplace_back(&AnimationStudioCrowdEvaluator::_worker_loop, this, i);
	}
}

void AnimationStudioCrowdEvaluator::_stop_pool() {
	if (workers.empty()) {
		return;
	}
	{
		std::lock_guard<std::mutex> lock(pool_mutex);
		stop_pool = true;
	}
	cv_start.notify_all();
	for (std::thread &t : workers) {
		if (t.joinable()) {
			t.join();
		}
	}
	workers.clear();
}

bool AnimationStudioCrowdEvaluator::configure(
		int32_t p_bone_count,
		int32_t p_key_count,
		double p_duration,
		double p_sample_rate,
		const Vector3 &p_pos_min,
		const Vector3 &p_pos_range,
		const PackedByteArray &p_pos_q,
		const PackedByteArray &p_rot_q,
		int32_t p_agent_count,
		int32_t p_thread_count) {
	if (p_bone_count <= 0 || p_key_count < 2 || p_duration <= 0.0 || p_sample_rate <= 0.0 || p_agent_count <= 0) {
		return false;
	}
	const int64_t total_keys = static_cast<int64_t>(p_bone_count) * static_cast<int64_t>(p_key_count);
	if (p_pos_q.size() != total_keys * 6 || p_rot_q.size() != total_keys * 8) {
		return false;
	}

	_stop_pool();

	bone_count = p_bone_count;
	key_count = p_key_count;
	agent_count = p_agent_count;
	duration = p_duration;
	sample_rate = p_sample_rate;
	pos_min = p_pos_min;
	pos_range = p_pos_range;

	pos_q.resize(static_cast<size_t>(total_keys * 3));
	rot_q.resize(static_cast<size_t>(total_keys * 4));
	std::memcpy(pos_q.data(), p_pos_q.ptr(), static_cast<size_t>(total_keys * 6));
	std::memcpy(rot_q.data(), p_rot_q.ptr(), static_cast<size_t>(total_keys * 8));

	agent_times.resize(static_cast<size_t>(agent_count));
	for (int32_t i = 0; i < agent_count; i++) {
		double t = std::fmod(static_cast<double>(i) * 0.037, duration);
		if (t < 0.0) {
			t += duration;
		}
		agent_times[i] = t;
	}

	const size_t total_out = static_cast<size_t>(agent_count) * static_cast<size_t>(bone_count);
	out_pos.assign(total_out, Vector3(0.0f, 0.0f, 0.0f));
	out_rot.assign(total_out, Quaternion(0.0f, 0.0f, 0.0f, 1.0f));

	_start_pool(p_thread_count);
	return true;
}

void AnimationStudioCrowdEvaluator::_worker_loop(int32_t p_worker_index) {
	uint64_t seen_gen = 0;
	for (;;) {
		{
			std::unique_lock<std::mutex> lock(pool_mutex);
			cv_start.wait(lock, [&]() { return stop_pool || job_generation != seen_gen; });
			if (stop_pool) {
				return;
			}
			seen_gen = job_generation;
		}

		const auto t0 = std::chrono::steady_clock::now();
		for (;;) {
			const int32_t start = next_agent.fetch_add(8, std::memory_order_relaxed);
			if (start >= agent_count) {
				break;
			}
			const int32_t end = std::min(agent_count, start + 8);
			for (int32_t a = start; a < end; a++) {
				_eval_agent(a);
			}
		}
		const auto t1 = std::chrono::steady_clock::now();
		worker_ns[p_worker_index] = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();

		{
			std::lock_guard<std::mutex> lock(pool_mutex);
			workers_remaining--;
			if (workers_remaining == 0) {
				cv_done.notify_one();
			}
		}
	}
}

void AnimationStudioCrowdEvaluator::_eval_agent(int32_t p_agent_idx) {
	constexpr float INV_U16 = 1.0f / 65535.0f;
	constexpr float INV_S16 = 1.0f / 32767.0f;

	const double fkey = agent_times[p_agent_idx] * sample_rate;
	int32_t k0 = static_cast<int32_t>(std::floor(fkey));
	if (k0 < 0) {
		k0 = 0;
	} else if (k0 >= key_count) {
		k0 = key_count - 1;
	}
	const int32_t k1 = (k0 + 1 < key_count) ? (k0 + 1) : (key_count - 1);
	const float frac = static_cast<float>(fkey - static_cast<double>(k0));
	const float inv_frac = 1.0f - frac;

	const float rx = pos_range.x * INV_U16;
	const float ry = pos_range.y * INV_U16;
	const float rz = pos_range.z * INV_U16;

	const uint16_t *p0_ptr = pos_q.data() + static_cast<size_t>(k0) * bone_count * 3;
	const uint16_t *p1_ptr = pos_q.data() + static_cast<size_t>(k1) * bone_count * 3;
	const int16_t *r0_ptr = rot_q.data() + static_cast<size_t>(k0) * bone_count * 4;
	const int16_t *r1_ptr = rot_q.data() + static_cast<size_t>(k1) * bone_count * 4;

	Vector3 *dst_p = out_pos.data() + static_cast<size_t>(p_agent_idx) * bone_count;
	Quaternion *dst_r = out_rot.data() + static_cast<size_t>(p_agent_idx) * bone_count;

	for (int32_t b = 0; b < bone_count; b++) {
		const int32_t po = b * 3;
		const float p0x = pos_min.x + static_cast<float>(p0_ptr[po]) * rx;
		const float p0y = pos_min.y + static_cast<float>(p0_ptr[po + 1]) * ry;
		const float p0z = pos_min.z + static_cast<float>(p0_ptr[po + 2]) * rz;
		const float p1x = pos_min.x + static_cast<float>(p1_ptr[po]) * rx;
		const float p1y = pos_min.y + static_cast<float>(p1_ptr[po + 1]) * ry;
		const float p1z = pos_min.z + static_cast<float>(p1_ptr[po + 2]) * rz;
		dst_p[b] = Vector3(
				p0x * inv_frac + p1x * frac,
				p0y * inv_frac + p1y * frac,
				p0z * inv_frac + p1z * frac);

		const int32_t ro = b * 4;
		const float q0x = static_cast<float>(r0_ptr[ro]) * INV_S16;
		const float q0y = static_cast<float>(r0_ptr[ro + 1]) * INV_S16;
		const float q0z = static_cast<float>(r0_ptr[ro + 2]) * INV_S16;
		const float q0w = static_cast<float>(r0_ptr[ro + 3]) * INV_S16;

		float q1x = static_cast<float>(r1_ptr[ro]) * INV_S16;
		float q1y = static_cast<float>(r1_ptr[ro + 1]) * INV_S16;
		float q1z = static_cast<float>(r1_ptr[ro + 2]) * INV_S16;
		float q1w = static_cast<float>(r1_ptr[ro + 3]) * INV_S16;

		const float dot = q0x * q1x + q0y * q1y + q0z * q1z + q0w * q1w;
		if (dot < 0.0f) {
			q1x = -q1x;
			q1y = -q1y;
			q1z = -q1z;
			q1w = -q1w;
		}
		// Normalized linear interpolation (nlerp) is accurate to < 0.001 deg across 60 Hz adjacent keys.
		float qx = q0x * inv_frac + q1x * frac;
		float qy = q0y * inv_frac + q1y * frac;
		float qz = q0z * inv_frac + q1z * frac;
		float qw = q0w * inv_frac + q1w * frac;
		const float len_sq = qx * qx + qy * qy + qz * qz + qw * qw;
		const float inv_len = len_sq > 1e-12f ? (1.0f / std::sqrt(len_sq)) : 1.0f;
		dst_r[b] = Quaternion(qx * inv_len, qy * inv_len, qz * inv_len, qw * inv_len);
	}
}

Dictionary AnimationStudioCrowdEvaluator::step_parallel(double p_delta, const Array &p_skeletons) {
	Dictionary out;
	if (agent_count <= 0 || bone_count <= 0 || p_skeletons.size() < agent_count || workers.empty()) {
		return out;
	}

	const auto t_dispatch = std::chrono::steady_clock::now();
	for (int32_t i = 0; i < agent_count; i++) {
		double t = std::fmod(agent_times[i] + p_delta, duration);
		if (t < 0.0) {
			t += duration;
		}
		agent_times[i] = t;
	}

	next_agent.store(0, std::memory_order_relaxed);
	{
		std::lock_guard<std::mutex> lock(pool_mutex);
		workers_remaining = static_cast<int32_t>(workers.size());
		job_generation++;
	}
	cv_start.notify_all();

	const auto t_wait_start = std::chrono::steady_clock::now();
	{
		std::unique_lock<std::mutex> lock(pool_mutex);
		cv_done.wait(lock, [&]() { return workers_remaining == 0; });
	}
	const auto t_wait_end = std::chrono::steady_clock::now();

	const auto t_apply_start = std::chrono::steady_clock::now();
	for (int32_t a = 0; a < agent_count; a++) {
		Skeleton3D *skel = Object::cast_to<Skeleton3D>(p_skeletons[a]);
		if (skel == nullptr) {
			continue;
		}
		const Vector3 *src_p = out_pos.data() + static_cast<size_t>(a) * bone_count;
		const Quaternion *src_r = out_rot.data() + static_cast<size_t>(a) * bone_count;
		for (int32_t b = 0; b < bone_count; b++) {
			skel->set_bone_pose_position(b, src_p[b]);
			skel->set_bone_pose_rotation(b, src_r[b]);
		}
	}
	const auto t_apply_end = std::chrono::steady_clock::now();

	int64_t worker_sum_ns = 0;
	for (int64_t ns : worker_ns) {
		worker_sum_ns += ns;
	}

	const double worker_cpu_ms = static_cast<double>(worker_sum_ns) / 1e6;
	const double worker_wait_ms = static_cast<double>(std::chrono::duration_cast<std::chrono::nanoseconds>(t_wait_end - t_wait_start).count()) / 1e6;
	const double main_apply_ms = static_cast<double>(std::chrono::duration_cast<std::chrono::nanoseconds>(t_apply_end - t_apply_start).count()) / 1e6;
	const double main_total_ms = static_cast<double>(std::chrono::duration_cast<std::chrono::nanoseconds>((t_wait_end - t_dispatch) + (t_apply_end - t_apply_start)).count()) / 1e6;

	out["worker_cpu_ms"] = worker_cpu_ms;
	out["worker_wait_ms"] = worker_wait_ms;
	out["main_apply_ms"] = main_apply_ms;
	out["main_total_ms"] = main_total_ms;
	out["threads"] = static_cast<int32_t>(workers.size());
	out["native"] = true;
	return out;
}
