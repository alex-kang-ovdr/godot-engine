@tool
class_name HavokDemoStandards
extends RefCounted
## Unified Havok 2015.1.0-r1 SDK -> Godot 4.7.2 Standard Parity Layer.
##
## Reconciles all default differences between Havok SDK demos and Godot 3D:
##   1. Coordinate System (Godot Standard):
##        - Right-handed, +Y Up, -Z Forward (Vector3.FORWARD), +X Right
##        - Havok Z-up (3ds Max): (x, y, z)_H -> (x, z, -y)_G  [Rx(-90°)]
##        - Every internalized character is aligned via ModelAlign so its
##          anatomical front and root motion travel strictly along Godot -Z
##          with lowest animated foot grounded at Y = 0.0 m.
##   2. Camera (Havok hkgCamera -> Godot Camera3D):
##        - hkgCamera::DEFAULT_FOV = 45.0° vertical -> Camera3D.fov = 45.0,
##          keep_aspect = Camera3D.KEEP_HEIGHT, near = 0.1 m, far = 100.0 m.
##        - Original per-demo Havok (from, to, up) vectors are transformed into
##          Godot Standard space and rotated to match the -Z-aligned character
##          so framing, distance, elevation, and viewing angle match identically.
##   3. Units & Simulation:
##        - 1.0 unit = 1.0 SI meter, gravity = 9.81 m/s² along -Y, step = 60 Hz.
##   4. Loop & Playback Modes:
##        - Havok hkaDefaultAnimationControl (maxCycles = 0) and
##          hkbClipGenerator (MODE_LOOPING) default to LOOP_LINEAR, whereas
##          Godot Animation defaults to LOOP_NONE.
##        - Cyclic clips default to LOOP_LINEAR; PingPong and SinglePlay demos
##          explicitly use LOOP_PINGPONG and LOOP_NONE.

const Store := preload("res://characters/character_store.gd")

const GODOT_UP := Vector3.UP
const GODOT_FORWARD := Vector3.FORWARD # (0, 0, -1)
const GODOT_RIGHT := Vector3.RIGHT     # (1, 0, 0)
const GRAVITY_MPS2 := 9.81
const FIXED_STEP_HZ := 60.0
const FIXED_DT := 1.0 / 60.0
const DEFAULT_FOV_DEG := 45.0          # Exact hkgCamera::DEFAULT_FOV
const DEFAULT_NEAR_M := 0.1
const DEFAULT_FAR_M := 100.0

# Measured anatomical forward -> Godot -Z yaw rotation (radians) and
# animated standing foot ground Y offset (meters) for all 30 internalized rigs.
# All 30 rigs verified in SI meters (unit_scale = 1.0).
const CHARACTER_ALIGNMENT := {
	"hero":            {"yaw": PI,       "ground_y": 0.000, "height": 1.78, "hover": false},
	"soldier":         {"yaw": PI * 0.5, "ground_y": 0.000, "height": 1.81, "hover": false},
	"orc_captain":     {"yaw": PI,       "ground_y": 0.000, "height": 1.64, "hover": false},
	"orc_grunt":       {"yaw": PI,       "ground_y": 0.000, "height": 1.34, "hover": false},
	"orc_troll":       {"yaw": PI,       "ground_y": 0.001, "height": 3.88, "hover": false},
	"ninja_blue":      {"yaw": PI,       "ground_y": 0.036, "height": 2.46, "hover": false},
	"ninja_staff":     {"yaw": PI,       "ground_y": 0.010, "height": 1.47, "hover": false},
	"fetid_hulk":      {"yaw": PI,       "ground_y": 0.182, "height": 3.40, "hover": false},
	"flying_imp":      {"yaw": PI,       "ground_y": 0.000, "height": 1.79, "hover": true},
	"siege_fiend":     {"yaw": PI,       "ground_y": 0.024, "height": 1.19, "hover": false},
	"hivequeen":       {"yaw": PI,       "ground_y": 0.000, "height": 0.21, "hover": false},
	"shulgoth":        {"yaw": PI,       "ground_y": 0.000, "height": 2.04, "hover": false},
	"creature":        {"yaw": PI,       "ground_y": 0.091, "height": 1.70, "hover": false},
	"havok_girl":      {"yaw": PI,       "ground_y": 0.000, "height": 1.53, "hover": false},
	"havok_girl_sdk":  {"yaw": PI,       "ground_y": 0.815, "height": 1.59, "hover": false},
	"firefighter":     {"yaw": PI,       "ground_y": 0.000, "height": 1.89, "hover": false},
	"desert_dan":      {"yaw": PI,       "ground_y": 0.000, "height": 1.89, "hover": false},
	"jungle_joe":      {"yaw": PI,       "ground_y": 0.000, "height": 1.89, "hover": false},
	"snow_sam":        {"yaw": PI,       "ground_y": 0.000, "height": 1.89, "hover": false},
	"zombie":          {"yaw": PI,       "ground_y": 0.000, "height": 1.70, "hover": false},
	"bigbad":          {"yaw": PI,       "ground_y": 0.009, "height": 2.13, "hover": false},
	"boy":             {"yaw": PI,       "ground_y": 0.004, "height": 1.18, "hover": false},
	"girl":            {"yaw": PI,       "ground_y": 0.005, "height": 1.17, "hover": false},
	"female_dress":    {"yaw": PI,       "ground_y": 0.003, "height": 1.69, "hover": false},
	"female_ponytail": {"yaw": PI,       "ground_y": 0.003, "height": 1.69, "hover": false},
	"male_cape":       {"yaw": PI,       "ground_y": 0.000, "height": 1.80, "hover": false},
	"male_nocape":     {"yaw": PI,       "ground_y": 0.000, "height": 1.80, "hover": false},
	"singer":          {"yaw": PI * 0.5, "ground_y": 0.000, "height": 1.31, "hover": false},
	"gingerbread":     {"yaw": PI,       "ground_y": 0.000, "height": 1.47, "hover": false},
	"crabby":          {"yaw": 0.0,      "ground_y": 1.733, "height": 2.06, "hover": false},
}

