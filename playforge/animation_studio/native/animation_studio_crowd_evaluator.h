#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/skeleton3d.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class AnimationStudioCrowdEvaluator : public RefCounted {
	GDCLASS(AnimationStudioCrowdEvaluator, RefCounted);

	int32_t bone_count = 0;
	int32_t key_count = 0;
	int32_t agent_count = 0;
	double duration = 0.0;
	double sample_rate = 60.0;
	Vector3 pos_min = Vector3(0.0f, 0.0f, 0.0f);
	Vector3 pos_range = Vector3(1.0f, 1.0f, 1.0f);

	std::vector<uint16_t> pos_q;
	std::vector<int16_t> rot_q;
	std::vector<double> agent_times;
	std::vector<Vector3> out_pos;
	std::vector<Quaternion> out_rot;
	std::vector<int64_t> worker_ns;

	// Persistent C++ worker thread pool for zero per-tick thread creation overhead.
	std::vector<std::thread> workers;
	std::mutex pool_mutex;
	std::condition_variable cv_start;
	std::condition_variable cv_done;
	uint64_t job_generation = 0;
	int32_t workers_remaining = 0;
	bool stop_pool = false;
	std::atomic<int32_t> next_agent{0};

	void _start_pool(int32_t p_thread_count);
	void _stop_pool();
	void _worker_loop(int32_t p_worker_index);
	void _eval_agent(int32_t p_agent_idx);

protected:
	static void _bind_methods();

public:
	AnimationStudioCrowdEvaluator() = default;
	~AnimationStudioCrowdEvaluator() override;

	bool configure(
			int32_t p_bone_count,
			int32_t p_key_count,
			double p_duration,
			double p_sample_rate,
			const Vector3 &p_pos_min,
			const Vector3 &p_pos_range,
			const PackedByteArray &p_pos_q,
			const PackedByteArray &p_rot_q,
			int32_t p_agent_count,
			int32_t p_thread_count = 0);

	Dictionary step_parallel(double p_delta, const Array &p_skeletons);
	int32_t get_worker_count() const { return static_cast<int32_t>(workers.size()); }
};

} // namespace godot
