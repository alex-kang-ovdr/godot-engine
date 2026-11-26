#define HK_FEATURE_PRODUCT_ANIMATION

#include <Common/Base/hkBase.h>
#include <Common/Base/Memory/System/Util/hkMemoryInitUtil.h>
#include <Common/Base/Memory/Allocator/Malloc/hkMallocAllocator.h>
#include <Common/Base/System/Io/IStream/hkIStream.h>
#include <Common/Base/Serialize/hkSerialize.h>
#include <Common/Base/Serialize/Resource/hkResource.h>
#include <Common/Base/Serialize/Util/hkRootLevelContainer.h>
#include <Animation/Animation/hkaAnimationContainer.h>
#include <Animation/Animation/Animation/hkaAnimationBinding.h>
#include <Animation/Animation/Rig/hkaSkeleton.h>
#include <Animation/Animation/Deform/Skinning/hkaMeshBinding.h>
#include <Common/Base/KeyCode.h>

#include <Common/Base/Config/hkProductFeatures.cxx>
#include <Common/Base/KeyCode.cxx>
#include <Common/Base/System/Init/PlatformInit.cxx>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <io.h>
#include <vector>

static void jsonString(const char* value)
{
	std::putchar('"');
	for (const unsigned char* p = reinterpret_cast<const unsigned char*>(value ? value : ""); *p; ++p)
	{
		if (*p == '"' || *p == '\\') { std::putchar('\\'); std::putchar(*p); }
		else if (*p < 0x20) std::printf("\\u%04x", *p);
		else std::putchar(*p);
	}
	std::putchar('"');
}

static void printTransform(const hkQsTransform& t)
{
	const hkVector4& p = t.getTranslation();
	const hkQuaternion& q = t.getRotation();
	const hkVector4& s = t.getScale();
	std::printf("[%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g]",
		(double)p(0), (double)p(1), (double)p(2), (double)q.m_vec(0), (double)q.m_vec(1), (double)q.m_vec(2), (double)q.m_vec(3), (double)s(0), (double)s(1), (double)s(2));
}

static void printTransform(const hkTransform& t)
{
	hkQsTransform qs;
	qs.setFromTransform(t);
	printTransform(qs);
}

static void printArray(const hkArray<hkInt16>& values)
{
	std::putchar('[');
	for (int i = 0; i < values.getSize(); ++i) std::printf("%s%d", i ? "," : "", int(values[i]));
	std::putchar(']');
}

static void HK_CALL reportError(const char* message, void*)
{
	std::fprintf(stderr, "%s\n", message);
}

