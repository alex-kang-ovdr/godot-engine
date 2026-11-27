// Official Havok 2015.1.0-r1 Offline Asset Extractor for Godot 4.7.2
// Extracts:
//   Mode 1 (--scene <in.hkt> <out.json> <out.bin>):
//     - Complete hkxScene node hierarchy, world transforms, hkxMesh / hkxMeshSection
//       (positions, normals, UVs, RGBA vertex colors, triangle indices),
//       hkxMaterial (diffuse/ambient/specular/emissive + external/inplace textures)
//     - Complete hknpPhysicsSystemData static/dynamic bodies (names, positions, orientations,
//       masses, shapes, surface geometry for dynamic props such as AttachmentScene skulls)
//   Mode 2 (--ragdoll <ragdoll_np.hkt> <mapper.hkt> <out.json> [behavior1.hkt ...]):
//     - Complete hknpRagdollData: hkaSkeleton (bones, parents, referencePose), boneToBodyMap,
//       every hknpBodyCinfo (mass, inertia, center of mass, damping, friction, restitution,
//       collisionFilterInfo, exact shape type + capsule/sphere/convex params + exact Havok
//       buildSurfaceGeometry triangle mesh!), and every hknpConstraintCinfo
//       (hkpRagdollConstraintData cone/plane/twist limits & frames, hkpLimitedHingeConstraintData)
//     - Complete hkaSkeletonMapper (ragdoll <-> high-res simple/chain mappings & aFromBTransforms)
//     - Complete per-Behavior ragdoll controller parameters extracted from official .hkt graphs
//       (hkbPoweredRagdollControlsModifier, hkbRigidBodyRagdollControlsModifier,
//        hkbKeyframeBonesModifier, plus enclosing hkbStateMachine state names!)
//
// Builds cleanly against unmodified Havok 2015.1.0-r1 x64 release libraries.

#define HK_FEATURE_PRODUCT_ANIMATION
#define HK_FEATURE_PRODUCT_PHYSICS
#define HK_FEATURE_PRODUCT_BEHAVIOR

#include <Common/Base/hkBase.h>
#include <Common/Base/Memory/System/Util/hkMemoryInitUtil.h>
#include <Common/Base/Memory/Allocator/Malloc/hkMallocAllocator.h>
#include <Common/Base/KeyCode.h>
#include <Common/Base/Types/Geometry/hkGeometry.h>
#include <Common/Serialize/Util/hkSerializeUtil.h>
#include <Common/Serialize/Util/hkRootLevelContainer.h>
#include <Common/Base/Serialize/Resource/hkObjectResource.h>
#include <Common/SceneData/Scene/hkxScene.h>
#include <Common/SceneData/Graph/hkxNode.h>
#include <Common/SceneData/Mesh/hkxMesh.h>
#include <Common/SceneData/Mesh/hkxMeshSection.h>
#include <Common/SceneData/Mesh/hkxVertexBuffer.h>
#include <Common/SceneData/Mesh/hkxIndexBuffer.h>
#include <Common/SceneData/Material/hkxMaterial.h>
#include <Common/SceneData/Material/hkxTextureFile.h>
#include <Common/SceneData/Material/hkxTextureInplace.h>

#include <Animation/Animation/Rig/hkaSkeleton.h>
#include <Animation/Animation/Mapper/hkaSkeletonMapper.h>
#include <Animation/PhysicsBridge/Ragdoll/hknpRagdoll.h>

#include <Physics/Physics/Extensions/PhysicsSystem/hknpPhysicsSystem.h>
#include <Physics/Physics/Extensions/PhysicsSystem/hknpPhysicsSceneData.h>
#include <Physics/Physics/Collide/Shape/hknpShape.h>
#include <Physics/Physics/Collide/Shape/Convex/hknpConvexShape.h>
#include <Physics/Physics/Collide/Shape/Convex/Capsule/hknpCapsuleShape.h>
#include <Physics/Physics/Collide/Shape/Convex/Sphere/hknpSphereShape.h>
#include <Physics/Physics/Dynamics/Material/hknpMaterial.h>
#include <Physics/Physics/Dynamics/Motion/hknpMotionProperties.h>
#include <Physics/Constraint/Data/hkpConstraintData.h>
#include <Physics/Constraint/Data/Ragdoll/hkpRagdollConstraintData.h>
#include <Physics/Constraint/Data/LimitedHinge/hkpLimitedHingeConstraintData.h>

#include <Behavior/Behavior/BehaviorGraph/hkbBehaviorGraph.h>
#include <Behavior/Behavior/StateMachine/hkbStateMachine.h>
#include <Behavior/Behavior/Modifier/Ragdoll/hkbPoweredRagdollControlsModifier.h>
#include <Behavior/Behavior/Modifier/Ragdoll/hkbRigidBodyRagdollControlsModifier.h>
#include <Behavior/Behavior/Modifier/Ragdoll/hkbKeyframeBonesModifier.h>

#undef HK_FEATURE_PRODUCT_AI
#undef HK_FEATURE_PRODUCT_CLOTH
#undef HK_FEATURE_PRODUCT_DESTRUCTION
#undef HK_FEATURE_PRODUCT_DESTRUCTION_2012
#undef HK_FEATURE_PRODUCT_PHYSICS_2012
#undef HK_FEATURE_PRODUCT_FX
#undef HK_FEATURE_PRODUCT_MILSIM
#include <Common/Base/Config/hkProductFeatures.cxx>
#include <Common/Base/KeyCode.cxx>
#include <Common/Base/System/Init/PlatformInit.cxx>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <vector>

static void HK_CALL reportErr(const char* msg, void*)
{
	std::fprintf(stderr, "[hk] %s\n", msg);
}

static std::string jesc(const char* s)
{
	if (!s) return "";
	std::string out;
	for (const char* p = s; *p; ++p)
	{
		unsigned char c = static_cast<unsigned char>(*p);
		if (c == '\\') out += "\\\\";
		else if (c == '"') out += "\\\"";
		else if (c == '\n') out += "\\n";
		else if (c == '\r') continue;
		else if (c < 0x20) { char buf[8]; std::snprintf(buf, sizeof(buf), "\\u%04x", c); out += buf; }
		else out.push_back(static_cast<char>(c));
	}
	return out;
}

static double safeF(double v)
{
	return std::isfinite(v) ? v : 0.0;
}

static void writeVec3(std::FILE* f, const hkVector4& v)
{
	std::fprintf(f, "[%.7f,%.7f,%.7f]", safeF(v(0)), safeF(v(1)), safeF(v(2)));
}

static void writeVec4(std::FILE* f, const hkVector4& v)
{
	std::fprintf(f, "[%.7f,%.7f,%.7f,%.7f]", safeF(v(0)), safeF(v(1)), safeF(v(2)), safeF(v(3)));
}

static void writeQuat(std::FILE* f, const hkQuaternion& q)
{
	std::fprintf(f, "[%.7f,%.7f,%.7f,%.7f]", safeF(q(0)), safeF(q(1)), safeF(q(2)), safeF(q(3)));
}

static void writeQs(std::FILE* f, const hkQsTransform& t)
{
	std::fprintf(f, "{\"t\":");
	writeVec3(f, t.getTranslation());
	std::fprintf(f, ",\"r\":");
	writeQuat(f, t.getRotation());
	std::fprintf(f, ",\"s\":");
	writeVec3(f, t.getScale());
	std::fprintf(f, "}");
}

static void writeMat3(std::FILE* f, const hkMatrix3& m)
{
	// Column-major 3 columns: col0, col1, col2
	std::fprintf(f, "[");
	for (int c = 0; c < 3; ++c)
	{
		const hkVector4& col = m.getColumn(c);
		if (c > 0) std::fprintf(f, ",");
		writeVec3(f, col);
	}
	std::fprintf(f, "]");
}

