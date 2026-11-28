// Official Havok 2015.1.0-r1 Offline Behavior Graph Topology Extractor (P1)
// Walks REAL hkbBehaviorGraph C++ object graphs inside official SDK `.hkt` files
// and serializes complete declarative topologies (variables, events, attributes,
// character properties, hkbVariableBindingSet, hkbCondition / expressions,
// hkbStateMachine states/transitions/intervals/effects, hkbGenerator tree,
// hkbModifier chains & parameters, hkbBoneWeightArray masks) into zero-SDK JSON.

#define HK_FEATURE_PRODUCT_ANIMATION
#define HK_FEATURE_PRODUCT_PHYSICS
#define HK_FEATURE_PRODUCT_BEHAVIOR

#include <Common/Base/hkBase.h>
#include <Common/Base/Memory/System/Util/hkMemoryInitUtil.h>
#include <Common/Base/Memory/Allocator/Malloc/hkMallocAllocator.h>
#include <Common/Base/KeyCode.h>
#include <Common/Serialize/Util/hkSerializeUtil.h>
#include <Common/Serialize/Util/hkRootLevelContainer.h>
#include <Common/Base/Serialize/Resource/hkObjectResource.h>

#include <Behavior/Behavior/BehaviorGraph/hkbBehaviorGraph.h>
#include <Behavior/Behavior/BehaviorGraph/hkbBehaviorGraphData.h>
#include <Behavior/Behavior/BehaviorGraph/hkbBehaviorGraphStringData.h>
#include <Behavior/Behavior/Variables/hkbVariableBindingSet.h>
#include <Behavior/Behavior/Variables/hkbVariableInfo.h>
#include <Behavior/Behavior/Variables/hkbVariableValueSet.h>
#include <Behavior/Behavior/Character/hkbBoneWeightArray.h>
#include <Behavior/Behavior/Character/hkbBoneIndexArray.h>
#include <Behavior/Behavior/Node/hkbBindable.h>
#include <Behavior/Behavior/Node/hkbNode.h>
#include <Behavior/Behavior/StateMachine/hkbStateMachine.h>
#include <Behavior/Behavior/Condition/hkbCondition.h>
#include <Behavior/Behavior/Condition/Expression/hkbExpressionCondition.h>
#include <Behavior/Behavior/Condition/String/hkbStringCondition.h>
#include <Behavior/Behavior/TransitionEffect/hkbTransitionEffect.h>
#include <Behavior/Behavior/TransitionEffect/Blending/hkbBlendingTransitionEffect.h>
#include <Behavior/Behavior/TransitionEffect/Generator/hkbGeneratorTransitionEffect.h>
#include <Behavior/Behavior/Generator/Clip/hkbClipGenerator.h>
#include <Behavior/Behavior/Generator/Blender/hkbBlenderGenerator.h>
#include <Behavior/Behavior/Generator/Blender/hkbBlenderGeneratorChild.h>
#include <Behavior/Behavior/Generator/Blender/Layer/hkbLayerGenerator.h>
#include <Behavior/Behavior/Generator/Blender/Layer/hkbLayer.h>
#include <Behavior/Behavior/Generator/ManualSelector/hkbManualSelectorGenerator.h>
#include <Behavior/Behavior/Generator/ReferencePose/hkbReferencePoseGenerator.h>
#include <Behavior/Behavior/Generator/Modifier/hkbModifierGenerator.h>
#include <Behavior/Behavior/Generator/BehaviorReference/hkbBehaviorReferenceGenerator.h>
#include <Behavior/Behavior/Generator/PoseMatching/hkbPoseMatchingGenerator.h>
#include <Behavior/Behavior/Generator/Docking/hkbDockingGenerator.h>
#include <Behavior/Behavior/Generator/Script/hkbScriptGenerator.h>
#include <Behavior/Behavior/Generator/ParametricMotion/hkbParametricMotionGenerator.h>
#include <Behavior/Utilities/Generator/PinBones/hkbPinBonesGenerator.h>
#include <Behavior/Behavior/Modifier/hkbModifier.h>
#include <Behavior/Behavior/Modifier/List/hkbModifierList.h>
#include <Behavior/Behavior/Modifier/EvaluateExpression/hkbEvaluateExpressionModifier.h>
#include <Behavior/Behavior/Modifier/EventsFromRange/hkbEventsFromRangeModifier.h>
#include <Behavior/Behavior/Modifier/EventDriven/hkbEventDrivenModifier.h>
#include <Behavior/Behavior/Modifier/Timer/hkbTimerModifier.h>
#include <Behavior/Behavior/Modifier/Delayed/hkbDelayedModifier.h>
#include <Behavior/Behavior/Modifier/Damping/hkbDampingModifier.h>
#include <Behavior/Behavior/Modifier/Mirror/hkbMirrorModifier.h>
#include <Behavior/Behavior/Modifier/LookAt/hkbLookAtModifier.h>
#include <Behavior/Behavior/Modifier/Twist/hkbTwistModifier.h>
#include <Behavior/Behavior/Modifier/RotateCharacter/hkbRotateCharacterModifier.h>
#include <Behavior/Behavior/Modifier/MoveCharacter/hkbMoveCharacterModifier.h>
#include <Behavior/Behavior/Modifier/FootIk/hkbFootIkControlsModifier.h>
#include <Behavior/Behavior/Modifier/HandIk/hkbHandIkControlsModifier.h>
#include <Behavior/Behavior/Modifier/BodyIk/hkbBodyIkControlsModifier.h>
#include <Behavior/Behavior/Modifier/Attachment/hkbAttachmentModifier.h>
#include <Behavior/Behavior/Modifier/Attachment/hkbMoveBoneAttachmentModifier.h>
#include <Behavior/Behavior/Modifier/SenseHandle/hkbSenseHandleModifier.h>
#include <Behavior/Behavior/Modifier/GetHandleOnBone/hkbGetHandleOnBoneModifier.h>
#include <Behavior/Behavior/Modifier/EvaluateHandle/hkbEvaluateHandleModifier.h>
#include <Behavior/Behavior/Modifier/Ragdoll/hkbPoweredRagdollControlsModifier.h>
#include <Behavior/Behavior/Modifier/Ragdoll/hkbRigidBodyRagdollControlsModifier.h>
#include <Behavior/Behavior/Modifier/Ragdoll/hkbKeyframeBonesModifier.h>
#include <Behavior/Behavior/Modifier/GetUp/hkbGetUpModifier.h>
#include <Behavior/Behavior/Modifier/CombineTransforms/hkbCombineTransformsModifier.h>
#include <Behavior/Behavior/Modifier/ComputeDirection/hkbComputeDirectionModifier.h>
#include <Behavior/Behavior/Modifier/ComputeRotationToTarget/hkbComputeRotationToTargetModifier.h>
#include <Behavior/Behavior/Modifier/CharacterController/hkbCharacterControllerModifier.h>
#include <Behavior/Behavior/Sequence/hkbSequence.h>
#include <Behavior/Behavior/Sequence/hkbSequencedData.h>

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
#include <sstream>
#include <string>
#include <vector>

static void HK_CALL reportErr(const char* msg, void*)
{
	if (msg) std::fprintf(stderr, "[hk] %s\n", msg);
}

class SilentNonBreakingError : public hkError
{
public:
	HK_DECLARE_CLASS_ALLOCATOR(HK_MEMORY_CLASS_BASE);
	virtual int message(Message m, int id, const char* description, const char* file, int line) HK_OVERRIDE
	{
		if (m == MESSAGE_ASSERT || m == MESSAGE_ERROR)
			std::fprintf(stderr, "[hk-warn %d] %s (%s:%d)\n", id, description ? description : "", file ? file : "", line);
		return 0; // NEVER trigger __debugbreak!
	}
	virtual void setEnabled(int, hkBool) HK_OVERRIDE {}
	virtual hkBool isEnabled(int) HK_OVERRIDE { return true; }
	virtual void enableAll() HK_OVERRIDE {}
	virtual void sectionBegin(int, const char*) HK_OVERRIDE {}
	virtual void sectionEnd() HK_OVERRIDE {}
};

static inline float safeF(float v)
{
	return (std::isfinite(v) && std::fabs(v) < 1e15f) ? v : 0.0f;
}

