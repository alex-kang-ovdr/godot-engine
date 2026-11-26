#define HK_FEATURE_PRODUCT_ANIMATION
#define HK_FEATURE_PRODUCT_PHYSICS
#define HK_FEATURE_PRODUCT_BEHAVIOR

#include <Common/Base/hkBase.h>
#include <Common/Base/Container/BlockStream/Allocator/Fixed/hkFixedBlockStreamAllocator.h>
#include <Common/Base/Memory/System/Util/hkMemoryInitUtil.h>
#include <Common/Base/Memory/Allocator/Malloc/hkMallocAllocator.h>
#include <Common/Base/KeyCode.h>
#include <Animation/Animation/Rig/hkaSkeleton.h>
#include <Behavior/Behavior/BehaviorGraph/hkbBehaviorGraph.h>
#include <Behavior/Behavior/Character/hkbCharacterSetup.h>
#include <Behavior/Behavior/Linker/hkbSymbolLinker.h>
#include <Behavior/Behavior/Node/hkbNodeInfo.h>
#include <Behavior/Behavior/StateMachine/hkbStateMachine.h>
#include <Behavior/Behavior/World/hkbWorld.h>
#include <Behavior/Behavior/World/hkbWorldCinfo.h>
#include <Behavior/PhysicsBridge/hkbnpPhysicsInterface.h>
#include <Behavior/Utilities/Utils/hkbDefaultAssetLoader.h>
#include <Behavior/Utilities/Utils/hkbProjectAssetManager.h>
#include <Physics/Physics/Collide/Shape/Convex/hknpConvexShape.h>
#include <Physics/Physics/Dynamics/Body/hknpBodyCinfo.h>
#include <Physics/Physics/Dynamics/World/hknpWorld.h>
#include <Physics/Physics/Dynamics/World/hknpWorldCinfo.h>
#include <Common/Base/Config/hkProductFeatures.cxx>
#include <Common/Base/KeyCode.cxx>
#include <Common/Base/System/Init/PlatformInit.cxx>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <windows.h>

static void HK_CALL report(const char* message, void*) { std::fprintf(stderr, "%s\n", message); }

// The project references logical character names shared by both physics backends.
class PhysicsResourceLoader final : public hkbDefaultResourceLoader
{
	void* loadResource(const char* path) override
	{
		std::string sibling(path);
		if (sibling.size() > 4 && sibling.substr(sibling.size() - 4) == ".hkt")
		{
			sibling.insert(sibling.size() - 4, "_np");
			if (std::ifstream(sibling).good()) return hkbDefaultResourceLoader::loadResource(sibling.c_str());
		}
		return hkbDefaultResourceLoader::loadResource(path);
	}
};

static void printPosition(std::FILE* file, const hkVector4& p)
{
	std::fprintf(file, "[%.8g,%.8g,%.8g]", double(p(0)), double(p(2)), -double(p(1)));
}

static void addBox(hknpWorld& world, const hkVector4& position, const hkVector4& half, float roll)
{
	hkAabb aabb;
	aabb.m_min.setNeg<4>(half);
	aabb.m_max = half;
	hkRefPtr<hknpConvexShape> shape;
	shape.setAndDontIncrementRefCount(hknpConvexShape::createFromAabb(aabb, 0));
	hknpBodyCinfo body;
	body.m_motionType = hknpMotionType::STATIC;
	body.m_shape = shape;
	body.m_position = position;
	body.m_orientation.setAxisAngle(hkVector4(0,-1,0), hkSimdReal::fromFloat(roll));
	world.createBody(body);
}