static hkObjectResource* loadHktResource(const char* path)
{
	hkSerializeUtil::ErrorDetails err;
	hkObjectResource* res = hkSerializeUtil::loadOnHeap(path, &err);
	if (!res)
	{
		std::fprintf(stderr, "[ERROR] Failed to load %s: %s\n", path, err.defaultMessage.cString());
	}
	return res;
}

// ============================================================================
// MODE 1: --scene <in.hkt> <out.json> <out.bin>
// ============================================================================

struct BinWriter
{
	std::vector<uint8_t> data;
	size_t append(const void* src, size_t nbytes)
	{
		while (data.size() % 4 != 0) data.push_back(0);
		size_t off = data.size();
		data.resize(off + nbytes);
		if (nbytes > 0) std::memcpy(data.data() + off, src, nbytes);
		return off;
	}
};

struct ExtractedMeshSection
{
	std::string nodeName;
	int sectionIdx;
	int matIdx;
	int numVerts;
	int numIndices;
	bool hasNormal;
	bool hasUv;
	bool hasColor;
	size_t posOff;
	size_t nrmOff;
	size_t uvOff;
	size_t colOff;
	size_t idxOff;
};

struct ExtractedMat
{
	std::string name;
	float diffuse[4];
	float ambient[4];
	float specular[4];
	float emissive[4];
	int transparency;
	std::string diffuseTexFile;
	std::string lightmapTexFile;
	std::string inplaceTexName;
	std::string inplaceTexExt;
	size_t inplaceTexOff;
	size_t inplaceTexLen;
};

static int registerMaterial(
	const hkxMaterial* mat,
	std::map<const hkxMaterial*, int>& matMap,
	std::vector<ExtractedMat>& mats,
	BinWriter& bin)
{
	if (!mat) return -1;
	auto it = matMap.find(mat);
	if (it != matMap.end()) return it->second;

	ExtractedMat em{};
	em.name = mat->m_name.cString() ? mat->m_name.cString() : "";
	for (int i = 0; i < 4; ++i)
	{
		em.diffuse[i] = float(mat->m_diffuseColor(i));
		em.ambient[i] = float(mat->m_ambientColor(i));
		em.specular[i] = float(mat->m_specularColor(i));
		em.emissive[i] = float(mat->m_emissiveColor(i));
	}
	em.transparency = int(mat->m_transparency);
	em.inplaceTexOff = 0;
	em.inplaceTexLen = 0;

	for (int si = 0; si < mat->m_stages.getSize(); ++si)
	{
		const hkxMaterial::TextureStage& st = mat->m_stages[si];
		hkReferencedObject* texObj = st.m_texture.val();
		if (!texObj) continue;
		const hkxTextureFile* tf = hkDynCast<hkxTextureFile>(texObj);
		const hkxTextureInplace* ti = hkDynCast<hkxTextureInplace>(texObj);
		std::string fname;
		if (tf)
		{
			if (tf->m_filename.cString() && tf->m_filename.cString()[0])
				fname = tf->m_filename.cString();
			else if (tf->m_originalFilename.cString())
				fname = tf->m_originalFilename.cString();
		}
		if (st.m_usageHint == hkxMaterial::TEX_DIFFUSE || (em.diffuseTexFile.empty() && em.inplaceTexLen == 0))
		{
			if (tf && !fname.empty())
			{
				if (em.diffuseTexFile.empty()) em.diffuseTexFile = fname;
				else if (em.lightmapTexFile.empty()) em.lightmapTexFile = fname;
			}
			else if (ti && ti->m_data.getSize() > 0 && em.inplaceTexLen == 0)
			{
				em.inplaceTexName = ti->m_name.cString() ? ti->m_name.cString() : "inplace";
				char ext[5] = { char(ti->m_fileType[0]), char(ti->m_fileType[1]), char(ti->m_fileType[2]), char(ti->m_fileType[3]), 0 };
				em.inplaceTexExt = ext;
				em.inplaceTexLen = size_t(ti->m_data.getSize());
				em.inplaceTexOff = bin.append(ti->m_data.begin(), em.inplaceTexLen);
			}
		}
		else if (tf && !fname.empty() && em.lightmapTexFile.empty())
		{
			em.lightmapTexFile = fname;
		}
	}

	int idx = int(mats.size());
	mats.push_back(em);
	matMap[mat] = idx;
	return idx;
}

