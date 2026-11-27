// Real Havok 2015.1.0-r1 C++ Behavior & Event 1:1 Oracle Runner.
// Executes authentic Havok hkbWorld + hknpWorld + hkbBehaviorGraph scenarios at
// fixed 60 Hz, hooking hkbWorldListener::eventsRaisedCallback() to capture EVERY
// event firing tick, active state machine state, active hkbClipGenerator local time,
// root transform, and landmark bone world positions in Godot Y-up SI meters.

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
#include <Behavior/Behavior/Driver/Docking/hkbDockingDriver.h>
#include <Behavior/Behavior/Driver/Docking/Target/Line/hkbLineDockingTarget.h>
#include <Behavior/Behavior/Event/hkbEventQueue.h>
#include <Behavior/Behavior/Generator/Clip/hkbClipGenerator.h>
#include <Behavior/Behavior/Linker/hkbSymbolLinker.h>
#include <Behavior/Behavior/Node/hkbNodeInfo.h>
#include <Behavior/Behavior/StateMachine/hkbStateMachine.h>
#include <Behavior/Behavior/World/hkbWorld.h>
#include <Behavior/Behavior/World/hkbWorldCinfo.h>
#include <Behavior/Behavior/World/hkbWorldListener.h>
#include <Behavior/PhysicsBridge/hkbnpPhysicsInterface.h>
#include <Behavior/Utilities/Utils/hkbDefaultAssetLoader.h>
#include <Behavior/Utilities/Utils/hkbProjectAssetManager.h>
#include <Physics/Physics/Collide/Shape/Convex/hknpConvexShape.h>
#include <Physics/Physics/Dynamics/Body/hknpBodyCinfo.h>
#include <Physics/Physics/Dynamics/World/hknpWorld.h>
#include <Physics/Physics/Dynamics/World/hknpWorldCinfo.h>
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
#include <string>
#include <vector>
#include <windows.h>

static void HK_CALL reportErr(const char* message, void*) { std::fprintf(stderr, "[hk] %s\n", message); }

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

struct CapturedEvent
{
	int id;
	std::string name;
};

class EventCaptureListener final : public hkbWorldListener
{
public:
	const hkbSymbolLinker* eventLinker = nullptr;
	const hkbCharacter* targetCharacter = nullptr;
	std::vector<CapturedEvent> tickEvents;

	void clearTick() { tickEvents.clear(); }

	void eventsRaisedCallback(hkbCharacter* character, const hkbEventQueue& eventQueue) override
	{
		if (targetCharacter && character != targetCharacter) return;
		const int n = eventQueue.getSize();
		for (int i = 0; i < n; ++i)
		{
			const hkbEvent e = eventQueue.peekAt(i);
			const int id = e.getId();
			const char* nm = (eventLinker && id >= 0) ? eventLinker->getNameFromId(id) : nullptr;
			tickEvents.push_back({id, nm ? std::string(nm) : ("event_" + std::to_string(id))});
		}
	}
};

static std::string jsonEscape(const std::string& s)
{
	std::string out;
	out.reserve(s.size() + 8);
	for (char c : s)
	{
		if (c == '\\') out += "\\\\";
		else if (c == '"') out += "\\\"";
		else if (c == '\n') out += "\\n";
		else if (c == '\r') continue;
		else out.push_back(c);
	}
	return out;
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
	body.m_orientation.setAxisAngle(hkVector4(0, -1, 0), hkSimdReal::fromFloat(roll));
	world.createBody(body);
}

// Convert Havok Z-up (x, y, z)_H -> Godot Y-up (x, z, -y)_G, or keep Maya Y-up when zUp == false.
static void printVec3(std::FILE* f, const hkVector4& p, bool zUp)
{
	if (zUp)
		std::fprintf(f, "[%.7f,%.7f,%.7f]", double(p(0)), double(p(2)), -double(p(1)));
	else
		std::fprintf(f, "[%.7f,%.7f,%.7f]", double(p(0)), double(p(1)), double(p(2)));
}

