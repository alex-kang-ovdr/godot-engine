#include "playforge_physics_batch.h"

#include "core/object/class_db.h"
#include "servers/physics_3d/physics_server_3d.h"
#include "servers/rendering/rendering_server.h"

static PackedFloat32Array g_playforge_mm_buffer;

void PlayForgePhysicsBatch::_bind_methods() {
	ClassDB::bind_static_method("PlayForgePhysicsBatch", D_METHOD("sync_multimesh_from_bodies", "multimesh_rid", "body_rids", "custom_data"), &PlayForgePhysicsBatch::sync_multimesh_from_bodies);
	ClassDB::bind_static_method("PlayForgePhysicsBatch", D_METHOD("clear_cache"), &PlayForgePhysicsBatch::clear_cache);
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