static void extractSceneNodeRecursive(
	const hkxScene* scene,
	const hkxNode* node,
	const hkMatrix4& parentWorld,
	std::map<const hkxMaterial*, int>& matMap,
	std::vector<ExtractedMat>& mats,
	std::vector<ExtractedMeshSection>& sections,
	BinWriter& bin)
{
	if (!node) return;
	hkMatrix4 localM;
	if (node->m_keyFrames.getSize() > 0)
		localM = node->m_keyFrames[0];
	else
		localM.setIdentity();

	hkMatrix4 worldM;
	worldM.setMul(parentWorld, localM);

	const hkxMesh* mesh = hkDynCast<hkxMesh>(node->m_object.val());
	if (mesh)
	{
		const std::string nodeName = node->m_name.cString() ? node->m_name.cString() : "mesh";
		// Normal transform = upper 3x3 determinant sign for winding check
		hkMatrix3 nrmM;
		nrmM.setCols(worldM.getColumn<0>(), worldM.getColumn<1>(), worldM.getColumn<2>());
		hkSimdReal det = nrmM.getDeterminant();
		const bool flipWinding = (double(det) < 0.0);

		for (int si = 0; si < mesh->m_sections.getSize(); ++si)
		{
			const hkxMeshSection* sec = mesh->m_sections[si];
			if (!sec || !sec->m_vertexBuffer) continue;
			const hkxVertexBuffer* vb = sec->m_vertexBuffer;
			const hkxVertexDescription& desc = vb->getVertexDesc();
			const int nv = vb->getNumVertices();
			if (nv <= 0) continue;

			const hkxVertexDescription::ElementDecl* posDecl = desc.getElementDecl(hkxVertexDescription::HKX_DU_POSITION, 0);
			if (!posDecl) continue;
			const hkxVertexDescription::ElementDecl* nrmDecl = desc.getElementDecl(hkxVertexDescription::HKX_DU_NORMAL, 0);
			const hkxVertexDescription::ElementDecl* uvDecl = desc.getElementDecl(hkxVertexDescription::HKX_DU_TEXCOORD, 0);
			const hkxVertexDescription::ElementDecl* colDecl = desc.getElementDecl(hkxVertexDescription::HKX_DU_COLOR, 0);

			std::vector<float> posBuf(size_t(nv) * 3, 0.0f);
			std::vector<float> nrmBuf(nrmDecl ? size_t(nv) * 3 : 0, 0.0f);
			std::vector<float> uvBuf(uvDecl ? size_t(nv) * 2 : 0, 0.0f);
			std::vector<float> colBuf(colDecl ? size_t(nv) * 4 : 0, 1.0f);

			const uint8_t* posBase = static_cast<const uint8_t*>(vb->getVertexDataPtr(*posDecl));
			const uint8_t* nrmBase = nrmDecl ? static_cast<const uint8_t*>(vb->getVertexDataPtr(*nrmDecl)) : nullptr;
			const uint8_t* uvBase = uvDecl ? static_cast<const uint8_t*>(vb->getVertexDataPtr(*uvDecl)) : nullptr;
			const uint8_t* colBase = colDecl ? static_cast<const uint8_t*>(vb->getVertexDataPtr(*colDecl)) : nullptr;

			for (int vi = 0; vi < nv; ++vi)
			{
				const float* pf = reinterpret_cast<const float*>(posBase + size_t(vi) * posDecl->m_byteStride);
				hkVector4 pLocal(pf[0], pf[1], pf[2], 1.0f);
				hkVector4 pWorld;
				worldM.transformPosition(pLocal, pWorld);
				posBuf[size_t(vi) * 3 + 0] = float(pWorld(0));
				posBuf[size_t(vi) * 3 + 1] = float(pWorld(1));
				posBuf[size_t(vi) * 3 + 2] = float(pWorld(2));

				if (nrmBase)
				{
					const float* nf = reinterpret_cast<const float*>(nrmBase + size_t(vi) * nrmDecl->m_byteStride);
					hkVector4 nLocal(nf[0], nf[1], nf[2], 0.0f);
					hkVector4 nWorld;
					worldM.transformDirection(nLocal, nWorld);
					if (nWorld.lengthSquared<3>() > hkSimdReal::fromFloat(1e-12f))
						nWorld.normalize<3>();
					else
						nWorld.set(0, 0, 1);
					nrmBuf[size_t(vi) * 3 + 0] = float(nWorld(0));
					nrmBuf[size_t(vi) * 3 + 1] = float(nWorld(1));
					nrmBuf[size_t(vi) * 3 + 2] = float(nWorld(2));
				}

				if (uvBase)
				{
					if (uvDecl->m_type == hkxVertexDescription::HKX_DT_FLOAT)
					{
						const float* uf = reinterpret_cast<const float*>(uvBase + size_t(vi) * uvDecl->m_byteStride);
						uvBuf[size_t(vi) * 2 + 0] = uf[0];
						uvBuf[size_t(vi) * 2 + 1] = uf[1];
					}
					else if (uvDecl->m_type == hkxVertexDescription::HKX_DT_INT16)
					{
						const int16_t* us = reinterpret_cast<const int16_t*>(uvBase + size_t(vi) * uvDecl->m_byteStride);
						uvBuf[size_t(vi) * 2 + 0] = float(us[0]) / 3276.7f;
						uvBuf[size_t(vi) * 2 + 1] = float(us[1]) / 3276.7f;
					}
				}

				if (colBase)
				{
					const uint8_t* cp = colBase + size_t(vi) * colDecl->m_byteStride;
					if (colDecl->m_type == hkxVertexDescription::HKX_DT_UINT32)
					{
						// Havok hkColor / D3DCOLOR is ARGB (little-endian bytes: B, G, R, A)
						uint32_t c32 = *reinterpret_cast<const uint32_t*>(cp);
						float b = float((c32 >> 0) & 0xFF) / 255.0f;
						float g = float((c32 >> 8) & 0xFF) / 255.0f;
						float r = float((c32 >> 16) & 0xFF) / 255.0f;
						float a = float((c32 >> 24) & 0xFF) / 255.0f;
						colBuf[size_t(vi) * 4 + 0] = r;
						colBuf[size_t(vi) * 4 + 1] = g;
						colBuf[size_t(vi) * 4 + 2] = b;
						colBuf[size_t(vi) * 4 + 3] = (a > 0.0f) ? a : 1.0f;
					}
					else if (colDecl->m_type == hkxVertexDescription::HKX_DT_UINT8)
					{
						colBuf[size_t(vi) * 4 + 0] = float(cp[0]) / 255.0f;
						colBuf[size_t(vi) * 4 + 1] = float(cp[1]) / 255.0f;
						colBuf[size_t(vi) * 4 + 2] = float(cp[2]) / 255.0f;
						colBuf[size_t(vi) * 4 + 3] = (colDecl->m_numElements >= 4) ? (float(cp[3]) / 255.0f) : 1.0f;
					}
					else if (colDecl->m_type == hkxVertexDescription::HKX_DT_FLOAT)
					{
						const float* cf = reinterpret_cast<const float*>(cp);
						colBuf[size_t(vi) * 4 + 0] = cf[0];
						colBuf[size_t(vi) * 4 + 1] = cf[1];
						colBuf[size_t(vi) * 4 + 2] = cf[2];
						colBuf[size_t(vi) * 4 + 3] = (colDecl->m_numElements >= 4) ? cf[3] : 1.0f;
					}
				}
			}

			std::vector<uint32_t> idxBuf;
			const hkUint32 nTris = sec->getNumTriangles();
			idxBuf.reserve(size_t(nTris) * 3);
			for (hkUint32 ti = 0; ti < nTris; ++ti)
			{
				hkUint32 a = 0, b = 0, c = 0;
				sec->getTriangleIndices(ti, a, b, c);
				if (a >= hkUint32(nv) || b >= hkUint32(nv) || c >= hkUint32(nv)) continue;
				if (a == b || b == c || c == a) continue;
				if (flipWinding) { idxBuf.push_back(a); idxBuf.push_back(c); idxBuf.push_back(b); }
				else { idxBuf.push_back(a); idxBuf.push_back(b); idxBuf.push_back(c); }
			}
			if (idxBuf.empty()) continue;

			const hkxMaterial* mat = sec->m_material;
			if (mat && mat->m_subMaterials.getSize() > 0 && mat->m_stages.isEmpty())
			{
				// Multi-material fallback if section points to parent container
				mat = mat->m_subMaterials[si % mat->m_subMaterials.getSize()];
			}
			int mIdx = registerMaterial(mat, matMap, mats, bin);

			ExtractedMeshSection es{};
			es.nodeName = nodeName;
			es.sectionIdx = si;
			es.matIdx = mIdx;
			es.numVerts = nv;
			es.numIndices = int(idxBuf.size());
			es.hasNormal = (nrmDecl != nullptr);
			es.hasUv = (uvDecl != nullptr);
			es.hasColor = (colDecl != nullptr);
			es.posOff = bin.append(posBuf.data(), posBuf.size() * sizeof(float));
			es.nrmOff = es.hasNormal ? bin.append(nrmBuf.data(), nrmBuf.size() * sizeof(float)) : 0;
			es.uvOff = es.hasUv ? bin.append(uvBuf.data(), uvBuf.size() * sizeof(float)) : 0;
			es.colOff = es.hasColor ? bin.append(colBuf.data(), colBuf.size() * sizeof(float)) : 0;
			es.idxOff = bin.append(idxBuf.data(), idxBuf.size() * sizeof(uint32_t));
			sections.push_back(es);
		}
	}

	for (int ci = 0; ci < node->m_children.getSize(); ++ci)
	{
		extractSceneNodeRecursive(scene, node->m_children[ci], worldM, matMap, mats, sections, bin);
	}
}

