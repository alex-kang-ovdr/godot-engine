// Real Havok 2015.1.0-r1 Official Behavior Demo Runner & Deterministic 60 FPS Capture Harness.
// Links unmodified official Havok DemoCommon framework + all 43 Hero & Soldier Behavior demos
// with the real Havok DX11/OpenGL renderer, runs each demo deterministically at exact 60.000 Hz
// (single-threaded, fixed timestep = 1/60s, official makeFakeInput() bootstrap sequences),
// captures REAL GPU framebuffer screenshots via hkgWindow::saveCurrentRenderTargetToBmp,
// and records full per-tick events, state machines, active clips, root/landmark positions,
// camera parameters, and 64-bit FNV-1a full-skeleton pose hashes for 1:1 comparison with Godot.

#include <Demos/demos.h>
#include <Common/Base/Memory/Allocator/Malloc/hkMallocAllocator.h>
#include <Common/Base/System/Io/FileSystem/hkFileSystem.h>
#include <Common/Base/System/Io/Writer/Array/hkArrayStreamWriter.h>
#include <Common/Base/System/Io/Reader/Memory/hkMemoryStreamReader.h>
#include <Demos/DemoCommon/DemoFramework/hkDefaultBehaviorWorldDemo.h>
#include <Demos/DemoCommon/DemoFramework/hkDemoFramework.h>
#include <Demos/DemoCommon/DemoFramework/hkDemoDatabase.h>
#include <Demos/DemoCommon/DemoFramework/hkDemoFrameworkOptions.h>

#include <Graphics/Common/Window/hkgWindow.h>
#include <Graphics/Common/Window/hkgViewport.h>
#include <Graphics/Common/Camera/hkgCamera.h>
#include <Graphics/Common/DisplayWorld/hkgDisplayWorld.h>
#include <Graphics/Common/DisplayObject/hkgDisplayObject.h>
#include <Graphics/Common/Shader/hkgShaderEffectCollection.h>
#include <Graphics/Common/Shader/hkgShaderEffect.h>
#include <Graphics/Common/Shader/hkgShader.h>
#include <Graphics/Common/Input/Pad/hkgPad.h>
#include <Graphics/Common/hkgSystem.h>

#include <Animation/Animation/Rig/hkaSkeleton.h>
#include <Behavior/Behavior/BehaviorGraph/hkbBehaviorGraph.h>
#include <Behavior/Behavior/BehaviorGraph/hkbBehaviorGraphData.h>
#include <Behavior/Behavior/BehaviorGraph/hkbBehaviorGraphStringData.h>
#include <Behavior/Behavior/Character/hkbCharacter.h>
#include <Behavior/Behavior/Character/hkbCharacterSetup.h>
#include <Behavior/Behavior/Character/hkbCharacterData.h>
#include <Behavior/Behavior/Character/hkbCharacterStringData.h>
#include <Behavior/Behavior/Event/hkbEventQueue.h>
#include <Behavior/Behavior/Generator/Clip/hkbClipGenerator.h>
#include <Behavior/Behavior/Linker/hkbSymbolLinker.h>
#include <Behavior/Behavior/Node/hkbNodeInfo.h>
#include <Behavior/Behavior/StateMachine/hkbStateMachine.h>
#include <Behavior/Behavior/World/hkbWorld.h>
#include <Behavior/Behavior/World/hkbWorldListener.h>

#include <Common/Base/keycode.cxx>
#include <Demos/_Auto/Types/hkDefaultDemo_Types.cxx>
#include <Demos/_Auto/Types/PathContainer_Types.cxx>
#include <Demos/_Auto/Types/DemoReplay_Types.cxx>
#include <Demos/_Auto/Types/MenuDemo_Types.cxx>
#include <Demos/_Auto/Types/Tweak_Types.cxx>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <algorithm>
#include <set>
#include <string>
#include <vector>

extern void HK_CALL DemoPlatformInit(hkDemoFrameworkOptions* options);

// VS2015 vs VS2022 __restrict symbol mangling shim for hkTransformf::get4x4ColumnMajor + MenuDemo hooks
void hkTransformf::get4x4ColumnMajor(hkFloat32* HK_RESTRICT d) const
{
	const hkFloat32* HK_RESTRICT p = &m_rotation(0, 0);
	for (int i = 0; i < 4; ++i)
	{
		d[0] = p[0]; d[1] = p[1]; d[2] = p[2]; d[3] = 0.0f;
		d += 4; p += 4;
	}
	d[-1] = 1.0f;
}
void hkSetLastDemoBootstrap(const char*) {}

// Havok 2015.1.0-r1's prebuilt hkgDx11.lib was compiled against DirectX June 2010 SDK (D3DX11_SDK_VERSION=43)
// and dynamically loads D3Dcompiler_43.dll, which requires the DX June 2010 IID_ID3D11ShaderReflection GUID
// ({0A233719-3960-4578-9D7C-203B8B1D9CC1}) rather than the Windows 10 SDK dxguid.lib GUID ({8D536CA1-...}).
extern "C" const GUID IID_ID3D11ShaderReflection = {
	0x0a233719, 0x3960, 0x4578, { 0x9d, 0x7c, 0x20, 0x3b, 0x8b, 0x1d, 0x9c, 0xc1 }
};

namespace
{
	// Intercepts temporary "internalState.hkt" used by SaveBehaviorStateDemo so writes are immediately
	// visible to hkSerializeUtil::loadObject before ~hkOstream() runs, without touching the Havok SDK dir.
	class InMemoryStateFileSystem final : public hkFileSystem
	{
	public:
		HK_DECLARE_CLASS_ALLOCATOR(HK_MEMORY_CLASS_BASE);
		explicit InMemoryStateFileSystem(hkFileSystem* base) : m_base(base) {}