static void printQuat(std::FILE* f, const hkQuaternion& q, bool zUp)
{
	if (zUp)
		std::fprintf(f, "[%.7f,%.7f,%.7f,%.7f]", double(q(0)), double(q(2)), -double(q(1)), double(q(3)));
	else
		std::fprintf(f, "[%.7f,%.7f,%.7f,%.7f]", double(q(0)), double(q(1)), double(q(2)), double(q(3)));
}

static double extractYawGodot(const hkQuaternion& q, bool zUp)
{
	// Forward basis vector of raw model (+Y in Z-up -> -Z in Godot; +X in Soldier Maya)
	hkVector4 fwdH;
	if (zUp)
		fwdH.setRotatedDir(q, hkVector4(0, -1, 0)); // Hero raw faces -Y in Havok Z-up (+Z in Godot)
	else
		fwdH.setRotatedDir(q, hkVector4(1, 0, 0));
	const double gx = double(fwdH(0));
	const double gz = zUp ? -double(fwdH(1)) : double(fwdH(2));
	return std::atan2(gx, gz);
}

static void dumpFrame(
	std::FILE* file,
	int tick,
	bool firstFrame,
	hkbCharacter& ch,
	const EventCaptureListener& listener,
	const std::vector<std::pair<std::string, int>>& landmarkBones,
	bool zUp,
	const std::string& extraJson = "")
{
	const hkaSkeleton& rig = *ch.getSetup()->m_animationSkeleton;
	const int boneCount = rig.m_bones.getSize();
	hkArray<hkQsTransform> model;
	model.setSize(boneCount);
	const hkQsTransform* local = ch.getPoseLocal();
	for (int b = 0; b < boneCount; ++b)
	{
		const int p = rig.m_parentIndices[b];
		if (p < 0) model[b] = local[b];
		else model[b].setMul(model[p], local[b]);
	}
	const hkQsTransform& root = ch.getWorldFromModel();
	auto& behavior = *ch.getBehavior();

	std::fprintf(file, "%s{\"tick\":%d,\"time\":%.6f,", firstFrame ? "" : ",", tick, double(tick) / 60.0);
	if (!extraJson.empty()) std::fprintf(file, "%s,", extraJson.c_str());

	// Root transform
	std::fprintf(file, "\"root\":");
	printVec3(file, root.getTranslation(), zUp);
	std::fprintf(file, ",\"root_quat\":");
	printQuat(file, root.getRotation(), zUp);
	std::fprintf(file, ",\"yaw\":%.6f", extractYawGodot(root.getRotation(), zUp));

	// Landmark world positions
	std::fprintf(file, ",\"landmarks\":{");
	for (size_t i = 0; i < landmarkBones.size(); ++i)
	{
		const int bi = landmarkBones[i].second;
		hkQsTransform w;
		if (bi >= 0 && bi < boneCount) w.setMul(root, model[bi]);
		else w = root;
		std::fprintf(file, "%s\"%s\":", i ? "," : "", landmarkBones[i].first.c_str());
		printVec3(file, w.getTranslation(), zUp);
	}
	std::fprintf(file, "}");

	// Active State Machines
	std::fprintf(file, ",\"states\":{");
	bool firstSm = true;
	for (const auto* node : behavior.getActiveNodes())
	{
		if (!node->m_nodeClone) continue;
		if (node->m_nodeClone->getType() == HKB_NODE_TYPE_STATE_MACHINE)
		{
			const auto& sm = *static_cast<const hkbStateMachine*>(node->m_nodeClone);
			const int sid = sm.getCurrentStateId();
			const char* smName = sm.m_name.cString() ? sm.m_name.cString() : "SM";
			const char* stName = (sid >= 0) ? sm.getStateInfoById(sid).m_name.cString() : "";
			std::fprintf(file, "%s\"%s\":\"%s\"", firstSm ? "" : ",", jsonEscape(smName).c_str(), jsonEscape(stName ? stName : "").c_str());
			firstSm = false;
		}
	}
	std::fprintf(file, "}");

	// Active Clip Generators
	std::fprintf(file, ",\"clips\":[");
	bool firstClip = true;
	for (const auto* node : behavior.getActiveNodes())
	{
		if (!node->m_nodeClone) continue;
		if (node->m_nodeClone->getType() == HKB_NODE_TYPE_CLIP_GENERATOR)
		{
			const auto& cg = *static_cast<const hkbClipGenerator*>(node->m_nodeClone);
			const char* cname = cg.m_name.cString() ? cg.m_name.cString() : "";
			const char* aname = cg.m_animationName.cString() ? cg.m_animationName.cString() : "";
			const double lt = double(cg.getLocalLocalTime());
			const double dur = double(cg.getDurationLocalTime());
			std::fprintf(file, "%s{\"name\":\"%s\",\"anim\":\"%s\",\"local_time\":%.6f,\"duration\":%.6f,\"mode\":%d,\"speed\":%.4f,\"pp_back\":%s}",
				firstClip ? "" : ",",
				jsonEscape(cname).c_str(),
				jsonEscape(aname).c_str(),
				lt, dur, int(cg.m_mode), double(cg.m_playbackSpeed),
				cg.isPingPongBackwards() ? "true" : "false");
			firstClip = false;
		}
	}
	std::fprintf(file, "]");

	// Captured Events during this tick
	std::fprintf(file, ",\"events\":[");
	for (size_t i = 0; i < listener.tickEvents.size(); ++i)
	{
		std::fprintf(file, "%s{\"id\":%d,\"name\":\"%s\"}",
			i ? "," : "", listener.tickEvents[i].id, jsonEscape(listener.tickEvents[i].name).c_str());
	}
	std::fprintf(file, "]}");
}