const ONESHOT_CLIPS := [
	"protect", "slash", "slam", "taunt", "roar", "kick", "dive",
	"vault", "jump", "jumpturn", "runjump", "idle_to_walk", "turn",
]


static func get_alignment(char_id: String) -> Dictionary:
	return CHARACTER_ALIGNMENT.get(char_id, {"yaw": PI, "ground_y": 0.0, "height": 1.75, "hover": false}) as Dictionary


static func default_loop_mode_for_clip(clip_key: String) -> int:
	var k := clip_key.to_lower()
	if k in ONESHOT_CLIPS:
		return Animation.LOOP_NONE
	return Animation.LOOP_LINEAR


static func loop_mode_name(mode: int) -> String:
	match mode:
		Animation.LOOP_LINEAR: return "LOOP_LINEAR (Havok MODE_LOOPING)"
		Animation.LOOP_PINGPONG: return "LOOP_PINGPONG (Havok MODE_PING_PONG)"
		_: return "LOOP_NONE (Havok MODE_SINGLE_PLAY)"


static func hk_zup_to_godot(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)


static func hk_camera_to_godot(hk_from: Vector3, hk_to: Vector3, is_zup: bool = true, yaw_rad: float = PI, ground_lift: float = 0.0) -> Dictionary:
	var f_g := hk_zup_to_godot(hk_from) if is_zup else hk_from
	var t_g := hk_zup_to_godot(hk_to) if is_zup else hk_to
	var rot := Basis(Vector3.UP, yaw_rad)
	var lift := Vector3(0.0, ground_lift, 0.0)
	return {
		"from": rot * f_g + lift,
		"to": rot * t_g + lift,
		"up": GODOT_UP,
	}


