// PlayForge A/B Narrow-Phase Experiment: Jolt GJK/EPA + BodyPairContactCache vs Compact Octahedral GSK Warm-Start Cache
// Clean-room MIT implementation for benchmarking inside Forge-godot-engine.
#pragma once

#include <Jolt/Jolt.h>
#include <Jolt/Math/Vec3.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>

JPH_NAMESPACE_BEGIN

struct PlayForgeGskStats {
	std::atomic<uint64_t> pair_total { 0 };
	std::atomic<uint64_t> pair_cache_hits { 0 };
	std::atomic<uint64_t> pair_cache_misses { 0 };
	std::atomic<uint64_t> gsk_warm_hits { 0 };
	std::atomic<uint64_t> gsk_early_sep { 0 };
	std::atomic<uint64_t> gjk_calls { 0 };
	std::atomic<uint64_t> gjk_iters { 0 };
	std::atomic<uint64_t> epa_calls { 0 };
	std::atomic<uint64_t> narrow_phase_ns { 0 };

	void Reset() {
		pair_total.store(0, std::memory_order_relaxed);
		pair_cache_hits.store(0, std::memory_order_relaxed);
		pair_cache_misses.store(0, std::memory_order_relaxed);
		gsk_warm_hits.store(0, std::memory_order_relaxed);
		gsk_early_sep.store(0, std::memory_order_relaxed);
		gjk_calls.store(0, std::memory_order_relaxed);
		gjk_iters.store(0, std::memory_order_relaxed);
		epa_calls.store(0, std::memory_order_relaxed);
		narrow_phase_ns.store(0, std::memory_order_relaxed);
	}
};

struct PlayForgeGskThreadCtx {
	Vec3 warm_axis = Vec3::sZero();
	bool has_warm_axis = false;
	Vec3 out_axis = Vec3::sZero();
	bool has_out_axis = false;
};

// Zero-sqrt 4-byte octahedral direction encoder/decoder (0 = empty sentinel)
inline uint32_t PlayForgeEncodeOctAxis(Vec3Arg inAxis) {
	const float x = inAxis.GetX();
	const float y = inAxis.GetY();
	const float z = inAxis.GetZ();
	const float l1 = std::fabs(x) + std::fabs(y) + std::fabs(z);
	if (l1 < 1e-6f) {
		return 0u;
	}
	const float inv = 1.0f / l1;
	float ox = x * inv;
	float oy = y * inv;
	if (z < 0.0f) {
		const float sx = (ox >= 0.0f) ? 1.0f : -1.0f;
		const float sy = (oy >= 0.0f) ? 1.0f : -1.0f;
		const float nx = (1.0f - std::fabs(oy)) * sx;
		const float ny = (1.0f - std::fabs(ox)) * sy;
		ox = nx;
		oy = ny;
	}
	int32_t ix = (int32_t)(ox * 32767.0f);
	int32_t iy = (int32_t)(oy * 32767.0f);
	if (ix < -32767) ix = -32767; else if (ix > 32767) ix = 32767;
	if (iy < -32767) iy = -32767; else if (iy > 32767) iy = 32767;
	if (ix == 0 && iy == 0) {
		ix = 1; // reserve 0 for empty sentinel
	}
	return (uint32_t)(uint16_t)(int16_t)ix | ((uint32_t)(uint16_t)(int16_t)iy << 16u);
}

inline Vec3 PlayForgeDecodeOctAxis(uint32_t inPacked) {
	const int16_t ix = (int16_t)(inPacked & 0xFFFFu);
	const int16_t iy = (int16_t)(inPacked >> 16u);
	float ox = (float)ix * (1.0f / 32767.0f);
	float oy = (float)iy * (1.0f / 32767.0f);
	const float oz = 1.0f - std::fabs(ox) - std::fabs(oy);
	if (oz < 0.0f) {
		const float sx = (ox >= 0.0f) ? 1.0f : -1.0f;
		const float sy = (oy >= 0.0f) ? 1.0f : -1.0f;
		const float nx = (1.0f - std::fabs(oy)) * sx;
		const float ny = (1.0f - std::fabs(ox)) * sy;
		ox = nx;
		oy = ny;
	}
	return Vec3(ox, oy, oz);
}

// Mode 0: Baseline Jolt (BodyPairContactCache + cold GJK/EPA)
// Mode 1: Pure GSK Warm-Start (replaces BodyPairContactCache early-out with cached separating/penetration axis warm-start)
// Mode 2: Hybrid (keeps BodyPairContactCache for resting pairs + compact 4B octahedral GSK warm-start axis on cache misses)
inline std::atomic<int> g_playforge_gsk_mode { 2 };
inline std::atomic<bool> g_playforge_narrow_stats_enabled { false };
inline PlayForgeGskStats g_playforge_gsk_stats;
inline thread_local PlayForgeGskThreadCtx g_playforge_gsk_tls;

JPH_NAMESPACE_END