static std::vector<std::pair<std::string, int>> resolveLandmarks(const hkaSkeleton& rig, const std::vector<std::string>& names)
{
	std::vector<std::pair<std::string, int>> out;
	for (const auto& nm : names)
	{
		int found = -1;
		for (int b = 0; b < rig.m_bones.getSize(); ++b)
		{
			if (std::strcmp(rig.m_bones[b].m_name, nm.c_str()) == 0) { found = b; break; }
		}
		out.push_back({nm, found});
	}
	return out;
}

static bool runHeroLocomotion(const std::string& sdkRoot, const std::string& outFile, bool withTerrainFixture)
{
	hkFixedBlockStreamAllocator persistentAlloc, stepAlloc;
	persistentAlloc.init(1024 * 1024);
	stepAlloc.init(2 * 1024 * 1024);
	hknpWorldCinfo pinfo;
	pinfo.m_persistentStreamAllocator = &persistentAlloc;
	pinfo.m_simulationType = hknpSimulationType::SINGLE_THREADED;
	pinfo.m_gravity.set(0, 0, -9.81f);
	hkRefPtr<hkbnpPhysicsInterface> physics;
	physics.setAndDontIncrementRefCount(new hkbnpPhysicsInterface(pinfo, nullptr, &stepAlloc));
	if (withTerrainFixture)
	{
		addBox(*physics->getWorld(), hkVector4(0, 0, -.12f), hkVector4(15, 15, .1f), 0);
		addBox(*physics->getWorld(), hkVector4(-.1f, -.92f, .08f), hkVector4(.4f, .275f, .08f), 0);
		addBox(*physics->getWorld(), hkVector4(.15f, -1.47f, .22f), hkVector4(.4f, .275f, .06f), 0);
		addBox(*physics->getWorld(), hkVector4(.8f, -1.05f, .13f), hkVector4(.5f, .9f, .11f), -.174532925f);
	}
	else
	{
		// Clean level ground plane at Z = 0.0 (top surface at Z = 0.0)
		addBox(*physics->getWorld(), hkVector4(0, 0, -1.0f), hkVector4(50, 50, 1.0f), 0);
	}

	hkbWorldCinfo winfo;
	winfo.m_up.set(0, 0, 1);
	winfo.m_physicsInterface = physics;
	winfo.m_enableMultithreadedUpdate = false;
	winfo.m_baseTimestep = 1.0f / 60.0f;
	hkRefPtr<hkbWorld> world;
	world.setAndDontIncrementRefCount(new hkbWorld(winfo));

	hkRefPtr<PhysicsResourceLoader> rl;
	rl.setAndDontIncrementRefCount(new PhysicsResourceLoader());
	hkbDefaultAssetLoader loader(rl);
	auto& linker = world->getGlobalSymbolLinker();
	const std::string projPath = sdkRoot + "/Demo/Demos/Resources/Behavior/GameAssets/Hero/Project/HeroProject.hkt";
	hkbProjectAssetManager project(projPath.c_str(), loader, linker, physics);
	if (!project.loadProject()) { std::fprintf(stderr, "Failed to load HeroProject.hkt\n"); return false; }

	hkRefPtr<hkbCharacter> hero;
	hero.setAndDontIncrementRefCount(project.createCharacter("Hero.hkt", "3rdPersonActionAdventure.hkt"));
	if (!hero) { std::fprintf(stderr, "Failed to create Hero character\n"); return false; }

	const auto& vars = linker.getLinker<hkbGlobalSymbolType::VARIABLE>();
	const int stickX = vars.getIdFromName("LeftStickX");
	const int stickY = vars.getIdFromName("LeftStickY");
	const int trigger = vars.getIdFromName("LeftTrigger");

	EventCaptureListener listener;
	listener.eventLinker = &linker.getLinker<hkbGlobalSymbolType::EVENT>();
	listener.targetCharacter = hero.val();
	world->addListener(&listener);
	world->addCharacter(hero);

	const auto landmarks = resolveLandmarks(*hero->getSetup()->m_animationSkeleton, {
		"Pelvis", "Head", "LeftArmPalm", "RightArmPalm", "LeftLegFoot", "RightLegFoot"
	});

	std::FILE* f = std::fopen(outFile.c_str(), "wb");
	if (!f) return false;
	std::fprintf(f, "{\"scenario\":\"%s\",\"character\":\"hero\",\"bones\":%d,\"hz\":60,\"z_up\":true,\"frames\":[",
		withTerrainFixture ? "hero_locomotion_terrain" : "hero_locomotion_flat",
		hero->getSetup()->m_animationSkeleton->m_bones.getSize());

	for (int tick = 0; tick < 255; ++tick)
	{
		const float x = (tick >= 150 && tick < 195) ? 1.0f : 0.0f;
		const float y = (tick >= 30 && tick < 90) ? 0.45f : ((tick >= 90 && tick < 150) ? 1.0f : 0.0f);
		const float walk = (tick >= 30 && tick < 90) ? 1.0f : 0.0f;
		auto& beh = *hero->getBehavior();
		beh.setVariableValueWord<hkReal>(stickX, x);
		beh.setVariableValueWord<hkReal>(stickY, y);
		beh.setVariableValueWord<hkReal>(trigger, walk);
		listener.clearTick();
		world->step(1.0f / 60.0f, static_cast<hkTaskQueue*>(nullptr));

		char extra[160];
		std::snprintf(extra, sizeof(extra), "\"stick\":[%.4f,%.4f],\"trigger\":%.4f", double(x), double(y), double(walk));
		dumpFrame(f, tick, tick == 0, *hero, listener, landmarks, true, extra);
	}
	std::fprintf(f, "]}\n");
	std::fclose(f);
	world->removeListener(&listener);
	world->removeCharacter(hero);
	std::fprintf(stdout, "[OK] %s (255 ticks)\n", outFile.c_str());
	return true;
}