		static bool isTempStateFile(const char* name)
		{
			return name && (std::strcmp(name, "internalState.hkt") == 0 || std::strcmp(name, "./internalState.hkt") == 0);
		}

		hkRefNew<hkStreamReader> openReader(const char* name, OpenFlags flags = OPEN_DEFAULT_READ) override
		{
			if (isTempStateFile(name))
				return new hkMemoryStreamReader(m_memBuf.begin(), m_memBuf.getSize(), hkMemoryStreamReader::MEMORY_COPY);
			return m_base->openReader(name, flags);
		}

		hkRefNew<hkStreamWriter> openWriter(const char* name, OpenFlags flags = OPEN_DEFAULT_WRITE) override
		{
			if (isTempStateFile(name))
			{
				m_memBuf.clear();
				return new hkArrayStreamWriter(&m_memBuf, hkArrayStreamWriter::ARRAY_BORROW);
			}
			return m_base->openWriter(name, flags);
		}

		Result remove(const char* path) override { return isTempStateFile(path) ? RESULT_OK : m_base->remove(path); }
		Result mkdir(const char* path) override { return m_base->mkdir(path); }

		Result stat(const char* path, Entry& entryOut) override
		{
			if (isTempStateFile(path))
			{
				entryOut.setAll(this, path, Entry::F_ISFILE, TimeStamp(), m_memBuf.getSize());
				return RESULT_OK;
			}
			return m_base->stat(path, entryOut);
		}

		const char* getOperatingSystemPath(const char* pathIn, hkStringBuf& pathOut, OSPathFlags flags = OS_PATH_NONE) override
		{
			return m_base->getOperatingSystemPath(pathIn, pathOut, flags);
		}

		hkRefNew<Iterator::Impl> createIterator(const char* top, const char* wildcard) override
		{
			return m_base->createIterator(top, wildcard);
		}

	private:
		hkRefPtr<hkFileSystem> m_base;
		hkArray<char> m_memBuf;
	};

	// Non-intrusive accessor into hkDefaultBehaviorWorldDemo's protected members.
	class BehaviorDemoAccessor : public hkDefaultBehaviorWorldDemo
	{
	public:
		hkbWorld* getWorld() const { return m_behaviorWorld; }
		const hkVector4& getWorldUp() const { return m_worldUp; }
		int getDemoType() const { return int(m_demoType); }
		int getDebugProcessCount() const { return m_debugProcesses.getSize(); }
		void setFixedTimestep(hkReal dt) { m_timestep = dt; }
	};

	static uint64_t fnv1aUpdate(uint64_t h, const void* data, size_t len)
	{
		const uint8_t* p = static_cast<const uint8_t*>(data);
		for (size_t i = 0; i < len; ++i)
		{
			h ^= uint64_t(p[i]);
			h *= 1099511628211ULL;
		}
		return h;
	}

	static uint64_t fnv1aInt32(uint64_t h, int32_t v)
	{
		return fnv1aUpdate(h, &v, sizeof(v));
	}

	static uint64_t fnv1aQuantFloat(uint64_t h, float v, float scale = 10000.0f)
	{
		if (!std::isfinite(v)) v = 0.0f;
		const int32_t q = static_cast<int32_t>(std::llround(double(v) * double(scale)));
		return fnv1aInt32(h, q);
	}

	static std::string jsonEscape(const std::string& s)
	{
		std::string out;
		out.reserve(s.size() + 8);
		for (unsigned char c : s)
		{
			if (c == '\\') out += "\\\\";
			else if (c == '"') out += "\\\"";
			else if (c == '\n') out += "\\n";
			else if (c == '\r') continue;
			else if (c < 0x20) { char buf[8]; std::snprintf(buf, sizeof(buf), "\\u%04x", c); out += buf; }
			else out.push_back(static_cast<char>(c));
		}
		return out;
	}

	static std::string makeSlug(const std::string& s)
	{
		std::string out;
		out.reserve(s.size());
		bool prevUnderscore = false;
		for (unsigned char c : s)
		{
			if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
			{
				out.push_back(static_cast<char>(c));
				prevUnderscore = false;
			}
			else if (!prevUnderscore && !out.empty())
			{
				out.push_back('_');
				prevUnderscore = true;
			}
		}
		while (!out.empty() && out.back() == '_') out.pop_back();
		return out;
	}

	static void printVec3Godot(std::FILE* f, const hkVector4& p, bool zUp)
	{
		const double x = std::isfinite(double(p(0))) ? double(p(0)) : 0.0;
		const double y = std::isfinite(double(p(1))) ? double(p(1)) : 0.0;
		const double z = std::isfinite(double(p(2))) ? double(p(2)) : 0.0;
		if (zUp)
			std::fprintf(f, "[%.6f,%.6f,%.6f]", x, z, -y);
		else
			std::fprintf(f, "[%.6f,%.6f,%.6f]", x, y, z);
	}

	static void printVec3Raw(std::FILE* f, const hkVector4& p)
	{
		const double x = std::isfinite(double(p(0))) ? double(p(0)) : 0.0;
		const double y = std::isfinite(double(p(1))) ? double(p(1)) : 0.0;
		const double z = std::isfinite(double(p(2))) ? double(p(2)) : 0.0;
		std::fprintf(f, "[%.6f,%.6f,%.6f]", x, y, z);
	}

	static void printQuatRaw(std::FILE* f, const hkQuaternion& q)
	{
		std::fprintf(f, "[%.6f,%.6f,%.6f,%.6f]", double(q(0)), double(q(1)), double(q(2)), double(q(3)));
	}