static bool trace(const char* projectPath, const char* outputPath)
{
	hkFixedBlockStreamAllocator persistentAllocator;
	persistentAllocator.init(1024 * 1024);
	hkFixedBlockStreamAllocator stepAllocator;
	stepAllocator.init(2 * 1024 * 1024);
	hknpWorldCinfo physicsInfo;
	physicsInfo.m_persistentStreamAllocator = &persistentAllocator;
	physicsInfo.m_simulationType = hknpSimulationType::SINGLE_THREADED;
	physicsInfo.m_gravity.set(0, 0, -9.81f);
	hkRefPtr<hkbnpPhysicsInterface> physics;
	physics.setAndDontIncrementRefCount(new hkbnpPhysicsInterface(physicsInfo, nullptr, &stepAllocator));
	addBox(*physics->getWorld(), hkVector4(0,0,-.12f), hkVector4(15,15,.1f), 0);
	addBox(*physics->getWorld(), hkVector4(-.1f,-.92f,.08f), hkVector4(.4f,.275f,.08f), 0);
	addBox(*physics->getWorld(), hkVector4(.15f,-1.47f,.22f), hkVector4(.4f,.275f,.06f), 0);
	addBox(*physics->getWorld(), hkVector4(.8f,-1.05f,.13f), hkVector4(.5f,.9f,.11f), -.174532925f);
	hkbWorldCinfo info;
	info.m_up.set(0, 0, 1);
	info.m_physicsInterface = physics;
	info.m_enableMultithreadedUpdate = false;
	info.m_baseTimestep = 1.0f / 60;
	hkRefPtr<hkbWorld> world;
	world.setAndDontIncrementRefCount(new hkbWorld(info));
	hkRefPtr<PhysicsResourceLoader> resourceLoader;
	resourceLoader.setAndDontIncrementRefCount(new PhysicsResourceLoader());
	hkbDefaultAssetLoader loader(resourceLoader);
	auto& linker = world->getGlobalSymbolLinker();
	hkbProjectAssetManager project(projectPath, loader, linker, physics);
	if (!project.loadProject())
	{
		std::fprintf(stderr, "Hero project could not be loaded.\n");
		return false;
	}
	hkRefPtr<hkbCharacter> hero;
	hero.setAndDontIncrementRefCount(project.createCharacter("Hero.hkt", "3rdPersonActionAdventure.hkt"));
	if (!hero)
	{
		std::fprintf(stderr, "Hero character or behavior could not be loaded.\n");
		return false;
	}
	const auto& variables = linker.getLinker<hkbGlobalSymbolType::VARIABLE>();
	const int stickX = variables.getIdFromName("LeftStickX");
	const int stickY = variables.getIdFromName("LeftStickY");
	const int trigger = variables.getIdFromName("LeftTrigger");
	if (stickX < 0 || stickY < 0 || trigger < 0)
	{
		std::fprintf(stderr, "Required Hero input variables are absent.\n");
		return false;
	}
	const hkaSkeleton& rig = *hero->getSetup()->m_animationSkeleton;
	int feet[] = {-1, -1};
	for (int bone = 0; bone < rig.m_bones.getSize(); ++bone)
	{
		if (std::strcmp(rig.m_bones[bone].m_name, "LeftLegFoot") == 0) feet[0] = bone;
		if (std::strcmp(rig.m_bones[bone].m_name, "RightLegFoot") == 0) feet[1] = bone;
	}
	if (feet[0] < 0 || feet[1] < 0) return false;
	hkArray<hkQsTransform> model;
	model.setSize(rig.m_bones.getSize());
	world->addCharacter(hero);
	std::FILE* file = std::fopen(outputPath, "wb");
	if (!file) return false;
	std::fprintf(file, "{\"hz\":60,\"fixture\":\"hero-step-slope-v1\",\"frames\":[");
	std::string previousLocomotion;
	for (int tick = 0; tick < 255; ++tick)
	{
		const float x = tick >= 150 && tick < 195 ? 1.f : 0.f;
		const float y = tick >= 30 && tick < 90 ? .45f : (tick >= 90 && tick < 150 ? 1.f : 0.f);
		const float walk = tick >= 30 && tick < 90 ? 1.f : 0.f;
		auto& behavior = *hero->getBehavior();
		behavior.setVariableValueWord<hkReal>(stickX, x);
		behavior.setVariableValueWord<hkReal>(stickY, y);
		behavior.setVariableValueWord<hkReal>(trigger, walk);
		world->step(1.0f / 60, static_cast<hkTaskQueue*>(nullptr));
		const char* state = "unknown";
		for (const auto* node : behavior.getActiveNodes())
		{
			const char* name = node->m_nodeClone ? static_cast<const char*>(node->m_nodeClone->m_name) : nullptr;
			if (!name) continue;
			if (std::strcmp(name, "Locomotion State Machine") == 0 && node->m_nodeClone->getType() == HKB_NODE_TYPE_STATE_MACHINE)
			{
				const auto& machine = *static_cast<const hkbStateMachine*>(node->m_nodeClone);
				const int id = machine.getCurrentStateId();
				if (id >= 0)
				{
					const char* active = machine.getStateInfoById(id).m_name.cString();
					if (previousLocomotion != active)
						std::fprintf(stderr, "Locomotion state at tick %d: %s\n", tick, active);
					previousLocomotion = active;
					if (std::strcmp(active, "Idle") == 0) state = "idle";
					if (std::strcmp(active, "Idle to Walk") == 0) state = "idle_to_walk";
					if (std::strcmp(active, "Walking") == 0) state = "walk";
					if (std::strcmp(active, "Running") == 0) state = "run";
				}
			}
		}
		if (std::strcmp(state, "unknown") == 0)
		{
			std::fprintf(stderr, "Unmapped locomotion state at tick %d.\n", tick);
			std::fclose(file);
			world->removeCharacter(hero);
			return false;
		}
		const hkQsTransform& root = hero->getWorldFromModel();
		const hkQsTransform* local = hero->getPoseLocal();
		for (int bone = 0; bone < model.getSize(); ++bone)
		{
			const int parent = rig.m_parentIndices[bone];
			if (parent < 0) model[bone] = local[bone];
			else model[bone].setMul(model[parent], local[bone]);
		}
		std::fprintf(file, "%s{\"stick\":[%.8g,%.8g],\"trigger\":%.8g,\"state\":\"%s\",\"root\":", tick ? "," : "", double(x), double(y), double(walk), state);
		printPosition(file, root.getTranslation());
		std::fprintf(file, ",\"feet\":[");
		for (int leg = 0; leg < 2; ++leg)
		{
			hkQsTransform foot;
			foot.setMul(root, model[feet[leg]]);
			if (leg) std::fputc(',', file);
			printPosition(file, foot.getTranslation());
		}
		std::fprintf(file, "]}");
	}
	std::fprintf(file, "]}\n");
	std::fclose(file);
	world->removeCharacter(hero);
	return true;
}

int main(int argc, char** argv)
{
	if (argc != 3)
	{
		std::fprintf(stderr, "Usage: native_behavior <HeroProject.hkt> <trace.json>\n");
		return 2;
	}
	PlatformInit();
	auto* router = hkMemoryInitUtil::initDefault(hkMallocAllocator::m_defaultMallocAllocator, hkMemorySystem::FrameInfo(2 * 1024 * 1024));
	if (hkBaseSystem::init(router, report) != HK_SUCCESS) return 2;
	const std::string pending = std::string(argv[2]) + ".partial";
	const bool ok = trace(argv[1], pending.c_str());
	if (ok && !MoveFileExA(pending.c_str(), argv[2], MOVEFILE_REPLACE_EXISTING))
	{
		std::fprintf(stderr, "Could not publish the completed trace.\n");
		return 1;
	}
	hkBaseSystem::quit();
	hkMemoryInitUtil::quit();
	return ok ? 0 : 1;
}