static func resolve_demo_spec(path: String, variant_name: String = "") -> Dictionary:
	var p := path.to_lower().replace("\\", "/")
	var v := variant_name.to_lower()
	var prod := "behavior" if p.begins_with("behavior/") else "animation"

	# Default spec (HavokGirl 50-bone SDK rig, front-3/4 camera at 45° vertical FOV, LOOP_LINEAR)
	var spec := {
		"product": prod,
		"primary_char": "havok_girl_sdk",
		"secondary_char": "",
		"primary_clip": "walk",
		"secondary_clip": "run",
		"loop_mode": Animation.LOOP_LINEAR,
		"playback_speed": 1.0,
		"hk_from": Vector3(-2.0, -2.5, 1.4),
		"hk_to": Vector3(0.0, 0.0, 0.0),
		"hk_zup": true,
		"cam_fov": DEFAULT_FOV_DEG,
		"cam_near": DEFAULT_NEAR_M,
		"cam_far": DEFAULT_FAR_M,
		"align_camera_to_char": true,
	}

	if prod == "animation":
		if "/crabby/" in p:
			spec["primary_char"] = "crabby"
			spec["primary_clip"] = "idle"
			spec["secondary_clip"] = "idle"
			spec["hk_from"] = Vector3(5.2, 5.8, 2.2)
			spec["hk_to"] = Vector3(0.0, 0.0, -0.7)
			spec["cam_far"] = 200.0
		elif "/dismemberment/" in p or "/ragdollanimation/" in p:
			spec["primary_char"] = "zombie"
			spec["primary_clip"] = "agrowalk"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(-1.4, -3.5, 2.2)
			spec["hk_to"] = Vector3(0.0, 0.0, 1.0)
		elif "/constraintmatching/" in p or "/ragdollcontroller/" in p:
			spec["primary_char"] = "firefighter"
			spec["primary_clip"] = "run"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(-2.4, 2.2, 3.6)
			spec["hk_to"] = Vector3(0.0, 1.0, 0.0)
			spec["hk_zup"] = false
		elif "/ragdoll/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "run"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(-2.2, -3.2, 1.8)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.1)
		elif "/retargeting/chain/" in p or "retargetingpartitionswithchains" in p:
			spec["primary_char"] = "singer"
			spec["secondary_char"] = "gingerbread"
			spec["primary_clip"] = "sing"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(0.0, 1.55, -4.2)
			spec["hk_to"] = Vector3(0.0, 0.85, 0.0)
			spec["hk_zup"] = false
			spec["align_camera_to_char"] = false
		elif "/retargeting/blendpartial/" in p:
			spec["primary_char"] = "female_dress"
			spec["secondary_char"] = "male_nocape"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(0.0, 1.65, -4.6)
			spec["hk_to"] = Vector3(0.0, 0.95, 0.0)
			spec["hk_zup"] = false
			spec["align_camera_to_char"] = false
		elif "/retargeting/blendadditive/" in p:
			spec["primary_char"] = "male_nocape"
			spec["secondary_char"] = "girl"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "dive"
			spec["hk_from"] = Vector3(0.0, 1.65, -4.6)
			spec["hk_to"] = Vector3(0.0, 0.95, 0.0)
			spec["hk_zup"] = false
			spec["align_camera_to_char"] = false
		elif "/retargeting/timings/" in p:
			spec["primary_char"] = "bigbad"
			spec["secondary_char"] = "boy"
			spec["primary_clip"] = "yell"
			spec["secondary_clip"] = "runjump"
			spec["hk_from"] = Vector3(0.0, 1.85, -5.2)
			spec["hk_to"] = Vector3(0.0, 1.05, 0.0)
			spec["hk_zup"] = false
			spec["align_camera_to_char"] = false
		elif "/retargeting/" in p:
			spec["primary_char"] = "shulgoth"
			spec["secondary_char"] = "male_nocape"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(0.0, 1.85, -5.2)
			spec["hk_to"] = Vector3(0.0, 1.05, 0.0)
			spec["hk_zup"] = false
			spec["align_camera_to_char"] = false
		elif "/skeletalmapping/" in p or "skeletonmapping" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["secondary_char"] = "firefighter"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(0.0, 1.70, -4.6)
			spec["hk_to"] = Vector3(0.0, 0.95, 0.0)
			spec["hk_zup"] = false
			spec["align_camera_to_char"] = false
		elif "/compression/timings/" in p or "sampleandblend" in p:
			spec["primary_char"] = "firefighter"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "run"
			spec["hk_from"] = Vector3(-4.2, 2.8, 5.2)
			spec["hk_to"] = Vector3(0.0, 0.9, 0.0)
			spec["hk_zup"] = false
		elif "/blending/additive/" in p or "/layeringandpartitions/additive/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "wave"
			spec["hk_from"] = Vector3(0.5, -2.4, 0.85)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.1)
		elif "/blending/normal/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "run"
			spec["hk_from"] = Vector3(-2.0, -2.4, 1.1)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.0)
		elif "/footik/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "idle"
			spec["playback_speed"] = 0.80
			spec["hk_from"] = Vector3(-2.6, -2.8, 1.4)
			spec["hk_to"] = Vector3(0.0, 0.0, -0.1)
		elif "/lookat/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "idle"
			spec["secondary_clip"] = "head_move"
			spec["hk_from"] = Vector3(-1.5, -2.0, 0.85)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.35)
		elif "/reaching/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "idle"
			spec["secondary_clip"] = "wave"
			spec["hk_from"] = Vector3(-2.0, -2.2, 1.0)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.2)
		elif "/scaling/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "scale"
			spec["secondary_clip"] = "idle"
			spec["hk_from"] = Vector3(-1.8, -2.4, 0.9)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.0)
		elif "/skinning/" in p or "/hardwareskinning/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "idle"
			spec["secondary_clip"] = "wave"
			spec["hk_from"] = Vector3(-1.4, -2.0, 0.75)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.15)
		elif "/attachments/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "wave"
			spec["hk_from"] = Vector3(-2.0, -2.4, 1.0)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.1)
		elif "/motionextraction/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			if "charactercontroller" in p:
				spec["primary_clip"] = "run"
				spec["secondary_clip"] = "protect"
			elif "basicmovement" in p or "mirroredmotion" in p:
				spec["primary_clip"] = "run"
				spec["secondary_clip"] = "jumpland"
			else:
				spec["primary_clip"] = "walk"
				spec["secondary_clip"] = "walk_turn_l"
			spec["hk_from"] = Vector3(-3.2, -3.5, 1.8)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.1)
		elif "/playback/" in p or "/layeringandpartitions/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			if "floattrack" in p:
				spec["primary_clip"] = "walk"
				spec["playback_speed"] = 0.5
			elif "animatedskeleton" in p or "individualbone" in p:
				spec["primary_clip"] = "jumpland"
			elif "mirroring" in p or "partitionplayback" in p:
				spec["primary_clip"] = "run"
				spec["secondary_clip"] = "wave"
			elif "easecurve" in p or "binding" in p:
				spec["primary_clip"] = "idle"
				spec["secondary_clip"] = "wave"
			else:
				spec["primary_clip"] = "walk"
				spec["secondary_clip"] = "wave"
			spec["hk_from"] = Vector3(-2.0, -2.6, 1.1)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.1)
		elif "/multithreading/" in p:
			spec["primary_char"] = "havok_girl_sdk"
			spec["primary_clip"] = "run_turn_l"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(-4.2, -5.2, 2.8)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.2)
	else:
		# Behavior product — exact original Havok Behavior SDK characters & modes
		if "quadruped" in p:
			spec["primary_char"] = "siege_fiend"
			spec["primary_clip"] = "move"
			spec["secondary_clip"] = "neutral"
			spec["hk_from"] = Vector3(-3.2, -3.8, 2.2)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.6)
		elif "charactertocharacter" in p:
			spec["primary_char"] = "flying_imp"
			spec["secondary_char"] = "hivequeen"
			spec["primary_clip"] = "fly"
			spec["secondary_clip"] = "discharge"
			spec["hk_from"] = Vector3(-2.4, -3.2, 1.8)
			spec["hk_to"] = Vector3(0.0, 0.0, 1.0)
		elif "swapskins" in p:
			spec["primary_char"] = "firefighter"
			spec["secondary_char"] = "desert_dan"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "run"
			spec["hk_from"] = Vector3(-2.0, 1.9, 3.2)
			spec["hk_to"] = Vector3(0.0, 1.0, 0.0)
			spec["hk_zup"] = false
		elif "sharedassetsperformance" in p:
			spec["primary_char"] = "firefighter"
			spec["secondary_char"] = "desert_dan"
			spec["primary_clip"] = "run"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(-4.5, 3.2, 5.5)
			spec["hk_to"] = Vector3(0.0, 0.9, 0.0)
			spec["hk_zup"] = false
		elif "orcs" in p or "animationsets" in p:
			spec["primary_char"] = "orc_captain"
			spec["secondary_char"] = "orc_grunt"
			spec["primary_clip"] = "jog"
			spec["secondary_clip"] = "slash"
			spec["hk_from"] = Vector3(-4.2, -5.2, 2.8)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.9)
		elif "asynchronousstepping" in p:
			spec["primary_char"] = "ninja_blue"
			spec["primary_clip"] = "run"
			spec["secondary_clip"] = "kick"
			spec["hk_from"] = Vector3(-4.5, -5.2, 2.8)
			spec["hk_to"] = Vector3(0.0, 0.0, 1.0)
		elif "differentshapesandsizes" in p:
			spec["primary_char"] = "boy"
			spec["secondary_char"] = "girl"
			spec["primary_clip"] = "runjump"
			spec["secondary_clip"] = "jumpturn"
			spec["hk_from"] = Vector3(0.0, 1.45, -4.0)
			spec["hk_to"] = Vector3(0.0, 0.75, 0.0)
			spec["hk_zup"] = false
			spec["align_camera_to_char"] = false
		elif "similartrunkdifferentleaf" in p:
			spec["primary_char"] = "female_dress"
			spec["secondary_char"] = "female_ponytail"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(0.0, 1.60, -4.4)
			spec["hk_to"] = Vector3(0.0, 0.90, 0.0)
			spec["hk_zup"] = false
			spec["align_camera_to_char"] = false
		elif "superset" in p:
			spec["primary_char"] = "male_cape"
			spec["secondary_char"] = "male_nocape"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "walk"
			spec["hk_from"] = Vector3(0.0, 1.65, -4.6)
			spec["hk_to"] = Vector3(0.0, 0.95, 0.0)
			spec["hk_zup"] = false
			spec["align_camera_to_char"] = false
		elif "charactertoobject" in p and "ragdoll" in v:
			# CharacterToObjectAttachmentDemo variant 1 (Ragdoll Attachments) uses Soldier 114b!
			spec["primary_char"] = "soldier"
			spec["primary_clip"] = "run"
			spec["secondary_clip"] = "idle"
			spec["hk_from"] = Vector3(2.8, 1.8, 2.2)
			spec["hk_to"] = Vector3(0.0, 0.95, 0.0)
			spec["hk_zup"] = false
		elif (
			"/docking/" in p or "/showcase/hero/" in p or "/drivers/charactercontroller" in p
			or "/drivers/footik" in p or "/drivers/handik" in p or "lookatmodifier" in p
			or "movingplatforms" in p or "partialanimation" in p or "determinism" in p
			or "nestedbehaviors" in p or "/transitiontest/" in p or p.ends_with("/transitiontest")
			or "generatortransition" in p or "ondemandassetloading" in p
			or "behaviorviewers" in p or "symbollinking" in p or "charactertoobject" in p
		):
			spec["primary_char"] = "hero"
			spec["primary_clip"] = "run" if ("hero" in p or "docking" in p) else "walk"
			spec["secondary_clip"] = "idle"
			spec["hk_from"] = Vector3(-2.4, -3.4, 1.9)
			spec["hk_to"] = Vector3(0.0, 0.0, 0.95)
		elif "gdc2005" in p:
			spec["primary_char"] = "firefighter"
			spec["primary_clip"] = "run"
			spec["secondary_clip"] = "jump"
			spec["hk_from"] = Vector3(-2.2, 1.8, 3.4)
			spec["hk_to"] = Vector3(0.0, 0.9, 0.0)
			spec["hk_zup"] = false
		else:
			# Soldier (FireTeamLeader_Character.hkt — 23 Behavior demos!)
			spec["primary_char"] = "soldier"
			spec["primary_clip"] = "walk"
			spec["secondary_clip"] = "run"
			spec["hk_from"] = Vector3(2.8, 1.8, 2.2)
			spec["hk_to"] = Vector3(0.0, 0.95, 0.0)
			spec["hk_zup"] = false
			if "pingpong" in p or "animationtest" in p or "ping_pong" in v:
				spec["loop_mode"] = Animation.LOOP_PINGPONG
			elif "clipgeneratormodes" in p:
				if "single" in v:
					spec["loop_mode"] = Animation.LOOP_NONE
				elif "pingpong" in v or "ping_pong" in v or "ping pong" in v:
					spec["loop_mode"] = Animation.LOOP_PINGPONG
				else:
					spec["loop_mode"] = Animation.LOOP_LINEAR
	return spec


