extends Node
## addons/playforge_avatar/ VFS 봉인 시험 (a18fb005: file_access.cpp, file_access_pack.cpp, main.cpp).
## 코어 팩(--playforge-core-pack) 없이도 에디터가 아닌 실행에서는 프리픽스가 봉인되므로,
## (1) res:// 아래 봉인 경로 쓰기, (2) 사용자 PCK로 봉인 경로 덮어쓰기를 시도한다. 둘 다 대조 경로로 setup을 검증한다.
## 루트가 Node(2D 취급)라 엔진은 상반신 초상 UI를 띄우지만 이 시험과 무관하다.

const PFTest = preload("res://lib/pf_test.gd")
const C := "a18fb005"
const SEALED_DIR := "res://addons/playforge_avatar"
const OPEN_DIR := "res://pf_tmp_open"

var t: PFTest


func _init() -> void:
	t = PFTest.new("vfs_seal")


func _ready() -> void:
	await PFTest.frames(get_tree(), 1)
	var pf := PFTest.pf()
	t.check("setup_prefix_sealed", C, pf != null and (pf.get_sealed_prefixes() as PackedStringArray).has("addons/playforge_avatar/"))

	# --- (1) FileAccess WRITE 차단 ---
	DirAccess.make_dir_recursive_absolute(SEALED_DIR)
	DirAccess.make_dir_recursive_absolute(OPEN_DIR)
	var dirs_ok := DirAccess.dir_exists_absolute(SEALED_DIR) and DirAccess.dir_exists_absolute(OPEN_DIR)
	# 대조: 봉인 안 된 경로 쓰기는 성공해야 setup이 유효하다
	var fo := FileAccess.open(OPEN_DIR + "/ok.txt", FileAccess.WRITE)
	var open_ok := fo != null
	if fo:
		fo.store_string("ok")
		fo.close()
	t.check("setup_unsealed_write_works", C, dirs_ok and open_ok and FileAccess.file_exists(OPEN_DIR + "/ok.txt"))

	for path in [SEALED_DIR + "/evil.gd", SEALED_DIR + "/../playforge_avatar/evil2.gd", "res://addons//playforge_avatar/evil3.gd"]:
		var v0 := PFTest.violations()
		var f := FileAccess.open(path, FileAccess.WRITE)
		var err := FileAccess.get_open_error()
		var created := FileAccess.file_exists(path)
		t.check("write_blocked:" + path, C, f == null and err == ERR_UNAUTHORIZED and not created and PFTest.violations() - v0 >= 1,
				"opened=%s err=%s created=%s violations+%d" % [f != null, error_string(err), created, PFTest.violations() - v0])
		if f:
			f.close()
	# READ_WRITE 도 WRITE 비트를 포함하므로 막혀야 한다
	var frw := FileAccess.open(SEALED_DIR + "/evil_rw.gd", FileAccess.WRITE_READ)
	t.check("write_read_blocked", C, frw == null and not FileAccess.file_exists(SEALED_DIR + "/evil_rw.gd"))

	# 대소문자 변형 경로(Windows 파일시스템은 대소문자 무시) — 봉인 설계 밖 관찰
	var case_path := "res://addons/PlayForge_Avatar/case_probe.txt"
	var fc := FileAccess.open(case_path, FileAccess.WRITE)
	if fc:
		fc.store_string("x")
		fc.close()
		var lands := FileAccess.file_exists(SEALED_DIR + "/case_probe.txt")
		t.gap("case_variant_path_write", C, "'%s' 쓰기가 허용됨 (봉인 디렉터리 실제 파일로 기록=%s). is_path_sealed는 대소문자를 구분한다." % [case_path, lands])
		DirAccess.remove_absolute(SEALED_DIR + "/case_probe.txt")
		DirAccess.remove_absolute(case_path)
	else:
		t.info("case_variant_path_write", "blocked or failed: %s" % error_string(FileAccess.get_open_error()))
	_cleanup()

	# --- (2) 사용자 PCK가 봉인 경로를 덮어쓰지 못함 ---
	var src_evil := "user://pf_evil_controller.gd"
	var src_ok := "user://pf_ok.txt"
	var fe := FileAccess.open(src_evil, FileAccess.WRITE)
	fe.store_string("extends CharacterBody3D\nvar pwned := true\n")
	fe.close()
	var fk := FileAccess.open(src_ok, FileAccess.WRITE)
	fk.store_string("ugc ok")
	fk.close()
	var pck_path := "user://pf_ugc_override_test.pck"
	var packer := PCKPacker.new()
	var e1 := packer.pck_start(pck_path)
	var e2 := packer.add_file("res://addons/playforge_avatar/avatar_controller.gd", src_evil)
	var e3 := packer.add_file("res://pf_ugc_probe/ok.txt", src_ok)
	var e4 := packer.flush()
	t.check("setup_pck_built", C, e1 == OK and e2 == OK and e3 == OK and e4 == OK, "%s %s %s %s" % [e1, e2, e3, e4])
	var v0 := PFTest.violations()
	var loaded := ProjectSettings.load_resource_pack(pck_path, true)
	var ok_visible := FileAccess.file_exists("res://pf_ugc_probe/ok.txt")
	t.check("setup_pck_mounted_unsealed_file_visible", C, loaded and ok_visible, "loaded=%s ok.txt visible=%s" % [loaded, ok_visible])
	var evil_visible := FileAccess.file_exists("res://addons/playforge_avatar/avatar_controller.gd") or ResourceLoader.exists("res://addons/playforge_avatar/avatar_controller.gd")
	t.check("pck_cannot_inject_sealed_path", C, not evil_visible and PFTest.violations() - v0 >= 1, "visible=%s violations+%d" % [evil_visible, PFTest.violations() - v0])
	t.not_covered("core_pack_mount_override", C, "--playforge-core-pack 로 실제 코어 팩을 마운트해 우선권을 갖는지는 코어 팩 산출물(.pck)이 이 저장소에 없어 다루지 않음")
	DirAccess.remove_absolute(src_evil)
	DirAccess.remove_absolute(src_ok)
	DirAccess.remove_absolute(pck_path)
	t.finish(get_tree())


func _cleanup() -> void:
	for f in [SEALED_DIR + "/evil.gd", SEALED_DIR + "/evil2.gd", SEALED_DIR + "/evil3.gd", SEALED_DIR + "/evil_rw.gd", OPEN_DIR + "/ok.txt"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)
	DirAccess.remove_absolute(SEALED_DIR)
	DirAccess.remove_absolute("res://addons")
	DirAccess.remove_absolute(OPEN_DIR)
	t.check("cleanup_temp_dirs", C, not DirAccess.dir_exists_absolute("res://addons") and not DirAccess.dir_exists_absolute(OPEN_DIR))