static std::string jesc(const char* s)
{
	if (!s) return "";
	std::string out;
	for (const unsigned char* p = reinterpret_cast<const unsigned char*>(s); *p; ++p)
	{
		unsigned char c = *p;
		switch (c)
		{
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\b': out += "\\b"; break;
			case '\f': out += "\\f"; break;
			case '\n': out += "\\n"; break;
			case '\r': out += "\\r"; break;
			case '\t': out += "\\t"; break;
			default:
				if (c < 0x20)
				{
					char buf[8];
					std::snprintf(buf, sizeof(buf), "\\u%04x", int(c));
					out += buf;
				}
				else
				{
					out.push_back(static_cast<char>(c));
				}
		}
	}
	return out;
}

static std::string nodeTypeName(hkbNodeType t)
{
	switch (t)
	{
		case HKB_NODE_TYPE_BEHAVIOR_GRAPH: return "hkbBehaviorGraph";
		case HKB_NODE_TYPE_BEHAVIOR_REFERENCE_GENERATOR: return "hkbBehaviorReferenceGenerator";
		case HKB_NODE_TYPE_BLENDER_GENERATOR: return "hkbBlenderGenerator";
		case HKB_NODE_TYPE_CLIP_GENERATOR: return "hkbClipGenerator";
		case HKB_NODE_TYPE_MANUAL_SELECTOR_GENERATOR: return "hkbManualSelectorGenerator";
		case HKB_NODE_TYPE_MODIFIER_GENERATOR: return "hkbModifierGenerator";
		case HKB_NODE_TYPE_REFERENCE_POSE_GENERATOR: return "hkbReferencePoseGenerator";
		case HKB_NODE_TYPE_STATE_MACHINE: return "hkbStateMachine";
		case HKB_NODE_TYPE_SCRIPT_GENERATOR: return "hkbScriptGenerator";
		case HKB_NODE_TYPE_LAYER_GENERATOR: return "hkbLayerGenerator";
		case HKB_NODE_TYPE_DOCKING_GENERATOR: return "hkbDockingGenerator";
		case HKB_NODE_TYPE_PARAMETRIC_MOTION_GENERATOR: return "hkbParametricMotionGenerator";
		case HKB_NODE_TYPE_PIN_BONE_GENERATOR: return "hkbPinBonesGenerator";
		case HKB_NODE_TYPE_BLENDING_TRANSITION_EFFECT: return "hkbBlendingTransitionEffect";
		case HKB_NODE_TYPE_GENERATOR_TRANSITION_EFFECT: return "hkbGeneratorTransitionEffect";
		case HKB_NODE_TYPE_MANUAL_SELECTOR_TRANSITION_EFFECT: return "hkbManualSelectorTransitionEffect";
		case HKB_NODE_TYPE_ATTACHMENT_MODIFIER: return "hkbAttachmentModifier";
		case HKB_NODE_TYPE_ATTRIBUTE_MODIFIER: return "hkbAttributeModifier";
		case HKB_NODE_TYPE_CHARACTER_CONTROLLER_MODIFIER: return "hkbCharacterControllerModifier";
		case HKB_NODE_TYPE_COMBINE_TRANSFORMS_MODIFIER: return "hkbCombineTransformsModifier";
		case HKB_NODE_TYPE_COMPUTE_DIRECTION_MODIFIER: return "hkbComputeDirectionModifier";
		case HKB_NODE_TYPE_COMPUTE_ROTATION_FROM_AXIS_ANGLE_MODIFIER: return "hkbComputeRotationFromAxisAngleModifier";
		case HKB_NODE_TYPE_COMPUTE_ROTATION_TO_TARGET_MODIFIER: return "hkbComputeRotationToTargetModifier";
		case HKB_NODE_TYPE_DAMPING_MODIFIER: return "hkbDampingModifier";
		case HKB_NODE_TYPE_DELAYED_MODIFIER: return "hkbDelayedModifier";
		case HKB_NODE_TYPE_EVALUATE_EXPRESSION_MODIFIER: return "hkbEvaluateExpressionModifier";
		case HKB_NODE_TYPE_EVENTS_FROM_RANGE_MODIFIER: return "hkbEventsFromRangeModifier";
		case HKB_NODE_TYPE_EVENT_DRIVEN_MODIFIER: return "hkbEventDrivenModifier";
		case HKB_NODE_TYPE_FOOT_IK_CONTROLS_MODIFIER: return "hkbFootIkControlsModifier";
		case HKB_NODE_TYPE_GET_WORLD_FROM_MODEL_MODIFIER: return "hkbGetWorldFromModelModifier";
		case HKB_NODE_TYPE_HAND_IK_CONTROLS_MODIFIER: return "hkbHandIkControlsModifier";
		case HKB_NODE_TYPE_KEYFRAME_BONES_MODIFIER: return "hkbKeyframeBonesModifier";
		case HKB_NODE_TYPE_LOOK_AT_MODIFIER: return "hkbLookAtModifier";
		case HKB_NODE_TYPE_MIRROR_MODIFIER: return "hkbMirrorModifier";
		case HKB_NODE_TYPE_MODIFIER_LIST: return "hkbModifierList";
		case HKB_NODE_TYPE_MOVE_BONE_ATTACHMENT_MODIFIER: return "hkbMoveBoneAttachmentModifier";
		case HKB_NODE_TYPE_MOVE_CHARACTER_MODIFIER: return "hkbMoveCharacterModifier";
		case HKB_NODE_TYPE_POWERED_RAGDOLL_CONTROLS_MODIFIER: return "hkbPoweredRagdollControlsModifier";
		case HKB_NODE_TYPE_RIGID_BODY_RAGDOLL_CONTROLS_MODIFIER: return "hkbRigidBodyRagdollControlsModifier";
		case HKB_NODE_TYPE_ROTATE_CHARACTER_MODIFIER: return "hkbRotateCharacterModifier";
		case HKB_NODE_TYPE_SET_WORLD_FROM_MODEL_MODIFIER: return "hkbSetWorldFromModelModifier";
		case HKB_NODE_TYPE_TIMER_MODIFIER: return "hkbTimerModifier";
		case HKB_NODE_TYPE_TRANSFORM_VECTOR_MODIFIER: return "hkbTransformVectorModifier";
		case HKB_NODE_TYPE_TWIST_MODIFIER: return "hkbTwistModifier";
		case HKB_NODE_TYPE_DETECT_CLOSE_TO_GROUND_MODIFIER: return "hkbDetectCloseToGroundModifier";
		case HKB_NODE_TYPE_EVALUATE_HANDLE_MODIFIER: return "hkbEvaluateHandleModifier";
		case HKB_NODE_TYPE_GET_HANDLE_ON_BONE_MODIFIER: return "hkbGetHandleOnBoneModifier";
		case HKB_NODE_TYPE_GET_UP_MODIFIER: return "hkbGetUpModifier";
		case HKB_NODE_TYPE_JIGGLER_MODIFIER: return "hkbJigglerModifier";
		case HKB_NODE_TYPE_SENSE_HANDLE_MODIFIER: return "hkbSenseHandleModifier";
		case HKB_NODE_TYPE_SEQUENCE: return "hkbSequence";
		case HKB_NODE_TYPE_AI_STEERING_MODIFIER: return "hkbAiSteeringModifier";
		case HKB_NODE_TYPE_AI_CONTROL_MODIFIER: return "hkbAiControlModifier";
		case HKB_NODE_TYPE_BODY_IK_CONTROLS_MODIFIER: return "hkbBodyIkControlsModifier";
		default: return "hkbNode_" + std::to_string(int(t));
	}
}

static std::string varTypeName(hkbVariableInfo::VariableType t)
{
	switch (t)
	{
		case hkbVariableInfo::VARIABLE_TYPE_BOOL: return "bool";
		case hkbVariableInfo::VARIABLE_TYPE_INT8: return "int8";
		case hkbVariableInfo::VARIABLE_TYPE_INT16: return "int16";
		case hkbVariableInfo::VARIABLE_TYPE_INT32: return "int32";
		case hkbVariableInfo::VARIABLE_TYPE_REAL: return "real";
		case hkbVariableInfo::VARIABLE_TYPE_POINTER: return "pointer";
		case hkbVariableInfo::VARIABLE_TYPE_VECTOR3: return "vector3";
		case hkbVariableInfo::VARIABLE_TYPE_VECTOR4: return "vector4";
		case hkbVariableInfo::VARIABLE_TYPE_QUATERNION: return "quaternion";
		default: return "invalid";
	}
}