static void writeShapeJson(std::FILE* f, const hknpShape* shape, bool includeSurfaceMesh)
{
	if (!shape)
	{
		std::fprintf(f, "null");
		return;
	}
	hknpShapeType::Enum st = shape->getType();
	const char* typeName = "UNKNOWN";
	switch (st)
	{
		case hknpShapeType::CONVEX: typeName = "CONVEX"; break;
		case hknpShapeType::CONVEX_POLYTOPE: typeName = "CONVEX_POLYTOPE"; break;
		case hknpShapeType::SPHERE: typeName = "SPHERE"; break;
		case hknpShapeType::CAPSULE: typeName = "CAPSULE"; break;
		case hknpShapeType::BOX: typeName = "BOX"; break;
		case hknpShapeType::COMPRESSED_MESH: typeName = "COMPRESSED_MESH"; break;
		case hknpShapeType::COMPOUND: typeName = "COMPOUND"; break;
		default: typeName = "OTHER"; break;
	}

	hkAabb aabb;
	shape->calcAabb(hkTransform::getIdentity(), aabb);

	std::fprintf(f, "{\"type\":\"%s\",\"convex_radius\":%.7f,\"aabb_min\":", typeName, safeF(shape->m_convexRadius));
	writeVec3(f, aabb.m_min);
	std::fprintf(f, ",\"aabb_max\":");
	writeVec3(f, aabb.m_max);

	if (st == hknpShapeType::CAPSULE)
	{
		const hknpCapsuleShape* cap = static_cast<const hknpCapsuleShape*>(shape);
		std::fprintf(f, ",\"capsule_a\":");
		writeVec3(f, cap->m_a);
		std::fprintf(f, ",\"capsule_b\":");
		writeVec3(f, cap->m_b);
		std::fprintf(f, ",\"capsule_radius\":%.7f", safeF(double(cap->getRadius())));
	}
	else if (st == hknpShapeType::SPHERE)
	{
		const hknpSphereShape* sph = static_cast<const hknpSphereShape*>(shape);
		const hkRelArray<hkcdVertex>& verts = sph->getVertices();
		hkVector4 ctr = (verts.getSize() > 0) ? verts[0] : hkVector4::getZero();
		std::fprintf(f, ",\"sphere_center\":");
		writeVec3(f, ctr);
		std::fprintf(f, ",\"sphere_radius\":%.7f", safeF(shape->m_convexRadius));
	}
	else if (const hknpConvexShape* cvx = shape->asConvexShape())
	{
		const hkRelArray<hkcdVertex>& verts = cvx->getVertices();
		std::fprintf(f, ",\"convex_verts\":[");
		for (int i = 0; i < verts.getSize(); ++i)
		{
			if (i > 0) std::fprintf(f, ",");
			writeVec3(f, verts[i]);
		}
		std::fprintf(f, "]");
	}

	if (includeSurfaceMesh)
	{
		hkGeometry geom;
		hknpShape::BuildSurfaceGeometryConfig cfg(hknpShape::CONVEX_RADIUS_DISPLAY_PLANAR);
		if (shape->buildSurfaceGeometry(cfg, &geom) == HK_SUCCESS && geom.m_vertices.getSize() > 0 && geom.m_triangles.getSize() > 0)
		{
			std::fprintf(f, ",\"mesh_verts\":[");
			for (int i = 0; i < geom.m_vertices.getSize(); ++i)
			{
				if (i > 0) std::fprintf(f, ",");
				writeVec3(f, geom.m_vertices[i]);
			}
			std::fprintf(f, "],\"mesh_tris\":[");
			for (int i = 0; i < geom.m_triangles.getSize(); ++i)
			{
				if (i > 0) std::fprintf(f, ",");
				std::fprintf(f, "[%d,%d,%d]", geom.m_triangles[i].m_a, geom.m_triangles[i].m_b, geom.m_triangles[i].m_c);
			}
			std::fprintf(f, "]");
		}
	}
	std::fprintf(f, "}");
}

static int runSceneExtract(const char* inHkt, const char* outJson, const char* outBin)
{
	hkObjectResource* res = loadHktResource(inHkt);
	if (!res) return 2;
	hkRootLevelContainer* rlc = res->getContents<hkRootLevelContainer>();
	if (!rlc)
	{
		std::fprintf(stderr, "[ERROR] No hkRootLevelContainer in %s\n", inHkt);
		res->removeReference();
		return 3;
	}

	const hkxScene* scene = rlc->findObject<hkxScene>();
	std::vector<const hknpPhysicsSystemData*> physSystems;
	if (const hknpPhysicsSystemData* sys = rlc->findObject<hknpPhysicsSystemData>())
		physSystems.push_back(sys);
	if (const hknpPhysicsSceneData* psd = rlc->findObject<hknpPhysicsSceneData>())
	{
		for (int si = 0; si < psd->m_systemDatas.getSize(); ++si)
		{
			if (psd->m_systemDatas[si]) physSystems.push_back(psd->m_systemDatas[si]);
		}
	}

	BinWriter bin;
	std::map<const hkxMaterial*, int> matMap;
	std::vector<ExtractedMat> mats;
	std::vector<ExtractedMeshSection> sections;

	if (scene && scene->m_rootNode)
	{
		hkMatrix4 ident;
		ident.setIdentity();
		extractSceneNodeRecursive(scene, scene->m_rootNode, ident, matMap, mats, sections, bin);
	}

	// Write binary buffer
	{
		std::FILE* bf = std::fopen(outBin, "wb");
		if (!bf) { std::fprintf(stderr, "[ERROR] Cannot open %s\n", outBin); res->removeReference(); return 4; }
		if (!bin.data.empty()) std::fwrite(bin.data.data(), 1, bin.data.size(), bf);
		std::fclose(bf);
	}

	// Write JSON manifest
	std::FILE* f = std::fopen(outJson, "wb");
	if (!f) { std::fprintf(stderr, "[ERROR] Cannot open %s\n", outJson); res->removeReference(); return 5; }

	std::fprintf(f, "{\n");
	std::fprintf(f, "  \"source\": \"%s\",\n", jesc(inHkt).c_str());
	std::fprintf(f, "  \"modeller\": \"%s\",\n", scene && scene->m_modeller.cString() ? jesc(scene->m_modeller.cString()).c_str() : "");
	std::fprintf(f, "  \"materials\": [\n");
	for (size_t i = 0; i < mats.size(); ++i)
	{
		const ExtractedMat& m = mats[i];
		std::fprintf(f, "    {\"name\":\"%s\",\"diffuse\":[%.5f,%.5f,%.5f,%.5f],\"ambient\":[%.5f,%.5f,%.5f,%.5f],\"specular\":[%.5f,%.5f,%.5f,%.5f],\"emissive\":[%.5f,%.5f,%.5f,%.5f],\"transparency\":%d,\"diffuse_tex\":\"%s\",\"lightmap_tex\":\"%s\",\"inplace_name\":\"%s\",\"inplace_ext\":\"%s\",\"inplace_off\":%zu,\"inplace_len\":%zu}%s\n",
			jesc(m.name.c_str()).c_str(),
			m.diffuse[0], m.diffuse[1], m.diffuse[2], m.diffuse[3],
			m.ambient[0], m.ambient[1], m.ambient[2], m.ambient[3],
			m.specular[0], m.specular[1], m.specular[2], m.specular[3],
			m.emissive[0], m.emissive[1], m.emissive[2], m.emissive[3],
			m.transparency,
			jesc(m.diffuseTexFile.c_str()).c_str(),
			jesc(m.lightmapTexFile.c_str()).c_str(),
			jesc(m.inplaceTexName.c_str()).c_str(),
			jesc(m.inplaceTexExt.c_str()).c_str(),
			m.inplaceTexOff, m.inplaceTexLen,
			(i + 1 < mats.size()) ? "," : "");
	}
	std::fprintf(f, "  ],\n");

	std::fprintf(f, "  \"sections\": [\n");
	for (size_t i = 0; i < sections.size(); ++i)
	{
		const ExtractedMeshSection& s = sections[i];
		std::fprintf(f, "    {\"node\":\"%s\",\"section\":%d,\"material\":%d,\"verts\":%d,\"indices\":%d,\"has_normal\":%s,\"has_uv\":%s,\"has_color\":%s,\"pos_off\":%zu,\"nrm_off\":%zu,\"uv_off\":%zu,\"col_off\":%zu,\"idx_off\":%zu}%s\n",
			jesc(s.nodeName.c_str()).c_str(), s.sectionIdx, s.matIdx, s.numVerts, s.numIndices,
			s.hasNormal ? "true" : "false", s.hasUv ? "true" : "false", s.hasColor ? "true" : "false",
			s.posOff, s.nrmOff, s.uvOff, s.colOff, s.idxOff,
			(i + 1 < sections.size()) ? "," : "");
	}
	std::fprintf(f, "  ],\n");

	std::fprintf(f, "  \"physics_bodies\": [\n");
	int totalPhysBodies = 0;
	for (const hknpPhysicsSystemData* ps : physSystems) totalPhysBodies += ps->m_bodyCinfos.getSize();
	int emittedBody = 0;
	for (const hknpPhysicsSystemData* physData : physSystems)
	{
		const int nb = physData->m_bodyCinfos.getSize();
		for (int bi = 0; bi < nb; ++bi)
		{
			const hknpPhysicsSystemData::bodyCinfoWithAttachment& b = physData->m_bodyCinfos[bi];
			const char* mtype = (b.m_motionType == hknpMotionType::STATIC) ? "STATIC" :
								(b.m_motionType == hknpMotionType::KEYFRAMED) ? "KEYFRAMED" : "DYNAMIC";
			std::fprintf(f, "    {\"index\":%d,\"name\":\"%s\",\"motion_type\":\"%s\",\"mass\":%.5f,\"position\":",
				emittedBody, jesc(b.m_name.cString()).c_str(), mtype, safeF(b.m_mass));
			writeVec3(f, b.m_position);
			std::fprintf(f, ",\"orientation\":");
			writeQuat(f, b.m_orientation);
			std::fprintf(f, ",\"shape\":");
			// Include surface mesh only for non-static or small convex shapes
			bool wantMesh = (b.m_motionType != hknpMotionType::STATIC);
			writeShapeJson(f, b.m_shape, wantMesh);
			++emittedBody;
			std::fprintf(f, "}%s\n", (emittedBody < totalPhysBodies) ? "," : "");
		}
	}
	std::fprintf(f, "  ]\n");
	std::fprintf(f, "}\n");
	std::fclose(f);

	std::fprintf(stderr, "[scene] Extracted %zu materials, %zu sections, %d physics bodies from %s\n",
		mats.size(), sections.size(), totalPhysBodies, inHkt);
	res->removeReference();
	return 0;
}