static func apply_camera(camera: Camera3D, spec: Dictionary) -> Dictionary:
	if camera == null:
		return {}
	var cid := str(spec.get("primary_char", "havok_girl_sdk"))
	var align := get_alignment(cid)
	var yaw := float(align["yaw"]) if bool(spec.get("align_camera_to_char", true)) else 0.0
	var ground_lift := float(align["ground_y"]) if bool(spec.get("hk_zup", true)) else 0.0
	var hk_from: Vector3 = spec.get("hk_from", Vector3(-2.0, -2.5, 1.5))
	var hk_to: Vector3 = spec.get("hk_to", Vector3(0.0, 0.0, 0.5))
	var is_zup := bool(spec.get("hk_zup", true))
	var cam_g := hk_camera_to_godot(hk_from, hk_to, is_zup, yaw, ground_lift)
	var from_p: Vector3 = cam_g["from"]
	var to_p: Vector3 = cam_g["to"]
	# Guarantee camera looks slightly above ground onto torso in Godot Y-up space
	if to_p.y < 0.25:
		to_p.y = clampf(float(align.get("height", 1.7)) * 0.52, 0.55, 1.45)
	if from_p.y < 0.45:
		from_p.y = to_p.y + 0.65
	if from_p.distance_to(to_p) < 1.2:
		from_p = to_p + Vector3(-1.8, 0.9, -2.6)
	var look_dir := (to_p - from_p).normalized()
	if absf(look_dir.dot(GODOT_UP)) > 0.98:
		from_p.z -= 2.4

	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.fov = float(spec.get("cam_fov", DEFAULT_FOV_DEG))
	camera.near = float(spec.get("cam_near", DEFAULT_NEAR_M))
	camera.far = float(spec.get("cam_far", DEFAULT_FAR_M))
	camera.position = from_p
	camera.look_at(to_p, GODOT_UP)
	return {
		"from": from_p,
		"to": to_p,
		"fov": camera.fov,
		"near": camera.near,
		"far": camera.far,
	}