struct GraphCtx
{
	const hkbBehaviorGraphStringData* strData = HK_NULL;
	std::map<const hkbNode*, int> nodeIds;
	std::vector<const hkbNode*> orderedNodes;

	std::string evName(int id) const
	{
		if (strData && id >= 0 && id < strData->m_eventNames.getSize())
			return strData->m_eventNames[id].cString() ? strData->m_eventNames[id].cString() : "";
		return "";
	}

	std::string varName(int id) const
	{
		if (strData && id >= 0 && id < strData->m_variableNames.getSize())
			return strData->m_variableNames[id].cString() ? strData->m_variableNames[id].cString() : "";
		return "";
	}

	std::string propName(int id) const
	{
		if (strData && id >= 0 && id < strData->m_characterPropertyNames.getSize())
			return strData->m_characterPropertyNames[id].cString() ? strData->m_characterPropertyNames[id].cString() : "";
		return "";
	}

	int registerNode(const hkbNode* n)
	{
		if (!n) return -1;
		auto it = nodeIds.find(n);
		if (it != nodeIds.end()) return it->second;
		int id = int(orderedNodes.size());
		nodeIds[n] = id;
		orderedNodes.push_back(n);
		return id;
	}
};

static void writeBindingsJson(std::FILE* f, const hkbVariableBindingSet* vbs, const GraphCtx& ctx)
{
	if (!vbs || const_cast<hkbVariableBindingSet*>(vbs)->numBindings() == 0)
	{
		std::fprintf(f, "[]");
		return;
	}
	auto* mut = const_cast<hkbVariableBindingSet*>(vbs);
	int nb = mut->numBindings();
	std::fprintf(f, "[");
	for (int i = 0; i < nb; ++i)
	{
		const hkbVariableBindingSet::Binding& b = mut->getBinding(i);
		bool isProp = (b.m_bindingType == hkbVariableBindingSet::Binding::BINDING_TYPE_CHARACTER_PROPERTY);
		std::string nm = isProp ? ctx.propName(b.m_variableIndex) : ctx.varName(b.m_variableIndex);
		std::fprintf(f, "{\"member\":\"%s\",\"var_idx\":%d,\"var_name\":\"%s\",\"type\":\"%s\",\"bit\":%d}%s",
			jesc(b.m_memberPath.cString()).c_str(),
			int(b.m_variableIndex),
			jesc(nm.c_str()).c_str(),
			isProp ? "character_property" : "variable",
			int(b.m_bitIndex),
			(i + 1 < nb) ? "," : "");
	}
	std::fprintf(f, "]");
}

static void writeConditionJson(std::FILE* f, const hkbCondition* cond)
{
	if (!cond)
	{
		std::fprintf(f, "null");
		return;
	}
	if (const hkbExpressionCondition* ec = hkDynCast<hkbExpressionCondition>(cond))
	{
		std::fprintf(f, "{\"kind\":\"expression\",\"expr\":\"%s\"}", jesc(ec->m_expression.cString()).c_str());
	}
	else if (const hkbStringCondition* sc = hkDynCast<hkbStringCondition>(cond))
	{
		std::fprintf(f, "{\"kind\":\"string\",\"expr\":\"%s\"}", jesc(sc->m_conditionString.cString()).c_str());
	}
	else
	{
		std::fprintf(f, "{\"kind\":\"other\"}");
	}
}

static void writeTransitionEffectJson(std::FILE* f, const hkbTransitionEffect* te, GraphCtx& ctx)
{
	if (!te)
	{
		std::fprintf(f, "null");
		return;
	}
	if (const hkbBlendingTransitionEffect* bte = hkDynCast<hkbBlendingTransitionEffect>(te))
	{
		std::fprintf(f, "{\"kind\":\"blending\",\"name\":\"%s\",\"duration\":%.5f,\"to_start_frac\":%.5f,\"flags\":%d,\"blend_curve\":%d,\"bindings\":",
			jesc(bte->m_name.cString()).c_str(),
			safeF(bte->m_duration),
			safeF(bte->m_toGeneratorStartTimeFraction),
			int(bte->m_flags.get()),
			int(bte->m_blendCurve));
		writeBindingsJson(f, bte->getVariableBindings(), ctx);
		std::fprintf(f, "}");
	}
	else if (const hkbGeneratorTransitionEffect* gte = hkDynCast<hkbGeneratorTransitionEffect>(te))
	{
		int tid = ctx.registerNode(gte->m_transitionGenerator);
		std::fprintf(f, "{\"kind\":\"generator\",\"name\":\"%s\",\"transition_gen\":%d,\"blend_in\":%.5f,\"blend_out\":%.5f,\"sync_start\":%s,\"bindings\":",
			jesc(gte->m_name.cString()).c_str(),
			tid,
			safeF(gte->m_blendInDuration),
			safeF(gte->m_blendOutDuration),
			gte->m_syncToGeneratorStartTime ? "true" : "false");
		writeBindingsJson(f, gte->getVariableBindings(), ctx);
		std::fprintf(f, "}");
	}
	else
	{
		std::fprintf(f, "{\"kind\":\"%s\",\"name\":\"%s\"}",
			nodeTypeName(te->getType()).c_str(),
			jesc(te->m_name.cString()).c_str());
	}
}

static void writeTransitionInfoJson(std::FILE* f, const hkbStateMachine::TransitionInfo& tr, GraphCtx& ctx)
{
	std::fprintf(f, "{\"event_id\":%d,\"event_name\":\"%s\",\"to_state_id\":%d,\"priority\":%d,\"flags\":%d",
		int(tr.m_eventId),
		jesc(ctx.evName(tr.m_eventId).c_str()).c_str(),
		int(tr.m_toStateId),
		int(tr.m_priority),
		int(tr.m_flags.get()));
	if (tr.m_flags.anyIsSet(hkbStateMachine::TransitionInfo::FLAG_USE_TRIGGER_INTERVAL))
	{
		std::fprintf(f, ",\"trigger_interval\":{\"enter_ev\":%d,\"exit_ev\":%d,\"enter_t\":%.4f,\"exit_t\":%.4f}",
			int(tr.m_triggerInterval.m_enterEventId), int(tr.m_triggerInterval.m_exitEventId),
			safeF(tr.m_triggerInterval.m_enterTime), safeF(tr.m_triggerInterval.m_exitTime));
	}
	if (tr.m_flags.anyIsSet(hkbStateMachine::TransitionInfo::FLAG_USE_INITIATE_INTERVAL))
	{
		std::fprintf(f, ",\"initiate_interval\":{\"enter_ev\":%d,\"exit_ev\":%d,\"enter_t\":%.4f,\"exit_t\":%.4f}",
			int(tr.m_initiateInterval.m_enterEventId), int(tr.m_initiateInterval.m_exitEventId),
			safeF(tr.m_initiateInterval.m_enterTime), safeF(tr.m_initiateInterval.m_exitTime));
	}
	std::fprintf(f, ",\"condition\":");
	writeConditionJson(f, tr.m_condition);
	std::fprintf(f, ",\"effect\":");
	writeTransitionEffectJson(f, tr.m_transition, ctx);
	std::fprintf(f, "}");
}

static void writeBoneWeightsJson(std::FILE* f, const hkbBoneWeightArray* bwa)
{
	if (!bwa || bwa->m_boneWeights.getSize() == 0)
	{
		std::fprintf(f, "null");
		return;
	}
	std::fprintf(f, "[");
	for (int i = 0; i < bwa->m_boneWeights.getSize(); ++i)
	{
		std::fprintf(f, "%.3f%s", safeF(bwa->m_boneWeights[i]), (i + 1 < bwa->m_boneWeights.getSize()) ? "," : "");
	}
	std::fprintf(f, "]");
}

static void writeBoneIndicesJson(std::FILE* f, const hkbBoneIndexArray* bia)
{
	if (!bia || bia->m_boneIndices.getSize() == 0)
	{
		std::fprintf(f, "null");
		return;
	}
	std::fprintf(f, "[");
	for (int i = 0; i < bia->m_boneIndices.getSize(); ++i)
	{
		std::fprintf(f, "%d%s", int(bia->m_boneIndices[i]), (i + 1 < bia->m_boneIndices.getSize()) ? "," : "");
	}
	std::fprintf(f, "]");
}

static void writeVec3Json(std::FILE* f, const hkVector4& v)
{
	std::fprintf(f, "[%.5f,%.5f,%.5f]", safeF(float(v(0))), safeF(float(v(1))), safeF(float(v(2))));
}