// ============================================================================
// MODE 2: --ragdoll <ragdoll_np.hkt> <mapper.hkt> <out.json> [behavior1.hkt ...]
// ============================================================================

struct RagdollModHit
{
	std::string behaviorFile;
	std::string statePath;
	std::string kind; // "powered" | "rigid_body" | "keyframe"
	std::string nodeName;
	// Powered fields
	float maxForce;
	float tau;
	float damping;
	float propRecoveryVel;
	float constRecoveryVel;
	int wfmMode;
	int wfmBones[3];
	float animBlendFrac;
	// RigidBody fields
	float hierarchyGain;
	float velocityDamping;
	float accelerationGain;
	float velocityGain;
	float positionGain;
	float posMaxLinVel;
	float posMaxAngVel;
	float snapGain;
	float snapMaxLinVel;
	float snapMaxAngVel;
	float snapMaxLinDist;
	float snapMaxAngDist;
	float durationToBlend;
	// Bone arrays
	std::vector<int> boneIndices;
	std::vector<float> boneWeights;
};

static void walkBehaviorNode(
	const hkbNode* node,
	const std::string& behFile,
	const std::string& statePath,
	std::set<std::pair<const hkbNode*, std::string>>& visited,
	std::vector<RagdollModHit>& hits)
{
	if (!node) return;
	auto key = std::make_pair(node, statePath);
	if (visited.count(key)) return;
	visited.insert(key);

	if (const hkbPoweredRagdollControlsModifier* pm = hkDynCast<hkbPoweredRagdollControlsModifier>(node))
	{
		RagdollModHit h{};
		h.behaviorFile = behFile;
		h.statePath = statePath;
		h.kind = "powered";
		h.nodeName = pm->m_name.cString() ? pm->m_name.cString() : "";
		h.maxForce = pm->m_controlData.m_maxForce;
		h.tau = pm->m_controlData.m_tau;
		h.damping = pm->m_controlData.m_damping;
		h.propRecoveryVel = pm->m_controlData.m_proportionalRecoveryVelocity;
		h.constRecoveryVel = pm->m_controlData.m_constantRecoveryVelocity;
		h.wfmMode = int(pm->m_worldFromModelModeData.m_mode);
		h.wfmBones[0] = pm->m_worldFromModelModeData.m_poseMatchingBone0;
		h.wfmBones[1] = pm->m_worldFromModelModeData.m_poseMatchingBone1;
		h.wfmBones[2] = pm->m_worldFromModelModeData.m_poseMatchingBone2;
		h.animBlendFrac = pm->m_animationBlendFraction;
		if (pm->m_bones)
		{
			for (int i = 0; i < pm->m_bones->m_boneIndices.getSize(); ++i)
				h.boneIndices.push_back(int(pm->m_bones->m_boneIndices[i]));
		}
		if (pm->m_boneWeights)
		{
			for (int i = 0; i < pm->m_boneWeights->m_boneWeights.getSize(); ++i)
				h.boneWeights.push_back(float(pm->m_boneWeights->m_boneWeights[i]));
		}
		hits.push_back(h);
	}
	else if (const hkbRigidBodyRagdollControlsModifier* rm = hkDynCast<hkbRigidBodyRagdollControlsModifier>(node))
	{
		RagdollModHit h{};
		h.behaviorFile = behFile;
		h.statePath = statePath;
		h.kind = "rigid_body";
		h.nodeName = rm->m_name.cString() ? rm->m_name.cString() : "";
		const hkbKeyFrameControlData& kf = rm->m_controlData.m_keyFrameControlData;
		h.hierarchyGain = kf.m_hierarchyGain;
		h.velocityDamping = kf.m_velocityDamping;
		h.accelerationGain = kf.m_accelerationGain;
		h.velocityGain = kf.m_velocityGain;
		h.positionGain = kf.m_positionGain;
		h.posMaxLinVel = kf.m_positionMaxLinearVelocity;
		h.posMaxAngVel = kf.m_positionMaxAngularVelocity;
		h.snapGain = kf.m_snapGain;
		h.snapMaxLinVel = kf.m_snapMaxLinearVelocity;
		h.snapMaxAngVel = kf.m_snapMaxAngularVelocity;
		h.snapMaxLinDist = kf.m_snapMaxLinearDistance;
		h.snapMaxAngDist = kf.m_snapMaxAngularDistance;
		h.durationToBlend = rm->m_controlData.m_durationToBlend;
		h.animBlendFrac = rm->m_animationBlendFraction;
		if (rm->m_bones)
		{
			for (int i = 0; i < rm->m_bones->m_boneIndices.getSize(); ++i)
				h.boneIndices.push_back(int(rm->m_bones->m_boneIndices[i]));
		}
		hits.push_back(h);
	}
	else if (const hkbKeyframeBonesModifier* km = hkDynCast<hkbKeyframeBonesModifier>(node))
	{
		RagdollModHit h{};
		h.behaviorFile = behFile;
		h.statePath = statePath;
		h.kind = "keyframe";
		h.nodeName = km->m_name.cString() ? km->m_name.cString() : "";
		if (km->m_keyframedBonesList)
		{
			for (int i = 0; i < km->m_keyframedBonesList->m_boneIndices.getSize(); ++i)
				h.boneIndices.push_back(int(km->m_keyframedBonesList->m_boneIndices[i]));
		}
		for (int i = 0; i < km->m_keyframeInfo.getSize(); ++i)
		{
			if (km->m_keyframeInfo[i].m_boneIndex >= 0)
				h.boneIndices.push_back(int(km->m_keyframeInfo[i].m_boneIndex));
		}
		hits.push_back(h);
	}

	if (const hkbStateMachine* sm = hkDynCast<hkbStateMachine>(node))
	{
		std::string smName = sm->m_name.cString() ? sm->m_name.cString() : "SM";
		for (int si = 0; si < sm->getNumStates(); ++si)
		{
			const hkbStateMachine::StateInfo& st = sm->getStateInfoByIndex(si);
			if (!st.getGenerator()) continue;
			std::string stName = st.m_name.cString() ? st.m_name.cString() : std::to_string(st.getStateId());
			std::string nextPath = statePath.empty() ? (smName + ":" + stName) : (statePath + "/" + smName + ":" + stName);
			walkBehaviorNode(st.getGenerator(), behFile, nextPath, visited, hits);
		}
		return;
	}

	// Generic traversal via hkbNode::getChildren
	hkArray<hkbNodeChildInfo> childList;
	hkbNode::ChildrenInfo cinfo(childList);
	const_cast<hkbNode*>(node)->getChildren(hkbNode::FLAG_IGNORE_REFERENCED_BEHAVIORS, cinfo);
	for (int ci = 0; ci < childList.getSize(); ++ci)
	{
		walkBehaviorNode(childList[ci].m_node, behFile, statePath, visited, hits);
	}
}