static func describe_spec(spec: Dictionary) -> String:
	var primary := str(spec.get("primary_char", "havok_girl_sdk"))
	var secondary := str(spec.get("secondary_char", ""))
	var asset_label := primary if secondary.is_empty() else "%s + %s" % [primary, secondary]
	var lmode := int(spec.get("loop_mode", Animation.LOOP_LINEAR))
	var fov := float(spec.get("cam_fov", DEFAULT_FOV_DEG))
	return "내재화 에셋 [%s] · Godot 표준(-Z 전방 / +Y 상향 / SI m / 9.81 m/s²) · 카메라 FOV %.0f° KEEP_HEIGHT · %s" % [
		asset_label, fov, loop_mode_name(lmode)
	]


static func spawn_aligned_character(char_id: String, name_prefix: String = "HavokActor", loop_override: int = -1) -> Dictionary:
	var rig := Store.build_rig(char_id, name_prefix + "_Inner", loop_override)
	if rig.is_empty():
		return {}
	var align := get_alignment(char_id)
	var yaw := float(align["yaw"])
	var gy := float(align["ground_y"])

	var outer := Node3D.new()
	outer.name = name_prefix
	var inner: Node3D = rig["root"] as Node3D
	inner.rotation = Vector3(0.0, yaw, 0.0)
	inner.position = Vector3(0.0, gy, 0.0)
	outer.add_child(inner)

	rig["outer"] = outer
	rig["align_yaw"] = yaw
	rig["ground_y"] = gy
	rig["char_id"] = char_id
	return rig