	static double extractYawGodot(const hkQuaternion& q, bool zUp)
	{
		hkVector4 fwdH;
		if (zUp)
			fwdH.setRotatedDir(q, hkVector4(0.0f, -1.0f, 0.0f));
		else
			fwdH.setRotatedDir(q, hkVector4(1.0f, 0.0f, 0.0f));
		const double gx = double(fwdH(0));
		const double gz = zUp ? -double(fwdH(1)) : double(fwdH(2));
		return std::atan2(gx, gz);
	}

	struct CapturedEvent
	{
		int charIdx;
		int id;
		std::string name;
	};

	class RealDemoEventListener final : public hkbWorldListener
	{
	public:
		hkbWorld* world = nullptr;
		const hkbSymbolLinker* globalEventLinker = nullptr;
		std::vector<CapturedEvent> tickEvents;

		void clearTick() { tickEvents.clear(); }

		int findCharIdx(const hkbCharacter* ch) const
		{
			if (!world || !ch) return -1;
			const hkArray<hkbCharacter*>& chars = world->getCharacters();
			for (int i = 0; i < chars.getSize(); ++i)
			{
				if (chars[i] == ch) return i;
			}
			return -1;
		}

		std::string resolveEventName(const hkbCharacter* ch, int id) const
		{
			if (id < 0) return "event_" + std::to_string(id);
			if (globalEventLinker)
			{
				const char* nm = globalEventLinker->getNameFromId(id);
				if (nm && nm[0]) return nm;
			}
			if (ch && ch->getBehavior() && ch->getBehavior()->getData() && ch->getBehavior()->getData()->getStringData())
			{
				const auto& names = ch->getBehavior()->getData()->getStringData()->m_eventNames;
				if (id < names.getSize() && names[id] && names[id][0])
					return names[id].cString();
			}
			return "event_" + std::to_string(id);
		}

		void eventsRaisedCallback(hkbCharacter* character, const hkbEventQueue& eventQueue) override
		{
			const int cidx = findCharIdx(character);
			const int n = eventQueue.getSize();
			for (int i = 0; i < n; ++i)
			{
				const hkbEvent e = eventQueue.peekAt(i);
				const int id = e.getId();
				tickEvents.push_back({cidx, id, resolveEventName(character, id)});
			}
		}
	};

	static std::vector<int> findLandmarkBones(const hkaSkeleton* skel)
	{
		static const char* kHeroLandmarks[] = {
			"Pelvis", "Head", "LeftArmPalm", "RightArmPalm", "LeftLegFoot", "RightLegFoot"
		};
		static const char* kSoldierLandmarks[] = {
			"Root_M", "Head_M", "Wrist_L", "Wrist_R", "Ankle_L", "Ankle_R"
		};
		std::vector<int> out;
		if (!skel) return out;
		auto tryList = [&](const char** list, int count) -> bool {
			std::vector<int> found;
			for (int i = 0; i < count; ++i)
			{
				int idx = -1;
				for (int b = 0; b < skel->m_bones.getSize(); ++b)
				{
					if (skel->m_bones[b].m_name && std::strcmp(skel->m_bones[b].m_name, list[i]) == 0)
					{
						idx = b;
						break;
					}
				}
				if (idx >= 0) found.push_back(idx);
			}
			if (found.size() >= 4)
			{
				out = found;
				return true;
			}
			return false;
		};
		if (tryList(kHeroLandmarks, 6)) return out;
		if (tryList(kSoldierLandmarks, 6)) return out;
		// Generic fallback: pick up to 6 evenly spaced bones
		const int nb = skel->m_bones.getSize();
		for (int i = 0; i < nb && out.size() < 6; i += std::max(1, nb / 6))
			out.push_back(i);
		return out;
	}

	struct RunSummary
	{
		bool ok = false;
		int ticks = 0;
		int totalEvents = 0;
		int numCharacters = 0;
		uint64_t finalPoseHash = 0;
		uint64_t trajectoryHash = 0;
		uint64_t eventHash = 0;
		std::vector<std::string> screenshots;
	};

	static void ensureDir(const std::string& dir)
	{
		std::string cur;
		for (size_t i = 0; i < dir.size(); ++i)
		{
			char c = dir[i];
			cur.push_back(c);
			if (c == '\\' || c == '/')
			{
				if (cur.size() > 3) CreateDirectoryA(cur.c_str(), nullptr);
			}
		}
		if (!cur.empty()) CreateDirectoryA(cur.c_str(), nullptr);
	}