static bool runHeroDockingBlend(const std::string& sdkRoot, const std::string& outFile)
{
	hkFixedBlockStreamAllocator persistentAlloc, stepAlloc;
	persistentAlloc.init(1024 * 1024);
	stepAlloc.init(2 * 1024 * 1024);
	hknpWorldCinfo pinfo;
	pinfo.m_persistentStreamAllocator = &persistentAlloc;
	pinfo.m_simulationType = hknpSimulationType::SINGLE_THREADED;
	pinfo.m_gravity.set(0, 0, -9.81f);
	hkRefPtr<hkbnpPhysicsInterface> physics;
	physics.setAndDontIncrementRefCount(new hkbnpPhysicsInterface(pinfo, nullptr, &stepAlloc));
	addBox(*physics->getWorld(), hkVector4(0, 0, -1.0f), hkVector4(50, 50, 1.0f), 0);

	hkbWorldCinfo winfo;
	winfo.m_up.set(0, 0, 1);
	winfo.m_physicsInterface = physics;
	winfo.m_enableMultithreadedUpdate = false;
	winfo.m_baseTimestep = 1.0f / 60.0f;
	hkRefPtr<hkbWorld> world;
	world.setAndDontIncrementRefCount(new hkbWorld(winfo));

	hkRefPtr<PhysicsResourceLoader> rl;
	rl.setAndDontIncrementRefCount(new PhysicsResourceLoader());
	hkbDefaultAssetLoader loader(rl);
	auto& linker = world->getGlobalSymbolLinker();
	const std::string projPath = sdkRoot + "/Demo/Demos/Resources/Behavior/GameAssets/Hero/Project/HeroProject.hkt";
	hkbProjectAssetManager project(projPath.c_str(), loader, linker, physics);
	if (!project.loadProject()) return false;

	hkRefPtr<hkbCharacter> hero;
	hero.setAndDontIncrementRefCount(project.createCharacter("Hero.hkt", "3rdPersonActionAdventure.hkt"));
	if (!hero) return false;
	hero->setDesiredCapabilities(hkbCharacter::BASIC_CAPABILITIES);

	const auto& vars = linker.getLinker<hkbGlobalSymbolType::VARIABLE>();
	const auto& evts = linker.getLinker<hkbGlobalSymbolType::EVENT>();
	const int dockHeightVar = vars.getIdFromName("DockingHeightSelector");
	const int intoCoverEvt = evts.getIdFromName("IntoCover");

	EventCaptureListener listener;
	listener.eventLinker = &evts;
	listener.targetCharacter = hero.val();
	world->addListener(&listener);
	world->addCharacter(hero);

	hero->accessWorldFromModel().m_translation.set(-2.0f, 0.0f, 0.0f);
	hero->accessWorldFromModel().m_rotation.setIdentity();
	if (dockHeightVar >= 0) hero->getBehavior()->setVariableValueWord<hkInt32>(dockHeightVar, 1);

	const auto landmarks = resolveLandmarks(*hero->getSetup()->m_animationSkeleton, {
		"Pelvis", "Head", "LeftArmPalm", "RightArmPalm", "LeftLegFoot", "RightLegFoot"
	});

	std::FILE* f = std::fopen(outFile.c_str(), "wb");
	if (!f) return false;
	std::fprintf(f, "{\"scenario\":\"hero_docking_blend\",\"character\":\"hero\",\"bones\":%d,\"hz\":60,\"z_up\":true,\"frames\":[",
		hero->getSetup()->m_animationSkeleton->m_bones.getSize());

	for (int tick = 0; tick < 120; ++tick)
	{
		if (tick == 10)
		{
			// Exact DockingBlendDemo.cpp tick 10 offset away from line
			hero->accessWorldFromModel().m_translation.addMul4(0.01f, hkVector4(0, 1, 0));
		}
		else if (tick == 30 && intoCoverEvt >= 0)
		{
			hkbLineDockingTarget* target = new hkbLineDockingTarget();
			target->m_constrainRotation = true;
			target->m_endPointA.m_translation.set(5, -2, 0);
			target->m_endPointA.m_rotation.set(0, 0, 1, 0);
			target->m_endPointB.m_translation.set(-5, -2, 0);
			target->m_endPointB.m_rotation.set(0, 0, 1, 0);
			hero->getDockingDriver()->m_dockingTarget = target;
			target->removeReference();
			hero->getEventQueue()->enqueueWithExternalId(hkbEvent(intoCoverEvt));
		}
		listener.clearTick();
		world->step(1.0f / 60.0f, static_cast<hkTaskQueue*>(nullptr));

		double blendParam = 0.0;
		if (hero->getDockingDriver()) blendParam = double(hero->getDockingDriver()->getLastBlendParam());
		char extra[128];
		std::snprintf(extra, sizeof(extra), "\"dock_blend\":%.6f", blendParam);
		dumpFrame(f, tick, tick == 0, *hero, listener, landmarks, true, extra);
	}
	std::fprintf(f, "]}\n");
	std::fclose(f);
	world->removeListener(&listener);
	world->removeCharacter(hero);
	std::fprintf(stdout, "[OK] %s (120 ticks)\n", outFile.c_str());
	return true;
}