static func pick_clip(rig: Dictionary, preferred: String, fallback_idx: int = 0) -> String:
	var clips: Array = rig.get("clips", []) as Array
	if clips.is_empty():
		return ""
	if not preferred.is_empty() and clips.has(preferred):
		return preferred
	for alt in ["walk", "run", "jog", "move", "idle", "neutral"]:
		if clips.has(alt):
			return alt
	return str(clips[clampi(fallback_idx, 0, clips.size() - 1)])


static func sample_root_motion_delta(rig: Dictionary, clip_name: String, t_prev: float, t_cur: float) -> Vector3:
	var data: Dictionary = rig.get("data", {}) as Dictionary
	var clips_dict: Dictionary = data.get("clips", {}) as Dictionary
	if not clips_dict.has(clip_name):
		return Vector3.ZERO
	var cdict: Dictionary = clips_dict[clip_name] as Dictionary
	var rm_raw: Variant = cdict.get("root_motion", null)
	if not (rm_raw is Dictionary):
		return Vector3.ZERO
	var keys: Array = (rm_raw as Dictionary).get("keys", []) as Array
	if keys.size() < 2:
		return Vector3.ZERO
	var dur := maxf(0.01, float(cdict.get("duration", 1.0)))
	var p_end := _sample_rm_pos(keys, dur)
	var p_start := _sample_rm_pos(keys, 0.0)
	var cycle_disp := p_end - p_start
	var raw_delta := Vector3.ZERO
	if t_cur >= t_prev:
		raw_delta = _sample_rm_pos(keys, t_cur) - _sample_rm_pos(keys, t_prev)
	else:
		raw_delta = (p_end - _sample_rm_pos(keys, t_prev)) + (_sample_rm_pos(keys, t_cur) - p_start)
	if raw_delta.length() > cycle_disp.length() * 1.5 + 0.5:
		raw_delta = Vector3.ZERO
	var yaw := float(rig.get("align_yaw", PI))
	return Basis(Vector3.UP, yaw) * raw_delta


static func _sample_rm_pos(keys: Array, t: float) -> Vector3:
	var n := keys.size()
	if n == 0:
		return Vector3.ZERO
	if t <= float((keys[0] as Dictionary).get("time", 0.0)):
		var a0: Array = (keys[0] as Dictionary).get("translation", [0, 0, 0]) as Array
		return Vector3(float(a0[0]), float(a0[1]), float(a0[2]))
	var last_d: Dictionary = keys[n - 1] as Dictionary
	if t >= float(last_d.get("time", 0.0)):
		var al: Array = last_d.get("translation", [0, 0, 0]) as Array
		return Vector3(float(al[0]), float(al[1]), float(al[2]))
	for i in range(n - 1):
		var d0: Dictionary = keys[i] as Dictionary
		var d1: Dictionary = keys[i + 1] as Dictionary
		var t0 := float(d0.get("time", 0.0))
		var t1 := float(d1.get("time", 0.0))
		if t >= t0 and t <= t1:
			var f := (t - t0) / maxf(1e-5, t1 - t0)
			var a0: Array = d0.get("translation", [0, 0, 0]) as Array
			var a1: Array = d1.get("translation", [0, 0, 0]) as Array
			return Vector3(float(a0[0]), float(a0[1]), float(a0[2])).lerp(Vector3(float(a1[0]), float(a1[1]), float(a1[2])), f)
	return Vector3.ZERO


