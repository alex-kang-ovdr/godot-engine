#pragma once

#include "core/object/object.h"
#include "core/variant/variant.h"

class PlayForgePhysicsBatch : public Object {
	GDCLASS(PlayForgePhysicsBatch, Object);

protected:
	static void _bind_methods();

public:
	static int64_t sync_multimesh_from_bodies(RID p_multimesh, const PackedInt64Array &p_body_rids, const PackedFloat32Array &p_custom_data);
	static void clear_cache();
};