	static RunSummary captureSingleDemo(
		hkDemoEnvironment& env,
		hkDemoFrameworkOptions& options,
		int demoIdx,
		const hkDemoEntry& entry,
		const std::string& outDir,
		int overrideTicks,
		bool useFakeInput,
		bool saveShots,
		bool writeJson)
	{
		RunSummary sum;
		const std::string menuPath = entry.m_menuPath.cString() ? entry.m_menuPath.cString() : ("demo_" + std::to_string(demoIdx));
		const std::string demoPath = entry.m_demoPath.cString() ? entry.m_demoPath.cString() : "";
		const std::string slug = makeSlug(menuPath);
		const std::string shotsDir = outDir + "\\shots";
		ensureDir(outDir);
		if (saveShots) ensureDir(shotsDir);

		env.m_isBootstrapping = useFakeInput;
		env.m_demoTypeFlags = entry.m_demoTypeFlags;
		if (env.m_input)
		{
			hkgPad& rawPad = const_cast<hkgPad&>(env.m_input->getGamePad(0));
			rawPad.setButtonState(0);
		}
		if (env.m_gamePad)
		{
			env.m_gamePad->setButtonState(0);
		}
		env.m_window->getContext()->lock();
		hkDemo* rawDemo = hkDemoDatabase::getInstance().createDemo(demoIdx, &env);
		if (rawDemo)
		{
			rawDemo->postConstruct();
			rawDemo->createScene();
		}
		env.m_window->getContext()->unlock();
		if (!rawDemo)
		{
			std::fprintf(stderr, "[capture] FAILED to instantiate demo %d: %s\n", demoIdx, menuPath.c_str());
			return sum;
		}

		// Force exact deterministic 60 Hz timestep on the demo instance
		BehaviorDemoAccessor* bdemo = static_cast<BehaviorDemoAccessor*>(rawDemo);
		bdemo->setFixedTimestep(1.0f / 60.0f);

		hkbWorld* world = bdemo->getWorld();
		const hkVector4 worldUp = bdemo->getWorldUp();
		const bool zUp = std::fabs(double(worldUp(2))) > 0.5;

		int numTicks = overrideTicks > 0 ? overrideTicks : rawDemo->m_bootstrapIterations;
		if (overrideTicks <= 0)
		{
			if (numTicks < 180) numTicks = 180;
			if (numTicks > 1080) numTicks = 1080;
		}
		sum.ticks = numTicks;

		// Attach hkbWorldListener to capture EVERY event raised inside hkbWorld
		RealDemoEventListener listener;
		listener.world = world;
		if (world)
		{
			listener.globalEventLinker = &world->getGlobalSymbolLinker().getLinker<hkbGlobalSymbolType::EVENT>();
			world->addListener(&listener);
		}

		// Choose deterministic screenshot ticks: initial settled + 1/3 + 2/3 + near end
		std::set<int> shotTicks;
		if (saveShots)
		{
			shotTicks.insert(std::min(15, numTicks - 1));
			shotTicks.insert(numTicks / 3);
			shotTicks.insert((numTicks * 2) / 3);
			shotTicks.insert(std::max(0, numTicks - 2));
		}
		bool capturedFirstEventShot = false;

		std::FILE* jf = nullptr;
		const std::string jsonPath = outDir + "\\" + slug + ".json";
		if (writeJson)
		{
			jf = std::fopen(jsonPath.c_str(), "wb");
			if (!jf)
			{
				std::fprintf(stderr, "[capture] Cannot open %s for writing\n", jsonPath.c_str());
			}
		}

		if (jf)
		{
			std::fprintf(jf, "{\n");
			std::fprintf(jf, "  \"schema\": \"havok-real-demo-60fps-v1\",\n");
			std::fprintf(jf, "  \"demo_index\": %d,\n", demoIdx);
			std::fprintf(jf, "  \"slug\": \"%s\",\n", jsonEscape(slug).c_str());
			std::fprintf(jf, "  \"menu_path\": \"%s\",\n", jsonEscape(menuPath).c_str());
			std::fprintf(jf, "  \"demo_path\": \"%s\",\n", jsonEscape(demoPath).c_str());
			std::fprintf(jf, "  \"variant_id\": %d,\n", entry.m_variantId);
			std::fprintf(jf, "  \"hz\": 60,\n");
			std::fprintf(jf, "  \"dt\": %.9f,\n", 1.0 / 60.0);
			std::fprintf(jf, "  \"ticks\": %d,\n", numTicks);
			std::fprintf(jf, "  \"bootstrap_iterations_default\": %d,\n", rawDemo->m_bootstrapIterations);
			std::fprintf(jf, "  \"fake_input_enabled\": %s,\n", useFakeInput ? "true" : "false");
			std::fprintf(jf, "  \"renderer\": \"%s\",\n", jsonEscape(hkgSystem::getInstance().getRendererString()).c_str());
			std::fprintf(jf, "  \"resolution\": [%d,%d],\n", env.m_window->getWidth(), env.m_window->getHeight());
			std::fprintf(jf, "  \"z_up\": %s,\n", zUp ? "true" : "false");
			std::fprintf(jf, "  \"world_up_hk\": ");
			printVec3Raw(jf, worldUp);
			std::fprintf(jf, ",\n");

			// Character roster snapshot
			std::fprintf(jf, "  \"characters\": [\n");
			if (world)
			{
				const hkArray<hkbCharacter*>& chars = world->getCharacters();
				sum.numCharacters = chars.getSize();
				for (int ci = 0; ci < chars.getSize(); ++ci)
				{
					hkbCharacter* ch = chars[ci];
					const hkaSkeleton* skel = (ch && ch->getSetup()) ? ch->getSetup()->m_animationSkeleton.val() : nullptr;
					const char* cname = (ch && ch->getName()) ? ch->getName() : "";
					const std::vector<int> lms = findLandmarkBones(skel);
					std::fprintf(jf, "    {\"index\":%d,\"name\":\"%s\",\"bones\":%d,\"landmarks\":[",
						ci, jsonEscape(cname).c_str(), skel ? skel->m_bones.getSize() : 0);
					for (size_t li = 0; li < lms.size(); ++li)
					{
						if (li) std::fprintf(jf, ",");
						std::fprintf(jf, "\"%s\"", jsonEscape(skel->m_bones[lms[li]].m_name.cString()).c_str());
					}
					std::fprintf(jf, "]}%s\n", (ci + 1 < chars.getSize()) ? "," : "");
				}
			}
			std::fprintf(jf, "  ],\n");
			std::fprintf(jf, "  \"frames\": [\n");
		}

		uint64_t trajHash = 14695981039346656037ULL;
		uint64_t evHash = 14695981039346656037ULL;
		uint64_t lastPoseHash = 0;
		std::set<std::string> uniqueStates;
		std::set<std::string> uniqueClips;

		for (int tick = 0; tick < numTicks; ++tick)
		{
			env.m_window->peekMessages();
			listener.clearTick();

			bool graphicsWindowOK = startRenderFrame(env);
			bdemo->setFixedTimestep(1.0f / 60.0f);
			rawDemo->advanceFrame();
			if (useFakeInput)
			{
				// Some demos (e.g. Soldier ClipGeneratorModes) force buttons on m_input->getGamePad(0),
				// while handleInput() reads m_env->m_gamePad (hkPseudoPad). Forward forced buttons
				// and immediately release them on rawPad so repeated presses and re-runs stay deterministic!
				hkgPad& rawPad = const_cast<hkgPad&>(env.m_input->getGamePad(0));
				const HKG_PAD_BUTTON prevRaw = rawPad.getButtonState();
				rawDemo->makeFakeInput();
				const HKG_PAD_BUTTON afterRaw = rawPad.getButtonState();
				const HKG_PAD_BUTTON newlyForced = afterRaw & ~prevRaw;
				if (newlyForced != 0)
				{
					if (env.m_gamePad)
					{
						env.m_gamePad->forceButtonPressed(newlyForced);
					}
					rawPad.setButtonState(afterRaw & ~newlyForced);
				}
			}
			hkDemo::Result stepRes = rawDemo->stepDemo();
			if (tick == 1)
			{
				const int nObj = env.m_displayWorld ? env.m_displayWorld->getNumDisplayObjects() : -1;
				const int nProc = bdemo->getDebugProcessCount();
				hkgViewport* vp0 = (env.m_window && env.m_window->getNumViewports() > 0) ? env.m_window->getViewport(0) : HK_NULL;
				const bool hasSky = (vp0 && vp0->getSkyBox() != HK_NULL);
				hkgDisplayContext* dctx = env.m_window ? env.m_window->getContext() : HK_NULL;
				hkgShaderEffectCollection* sc = dctx ? dctx->getDefaultShaderEffectCollection() : HK_NULL;
				int nEff = sc ? sc->getNumShaderEffects() : -1;
				int eff0Inputs = -1;
				if (sc && nEff > 0 && sc->getShaderEffect(0) && sc->getShaderEffect(0)->getInputOrder())
				{
					eff0Inputs = sc->getShaderEffect(0)->getInputOrder()->getSize();
				}
				int vpLL[2] = {0, 0}, vpUR[2] = {0, 0};
				if (vp0)
				{
					vp0->getLowerLeftCoord(vpLL[0], vpLL[1]);
					vp0->getUpperRightCoord(vpUR[0], vpUR[1]);
				}
				std::printf("[DIAG] #%d demoType=%d displayObjs=%d debugProcs=%d skyBox=%d gfxOK=%d vp=(%d,%d)-(%d,%d) eff=%d eff0In=%d vsVer=%d shadows=%d\n",
					demoIdx, bdemo->getDemoType(), nObj, nProc, int(hasSky), int(graphicsWindowOK),
					vpLL[0], vpLL[1], vpUR[0], vpUR[1], nEff, eff0Inputs,
					dctx ? int(dctx->getRenderCaps().m_vertexShaderMajorVersion) : -1,
					int(options.m_enableShadows));
				std::fflush(stdout);
			}

			// Trigger an extra event screenshot on the very first tick with raised events (after tick 0)
			bool takeShot = saveShots && (shotTicks.count(tick) > 0);
			if (saveShots && !capturedFirstEventShot && tick >= 2 && !listener.tickEvents.empty())
			{
				takeShot = true;
				capturedFirstEventShot = true;
			}

			int savedFrameNum = -1;
			if (graphicsWindowOK)
			{
				if (takeShot)
				{
					savedFrameNum = options.m_numSaveFrames;
					options.m_saveFrames = true;
				}
				renderFrame(env, rawDemo);
				options.m_saveFrames = false;
				tickFrame(env, (stepRes == hkDemo::DEMO_PAUSED));
			}
			else
			{
				clearFrameData(env);
			}

			std::string shotRel;
			if (takeShot && savedFrameNum >= 0)
			{
				char srcBmp[128];
				std::snprintf(srcBmp, sizeof(srcBmp), "frame%05i.bmp", savedFrameNum);
				char dstName[256];
				std::snprintf(dstName, sizeof(dstName), "%s_t%03d.bmp", slug.c_str(), tick);
				std::string dstBmp = shotsDir + "\\" + dstName;
				DeleteFileA(dstBmp.c_str());
				if (MoveFileA(srcBmp, dstBmp.c_str()))
				{
					shotRel = std::string("shots/") + dstName;
					sum.screenshots.push_back(shotRel);
				}
			}

			// Collect full deterministic telemetry from hkbWorld
			uint64_t framePoseHash = 14695981039346656037ULL;
			for (const auto& ev : listener.tickEvents)
			{
				sum.totalEvents++;
				evHash = fnv1aInt32(evHash, tick);
				evHash = fnv1aInt32(evHash, ev.charIdx);
				evHash = fnv1aInt32(evHash, ev.id);
				evHash = fnv1aUpdate(evHash, ev.name.data(), ev.name.size());
			}

			if (jf)
			{
				std::fprintf(jf, "    {\"tick\":%d,\"time\":%.6f", tick, double(tick) / 60.0);
				if (!shotRel.empty())
					std::fprintf(jf, ",\"shot\":\"%s\"", jsonEscape(shotRel).c_str());

				// Camera state
				if (env.m_window && env.m_window->getNumViewports() > 0 && env.m_window->getViewport(0)->getCamera())
				{
					hkgCamera* cam = env.m_window->getViewport(0)->getCamera();
					float from[3], to[3], up[3];
					cam->getFrom(from);
					cam->getTo(to);
					cam->getUp(up);
					std::fprintf(jf, ",\"cam\":{\"from\":[%.4f,%.4f,%.4f],\"to\":[%.4f,%.4f,%.4f],\"up\":[%.4f,%.4f,%.4f],\"fov\":%.3f,\"near\":%.4f,\"far\":%.2f}",
						from[0], from[1], from[2], to[0], to[1], to[2], up[0], up[1], up[2],
						double(cam->getFOV()), double(cam->getNear()), double(cam->getFar()));
				}

				// Events raised on this exact tick
				std::fprintf(jf, ",\"events\":[");
				for (size_t ei = 0; ei < listener.tickEvents.size(); ++ei)
				{
					const auto& ev = listener.tickEvents[ei];
					if (ei) std::fprintf(jf, ",");
					std::fprintf(jf, "{\"char\":%d,\"id\":%d,\"name\":\"%s\"}",
						ev.charIdx, ev.id, jsonEscape(ev.name).c_str());
				}
				std::fprintf(jf, "]");

				// Per-character root, landmarks, active states, active clips, pose hash
				std::fprintf(jf, ",\"chars\":[");
			}

			if (world)
			{
				const hkArray<hkbCharacter*>& chars = world->getCharacters();
				for (int ci = 0; ci < chars.getSize(); ++ci)
				{
					hkbCharacter* ch = chars[ci];
					if (!ch) continue;
					const hkQsTransform& wfm = ch->getWorldFromModel();
					const hkVector4 rpos = wfm.getTranslation();
					const hkQuaternion rrot = wfm.getRotation();
					const double yawG = extractYawGodot(rrot, zUp);

					trajHash = fnv1aQuantFloat(trajHash, float(rpos(0)));
					trajHash = fnv1aQuantFloat(trajHash, float(rpos(1)));
					trajHash = fnv1aQuantFloat(trajHash, float(rpos(2)));
					trajHash = fnv1aQuantFloat(trajHash, float(rrot(0)));
					trajHash = fnv1aQuantFloat(trajHash, float(rrot(1)));
					trajHash = fnv1aQuantFloat(trajHash, float(rrot(2)));
					trajHash = fnv1aQuantFloat(trajHash, float(rrot(3)));

					const hkaSkeleton* skel = ch->getSetup() ? ch->getSetup()->m_animationSkeleton.val() : nullptr;
					const int numPose = ch->getNumPoseLocal();
					std::vector<hkQsTransform> modelPose;
					if (skel && numPose > 0)
					{
						const hkQsTransform* poseLocal = ch->getPoseLocal();
						const int nb = std::min(numPose, skel->m_bones.getSize());
						modelPose.resize(nb);
						for (int b = 0; b < nb; ++b)
						{
							const hkInt16 parent = skel->m_parentIndices[b];
							if (parent >= 0 && parent < b)
								modelPose[b].setMul(modelPose[parent], poseLocal[b]);
							else
								modelPose[b] = poseLocal[b];
							const hkVector4& mp = modelPose[b].getTranslation();
							const hkQuaternion& mq = modelPose[b].getRotation();
							framePoseHash = fnv1aQuantFloat(framePoseHash, float(mp(0)));
							framePoseHash = fnv1aQuantFloat(framePoseHash, float(mp(1)));
							framePoseHash = fnv1aQuantFloat(framePoseHash, float(mp(2)));
							framePoseHash = fnv1aQuantFloat(framePoseHash, float(mq(0)), 1000.0f);
							framePoseHash = fnv1aQuantFloat(framePoseHash, float(mq(1)), 1000.0f);
							framePoseHash = fnv1aQuantFloat(framePoseHash, float(mq(2)), 1000.0f);
							framePoseHash = fnv1aQuantFloat(framePoseHash, float(mq(3)), 1000.0f);
						}
					}

					if (jf)
					{
						if (ci) std::fprintf(jf, ",");
						std::fprintf(jf, "{\"idx\":%d,\"root_hk\":", ci);
						printVec3Raw(jf, rpos);
						std::fprintf(jf, ",\"rot_hk\":");
						printQuatRaw(jf, rrot);
						std::fprintf(jf, ",\"root_g\":");
						printVec3Godot(jf, rpos, zUp);
						std::fprintf(jf, ",\"yaw_g\":%.5f", yawG);

						// Landmarks in Godot Y-up world space
						std::fprintf(jf, ",\"lm\":{");
						if (skel && !modelPose.empty())
						{
							const std::vector<int> lms = findLandmarkBones(skel);
							for (size_t li = 0; li < lms.size(); ++li)
							{
								const int bi = lms[li];
								if (bi < 0 || bi >= int(modelPose.size())) continue;
								hkQsTransform wp;
								wp.setMul(wfm, modelPose[bi]);
								if (li) std::fprintf(jf, ",");
								std::fprintf(jf, "\"%s\":", jsonEscape(skel->m_bones[bi].m_name.cString()).c_str());
								printVec3Godot(jf, wp.getTranslation(), zUp);
							}
						}
						std::fprintf(jf, "}");

						// Active state machines & clip generators
						std::fprintf(jf, ",\"states\":{");
						hkbBehaviorGraph* bg = ch->getBehavior();
						if (bg)
						{
							bool firstS = true;
							for (const auto* ni : bg->getActiveNodes())
							{
								hkbNode* node = ni ? ni->m_nodeClone : nullptr;
								if (!node) continue;
								if (node->getType() == HKB_NODE_TYPE_STATE_MACHINE)
								{
									const hkbStateMachine* sm = static_cast<const hkbStateMachine*>(node);
									const char* smName = sm->m_name.cString() ? sm->m_name.cString() : "SM";
									const int sid = sm->getCurrentStateId();
									const char* stName = (sid >= 0) ? sm->getStateInfoById(sid).m_name.cString() : "";
									const std::string stStr = stName ? stName : "";
									uniqueStates.insert(std::string(smName) + ":" + stStr);
									if (!firstS) std::fprintf(jf, ",");
									firstS = false;
									std::fprintf(jf, "\"%s\":\"%s\"", jsonEscape(smName).c_str(), jsonEscape(stStr).c_str());
								}
							}
							std::fprintf(jf, "},\"clips\":[");
							bool firstC = true;
							for (const auto* ni : bg->getActiveNodes())
							{
								hkbNode* node = ni ? ni->m_nodeClone : nullptr;
								if (!node) continue;
								if (node->getType() == HKB_NODE_TYPE_CLIP_GENERATOR)
								{
									const hkbClipGenerator* cg = static_cast<const hkbClipGenerator*>(node);
									const char* cn = cg->m_name.cString() ? cg->m_name.cString() : "";
									const char* an = cg->m_animationName.cString() ? cg->m_animationName.cString() : "";
									uniqueClips.insert(an);
									if (!firstC) std::fprintf(jf, ",");
									firstC = false;
									std::fprintf(jf, "{\"name\":\"%s\",\"anim\":\"%s\",\"lt\":%.5f,\"dur\":%.5f,\"mode\":%d,\"spd\":%.4f,\"pb\":%s}",
										jsonEscape(cn).c_str(),
										jsonEscape(an).c_str(),
										double(cg->getLocalLocalTime()),
										double(cg->getDurationLocalTime()),
										int(cg->m_mode),
										double(cg->m_playbackSpeed),
										cg->isPingPongBackwards() ? "true" : "false");
								}
							}
							std::fprintf(jf, "]");
						}
						else
						{
							std::fprintf(jf, "},\"clips\":[]");
						}
						std::fprintf(jf, "}");
					}
				}
			}

			lastPoseHash = framePoseHash;
			if (jf)
			{
				std::fprintf(jf, "],\"pose_hash\":\"%016llx\"}%s\n",
					(unsigned long long)framePoseHash,
					(tick + 1 < numTicks) ? "," : "");
			}

			if (stepRes == hkDemo::DEMO_STOP)
			{
				sum.ticks = tick + 1;
				break;
			}
		}

		sum.finalPoseHash = lastPoseHash;
		sum.trajectoryHash = trajHash;
		sum.eventHash = evHash;
		sum.ok = true;

		if (jf)
		{
			std::fprintf(jf, "  ],\n");
			std::fprintf(jf, "  \"summary\": {\n");
			std::fprintf(jf, "    \"demo_type\": %d,\n", bdemo->getDemoType());
			std::fprintf(jf, "    \"display_objects\": %d,\n", env.m_displayWorld ? env.m_displayWorld->getNumDisplayObjects() : 0);
			std::fprintf(jf, "    \"executed_ticks\": %d,\n", sum.ticks);
			std::fprintf(jf, "    \"num_characters\": %d,\n", sum.numCharacters);
			std::fprintf(jf, "    \"total_events\": %d,\n", sum.totalEvents);
			std::fprintf(jf, "    \"unique_states_count\": %d,\n", int(uniqueStates.size()));
			std::fprintf(jf, "    \"unique_clips_count\": %d,\n", int(uniqueClips.size()));
			std::fprintf(jf, "    \"final_pose_hash\": \"%016llx\",\n", (unsigned long long)sum.finalPoseHash);
			std::fprintf(jf, "    \"trajectory_hash\": \"%016llx\",\n", (unsigned long long)sum.trajectoryHash);
			std::fprintf(jf, "    \"event_hash\": \"%016llx\",\n", (unsigned long long)sum.eventHash);
			std::fprintf(jf, "    \"screenshots\": [");
			for (size_t i = 0; i < sum.screenshots.size(); ++i)
			{
				if (i) std::fprintf(jf, ",");
				std::fprintf(jf, "\"%s\"", jsonEscape(sum.screenshots[i]).c_str());
			}
			std::fprintf(jf, "]\n  }\n}\n");
			std::fclose(jf);
		}

		if (world)
		{
			world->removeListener(&listener);
		}
		delete rawDemo;
		env.m_isBootstrapping = false;
		return sum;
	}
}