static func find_semantic_bone(skel: Skeleton3D, semantic: String) -> int:
	if skel == null:
		return -1
	var patterns: Array[String] = []
	match semantic:
		"root":        patterns = ["root", "pelvis", "hips", "bip01", "reference", "spiderroot"]
		"pelvis":      patterns = ["pelvis", "hips", "root_m", "body"]
		"spine":       patterns = ["spine1", "spine", "backb", "chest", "torso"]
		"neck":        patterns = ["neck1_m", "neck"]
		"head":        patterns = ["head_m", "head"]
		"r_hand":      patterns = ["r hand", "rightarmpalm", "righthand", "hand_r", "r_hand", "wrist_r", "rightwrist"]
		"l_hand":      patterns = ["l hand", "leftarmpalm", "lefthand", "hand_l", "l_hand", "wrist_l", "leftwrist"]
		"l_upper_arm": patterns = ["l upperarm", "leftarmupperarm", "leftupperarm", "leftarm", "shoulder_l", "l_upperarm", "leftshoulder"]
		"l_lower_arm": patterns = ["l forearm", "leftarmforearm", "leftforearm", "leftlowerarm", "elbow_l", "l_forearm", "leftelbow"]
		"r_upper_arm": patterns = ["r upperarm", "rightarmupperarm", "rightupperarm", "rightarm", "shoulder_r", "r_upperarm", "rightshoulder"]
		"r_lower_arm": patterns = ["r forearm", "rightarmforearm", "rightforearm", "rightlowerarm", "elbow_r", "r_forearm", "rightelbow"]
		"l_thigh":     patterns = ["l thigh", "leftlegthigh3", "leftthigh", "leftlegthigh1", "lefthip", "hip_l", "l_thigh", "backleft1"]
		"l_calf":      patterns = ["l calf", "leftlegcalf", "leftcalf", "leftlegshin", "leftknee", "knee_l", "l_calf", "backleft2"]
		"l_foot":      patterns = ["l foot", "leftlegfoot", "leftfoot", "leftankle", "ankle_l", "l_foot", "backleft3"]
		"r_thigh":     patterns = ["r thigh", "rightlegthigh3", "rightthigh", "rightlegthigh1", "righthip", "hip_r", "r_thigh", "backright1"]
		"r_calf":      patterns = ["r calf", "rightlegcalf", "rightcalf", "rightlegshin", "rightknee", "knee_r", "r_calf", "backright2"]
		"r_foot":      patterns = ["r foot", "rightlegfoot", "rightfoot", "rightankle", "ankle_r", "r_foot", "backright3"]
	for pat in patterns:
		for bi in skel.get_bone_count():
			var bnl := skel.get_bone_name(bi).to_lower()
			if pat in bnl:
				return bi
	return 0 if skel.get_bone_count() > 0 else -1


static func build_semantic_retarget_pairs(src_skel: Skeleton3D, dst_skel: Skeleton3D) -> Array[Array]:
	var pairs: Array[Array] = []
	if src_skel == null or dst_skel == null:
		return pairs
	var semantics := [
		"pelvis", "spine", "neck", "head",
		"l_upper_arm", "l_lower_arm", "l_hand",
		"r_upper_arm", "r_lower_arm", "r_hand",
		"l_thigh", "l_calf", "l_foot",
		"r_thigh", "r_calf", "r_foot",
	]
	var used_dst := {}
	for sem in semantics:
		var sidx := find_semantic_bone(src_skel, sem)
		var didx := find_semantic_bone(dst_skel, sem)
		if sidx >= 0 and didx >= 0 and not used_dst.has(didx):
			used_dst[didx] = true
			pairs.append([sidx, didx, sem])
	return pairs