struct ScheduledEvent { int tick; std::string name; };

static bool runSoldierBehavior(
	const std::string& sdkRoot,
	const std::string& scenarioName,
	const std::string& behaviorFile,
	int totalTicks,
	const std::vector<ScheduledEvent>& schedule,
	const std::string& outFile)
{
	hkFixedBlockStreamAllocator persistentAlloc, stepAlloc;
	persistentAlloc.init(1024 * 1024);
	stepAlloc.init(2 * 1024 * 1024);
	hknpWorldCinfo pinfo;
	pinfo.m_persistentStreamAllocator = &persistentAlloc;
	pinfo.m_simulationType = hknpSimulationType::SINGLE_THREADED;
	pinfo.m_gravity.set(0, -9.81f, 0);
	hkRefPtr<hkbnpPhysicsInterface> physics;
	physics.setAndDontIncrementRefCount(new hkbnpPhysicsInterface(pinfo, nullptr, &stepAlloc));
	addBox(*physics->getWorld(), hkVector4(0, -1.0f, 0), hkVector4(50, 1.0f, 50), 0);

	hkbWorldCinfo winfo;
	winfo.m_up.set(0, 0, 1); // Match Soldier SDK demos (g_worldUp = (0,0,1))
	winfo.m_physicsInterface = physics;
	winfo.m_enableMultithreadedUpdate = false;
	winfo.m_baseTimestep = 1.0f / 60.0f;
	hkRefPtr<hkbWorld> world;
	world.setAndDontIncrementRefCount(new hkbWorld(winfo));
	world->m_accumulateMotionState = hkbWorldEnums::DO_NOT_ACCUMULATE_MOTION;

	hkRefPtr<PhysicsResourceLoader> rl;
	rl.setAndDontIncrementRefCount(new PhysicsResourceLoader());
	hkbDefaultAssetLoader loader(rl);
	auto& linker = world->getGlobalSymbolLinker();
	const std::string projPath = sdkRoot + "/Demo/Demos/Resources/Behavior/GameAssets/Soldier/US_Soldier_Project.hkt";
	hkbProjectAssetManager project(projPath.c_str(), loader, linker, physics);
	if (!project.loadProject()) { std::fprintf(stderr, "Failed to load US_Soldier_Project.hkt\n"); return false; }

	hkRefPtr<hkbCharacter> soldier;
	soldier.setAndDontIncrementRefCount(project.createCharacter("FireTeamLeader_Character.hkt", behaviorFile.c_str()));
	if (!soldier) { std::fprintf(stderr, "Failed to create Soldier with %s\n", behaviorFile.c_str()); return false; }

	const auto& evts = linker.getLinker<hkbGlobalSymbolType::EVENT>();
	EventCaptureListener listener;
	listener.eventLinker = &evts;
	listener.targetCharacter = soldier.val();
	world->addListener(&listener);
	world->addCharacter(soldier);

	const auto landmarks = resolveLandmarks(*soldier->getSetup()->m_animationSkeleton, {
		"Root_M", "Head_M", "Wrist_L", "Wrist_R", "Ankle_L", "Ankle_R"
	});

	std::FILE* f = std::fopen(outFile.c_str(), "wb");
	if (!f) return false;
	// Soldier rig in US_Soldier_Project is Y-up (Head_M.y ~= 1.65 m)!
	std::fprintf(f, "{\"scenario\":\"%s\",\"behavior\":\"%s\",\"character\":\"soldier\",\"bones\":%d,\"hz\":60,\"z_up\":false,\"frames\":[",
		scenarioName.c_str(), behaviorFile.c_str(),
		soldier->getSetup()->m_animationSkeleton->m_bones.getSize());

	for (int tick = 0; tick < totalTicks; ++tick)
	{
		std::string injected = "";
		for (const auto& se : schedule)
		{
			if (se.tick == tick)
			{
				const int eid = evts.getIdFromName(se.name.c_str());
				if (eid >= 0)
				{
					soldier->getEventQueue()->enqueueWithExternalId(hkbEvent(eid));
					injected = se.name;
				}
				else
				{
					std::fprintf(stderr, "[WARN] %s missing event %s\n", scenarioName.c_str(), se.name.c_str());
				}
			}
		}
		listener.clearTick();
		world->step(1.0f / 60.0f, static_cast<hkTaskQueue*>(nullptr));

		std::string extra = injected.empty() ? "" : ("\"injected\":\"" + jsonEscape(injected) + "\"");
		dumpFrame(f, tick, tick == 0, *soldier, listener, landmarks, false, extra);
	}
	std::fprintf(f, "]}\n");
	std::fclose(f);
	world->removeListener(&listener);
	world->removeCharacter(soldier);
	std::fprintf(stdout, "[OK] %s (%d ticks)\n", outFile.c_str(), totalTicks);
	return true;
}