extern "C" __declspec(dllimport) int __stdcall SetDllDirectoryA(const char* lpPathName);

int __cdecl main(int argc, char** argv)
{
	bool listOnly = false;
	bool runAll = false;
	bool verifyDet = false;
	bool noFakeInput = false;
	bool noShots = false;
	bool noJson = false;
	bool verbose = false;
	bool forceCompiled = false;
	bool noShadows = false;
	int targetDemoIdx = -1;
	std::string targetDemoQuery;
	std::string outDir = "havok_capture_out";
	std::string renderer = "d3d11";
	int overrideTicks = 0;
	int width = 1280;
	int height = 720;

	for (int i = 1; i < argc; ++i)
	{
		std::string a = argv[i];
		if (a == "--list") listOnly = true;
		else if (a == "--run-all") runAll = true;
		else if (a == "--verify-determinism") verifyDet = true;
		else if (a == "--no-fake-input") noFakeInput = true;
		else if (a == "--no-shots") noShots = true;
		else if (a == "--no-json") noJson = true;
		else if (a == "--verbose") verbose = true;
		else if (a == "--bin") forceCompiled = true;
		else if (a == "--noshadows") noShadows = true;
		else if (a == "--demo-index" && i + 1 < argc) targetDemoIdx = std::atoi(argv[++i]);
		else if (a == "--demo" && i + 1 < argc) targetDemoQuery = argv[++i];
		else if (a == "--out" && i + 1 < argc) outDir = argv[++i];
		else if (a == "--renderer" && i + 1 < argc) renderer = argv[++i];
		else if (a == "--ticks" && i + 1 < argc) overrideTicks = std::atoi(argv[++i]);
		else if (a == "--width" && i + 1 < argc) width = std::atoi(argv[++i]);
		else if (a == "--height" && i + 1 < argc) height = std::atoi(argv[++i]);
	}

	SetDllDirectoryA("D:\\SDK\\hk2015_1_0\\hk2015_1_0_r1\\Demo\\Demos");
	DemoPlatformInit(HK_NULL);
	hkDemoFrameworkOptions options;
	options.m_windowed = true;
	options.m_maximized = false;
	options.m_width = width;
	options.m_height = height;
	options.m_enableMsaa = false;
	options.m_enableVsync = false;
	options.m_enableShadows = !noShadows;
	options.m_forceNoShadows = noShadows;
	options.m_forceCompiledShaders = forceCompiled;
	options.m_debugger = false;
	options.m_forceMT = false;
	options.m_numThreads = 1;
	options.m_lockFps = 0;
	options.m_timestep = 1.0f / 60.0f;
	options.m_renderer = renderer.c_str();
	options.m_windowTitle = "Havok 2015.1.0-r1 Official Behavior Demo Capture (60 Hz)";
	options.m_reportingLevel = verbose ? hkDemoEnvironment::REPORT_ALL : hkDemoEnvironment::REPORT_ERROR;
	DemoPlatformInit(&options);

	hkMallocAllocator mallocBase;
	if (!frameworkInitBaseSystem(&mallocBase, options))
	{
		std::fprintf(stderr, "[capture] frameworkInitBaseSystem failed\n");
		return 2;
	}
	hkFileSystem::replaceInstance(new InMemoryStateFileSystem(&hkFileSystem::getInstance()));

	// Silence noisy info/asset conversion reports unless verbose
	if (!verbose)
	{
		hkError::getInstance().setEnabled(0xABBA55FE, false);
		hkError::getInstance().setEnabled(0x00023461, false);
	}

	auto isBehaviorEntry = [](const hkDemoEntry& e) -> bool {
		const char* dp = e.m_demoPath.cString() ? e.m_demoPath.cString() : "";
		return std::strstr(dp, "Behavior/") != nullptr || std::strstr(dp, "Behavior\\") != nullptr;
	};

	const hkArray<hkDemoEntry>& demos = hkDemoDatabase::getInstance().getDemos();
	if (listOnly)
	{
		std::printf("TOTAL_DEMOS=%d\n", demos.getSize());
		for (int i = 0; i < demos.getSize(); ++i)
		{
			const hkDemoEntry& e = demos[i];
			const char* mp = e.m_menuPath.cString() ? e.m_menuPath.cString() : "";
			const char* dp = e.m_demoPath.cString() ? e.m_demoPath.cString() : "";
			if (!isBehaviorEntry(e)) continue;
			std::printf("DEMO|%d|%d|%s|%s|%s\n",
				i, e.m_variantId, makeSlug(mp).c_str(), mp, dp);
		}
		frameworkQuitBaseSystem();
		return 0;
	}

	std::vector<int> queue;
	for (int i = 0; i < demos.getSize(); ++i)
	{
		const hkDemoEntry& e = demos[i];
		if (!isBehaviorEntry(e)) continue;
		const std::string mp = e.m_menuPath.cString() ? e.m_menuPath.cString() : "";
		if (runAll)
		{
			queue.push_back(i);
		}
		else if (targetDemoIdx == i)
		{
			queue.push_back(i);
		}
		else if (!targetDemoQuery.empty() &&
			(mp.find(targetDemoQuery) != std::string::npos || makeSlug(mp).find(targetDemoQuery) != std::string::npos))
		{
			queue.push_back(i);
		}
	}

	if (queue.empty())
	{
		std::fprintf(stderr, "[capture] No matching Behavior demos found (total registered=%d)\n", demos.getSize());
		frameworkQuitBaseSystem();
		return 3;
	}

	int exitCode = 0;
	{
		hkDemoEnvironment env;
		env.m_options = &options;
		env.m_reportingLevel = (hkDemoEnvironment::ReportingLevel)options.m_reportingLevel;
		s_debugEnvironmentHandle = &env;
		s_demoObjectCache = new hkDemoReferencedObjectCache();

		if (!initRendererAndEnv(env))
		{
			std::fprintf(stderr, "[capture] initRendererAndEnv failed for renderer=%s\n", renderer.c_str());
			delete s_demoObjectCache;
			frameworkQuitBaseSystem();
			return 4;
		}

		for (int idx : queue)
		{
			const hkDemoEntry& entry = demos[idx];
			const std::string mp = entry.m_menuPath.cString() ? entry.m_menuPath.cString() : "";
			std::printf("[RUN] #%d %s ...\n", idx, mp.c_str());
			std::fflush(stdout);

			RunSummary r1 = captureSingleDemo(env, options, idx, entry, outDir, overrideTicks, !noFakeInput, !noShots, !noJson);
			bool detOk = true;
			if (verifyDet && r1.ok)
			{
				RunSummary r2 = captureSingleDemo(env, options, idx, entry, outDir, overrideTicks, !noFakeInput, false, false);
				detOk = r2.ok && (r1.finalPoseHash == r2.finalPoseHash) && (r1.trajectoryHash == r2.trajectoryHash) && (r1.eventHash == r2.eventHash);
			}
			std::printf("[DONE] #%d ok=%d det=%d ticks=%d chars=%d events=%d shots=%d pose=%016llx traj=%016llx ev=%016llx | %s\n",
				idx, int(r1.ok), int(detOk), r1.ticks, r1.numCharacters, r1.totalEvents, int(r1.screenshots.size()),
				(unsigned long long)r1.finalPoseHash, (unsigned long long)r1.trajectoryHash, (unsigned long long)r1.eventHash,
				mp.c_str());
			std::fflush(stdout);
			if (!r1.ok || !detOk) exitCode = 1;
		}

		quitRendererAndEnv(env);
		delete s_demoObjectCache;
		s_demoObjectCache = HK_NULL;
	}

	frameworkQuitBaseSystem();
	return exitCode;
}