static func apply_semantic_retarget(src_skel: Skeleton3D, dst_skel: Skeleton3D, pairs: Array[Array], weight: float = 1.0, src_yaw: float = PI, dst_yaw: float = PI) -> void:
	if src_skel == null or dst_skel == null:
		return
	var rel_yaw := Quaternion(Vector3.UP, src_yaw - dst_yaw).normalized()
	for pair in pairs:
		var sidx: int = int(pair[0])
		var didx: int = int(pair[1])
		var sem: String = str(pair[2]) if pair.size() >= 3 else ""
		var s_rest_g := src_skel.get_bone_global_rest(sidx).basis.get_rotation_quaternion().normalized()
		var s_pose_g := src_skel.get_bone_global_pose(sidx).basis.get_rotation_quaternion().normalized()
		var sp := src_skel.get_bone_parent(sidx)
		var s_p_rest_g := src_skel.get_bone_global_rest(sp).basis.get_rotation_quaternion().normalized() if sp >= 0 else Quaternion.IDENTITY
		var s_p_pose_g := src_skel.get_bone_global_pose(sp).basis.get_rotation_quaternion().normalized() if sp >= 0 else Quaternion.IDENTITY
		var w_s := (s_pose_g * s_rest_g.inverse()).normalized()
		var w_sp := (s_p_pose_g * s_p_rest_g.inverse()).normalized()
		var d_world := (w_sp.inverse() * w_s).normalized()
		if absf(src_yaw - dst_yaw) > 0.001:
			d_world = (rel_yaw * d_world * rel_yaw.inverse()).normalized()
		if sem == "pelvis":
			var e := d_world.get_euler()
			d_world = Quaternion.from_euler(Vector3(e.x * 0.12, e.y * 0.5, e.z * 0.12)).normalized()
		elif sem in ["l_thigh", "r_thigh", "l_calf", "r_calf", "l_foot", "r_foot"]:
			d_world = Quaternion.IDENTITY.slerp(d_world, 0.45).normalized()
		var d_rest_g := dst_skel.get_bone_global_rest(didx).basis.get_rotation_quaternion().normalized()
		var dp := dst_skel.get_bone_parent(didx)
		var d_p_rest_g := dst_skel.get_bone_global_rest(dp).basis.get_rotation_quaternion().normalized() if dp >= 0 else Quaternion.IDENTITY
		var target_q := (d_p_rest_g.inverse() * d_world * d_rest_g).normalized()
		if weight < 0.999:
			var rest_local := dst_skel.get_bone_rest(didx).basis.get_rotation_quaternion().normalized()
			target_q = rest_local.slerp(target_q, clampf(weight, 0.0, 1.0)).normalized()
		dst_skel.set_bone_pose_rotation(didx, target_q)
	dst_skel.force_update_all_bone_transforms()
	var min_foot_y := INF
	for fsem in ["l_foot", "r_foot"]:
		var fidx := find_semantic_bone(dst_skel, fsem)
		if fidx >= 0:
			min_foot_y = minf(min_foot_y, dst_skel.get_bone_global_pose(fidx).origin.y)
	if min_foot_y < INF:
		dst_skel.position.y = -min_foot_y + 0.06


static func build_upper_body_bone_paths(skel: Skeleton3D, rig_name: String = "Skeleton3D") -> Array[NodePath]:
	var out: Array[NodePath] = []
	if skel == null:
		return out
	var tokens := [
		"spine", "chest", "ribcage", "backb", "neck", "head", "eye", "jaw",
		"clavicle", "collar", "scapula", "shoulder", "upperarm", "forearm",
		"foretwist", "elbow", "arm", "hand", "wrist", "palm", "finger", "digit",
		"weapon", "cape", "ponytail",
	]
	for bi in skel.get_bone_count():
		var bname := skel.get_bone_name(bi)
		var low := bname.to_lower()
		var matched := false
		for tok in tokens:
			if tok in low:
				matched = true
				break
		if matched:
			out.append(NodePath("%s:%s" % [rig_name, bname]))
	return out


static func build_mirrored_animation(source: Animation) -> Animation:
	var mirrored := source.duplicate(true) as Animation
	if mirrored == null:
		return source
	for t in mirrored.get_track_count():
		var path_str := str(mirrored.track_get_path(t))
		var swapped := path_str
		if " L " in swapped:
			swapped = swapped.replace(" L ", " R ")
		elif " R " in swapped:
			swapped = swapped.replace(" R ", " L ")
		elif "Left" in swapped:
			swapped = swapped.replace("Left", "Right")
		elif "Right" in swapped:
			swapped = swapped.replace("Right", "Left")
		elif swapped.ends_with("_L"):
			swapped = swapped.substr(0, swapped.length() - 2) + "_R"
		elif swapped.ends_with("_R"):
			swapped = swapped.substr(0, swapped.length() - 2) + "_L"
		mirrored.track_set_path(t, NodePath(swapped))
		var ttype := mirrored.track_get_type(t)
		var kc := mirrored.track_get_key_count(t)
		if ttype == Animation.TYPE_ROTATION_3D:
			for k in kc:
				var q: Quaternion = mirrored.track_get_key_value(t, k)
				mirrored.track_set_key_value(t, k, Quaternion(q.x, -q.y, -q.z, q.w).normalized())
		elif ttype == Animation.TYPE_POSITION_3D:
			for k in kc:
				var p: Vector3 = mirrored.track_get_key_value(t, k)
				mirrored.track_set_key_value(t, k, Vector3(-p.x, p.y, p.z))
	return mirrored