static bool runQuadrupedSiegeFiend(const std::string& sdkRoot, const std::string& outFile)
{
	hkFixedBlockStreamAllocator persistentAlloc, stepAlloc;
	persistentAlloc.init(1024 * 1024);
	stepAlloc.init(2 * 1024 * 1024);
	hknpWorldCinfo pinfo;
	pinfo.m_persistentStreamAllocator = &persistentAlloc;
	pinfo.m_simulationType = hknpSimulationType::SINGLE_THREADED;
	pinfo.m_gravity.set(0, 0, -9.81f);
	hkRefPtr<hkbnpPhysicsInterface> physics;
	physics.setAndDontIncrementRefCount(new hkbnpPhysicsInterface(pinfo, nullptr, &stepAlloc));
	addBox(*physics->getWorld(), hkVector4(0, 0, -1.0f), hkVector4(50, 50, 1.0f), 0);

	hkbWorldCinfo winfo;
	winfo.m_up.set(0, 0, 1);
	winfo.m_physicsInterface = physics;
	winfo.m_enableMultithreadedUpdate = false;
	winfo.m_baseTimestep = 1.0f / 60.0f;
	hkRefPtr<hkbWorld> world;
	world.setAndDontIncrementRefCount(new hkbWorld(winfo));

	hkRefPtr<PhysicsResourceLoader> rl;
	rl.setAndDontIncrementRefCount(new PhysicsResourceLoader());
	hkbDefaultAssetLoader loader(rl);
	auto& linker = world->getGlobalSymbolLinker();
	const std::string projPath = sdkRoot + "/Demo/Demos/Resources/Behavior/GameAssets/SiegeFiend/SiegeFiend.hkt";
	hkbProjectAssetManager project(projPath.c_str(), loader, linker, physics);
	if (!project.loadProject()) { std::fprintf(stderr, "Failed to load SiegeFiend.hkt\n"); return false; }

	hkRefPtr<hkbCharacter> quad;
	quad.setAndDontIncrementRefCount(project.createCharacter("SiegeFiend.hkt", "QuadrupedLessWorldGain.hkt"));
	if (!quad) { std::fprintf(stderr, "Failed to create SiegeFiend\n"); return false; }

	const auto& evts = linker.getLinker<hkbGlobalSymbolType::EVENT>();
	EventCaptureListener listener;
	listener.eventLinker = &evts;
	listener.targetCharacter = quad.val();
	world->addListener(&listener);
	world->addCharacter(quad);

	const auto landmarks = resolveLandmarks(*quad->getSetup()->m_animationSkeleton, {
		"Bip01 Pelvis", "Bip01 Head", "Bip01 L Hand", "Bip01 R Hand", "Bip01 L Foot", "Bip01 R Foot"
	});

	const std::vector<ScheduledEvent> schedule = {
		{15, "RotateCounterClockwise"},
		{50, "StopRotation"},
		{110, "MoveForward"},
		{200, "StopMovingForward"},
	};

	std::FILE* f = std::fopen(outFile.c_str(), "wb");
	if (!f) return false;
	std::fprintf(f, "{\"scenario\":\"quadruped_siegefiend\",\"behavior\":\"QuadrupedLessWorldGain.hkt\",\"character\":\"siege_fiend\",\"bones\":%d,\"hz\":60,\"z_up\":true,\"frames\":[",
		quad->getSetup()->m_animationSkeleton->m_bones.getSize());

	for (int tick = 0; tick < 250; ++tick)
	{
		std::string injected = "";
		for (const auto& se : schedule)
		{
			if (se.tick == tick)
			{
				const int eid = evts.getIdFromName(se.name.c_str());
				if (eid >= 0) { quad->getEventQueue()->enqueueWithExternalId(hkbEvent(eid)); injected = se.name; }
			}
		}
		listener.clearTick();
		world->step(1.0f / 60.0f, static_cast<hkTaskQueue*>(nullptr));
		std::string extra = injected.empty() ? "" : ("\"injected\":\"" + jsonEscape(injected) + "\"");
		dumpFrame(f, tick, tick == 0, *quad, listener, landmarks, true, extra);
	}
	std::fprintf(f, "]}\n");
	std::fclose(f);
	world->removeListener(&listener);
	world->removeCharacter(quad);
	std::fprintf(stdout, "[OK] %s (250 ticks)\n", outFile.c_str());
	return true;
}

