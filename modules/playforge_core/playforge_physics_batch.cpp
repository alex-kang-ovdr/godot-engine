#include "playforge_physics_batch.h"

#include "core/object/class_db.h"
#include "servers/physics_3d/physics_server_3d.h"
#include "servers/rendering/rendering_server.h"

static PackedFloat32Array g_playforge_mm_buffer;

extern "C" void playforge_jolt_set_gsk_mode(int p_mode);
extern "C" int playforge_jolt_get_gsk_mode();
extern "C" void playforge_jolt_set_narrow_stats_enabled(bool p_enabled);
extern "C" void playforge_jolt_reset_narrow_stats();
extern "C" void playforge_jolt_get_narrow_stats(uint64_t *p_out9);

void PlayForgePhysicsBatch::_bind_methods() {
	ClassDB::bind_static_method("PlayForgePhysicsBatch", D_METHOD("sync_multimesh_from_bodies", "multimesh_rid", "body_rids", "custom_data"), &PlayForgePhysicsBatch::sync_multimesh_from_bodies);
	ClassDB::bind_static_method("PlayForgePhysicsBatch", D_METHOD("clear_cache"), &PlayForgePhysicsBatch::clear_cache);
	ClassDB::bind_static_method("PlayForgePhysicsBatch", D_METHOD("set_jolt_gsk_mode", "mode"), &PlayForgePhysicsBatch::set_jolt_gsk_mode);
	ClassDB::bind_static_method("PlayForgePhysicsBatch", D_METHOD("get_jolt_gsk_mode"), &PlayForgePhysicsBatch::get_jolt_gsk_mode);
	ClassDB::bind_static_method("PlayForgePhysicsBatch", D_METHOD("set_jolt_narrow_stats_enabled", "enabled"), &PlayForgePhysicsBatch::set_jolt_narrow_stats_enabled);
	ClassDB::bind_static_method("PlayForgePhysicsBatch", D_METHOD("reset_jolt_narrow_stats"), &PlayForgePhysicsBatch::reset_jolt_narrow_stats);
	ClassDB::bind_static_method("PlayForgePhysicsBatch", D_METHOD("get_jolt_narrow_stats"), &PlayForgePhysicsBatch::get_jolt_narrow_stats);
}

int64_t PlayForgePhysicsBatch::sync_multimesh_from_bodies(RID p_multimesh, const PackedInt64Array &p_body_rids, const PackedFloat32Array &p_custom_data) {
	if (!p_multimesh.is_valid()) {
		return 0;
	}
	PhysicsServer3D *ps = PhysicsServer3D::get_singleton();
	RenderingServer *rs = RenderingServer::get_singleton();
	if (!ps || !rs) {
		return 0;
	}
	const int64_t count = p_body_rids.size();
	if (count <= 0) {
		return 0;
	}

	const int64_t needed = count * 16;
	if (g_playforge_mm_buffer.size() != needed) {
		g_playforge_mm_buffer.resize(needed);
	}

	const int64_t *rids_ptr = p_body_rids.ptr();
	const float *custom_ptr = (p_custom_data.size() >= count) ? p_custom_data.ptr() : nullptr;
	float *dst = g_playforge_mm_buffer.ptrw();

	const int64_t written = ps->batch_fill_multimesh_buffer(rids_ptr, custom_ptr, count, dst);
	rs->multimesh_set_buffer(p_multimesh, g_playforge_mm_buffer);
	return written;
}

void PlayForgePhysicsBatch::clear_cache() {
	g_playforge_mm_buffer.clear();
}

void PlayForgePhysicsBatch::set_jolt_gsk_mode(int p_mode) {
	playforge_jolt_set_gsk_mode(p_mode);
}

int PlayForgePhysicsBatch::get_jolt_gsk_mode() {
	return playforge_jolt_get_gsk_mode();
}

void PlayForgePhysicsBatch::set_jolt_narrow_stats_enabled(bool p_enabled) {
	playforge_jolt_set_narrow_stats_enabled(p_enabled);
}

void PlayForgePhysicsBatch::reset_jolt_narrow_stats() {
	playforge_jolt_reset_narrow_stats();
}

Dictionary PlayForgePhysicsBatch::get_jolt_narrow_stats() {
	uint64_t s[9] = {};
	playforge_jolt_get_narrow_stats(s);
	Dictionary d;
	d["pair_total"] = (int64_t)s[0];
	d["pair_cache_hits"] = (int64_t)s[1];
	d["pair_cache_misses"] = (int64_t)s[2];
	d["gsk_warm_hits"] = (int64_t)s[3];
	d["gsk_early_sep"] = (int64_t)s[4];
	d["gjk_calls"] = (int64_t)s[5];
	d["gjk_iters"] = (int64_t)s[6];
	d["epa_calls"] = (int64_t)s[7];
	d["narrow_phase_ms"] = (double)s[8] / 1e6;
	return d;
}