static int runRagdollExtract(
	const char* ragdollHkt,
	const char* mapperHkt,
	const char* outJson,
	const std::vector<const char*>& behFiles)
{
	hkObjectResource* ragRes = loadHktResource(ragdollHkt);
	if (!ragRes) return 2;
	hkRootLevelContainer* ragRlc = ragRes->getContents<hkRootLevelContainer>();
	const hknpRagdollData* ragData = ragRlc ? ragRlc->findObject<hknpRagdollData>() : HK_NULL;
	if (!ragData || !ragData->m_skeleton)
	{
		std::fprintf(stderr, "[ERROR] No hknpRagdollData in %s\n", ragdollHkt);
		ragRes->removeReference();
		return 3;
	}

	hkObjectResource* mapRes = loadHktResource(mapperHkt);
	hkRootLevelContainer* mapRlc = mapRes ? mapRes->getContents<hkRootLevelContainer>() : HK_NULL;

	// Collect all hkaSkeletonMapper objects in BOTH ragdoll.hkt AND mapper.hkt!
	std::vector<const hkaSkeletonMapper*> mappers;
	auto collectMappers = [&](hkRootLevelContainer* container) {
		if (!container) return;
		const hkaSkeletonMapper* prev = HK_NULL;
		while (const hkaSkeletonMapper* mp = container->findObject<hkaSkeletonMapper>(prev))
		{
			mappers.push_back(mp);
			prev = mp;
		}
	};
	collectMappers(ragRlc);
	collectMappers(mapRlc);

	// Collect ragdoll modifiers across all passed Behavior .hkt graphs
	std::vector<RagdollModHit> modHits;
	for (const char* bf : behFiles)
	{
		hkObjectResource* bRes = loadHktResource(bf);
		if (!bRes) continue;
		hkRootLevelContainer* bRlc = bRes->getContents<hkRootLevelContainer>();
		const hkbBehaviorGraph* bg = bRlc ? bRlc->findObject<hkbBehaviorGraph>() : HK_NULL;
		if (bg && bg->getRootGenerator())
		{
			std::set<std::pair<const hkbNode*, std::string>> visited;
			// Base filename
			std::string bname = bf;
			size_t slash = bname.find_last_of("/\\");
			if (slash != std::string::npos) bname = bname.substr(slash + 1);
			walkBehaviorNode(bg->getRootGenerator(), bname, "", visited, modHits);
		}
		bRes->removeReference();
	}

	std::FILE* f = std::fopen(outJson, "wb");
	if (!f) { std::fprintf(stderr, "[ERROR] Cannot open %s\n", outJson); ragRes->removeReference(); if (mapRes) mapRes->removeReference(); return 4; }

	const hkaSkeleton* skel = ragData->m_skeleton;
	const int nBones = skel->m_bones.getSize();
	const int nBodies = ragData->m_bodyCinfos.getSize();
	const int nConstraints = ragData->m_constraintCinfos.getSize();

	std::fprintf(f, "{\n");
	std::fprintf(f, "  \"schema\": \"havok-soldier-ragdoll-spec-v1\",\n");
	std::fprintf(f, "  \"contains_sdk_hkt_runtime_dep\": false,\n");
	std::fprintf(f, "  \"source_ragdoll\": \"%s\",\n", jesc(ragdollHkt).c_str());
	std::fprintf(f, "  \"source_mapper\": \"%s\",\n", jesc(mapperHkt).c_str());
	std::fprintf(f, "  \"skeleton_name\": \"%s\",\n", jesc(skel->m_name.cString()).c_str());
	std::fprintf(f, "  \"bone_count\": %d,\n", nBones);
	std::fprintf(f, "  \"body_count\": %d,\n", nBodies);
	std::fprintf(f, "  \"constraint_count\": %d,\n", nConstraints);

	// 1. Ragdoll Skeleton
	std::fprintf(f, "  \"bones\": [\n");
	for (int i = 0; i < nBones; ++i)
	{
		int bodyIdx = (i < ragData->m_boneToBodyMap.getSize()) ? ragData->m_boneToBodyMap[i] : i;
		std::fprintf(f, "    {\"index\":%d,\"name\":\"%s\",\"parent\":%d,\"body_index\":%d,\"ref_pose\":",
			i, jesc(skel->m_bones[i].m_name.cString()).c_str(), int(skel->m_parentIndices[i]), bodyIdx);
		writeQs(f, skel->m_referencePose[i]);
		std::fprintf(f, "}%s\n", (i + 1 < nBones) ? "," : "");
	}
	std::fprintf(f, "  ],\n");

	// 2. Materials
	std::fprintf(f, "  \"materials\": [\n");
	for (int i = 0; i < ragData->m_materials.getSize(); ++i)
	{
		const hknpMaterial& m = ragData->m_materials[i];
		std::fprintf(f, "    {\"index\":%d,\"name\":\"%s\",\"dynamic_friction\":%.5f,\"static_friction\":%.5f,\"restitution\":%.5f}%s\n",
			i, jesc(m.m_name.cString()).c_str(),
			safeF(float(m.m_dynamicFriction)),
			safeF(float(m.m_staticFriction)),
			safeF(float(m.m_restitution)),
			(i + 1 < ragData->m_materials.getSize()) ? "," : "");
	}
	std::fprintf(f, "  ],\n");

	// 3. Motion Properties
	std::fprintf(f, "  \"motion_properties\": [\n");
	for (int i = 0; i < ragData->m_motionProperties.getSize(); ++i)
	{
		const hknpMotionProperties& mp = ragData->m_motionProperties[i];
		std::fprintf(f, "    {\"index\":%d,\"gravity_factor\":%.5f,\"linear_damping\":%.5f,\"angular_damping\":%.5f,\"max_linear_speed\":%.5f,\"max_angular_speed\":%.5f}%s\n",
			i, safeF(mp.m_gravityFactor), safeF(mp.m_linearDamping), safeF(mp.m_angularDamping),
			safeF(mp.m_maxLinearSpeed), safeF(mp.m_maxAngularSpeed),
			(i + 1 < ragData->m_motionProperties.getSize()) ? "," : "");
	}
	std::fprintf(f, "  ],\n");

	// 4. Rigid Bodies (exact masses, inertia, COM, materials, damping, shapes + exact surface meshes!)
	std::fprintf(f, "  \"bodies\": [\n");
	for (int i = 0; i < nBodies; ++i)
	{
		const hknpPhysicsSystemData::bodyCinfoWithAttachment& b = ragData->m_bodyCinfos[i];
		int matIdx = int(b.m_materialId.value());
		int mpIdx = int(b.m_motionPropertiesId.value());
		float dynFric = 0.5f, statFric = 0.5f, restit = 0.0f;
		if (matIdx >= 0 && matIdx < ragData->m_materials.getSize())
		{
			dynFric = float(ragData->m_materials[matIdx].m_dynamicFriction);
			statFric = float(ragData->m_materials[matIdx].m_staticFriction);
			restit = float(ragData->m_materials[matIdx].m_restitution);
		}
		float linDamp = 0.0f, angDamp = 0.05f, gravFac = 1.0f;
		if (mpIdx >= 0 && mpIdx < ragData->m_motionProperties.getSize())
		{
			linDamp = ragData->m_motionProperties[mpIdx].m_linearDamping;
			angDamp = ragData->m_motionProperties[mpIdx].m_angularDamping;
			gravFac = ragData->m_motionProperties[mpIdx].m_gravityFactor;
		}
		hkVector4 com = hkVector4::getZero();
		hkVector4 inertia = hkVector4(0.05f, 0.05f, 0.05f);
		float vol = 0.0f;
		if (b.m_massDistribution)
		{
			com = b.m_massDistribution->m_massDistribution.m_centerOfMassAndVolume;
			vol = float(com(3));
			inertia = b.m_massDistribution->m_massDistribution.m_inertiaTensor;
		}
		else if (b.m_shape)
		{
			hkDiagonalizedMassProperties dmp;
			b.m_shape->buildMassProperties(hknpShape::MassConfig::fromMass(b.m_mass > 0.0f ? b.m_mass : 5.0f), dmp);
			com = dmp.m_centerOfMass;
			inertia = dmp.m_inertiaTensor;
			vol = float(dmp.m_volume);
		}

		// Find matching bone index
		int boneIdx = -1;
		for (int k = 0; k < ragData->m_boneToBodyMap.getSize(); ++k)
		{
			if (ragData->m_boneToBodyMap[k] == i) { boneIdx = k; break; }
		}
		if (boneIdx < 0 && i < nBones) boneIdx = i;

		std::fprintf(f, "    {\"index\":%d,\"bone_index\":%d,\"name\":\"%s\",\"mass\":%.5f,\"volume\":%.6f,\"collision_filter_info\":%u,\"dynamic_friction\":%.5f,\"static_friction\":%.5f,\"restitution\":%.5f,\"linear_damping\":%.5f,\"angular_damping\":%.5f,\"gravity_factor\":%.5f,\"position\":",
			i, boneIdx, jesc(b.m_name.cString()).c_str(),
			safeF(b.m_mass), safeF(vol), unsigned(b.m_collisionFilterInfo),
			safeF(dynFric), safeF(statFric), safeF(restit),
			safeF(linDamp), safeF(angDamp), safeF(gravFac));
		writeVec3(f, b.m_position);
		std::fprintf(f, ",\"orientation\":");
		writeQuat(f, b.m_orientation);
		std::fprintf(f, ",\"center_of_mass\":");
		writeVec3(f, com);
		std::fprintf(f, ",\"inertia_diag\":");
		writeVec3(f, inertia);
		std::fprintf(f, ",\"shape\":");
		writeShapeJson(f, b.m_shape, true);
		std::fprintf(f, "}%s\n", (i + 1 < nBodies) ? "," : "");
	}
	std::fprintf(f, "  ],\n");

	// 5. Constraints (exact Ragdoll cone/plane/twist & LimitedHinge limits + local pivot/axis frames!)
	std::fprintf(f, "  \"constraints\": [\n");
	for (int i = 0; i < nConstraints; ++i)
	{
		const hknpConstraintCinfo& cc = ragData->m_constraintCinfos[i];
		const hkpConstraintData* cd = cc.m_constraintData;
		int bodyA = int(cc.m_bodyA.index());
		int bodyB = int(cc.m_bodyB.index());
		int ctype = cd ? cd->getType() : -1;

		std::fprintf(f, "    {\"index\":%d,\"name\":\"%s\",\"body_a\":%d,\"body_b\":%d",
			i, jesc(cc.m_name.cString()).c_str(), bodyA, bodyB);

		if (cd && ctype == hkpConstraintData::CONSTRAINT_TYPE_RAGDOLL)
		{
			const hkpRagdollConstraintData* rd = static_cast<const hkpRagdollConstraintData*>(cd);
			hkMatrix3 frameA, frameB;
			rd->getConstraintFrameA(frameA);
			rd->getConstraintFrameB(frameB);
			std::fprintf(f, ",\"type\":\"ragdoll\",\"pivot_a\":");
			writeVec3(f, rd->m_atoms.m_transforms.m_transformA.getTranslation());
			std::fprintf(f, ",\"pivot_b\":");
			writeVec3(f, rd->m_atoms.m_transforms.m_transformB.getTranslation());
			std::fprintf(f, ",\"frame_a\":");
			writeMat3(f, frameA);
			std::fprintf(f, ",\"frame_b\":");
			writeMat3(f, frameB);
			std::fprintf(f, ",\"twist_min\":%.6f,\"twist_max\":%.6f,\"plane_min\":%.6f,\"plane_max\":%.6f,\"cone_max\":%.6f,\"max_friction_torque\":%.5f,\"angular_limits_tau\":%.5f",
				safeF(rd->getTwistMinAngularLimit()),
				safeF(rd->getTwistMaxAngularLimit()),
				safeF(rd->getPlaneMinAngularLimit()),
				safeF(rd->getPlaneMaxAngularLimit()),
				safeF(rd->getConeAngularLimit()),
				safeF(rd->getMaxFrictionTorque()),
				safeF(rd->getAngularLimitsTauFactor()));
		}
		else if (cd && ctype == hkpConstraintData::CONSTRAINT_TYPE_LIMITEDHINGE)
		{
			const hkpLimitedHingeConstraintData* hd = static_cast<const hkpLimitedHingeConstraintData*>(cd);
			std::fprintf(f, ",\"type\":\"limited_hinge\",\"pivot_a\":");
			writeVec3(f, hd->m_atoms.m_transforms.m_transformA.getTranslation());
			std::fprintf(f, ",\"pivot_b\":");
			writeVec3(f, hd->m_atoms.m_transforms.m_transformB.getTranslation());
			std::fprintf(f, ",\"frame_a\":");
			writeMat3(f, hd->m_atoms.m_transforms.m_transformA.getRotation());
			std::fprintf(f, ",\"frame_b\":");
			writeMat3(f, hd->m_atoms.m_transforms.m_transformB.getRotation());
			std::fprintf(f, ",\"min_angle\":%.6f,\"max_angle\":%.6f,\"max_friction_torque\":%.5f,\"angular_limits_tau\":%.5f",
				safeF(hd->getMinAngularLimit()),
				safeF(hd->getMaxAngularLimit()),
				safeF(hd->getMaxFrictionTorque()),
				safeF(hd->getAngularLimitsTauFactor()));
		}
		else
		{
			std::fprintf(f, ",\"type\":\"other_%d\"", ctype);
		}
		std::fprintf(f, "}%s\n", (i + 1 < nConstraints) ? "," : "");
	}
	std::fprintf(f, "  ],\n");

	// 6. Skeleton Mappers (ragdoll <-> high-res)
	std::fprintf(f, "  \"mappers\": [\n");
	for (size_t mi = 0; mi < mappers.size(); ++mi)
	{
		const hkaSkeletonMapperData& md = mappers[mi]->m_mapping;
		const hkaSkeleton* skA = md.m_skeletonA;
		const hkaSkeleton* skB = md.m_skeletonB;
		std::fprintf(f, "    {\"skeleton_a\":\"%s\",\"bones_a\":%d,\"skeleton_b\":\"%s\",\"bones_b\":%d,\"mapping_type\":%d,\"keep_unmapped_local\":%s,\"simple_mappings\":[",
			skA && skA->m_name.cString() ? jesc(skA->m_name.cString()).c_str() : "",
			skA ? skA->m_bones.getSize() : 0,
			skB && skB->m_name.cString() ? jesc(skB->m_name.cString()).c_str() : "",
			skB ? skB->m_bones.getSize() : 0,
			int(md.m_mappingType),
			md.m_keepUnmappedLocal ? "true" : "false");
		for (int si = 0; si < md.m_simpleMappings.getSize(); ++si)
		{
			const hkaSkeletonMapperData::SimpleMapping& sm = md.m_simpleMappings[si];
			const char* nmA = (skA && sm.m_boneA >= 0 && sm.m_boneA < skA->m_bones.getSize()) ? skA->m_bones[sm.m_boneA].m_name.cString() : "";
			const char* nmB = (skB && sm.m_boneB >= 0 && sm.m_boneB < skB->m_bones.getSize()) ? skB->m_bones[sm.m_boneB].m_name.cString() : "";
			if (si > 0) std::fprintf(f, ",");
			std::fprintf(f, "{\"bone_a\":%d,\"name_a\":\"%s\",\"bone_b\":%d,\"name_b\":\"%s\",\"a_from_b\":",
				int(sm.m_boneA), jesc(nmA).c_str(), int(sm.m_boneB), jesc(nmB).c_str());
			writeQs(f, sm.m_aFromBTransform);
			std::fprintf(f, "}");
		}
		std::fprintf(f, "],\"chain_mappings\":[");
		for (int ci = 0; ci < md.m_chainMappings.getSize(); ++ci)
		{
			const hkaSkeletonMapperData::ChainMapping& cm = md.m_chainMappings[ci];
			if (ci > 0) std::fprintf(f, ",");
			std::fprintf(f, "{\"start_a\":%d,\"end_a\":%d,\"start_b\":%d,\"end_b\":%d,\"start_a_from_b\":",
				int(cm.m_startBoneA), int(cm.m_endBoneA), int(cm.m_startBoneB), int(cm.m_endBoneB));
			writeQs(f, cm.m_startAFromBTransform);
			std::fprintf(f, ",\"end_a_from_b\":");
			writeQs(f, cm.m_endAFromBTransform);
			std::fprintf(f, "}");
		}
		std::fprintf(f, "]}%s\n", (mi + 1 < mappers.size()) ? "," : "");
	}
	std::fprintf(f, "  ],\n");

	// 7. Official Behavior Ragdoll Control Modifiers (Palettes, MultipleControllers, Stagger, Attachments, AnimationTest)
	std::fprintf(f, "  \"behavior_controls\": [\n");
	for (size_t hi = 0; hi < modHits.size(); ++hi)
	{
		const RagdollModHit& h = modHits[hi];
		std::fprintf(f, "    {\"behavior\":\"%s\",\"state_path\":\"%s\",\"kind\":\"%s\",\"node\":\"%s\",\"anim_blend_fraction\":%.5f",
			jesc(h.behaviorFile.c_str()).c_str(),
			jesc(h.statePath.c_str()).c_str(),
			jesc(h.kind.c_str()).c_str(),
			jesc(h.nodeName.c_str()).c_str(),
			safeF(h.animBlendFrac));
		if (h.kind == "powered")
		{
			std::fprintf(f, ",\"max_force\":%.5f,\"tau\":%.5f,\"damping\":%.5f,\"prop_recovery_vel\":%.5f,\"const_recovery_vel\":%.5f,\"wfm_mode\":%d,\"wfm_bones\":[%d,%d,%d]",
				safeF(h.maxForce), safeF(h.tau), safeF(h.damping),
				safeF(h.propRecoveryVel), safeF(h.constRecoveryVel),
				h.wfmMode, h.wfmBones[0], h.wfmBones[1], h.wfmBones[2]);
		}
		else if (h.kind == "rigid_body")
		{
			std::fprintf(f, ",\"hierarchy_gain\":%.5f,\"velocity_damping\":%.5f,\"acceleration_gain\":%.5f,\"velocity_gain\":%.5f,\"position_gain\":%.5f,\"pos_max_lin_vel\":%.5f,\"pos_max_ang_vel\":%.5f,\"snap_gain\":%.5f,\"snap_max_lin_vel\":%.5f,\"snap_max_ang_vel\":%.5f,\"snap_max_lin_dist\":%.5f,\"snap_max_ang_dist\":%.5f,\"duration_to_blend\":%.5f",
				safeF(h.hierarchyGain), safeF(h.velocityDamping), safeF(h.accelerationGain),
				safeF(h.velocityGain), safeF(h.positionGain),
				safeF(h.posMaxLinVel), safeF(h.posMaxAngVel),
				safeF(h.snapGain), safeF(h.snapMaxLinVel), safeF(h.snapMaxAngVel),
				safeF(h.snapMaxLinDist), safeF(h.snapMaxAngDist), safeF(h.durationToBlend));
		}
		std::fprintf(f, ",\"bones\":[");
		for (size_t bi = 0; bi < h.boneIndices.size(); ++bi)
		{
			if (bi > 0) std::fprintf(f, ",");
			std::fprintf(f, "%d", h.boneIndices[bi]);
		}
		std::fprintf(f, "],\"bone_names\":[");
		for (size_t bi = 0; bi < h.boneIndices.size(); ++bi)
		{
			if (bi > 0) std::fprintf(f, ",");
			int bidx = h.boneIndices[bi];
			const char* bnm = (bidx >= 0 && bidx < nBones) ? skel->m_bones[bidx].m_name.cString() : "";
			std::fprintf(f, "\"%s\"", jesc(bnm).c_str());
		}
		std::fprintf(f, "],\"bone_weights\":[");
		for (size_t wi = 0; wi < h.boneWeights.size(); ++wi)
		{
			if (wi > 0) std::fprintf(f, ",");
			std::fprintf(f, "%.5f", safeF(h.boneWeights[wi]));
		}
		std::fprintf(f, "]}%s\n", (hi + 1 < modHits.size()) ? "," : "");
	}
	std::fprintf(f, "  ]\n");
	std::fprintf(f, "}\n");
	std::fclose(f);

	std::fprintf(stderr, "[ragdoll] Extracted %d bones, %d bodies, %d constraints, %zu mappers, %zu behavior control modifiers -> %s\n",
		nBones, nBodies, nConstraints, mappers.size(), modHits.size(), outJson);

	ragRes->removeReference();
	if (mapRes) mapRes->removeReference();
	return 0;
}