int main(int argc, char** argv)
{
	if (argc < 3)
	{
		std::fprintf(stderr, "Usage: havok_behavior_oracle <sdk_root> <output_dir>\n");
		return 2;
	}
	const std::string sdkRoot = argv[1];
	const std::string outDir = argv[2];
	CreateDirectoryA(outDir.c_str(), nullptr);

	PlatformInit();
	auto* router = hkMemoryInitUtil::initDefault(hkMallocAllocator::m_defaultMallocAllocator, hkMemorySystem::FrameInfo(4 * 1024 * 1024));
	if (hkBaseSystem::init(router, reportErr) != HK_SUCCESS) return 2;

	bool ok = true;
	ok = runHeroLocomotion(sdkRoot, outDir + "/hero_locomotion_flat.json", false) && ok;
	ok = runHeroLocomotion(sdkRoot, outDir + "/hero_locomotion_terrain.json", true) && ok;
	ok = runHeroDockingBlend(sdkRoot, outDir + "/hero_docking_blend.json") && ok;
	ok = runSoldierBehavior(sdkRoot, "soldier_clip_modes", "ClipGeneratorModes.hkt", 480, {
		{5, "ToSinglePlay"},
		{125, "ToSinglePlayContinueMotionAtEnd"},
		{245, "ToLooping"},
		{365, "ToPingPong"},
		{445, "ToIdle"},
	}, outDir + "/soldier_clip_modes.json") && ok;
	ok = runSoldierBehavior(sdkRoot, "soldier_return_to_prev", "ReturnToPreviousState.hkt", 340, {
		{5, "ToWalk"},
		{65, "ToPreviousState"},
		{125, "ToRun"},
		{225, "ToIdle"},
		{285, "ToPreviousState"},
	}, outDir + "/soldier_return_to_prev.json") && ok;
	ok = runSoldierBehavior(sdkRoot, "soldier_pingpong_sync", "PingPongSync.hkt", 360, {
		{5, "ToPingPongFullCycle"},
		{205, "ToPingPongHalfCycle"},
		{320, "ToIdle"},
	}, outDir + "/soldier_pingpong_sync.json") && ok;
	ok = runQuadrupedSiegeFiend(sdkRoot, outDir + "/quadruped_siegefiend.json") && ok;

	hkBaseSystem::quit();
	hkMemoryInitUtil::quit();
	return ok ? 0 : 1;
}