int main(int argc, const char** argv)
{
	if (argc < 2 || std::strcmp(argv[1], "--help") == 0)
	{
		std::fprintf(stderr, "usage: hero_oracle <asset.hkt> [--grid] [--holdouts]\n");
		return argc < 2 ? 2 : 0;
	}
	PlatformInit();
	hkMemoryRouter* router = hkMemoryInitUtil::initDefault(hkMallocAllocator::m_defaultMallocAllocator, hkMemorySystem::FrameInfo(1024 * 1024));
	if (!router) return 3;
	std::fflush(stdout);
	const int stdoutFd = _dup(_fileno(stdout));
	FILE* nullOutput = std::fopen("NUL", "w");
	_dup2(_fileno(nullOutput), _fileno(stdout));
	const hkResult initResult = hkBaseSystem::init(router, reportError);
	std::fflush(stdout);
	_dup2(stdoutFd, _fileno(stdout)); _close(stdoutFd); std::fclose(nullOutput);
	std::clearerr(stdout);
	if (initResult != HK_SUCCESS) return 3;
	hkIstream input(argv[1]);
	if (!input.isOk()) { std::fprintf(stderr, "cannot open: %s\n", argv[1]); hkBaseSystem::quit(); hkMemoryInitUtil::quit(); return 4; }
	hkRefNew<hkResource> resourceOwner = hkSerialize::Load(input.getStreamReader()).withVersioning(true).toOwnedResource();
	hkResource* resource = resourceOwner.val();
	if (!resource) { std::fprintf(stderr, "failed to deserialize: %s\n", argv[1]); hkBaseSystem::quit(); hkMemoryInitUtil::quit(); return 4; }
	hkaAnimationContainer* container = resource->getContents<hkaAnimationContainer>();
	hkRootLevelContainer* root = resource->getContents<hkRootLevelContainer>();
	if (!container && root) container = root->findObject<hkaAnimationContainer>();
	hkaSkeleton* standaloneSkeleton = resource->getContents<hkaSkeleton>();
	if (!standaloneSkeleton && root) standaloneSkeleton = root->findObject<hkaSkeleton>();
	if (!container && !standaloneSkeleton) { std::fprintf(stderr, "no hkaAnimationContainer or hkaSkeleton found\n"); hkBaseSystem::quit(); hkMemoryInitUtil::quit(); return 5; }
	bool sampleGrid = false, sampleHoldouts = false;
	for (int i = 2; i < argc; ++i) { sampleGrid |= std::strcmp(argv[i], "--grid") == 0; sampleHoldouts |= std::strcmp(argv[i], "--holdouts") == 0; }
	std::printf("{\"asset\":"); jsonString(argv[1]); std::printf(",\"containers\":[{\"skeleton\":");
	const hkaSkeleton* outputSkeleton = standaloneSkeleton ? standaloneSkeleton : (container->m_skeletons.getSize() > 0 ? container->m_skeletons[0].val() : HK_NULL);
	if (outputSkeleton)
	{
		const hkaSkeleton* skel = outputSkeleton;
		std::printf("{\"name\":"); jsonString(skel->m_name.cString()); std::printf(",\"bones\":[");
		for (int bi = 0; bi < skel->m_bones.getSize(); ++bi)
		{
			if (bi) std::putchar(','); std::printf("{\"name\":"); jsonString(skel->m_bones[bi].m_name.cString());
			std::printf(",\"parent\":%d,\"reference\":", int(skel->m_parentIndices[bi])); printTransform(skel->m_referencePose[bi]); std::putchar('}');
		}
		std::printf("]}");
	}
	else std::printf("null");
	std::printf(",\"clips\":[");
	for (int ai = 0; container && ai < container->m_animations.getSize(); ++ai)
	{
		const hkaAnimation* anim = container->m_animations[ai]; if (ai) std::putchar(',');
		std::printf("{\"name\":"); jsonString(argv[1]); std::printf(",\"type\":%d,\"duration\":%.9g,\"numOriginalFrames\":%d,\"numTransformTracks\":%d,\"numFloatTracks\":%d,\"binding\":", int(anim->getType()), (double)anim->m_duration, anim->getNumOriginalFrames(), anim->m_numberOfTransformTracks, anim->m_numberOfFloatTracks);
		const hkaAnimationBinding* binding = ai < container->m_bindings.getSize() ? container->m_bindings[ai] : HK_NULL;
		if (binding)
		{
			std::printf("{\"originalSkeletonName\":"); jsonString(binding->m_originalSkeletonName.cString());
			std::printf(",\"trackToBoneIndices\":"); printArray(binding->m_transformTrackToBoneIndices); std::printf("}");
		}
		else std::printf("null");
		auto emitSamples = [&](const char* field, const std::vector<hkReal>& times)
		{
			std::printf(",\"%s\":[", field);
			for (size_t ti = 0; ti < times.size(); ++ti)
			{
				hkArray<hkQsTransform> tracks;
				tracks.setSize(anim->m_numberOfTransformTracks);
				std::vector<hkReal> floats(anim->m_numberOfFloatTracks);
				anim->sampleTracks(times[ti], tracks.begin(), floats.empty() ? HK_NULL : floats.data());
				if (ti) std::putchar(','); std::printf("{\"time\":%.9g,\"tracks\":[", (double)times[ti]);
				for (int i = 0; i < tracks.getSize(); ++i) { if (i) std::putchar(','); printTransform(tracks[i]); }
				std::printf("],\"floats\":[");
				for (size_t i = 0; i < floats.size(); ++i) std::printf("%s%.9g", i ? "," : "", (double)floats[i]);
				std::printf("],\"extractedMotion\":");
				if (anim->hasExtractedMotion()) { hkQsTransform root; anim->getExtractedMotionReferenceFrame(times[ti], root); printTransform(root); }
				else std::printf("null");
				std::putchar('}');
			}
			std::putchar(']');
		};
		std::vector<hkReal> gridTimes;
		if (sampleGrid)
		{
			const int frameCount = anim->getNumOriginalFrames();
			const int keySteps = frameCount > 1 ? frameCount - 1 : 0;
			for (int frame = 0; frame <= keySteps; ++frame) gridTimes.push_back(keySteps ? anim->m_duration * hkReal(frame) / hkReal(keySteps) : 0.0f);
		}
		std::vector<hkReal> holdoutTimes;
		if (sampleHoldouts)
		{
			const hkReal requested[] = {0.137f, 0.731f, anim->m_duration * 0.613f};
			for (int i = 0; i < 3; ++i) if (requested[i] >= 0 && requested[i] <= anim->m_duration) holdoutTimes.push_back(requested[i]);
		}
		if (sampleGrid) emitSamples("source_grid", gridTimes);
		if (sampleHoldouts) emitSamples("holdouts", holdoutTimes);
		std::printf("}");
	}
	std::printf("],\"skins\":[],\"skinCount\":%d}] }\n", container ? container->m_skins.getSize() : 0);
	std::fflush(stdout);
	return 0;
}