int main(int argc, char** argv)
{
	if (argc < 4)
	{
		std::fprintf(stderr, "Usage:\n  --scene <in.hkt> <out.json> <out.bin>\n  --ragdoll <ragdoll_np.hkt> <mapper.hkt> <out.json> [behavior1.hkt ...]\n");
		return 1;
	}

	PlatformInit();
	hkMemoryRouter* memoryRouter = hkMemoryInitUtil::initDefault(hkMallocAllocator::m_defaultMallocAllocator, hkMemorySystem::FrameInfo(8 * 1024 * 1024));
	hkBaseSystem::init(memoryRouter, reportErr);

	int rc = 1;
	if (std::strcmp(argv[1], "--scene") == 0 && argc >= 5)
	{
		rc = runSceneExtract(argv[2], argv[3], argv[4]);
	}
	else if (std::strcmp(argv[1], "--ragdoll") == 0 && argc >= 5)
	{
		std::vector<const char*> behs;
		for (int i = 5; i < argc; ++i) behs.push_back(argv[i]);
		rc = runRagdollExtract(argv[2], argv[3], argv[4], behs);
	}
	else
	{
		std::fprintf(stderr, "[ERROR] Invalid arguments\n");
	}

	hkBaseSystem::quit();
	hkMemoryInitUtil::quit();
	return rc;
}