static void writeNodeJson(std::FILE* f, const hkbNode* node, int id, GraphCtx& ctx)
{
	std::string tname = nodeTypeName(node->getType());
	std::fprintf(f, "        {\"id\":%d,\"type\":\"%s\",\"name\":\"%s\",\"bindings\":",
		id, tname.c_str(), jesc(node->m_name.cString()).c_str());
	writeBindingsJson(f, node->getVariableBindings(), ctx);

	if (const hkbModifier* mod = hkDynCast<hkbModifier>(node))
	{
		std::fprintf(f, ",\"enable\":%s", mod->m_enable ? "true" : "false");
	}

	if (const hkbStateMachine* sm = hkDynCast<hkbStateMachine>(node))
	{
		std::fprintf(f, ",\"start_state_id\":%d,\"start_state_mode\":%d,\"return_prev_ev\":%d,\"random_ev\":%d,\"next_hi_ev\":%d,\"next_lo_ev\":%d,\"sync_var\":%d,\"max_sim_trans\":%d",
			int(sm->m_startStateId),
			int(sm->m_startStateMode),
			int(sm->m_returnToPreviousStateEventId),
			int(sm->m_randomTransitionEventId),
			int(sm->m_transitionToNextHigherStateEventId),
			int(sm->m_transitionToNextLowerStateEventId),
			int(sm->m_syncVariableIndex),
			int(sm->m_maxSimultaneousTransitions));

		std::fprintf(f, ",\"states\":[");
		for (int si = 0; si < sm->getNumStates(); ++si)
		{
			const hkbStateMachine::StateInfo& st = sm->getStateInfoByIndex(si);
			int gid = ctx.registerNode(st.getGenerator());
			std::fprintf(f, "{\"state_id\":%d,\"name\":\"%s\",\"gen\":%d,\"prob\":%.4f,\"enable\":%s,\"bindings\":",
				int(st.getStateId()),
				jesc(st.m_name.cString()).c_str(),
				gid,
				safeF(st.m_probability),
				st.m_enable ? "true" : "false");
			writeBindingsJson(f, st.getVariableBindings(), ctx);

			std::fprintf(f, ",\"enter_events\":[");
			if (st.m_enterNotifyEvents)
			{
				for (int ei = 0; ei < st.m_enterNotifyEvents->m_events.getSize(); ++ei)
				{
					int eid = st.m_enterNotifyEvents->m_events[ei].m_id;
					std::fprintf(f, "{\"id\":%d,\"name\":\"%s\"}%s", eid, jesc(ctx.evName(eid).c_str()).c_str(),
						(ei + 1 < st.m_enterNotifyEvents->m_events.getSize()) ? "," : "");
				}
			}
			std::fprintf(f, "],\"exit_events\":[");
			if (st.m_exitNotifyEvents)
			{
				for (int ei = 0; ei < st.m_exitNotifyEvents->m_events.getSize(); ++ei)
				{
					int eid = st.m_exitNotifyEvents->m_events[ei].m_id;
					std::fprintf(f, "{\"id\":%d,\"name\":\"%s\"}%s", eid, jesc(ctx.evName(eid).c_str()).c_str(),
						(ei + 1 < st.m_exitNotifyEvents->m_events.getSize()) ? "," : "");
				}
			}
			std::fprintf(f, "],\"transitions\":[");
			for (int ti = 0; ti < st.getNumTransitions(); ++ti)
			{
				writeTransitionInfoJson(f, st.getTransitionInfo(ti), ctx);
				if (ti + 1 < st.getNumTransitions()) std::fprintf(f, ",");
			}
			std::fprintf(f, "]}%s", (si + 1 < sm->getNumStates()) ? "," : "");
		}
		std::fprintf(f, "]");

		std::fprintf(f, ",\"wildcards\":[");
		if (hkArray<hkbStateMachine::TransitionInfo>* wcs = sm->getTransitionsFromAnyState())
		{
			for (int wi = 0; wi < wcs->getSize(); ++wi)
			{
				writeTransitionInfoJson(f, (*wcs)[wi], ctx);
				if (wi + 1 < wcs->getSize()) std::fprintf(f, ",");
			}
		}
		std::fprintf(f, "]");
	}
	else if (const hkbClipGenerator* cg = hkDynCast<hkbClipGenerator>(node))
	{
		std::fprintf(f, ",\"animation\":\"%s\",\"mode\":%d,\"speed\":%.5f,\"start_time\":%.5f,\"enforced_duration\":%.5f,\"user_frac\":%.5f,\"flags\":%d,\"triggers\":[",
			jesc(cg->m_animationName.cString()).c_str(),
			int(cg->m_mode),
			safeF(cg->m_playbackSpeed),
			safeF(cg->m_startTime),
			safeF(cg->m_enforcedDuration),
			safeF(cg->m_userControlledTimeFraction),
			int(cg->m_flags));
		if (cg->m_triggers)
		{
			const auto& trs = cg->m_triggers->m_triggers;
			for (int ti = 0; ti < trs.getSize(); ++ti)
			{
				int eid = trs[ti].m_event.m_id;
				std::fprintf(f, "{\"t\":%.5f,\"ev_id\":%d,\"ev_name\":\"%s\",\"rel_end\":%s,\"acyclic\":%s}%s",
					safeF(trs[ti].m_localTime), eid, jesc(ctx.evName(eid).c_str()).c_str(),
					trs[ti].m_relativeToEndOfClip ? "true" : "false",
					trs[ti].m_acyclic ? "true" : "false",
					(ti + 1 < trs.getSize()) ? "," : "");
			}
		}
		std::fprintf(f, "]");
	}
	else if (const hkbBlenderGenerator* bg = hkDynCast<hkbBlenderGenerator>(node))
	{
		std::fprintf(f, ",\"flags\":%d,\"ref_threshold\":%.4f,\"blend_param\":%.4f,\"subtract_last\":%s,\"children\":[",
			int(bg->m_flags),
			safeF(bg->m_referencePoseWeightThreshold),
			safeF(bg->m_blendParameter),
			bg->m_subtractLastChild ? "true" : "false");
		for (int ci = 0; ci < bg->m_children.getSize(); ++ci)
		{
			const hkbBlenderGeneratorChild* ch = bg->m_children[ci];
			int cid = ch ? ctx.registerNode(ch->m_generator) : -1;
			std::fprintf(f, "{\"gen\":%d,\"weight\":%.5f,\"wfm_weight\":%.5f,\"bindings\":",
				cid, ch ? safeF(ch->m_weight) : 0.0f, ch ? safeF(ch->m_worldFromModelWeight) : 1.0f);
			writeBindingsJson(f, ch ? ch->getVariableBindings() : HK_NULL, ctx);
			std::fprintf(f, ",\"bone_weights\":");
			writeBoneWeightsJson(f, ch ? ch->m_boneWeights.val() : HK_NULL);
			std::fprintf(f, "}%s", (ci + 1 < bg->m_children.getSize()) ? "," : "");
		}
		std::fprintf(f, "]");
	}
	else if (const hkbLayerGenerator* lg = hkDynCast<hkbLayerGenerator>(node))
	{
		std::fprintf(f, ",\"flags\":%d,\"layers\":[", int(lg->m_flags.get()));
		for (int li = 0; li < lg->m_layers.getSize(); ++li)
		{
			const hkbLayer* ly = lg->m_layers[li];
			int lid = ly ? ctx.registerNode(ly->m_generator) : -1;
			std::fprintf(f, "{\"gen\":%d,\"weight\":%.5f,\"fade_in\":%.4f,\"fade_out\":%.4f,\"on_ev\":%d,\"off_ev\":%d,\"on_default\":%s,\"use_motion\":%s,\"bindings\":",
				lid,
				ly ? safeF(ly->m_blendingControlData.m_weight) : 1.0f,
				ly ? safeF(ly->m_blendingControlData.m_fadeInDuration) : 0.0f,
				ly ? safeF(ly->m_blendingControlData.m_fadeOutDuration) : 0.0f,
				ly ? int(ly->m_blendingControlData.m_onEventId) : -1,
				ly ? int(ly->m_blendingControlData.m_offEventId) : -1,
				(ly && ly->m_blendingControlData.m_onByDefault) ? "true" : "false",
				(ly && ly->m_useMotion) ? "true" : "false");
			writeBindingsJson(f, ly ? ly->getVariableBindings() : HK_NULL, ctx);
			std::fprintf(f, ",\"bone_weights\":");
			writeBoneWeightsJson(f, ly ? ly->m_boneWeights.val() : HK_NULL);
			std::fprintf(f, "}%s", (li + 1 < lg->m_layers.getSize()) ? "," : "");
		}
		std::fprintf(f, "]");
	}
	else if (const hkbManualSelectorGenerator* msg = hkDynCast<hkbManualSelectorGenerator>(node))
	{
		std::fprintf(f, ",\"selected_idx\":%d,\"generators\":[", int(msg->m_selectedGeneratorIndex));
		for (int gi = 0; gi < msg->m_generators.getSize(); ++gi)
		{
			int gid = ctx.registerNode(msg->m_generators[gi]);
			std::fprintf(f, "%d%s", gid, (gi + 1 < msg->m_generators.getSize()) ? "," : "");
		}
		std::fprintf(f, "]");
	}
	else if (const hkbModifierGenerator* mg = hkDynCast<hkbModifierGenerator>(node))
	{
		int mid = ctx.registerNode(mg->m_modifier);
		int gid = ctx.registerNode(mg->m_generator);
		std::fprintf(f, ",\"modifier\":%d,\"generator\":%d", mid, gid);
	}
	else if (const hkbBehaviorReferenceGenerator* brg = hkDynCast<hkbBehaviorReferenceGenerator>(node))
	{
		std::fprintf(f, ",\"behavior_name\":\"%s\"", jesc(brg->m_behaviorName.cString()).c_str());
	}
	else if (const hkbModifierList* ml = hkDynCast<hkbModifierList>(node))
	{
		std::fprintf(f, ",\"modifiers\":[");
		for (int mi = 0; mi < ml->m_modifiers.getSize(); ++mi)
		{
			int mid = ctx.registerNode(ml->m_modifiers[mi]);
			std::fprintf(f, "%d%s", mid, (mi + 1 < ml->m_modifiers.getSize()) ? "," : "");
		}
		std::fprintf(f, "]");
	}
	else if (const hkbEvaluateExpressionModifier* eem = hkDynCast<hkbEvaluateExpressionModifier>(node))
	{
		std::fprintf(f, ",\"expressions\":[");
		if (eem->m_expressions)
		{
			const auto& exs = eem->m_expressions->m_expressionsData;
			for (int ei = 0; ei < exs.getSize(); ++ei)
			{
				std::fprintf(f, "{\"expr\":\"%s\",\"var_idx\":%d,\"var_name\":\"%s\",\"ev_idx\":%d,\"ev_name\":\"%s\",\"ev_mode\":%d}%s",
					jesc(exs[ei].m_expression.cString()).c_str(),
					int(exs[ei].m_assignmentVariableIndex),
					jesc(ctx.varName(exs[ei].m_assignmentVariableIndex).c_str()).c_str(),
					int(exs[ei].m_assignmentEventIndex),
					jesc(ctx.evName(exs[ei].m_assignmentEventIndex).c_str()).c_str(),
					int(exs[ei].m_eventMode),
					(ei + 1 < exs.getSize()) ? "," : "");
			}
		}
		std::fprintf(f, "]");
	}
	else if (const hkbEventsFromRangeModifier* efrm = hkDynCast<hkbEventsFromRangeModifier>(node))
	{
		std::fprintf(f, ",\"input_value\":%.5f,\"lower_bound\":%.5f,\"ranges\":[",
			safeF(efrm->m_inputValue), safeF(efrm->m_lowerBound));
		if (efrm->m_eventRanges)
		{
			const auto& rgs = efrm->m_eventRanges->m_eventData;
			for (int ri = 0; ri < rgs.getSize(); ++ri)
			{
				int eid = rgs[ri].m_event.m_id;
				std::fprintf(f, "{\"upper\":%.5f,\"ev_id\":%d,\"ev_name\":\"%s\",\"ev_mode\":%d}%s",
					safeF(rgs[ri].m_upperBound), eid, jesc(ctx.evName(eid).c_str()).c_str(),
					int(rgs[ri].m_eventMode),
					(ri + 1 < rgs.getSize()) ? "," : "");
			}
		}
		std::fprintf(f, "]");
	}
	else if (const hkbEventDrivenModifier* edm = hkDynCast<hkbEventDrivenModifier>(node))
	{
		int cid = ctx.registerNode(edm->m_modifier);
		std::fprintf(f, ",\"modifier\":%d,\"activate_ev\":%d,\"activate_ev_name\":\"%s\",\"deactivate_ev\":%d,\"deactivate_ev_name\":\"%s\",\"active_default\":%s",
			cid, int(edm->m_activateEventId), jesc(ctx.evName(edm->m_activateEventId).c_str()).c_str(),
			int(edm->m_deactivateEventId), jesc(ctx.evName(edm->m_deactivateEventId).c_str()).c_str(),
			edm->m_activeByDefault ? "true" : "false");
	}
	else if (const hkbTimerModifier* tm = hkDynCast<hkbTimerModifier>(node))
	{
		int eid = tm->m_alarmEvent.m_id;
		std::fprintf(f, ",\"alarm_time\":%.5f,\"alarm_ev\":%d,\"alarm_ev_name\":\"%s\"",
			safeF(tm->m_alarmTimeSeconds), eid, jesc(ctx.evName(eid).c_str()).c_str());
	}
	else if (const hkbDelayedModifier* dm = hkDynCast<hkbDelayedModifier>(node))
	{
		int cid = ctx.registerNode(dm->m_modifier);
		std::fprintf(f, ",\"modifier\":%d,\"delay\":%.5f,\"duration\":%.5f",
			cid, safeF(dm->m_delaySeconds), safeF(dm->m_durationSeconds));
	}
	else if (const hkbDampingModifier* damp = hkDynCast<hkbDampingModifier>(node))
	{
		std::fprintf(f, ",\"kp\":%.5f,\"ki\":%.5f,\"kd\":%.5f,\"scalar\":%s,\"vector\":%s,\"raw_val\":%.5f",
			safeF(damp->m_kP), safeF(damp->m_kI), safeF(damp->m_kD),
			damp->m_enableScalarDamping ? "true" : "false",
			damp->m_enableVectorDamping ? "true" : "false",
			safeF(damp->m_rawValue));
	}
	else if (const hkbLookAtModifier* lam = hkDynCast<hkbLookAtModifier>(node))
	{
		std::fprintf(f, ",\"head_idx\":%d,\"neck_idx\":%d,\"limit_deg\":%.3f,\"on_gain\":%.4f,\"off_gain\":%.4f,\"new_target_gain\":%.4f,\"is_on\":%s,\"target_ws\":",
			int(lam->m_headIndex), int(lam->m_neckIndex),
			safeF(lam->m_limitAngleDegrees), safeF(lam->m_onGain), safeF(lam->m_offGain),
			safeF(lam->m_newTargetGain), lam->m_isOn ? "true" : "false");
		writeVec3Json(f, lam->m_targetWS);
	}
	else if (const hkbTwistModifier* tw = hkDynCast<hkbTwistModifier>(node))
	{
		std::fprintf(f, ",\"start_bone\":%d,\"end_bone\":%d,\"twist_deg\":%.4f,\"is_additive\":%s,\"axis\":",
			int(tw->m_startBoneIndex), int(tw->m_endBoneIndex),
			safeF(tw->m_twistAngle), tw->m_isAdditive ? "true" : "false");
		writeVec3Json(f, tw->m_axisOfRotation);
	}
	else if (const hkbMirrorModifier* mm = hkDynCast<hkbMirrorModifier>(node))
	{
		std::fprintf(f, ",\"is_additive\":%s", mm->m_isAdditive ? "true" : "false");
	}
	else if (const hkbFootIkControlsModifier* fik = hkDynCast<hkbFootIkControlsModifier>(node))
	{
		std::fprintf(f, ",\"on_off_gain\":%.4f,\"ground_asc_gain\":%.4f,\"ground_desc_gain\":%.4f,\"foot_planted_gain\":%.4f,\"foot_raised_gain\":%.4f,\"legs\":%d",
			safeF(fik->m_controlData.m_gains.m_onOffGain),
			safeF(fik->m_controlData.m_gains.m_groundAscendingGain),
			safeF(fik->m_controlData.m_gains.m_groundDescendingGain),
			safeF(fik->m_controlData.m_gains.m_footPlantedGain),
			safeF(fik->m_controlData.m_gains.m_footRaisedGain),
			int(fik->m_legs.getSize()));
	}
	else if (const hkbPoweredRagdollControlsModifier* prm = hkDynCast<hkbPoweredRagdollControlsModifier>(node))
	{
		std::fprintf(f, ",\"max_force\":%.4f,\"tau\":%.4f,\"damping\":%.4f,\"prop_recovery\":%.4f,\"const_recovery\":%.4f,\"bones\":",
			safeF(prm->m_controlData.m_maxForce), safeF(prm->m_controlData.m_tau),
			safeF(prm->m_controlData.m_damping), safeF(prm->m_controlData.m_proportionalRecoveryVelocity),
			safeF(prm->m_controlData.m_constantRecoveryVelocity));
		writeBoneIndicesJson(f, prm->m_bones);
		std::fprintf(f, ",\"bone_weights\":");
		writeBoneWeightsJson(f, prm->m_boneWeights);
	}
	else if (const hkbRigidBodyRagdollControlsModifier* rbm = hkDynCast<hkbRigidBodyRagdollControlsModifier>(node))
	{
		const hkbKeyFrameControlData& kf = rbm->m_controlData.m_keyFrameControlData;
		std::fprintf(f, ",\"hierarchy_gain\":%.4f,\"vel_damping\":%.4f,\"accel_gain\":%.4f,\"vel_gain\":%.4f,\"pos_gain\":%.4f,\"anim_blend\":%.4f,\"bones\":",
			safeF(kf.m_hierarchyGain),
			safeF(kf.m_velocityDamping),
			safeF(kf.m_accelerationGain),
			safeF(kf.m_velocityGain),
			safeF(kf.m_positionGain),
			safeF(rbm->m_animationBlendFraction));
		writeBoneIndicesJson(f, rbm->m_bones);
	}
	else if (const hkbKeyframeBonesModifier* kbm = hkDynCast<hkbKeyframeBonesModifier>(node))
	{
		std::fprintf(f, ",\"bones\":");
		writeBoneIndicesJson(f, kbm->m_keyframedBonesList);
	}
	else if (const hkbAttachmentModifier* am = hkDynCast<hkbAttachmentModifier>(node))
	{
		std::fprintf(f, ",\"attacher_attach_ev\":%d,\"attacher_detach_ev\":%d",
			int(am->m_sendToAttacherOnAttach.m_id), int(am->m_sendToAttacherOnDetach.m_id));
	}
	else if (const hkbGetUpModifier* gum = hkDynCast<hkbGetUpModifier>(node))
	{
		std::fprintf(f, ",\"duration\":%.4f,\"align_duration\":%.4f,\"root_bone\":%d",
			safeF(gum->m_duration), safeF(gum->m_alignWithGroundDuration), int(gum->m_rootBoneIndex));
	}
	else if (const hkbScriptGenerator* sg = hkDynCast<hkbScriptGenerator>(node))
	{
		int cid = ctx.registerNode(sg->m_child);
		std::fprintf(f, ",\"child\":%d,\"on_activate\":\"%s\",\"on_pre_update\":\"%s\",\"on_generate\":\"%s\",\"on_handle_event\":\"%s\",\"on_deactivate\":\"%s\"",
			cid,
			jesc(sg->m_onActivateScript.cString()).c_str(),
			jesc(sg->m_onPreUpdateScript.cString()).c_str(),
			jesc(sg->m_onGenerateScript.cString()).c_str(),
			jesc(sg->m_onHandleEventScript.cString()).c_str(),
			jesc(sg->m_onDeactivateScript.cString()).c_str());
	}
	else if (const hkbRotateCharacterModifier* rcm = hkDynCast<hkbRotateCharacterModifier>(node))
	{
		std::fprintf(f, ",\"deg_per_sec\":%.5f,\"speed_mult\":%.5f,\"axis\":",
			safeF(rcm->m_degreesPerSecond), safeF(rcm->m_speedMultiplier));
		writeVec3Json(f, rcm->m_axisOfRotation);
	}
	else if (const hkbMoveCharacterModifier* mcm = hkDynCast<hkbMoveCharacterModifier>(node))
	{
		std::fprintf(f, ",\"offset_per_sec\":");
		writeVec3Json(f, mcm->m_offsetPerSecondMS);
	}
	else if (const hkbMoveBoneAttachmentModifier* mbam = hkDynCast<hkbMoveBoneAttachmentModifier>(node))
	{
		std::fprintf(f, ",\"activate_ev\":%d,\"activate_ev_name\":\"%s\",\"attachment\":\"%s\",\"local_frame\":\"%s\"",
			int(mbam->m_activateEventId), jesc(ctx.evName(mbam->m_activateEventId).c_str()).c_str(),
			jesc(mbam->m_attachment.cString()).c_str(), jesc(mbam->m_localFrame.cString()).c_str());
	}
	else if (const hkbSenseHandleModifier* shm = hkDynCast<hkbSenseHandleModifier>(node))
	{
		std::fprintf(f, ",\"min_dist\":%.4f,\"max_dist\":%.4f,\"local_frame\":\"%s\",\"sensor_local_frame\":\"%s\",\"sensor_anim_bone\":%d,\"sensor_ragdoll_bone\":%d,\"sensing_mode\":%d,\"keep_first\":%s,\"sensor_offset\":",
			safeF(shm->m_minDistance), safeF(shm->m_maxDistance),
			jesc(shm->m_localFrameName.cString()).c_str(),
			jesc(shm->m_sensorLocalFrameName.cString()).c_str(),
			int(shm->m_sensorAnimationBoneIndex), int(shm->m_sensorRagdollBoneIndex),
			int(shm->m_sensingMode), shm->m_keepFirstSensedHandle ? "true" : "false");
		writeVec3Json(f, shm->m_sensorLocalOffset);
		std::fprintf(f, ",\"ranges\":[");
		for (int ri = 0; ri < shm->m_ranges.getSize(); ++ri)
		{
			const auto& rg = shm->m_ranges[ri];
			int eid = rg.m_event.m_id;
			std::fprintf(f, "{\"min\":%.4f,\"max\":%.4f,\"ev_id\":%d,\"ev_name\":\"%s\",\"ignore\":%s}%s",
				safeF(rg.m_minDistance), safeF(rg.m_maxDistance), eid, jesc(ctx.evName(eid).c_str()).c_str(),
				rg.m_ignoreHandle ? "true" : "false",
				(ri + 1 < shm->m_ranges.getSize()) ? "," : "");
		}
		std::fprintf(f, "]");
	}
	else if (const hkbGetHandleOnBoneModifier* ghb = hkDynCast<hkbGetHandleOnBoneModifier>(node))
	{
		std::fprintf(f, ",\"local_frame\":\"%s\",\"anim_bone\":%d,\"ragdoll_bone\":%d",
			jesc(ghb->m_localFrameName.cString()).c_str(),
			int(ghb->m_animationBoneIndex), int(ghb->m_ragdollBoneIndex));
	}
	else if (const hkbEvaluateHandleModifier* ehm = hkDynCast<hkbEvaluateHandleModifier>(node))
	{
		std::fprintf(f, ",\"extrap_dt\":%.5f,\"change_speed\":%.5f,\"change_mode\":%d",
			safeF(ehm->m_extrapolationTimeStep), safeF(ehm->m_handleChangeSpeed), int(ehm->m_handleChangeMode));
	}
	else if (const hkbBodyIkControlsModifier* bik = hkDynCast<hkbBodyIkControlsModifier>(node))
	{
		std::fprintf(f, ",\"profile_name\":\"%s\",\"controls\":[",
			jesc(bik->m_profileName.cString()).c_str());
		for (int ci = 0; ci < bik->m_controlDatas.getSize(); ++ci)
		{
			const auto& cd = bik->m_controlDatas[ci];
			std::fprintf(f, "{\"point\":\"%s\",\"effectors\":%d,\"anim_influence\":%.4f,\"trans_dur\":%.4f,\"target_pos\":",
				jesc(cd.m_controlPointName.cString()).c_str(),
				int(cd.m_effectors.get()), safeF(cd.m_animationInfluence), safeF(cd.m_targetTransitionDuration));
			writeVec3Json(f, cd.m_targetPosition);
			const hkQuaternion& tq = cd.m_targetRotation;
			std::fprintf(f, ",\"target_rot\":[%.5f,%.5f,%.5f,%.5f]}%s",
				safeF(float(tq.m_vec(0))), safeF(float(tq.m_vec(1))), safeF(float(tq.m_vec(2))), safeF(float(tq.m_vec(3))),
				(ci + 1 < bik->m_controlDatas.getSize()) ? "," : "");
		}
		std::fprintf(f, "]");
	}
	else if (const hkbPinBonesGenerator* pbg = hkDynCast<hkbPinBonesGenerator>(node))
	{
		int refId = ctx.registerNode(pbg->m_referenceFrameGenerator);
		int pinId = ctx.registerNode(pbg->m_pinnedGenerator);
		std::fprintf(f, ",\"ref_gen\":%d,\"pinned_gen\":%d,\"fraction\":%.4f,\"bones\":",
			refId, pinId, safeF(pbg->m_fraction));
		writeBoneIndicesJson(f, pbg->m_boneIndices);
	}
	else if (const hkbParametricMotionGenerator* pmg = hkDynCast<hkbParametricMotionGenerator>(node))
	{
		std::fprintf(f, ",\"x_param\":%.5f,\"y_param\":%.5f,\"motion_space\":%d,\"generators\":[",
			safeF(pmg->m_xAxisParameterValue), safeF(pmg->m_yAxisParameterValue), int(pmg->m_motionSpace));
		for (int gi = 0; gi < pmg->m_generators.getSize(); ++gi)
		{
			int cid = ctx.registerNode(pmg->m_generators[gi]);
			std::fprintf(f, "%d%s", cid, (gi + 1 < pmg->m_generators.getSize()) ? "," : "");
		}
		std::fprintf(f, "]");
	}
	else if (const hkbSequence* seq = hkDynCast<hkbSequence>(node))
	{
		const hkbSequenceStringData* ssd = const_cast<hkbSequence*>(seq)->getStringData();
		std::fprintf(f, ",\"enable_ev\":%d,\"enable_ev_name\":\"%s\",\"disable_ev\":%d,\"disable_ev_name\":\"%s\"",
			int(seq->m_enableEventId), jesc(ctx.evName(seq->m_enableEventId).c_str()).c_str(),
			int(seq->m_disableEventId), jesc(ctx.evName(seq->m_disableEventId).c_str()).c_str());
		std::fprintf(f, ",\"event_tracks\":[");
		for (int ti = 0; ti < seq->m_eventSequencedData.getSize(); ++ti)
		{
			const hkbEventSequencedData* ed = seq->m_eventSequencedData[ti];
			std::fprintf(f, "[");
			if (ed)
			{
				for (int ei = 0; ei < ed->m_events.getSize(); ++ei)
				{
					int eid = ed->m_events[ei].m_event.m_id;
					std::string enm = (ssd && eid >= 0 && eid < ssd->m_eventNames.getSize() && ssd->m_eventNames[eid].cString())
						? ssd->m_eventNames[eid].cString() : ctx.evName(eid);
					std::fprintf(f, "{\"t\":%.5f,\"ev_id\":%d,\"ev_name\":\"%s\"}%s",
						safeF(ed->m_events[ei].m_time), eid, jesc(enm.c_str()).c_str(),
						(ei + 1 < ed->m_events.getSize()) ? "," : "");
				}
			}
			std::fprintf(f, "]%s", (ti + 1 < seq->m_eventSequencedData.getSize()) ? "," : "");
		}
		std::fprintf(f, "],\"real_tracks\":[");
		for (int ti = 0; ti < seq->m_realVariableSequencedData.getSize(); ++ti)
		{
			const hkbRealVariableSequencedData* rd = seq->m_realVariableSequencedData[ti];
			int vi = rd ? int(rd->m_variableIndex) : -1;
			std::string vnm = (ssd && vi >= 0 && vi < ssd->m_variableNames.getSize() && ssd->m_variableNames[vi].cString())
				? ssd->m_variableNames[vi].cString() : ctx.varName(vi);
			std::fprintf(f, "{\"var_idx\":%d,\"var_name\":\"%s\",\"samples\":[", vi, jesc(vnm.c_str()).c_str());
			if (rd)
			{
				for (int si = 0; si < rd->m_samples.getSize(); ++si)
					std::fprintf(f, "[%.5f,%.5f]%s", safeF(rd->m_samples[si].m_time), safeF(rd->m_samples[si].m_value),
						(si + 1 < rd->m_samples.getSize()) ? "," : "");
			}
			std::fprintf(f, "]}%s", (ti + 1 < seq->m_realVariableSequencedData.getSize()) ? "," : "");
		}
		std::fprintf(f, "],\"bool_tracks\":[");
		for (int ti = 0; ti < seq->m_boolVariableSequencedData.getSize(); ++ti)
		{
			const hkbBoolVariableSequencedData* bd = seq->m_boolVariableSequencedData[ti];
			int vi = bd ? int(bd->m_variableIndex) : -1;
			std::string vnm = (ssd && vi >= 0 && vi < ssd->m_variableNames.getSize() && ssd->m_variableNames[vi].cString())
				? ssd->m_variableNames[vi].cString() : ctx.varName(vi);
			std::fprintf(f, "{\"var_idx\":%d,\"var_name\":\"%s\",\"samples\":[", vi, jesc(vnm.c_str()).c_str());
			if (bd)
			{
				for (int si = 0; si < bd->m_samples.getSize(); ++si)
					std::fprintf(f, "[%.5f,%s]%s", safeF(bd->m_samples[si].m_time), bd->m_samples[si].m_value ? "true" : "false",
						(si + 1 < bd->m_samples.getSize()) ? "," : "");
			}
			std::fprintf(f, "]}%s", (ti + 1 < seq->m_boolVariableSequencedData.getSize()) ? "," : "");
		}
		std::fprintf(f, "],\"int_tracks\":[");
		for (int ti = 0; ti < seq->m_intVariableSequencedData.getSize(); ++ti)
		{
			const hkbIntVariableSequencedData* idata = seq->m_intVariableSequencedData[ti];
			int vi = idata ? int(idata->m_variableIndex) : -1;
			std::string vnm = (ssd && vi >= 0 && vi < ssd->m_variableNames.getSize() && ssd->m_variableNames[vi].cString())
				? ssd->m_variableNames[vi].cString() : ctx.varName(vi);
			std::fprintf(f, "{\"var_idx\":%d,\"var_name\":\"%s\",\"samples\":[", vi, jesc(vnm.c_str()).c_str());
			if (idata)
			{
				for (int si = 0; si < idata->m_samples.getSize(); ++si)
					std::fprintf(f, "[%.5f,%d]%s", safeF(idata->m_samples[si].m_time), int(idata->m_samples[si].m_value),
						(si + 1 < idata->m_samples.getSize()) ? "," : "");
			}
			std::fprintf(f, "]}%s", (ti + 1 < seq->m_intVariableSequencedData.getSize()) ? "," : "");
		}
		std::fprintf(f, "]");
	}
	else
	{
		// Generic children fallback for any other generator/modifier
		hkArray<hkbNodeChildInfo> childList;
		hkbNode::ChildrenInfo cinfo(childList);
		const_cast<hkbNode*>(node)->getChildren(hkbNode::FLAG_IGNORE_REFERENCED_BEHAVIORS, cinfo);
		if (childList.getSize() > 0)
		{
			std::fprintf(f, ",\"children_ids\":[");
			for (int ci = 0; ci < childList.getSize(); ++ci)
			{
				int cid = ctx.registerNode(childList[ci].m_node);
				std::fprintf(f, "%d%s", cid, (ci + 1 < childList.getSize()) ? "," : "");
			}
			std::fprintf(f, "]");
		}
	}

	std::fprintf(f, "}");
}

static bool extractGraphEntry(std::FILE* f, const std::string& key, const std::string& hktPath, bool firstEntry)
{
	hkSerializeUtil::ErrorDetails err;
	hkObjectResource* res = hkSerializeUtil::loadOnHeap(hktPath.c_str(), &err);
	if (!res)
	{
		std::fprintf(stderr, "[WARN] Skip unreadable %s (%s)\n", hktPath.c_str(), err.defaultMessage.cString());
		return false;
	}
	hkRootLevelContainer* rlc = res->getContents<hkRootLevelContainer>();
	const hkbBehaviorGraph* bg = rlc ? rlc->findObject<hkbBehaviorGraph>() : HK_NULL;
	if (!bg || !bg->getRootGenerator())
	{
		res->removeReference();
		return false;
	}

	const hkbBehaviorGraphData* data = bg->getData();
	const hkbBehaviorGraphStringData* sd = data ? const_cast<hkbBehaviorGraphData*>(data)->getStringData() : HK_NULL;

	GraphCtx ctx;
	ctx.strData = sd;
	int rootId = ctx.registerNode(bg->getRootGenerator());

	if (!firstEntry) std::fprintf(f, ",\n");
	std::fprintf(f, "    \"%s\": {\n", jesc(key.c_str()).c_str());
	std::fprintf(f, "      \"graph_name\": \"%s\",\n", jesc(bg->m_name.cString()).c_str());
	std::fprintf(f, "      \"root_node\": %d,\n", rootId);

	// Variables
	std::fprintf(f, "      \"variables\": [");
	if (data && sd)
	{
		int nv = data->m_variableInfos.getSize();
		const hkbVariableValueSet* initVals = data->m_variableInitialValues;
		int nInit = initVals ? initVals->getNumValues() : 0;
		for (int i = 0; i < nv; ++i)
		{
			const hkbVariableInfo& vi = data->m_variableInfos[i];
			std::string nm = (i < sd->m_variableNames.getSize() && sd->m_variableNames[i].cString()) ? sd->m_variableNames[i].cString() : ("var_" + std::to_string(i));
			std::fprintf(f, "{\"idx\":%d,\"name\":\"%s\",\"type\":\"%s\",\"default\":",
				i, jesc(nm.c_str()).c_str(), varTypeName(vi.m_type).c_str());
			if (initVals && i < nInit)
			{
				if (vi.m_type == hkbVariableInfo::VARIABLE_TYPE_BOOL)
					std::fprintf(f, "%s", initVals->getWord<hkBool>(i) ? "true" : "false");
				else if (vi.m_type == hkbVariableInfo::VARIABLE_TYPE_INT8 || vi.m_type == hkbVariableInfo::VARIABLE_TYPE_INT16 || vi.m_type == hkbVariableInfo::VARIABLE_TYPE_INT32)
					std::fprintf(f, "%d", int(initVals->getWord<hkInt32>(i)));
				else if (vi.m_type == hkbVariableInfo::VARIABLE_TYPE_REAL)
					std::fprintf(f, "%.5f", safeF(initVals->getWord<hkReal>(i)));
				else if (vi.isQuad())
				{
					int qIdx = initVals->getWord<int>(i);
					if (qIdx >= 0 && qIdx < 4096)
					{
						const hkVector4& qv = initVals->getQuad<hkVector4>(i);
						std::fprintf(f, "[%.5f,%.5f,%.5f,%.5f]",
							safeF(float(qv(0))), safeF(float(qv(1))), safeF(float(qv(2))), safeF(float(qv(3))));
					}
					else std::fprintf(f, "[0,0,0,0]");
				}
				else
					std::fprintf(f, "0");
			}
			else
			{
				std::fprintf(f, "0");
			}
			std::fprintf(f, "}%s", (i + 1 < nv) ? "," : "");
		}
	}
	std::fprintf(f, "],\n");

	// Character properties
	std::fprintf(f, "      \"character_properties\": [");
	if (data && sd)
	{
		int np = data->m_characterPropertyInfos.getSize();
		for (int i = 0; i < np; ++i)
		{
			std::string nm = (i < sd->m_characterPropertyNames.getSize() && sd->m_characterPropertyNames[i].cString()) ? sd->m_characterPropertyNames[i].cString() : ("prop_" + std::to_string(i));
			std::fprintf(f, "{\"idx\":%d,\"name\":\"%s\",\"type\":\"%s\"}%s",
				i, jesc(nm.c_str()).c_str(), varTypeName(data->m_characterPropertyInfos[i].m_type).c_str(),
				(i + 1 < np) ? "," : "");
		}
	}
	std::fprintf(f, "],\n");

	// Events
	std::fprintf(f, "      \"events\": [");
	if (sd)
	{
		for (int i = 0; i < sd->m_eventNames.getSize(); ++i)
		{
			std::fprintf(f, "\"%s\"%s", jesc(sd->m_eventNames[i].cString()).c_str(),
				(i + 1 < sd->m_eventNames.getSize()) ? "," : "");
		}
	}
	std::fprintf(f, "],\n");

	// Attributes
	std::fprintf(f, "      \"attributes\": [");
	if (data && sd)
	{
		int na = sd->m_attributeNames.getSize();
		for (int i = 0; i < na; ++i)
		{
			float dv = (i < data->m_attributeDefaults.getSize()) ? safeF(data->m_attributeDefaults[i]) : 0.0f;
			std::fprintf(f, "{\"idx\":%d,\"name\":\"%s\",\"default\":%.4f}%s",
				i, jesc(sd->m_attributeNames[i].cString()).c_str(), dv, (i + 1 < na) ? "," : "");
		}
	}
	std::fprintf(f, "],\n");

	// BFS over all reachable nodes (registerNode appends new children dynamically)
	std::fprintf(f, "      \"nodes\": [\n");
	for (size_t ni = 0; ni < ctx.orderedNodes.size(); ++ni)
	{
		if (ni > 0) std::fprintf(f, ",\n");
		writeNodeJson(f, ctx.orderedNodes[ni], int(ni), ctx);
	}
	std::fprintf(f, "\n      ]\n");
	std::fprintf(f, "    }");

	res->removeReference();
	return true;
}

int main(int argc, char** argv)
{
	bool singleMode = (argc >= 5 && std::strcmp(argv[1], "--single") == 0);
	bool batchMode = (argc >= 4 && std::strcmp(argv[1], "--batch") == 0);
	if (!singleMode && !batchMode)
	{
		std::fprintf(stderr, "Usage: %s --batch <list.tsv> <out.json> | --single <key> <in.hkt> <out.json>\n", argv[0]);
		return 1;
	}

	PlatformInit();
	hkMemoryRouter* memoryRouter = hkMemoryInitUtil::initDefault(hkMallocAllocator::m_defaultMallocAllocator, hkMemorySystem::FrameInfo(32 * 1024 * 1024));
	hkBaseSystem::init(memoryRouter, reportErr);
	hkError::replaceInstance(new SilentNonBreakingError());

	if (singleMode)
	{
		std::FILE* out = std::fopen(argv[4], "wb");
		if (!out) return 3;
		std::fprintf(out, "{\n");
		bool ok = extractGraphEntry(out, argv[2], argv[3], true);
		std::fprintf(out, "\n}\n");
		std::fclose(out);
		hkBaseSystem::quit();
		hkMemoryInitUtil::quit();
		return ok ? 0 : 4;
	}

	std::ifstream in(argv[2]);
	if (!in)
	{
		std::fprintf(stderr, "[ERROR] Cannot open batch list: %s\n", argv[2]);
		return 2;
	}

	std::FILE* out = std::fopen(argv[3], "wb");
	if (!out)
	{
		std::fprintf(stderr, "[ERROR] Cannot open output JSON: %s\n", argv[3]);
		return 3;
	}

	std::fprintf(out, "{\n");
	std::fprintf(out, "  \"schema\": \"havok-hkb-graph-topology-v1\",\n");
	std::fprintf(out, "  \"contains_sdk_hkt_runtime_dep\": false,\n");
	std::fprintf(out, "  \"contains_baked_poses\": false,\n");
	std::fprintf(out, "  \"graphs\": {\n");

	int extracted = 0;
	std::string line;
	while (std::getline(in, line))
	{
		if (line.empty()) continue;
		size_t tab = line.find('\t');
		if (tab == std::string::npos) continue;
		std::string key = line.substr(0, tab);
		std::string path = line.substr(tab + 1);
		while (!path.empty() && (path.back() == '\r' || path.back() == '\n')) path.pop_back();
		if (extractGraphEntry(out, key, path, extracted == 0))
		{
			extracted++;
		}
	}

	std::fprintf(out, "\n  },\n");
	std::fprintf(out, "  \"total_graphs\": %d\n", extracted);
	std::fprintf(out, "}\n");
	std::fclose(out);

	std::fprintf(stdout, "[OK] Extracted %d official Havok hkbBehaviorGraph topologies -> %s\n", extracted, argv[3]);

	hkBaseSystem::quit();
	hkMemoryInitUtil::quit();
	return 0;
}
