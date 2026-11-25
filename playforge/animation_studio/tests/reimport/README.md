# Pose clip glTF reimport probe

Run the end-to-end check with a Godot 4 editor binary:

```sh
python run_gltf_reimport.py --godot /path/to/godot
```

Alternatively, set `GODOT_BIN` and omit `--godot`. `--timeout` sets the timeout
for each Godot process; it defaults to 120 seconds.

The runner creates a temporary project and generates a minimal animated,
skinned glTF plus its binary buffer using Python's standard library. It imports
the scene, saves a custom `HandOverride` animation-track mapping through the
scene importer's custom-track sidecar, edits the glTF translation accessor,
then imports it again. The probe seeds the sidecar with a stable UID before the
first editor scan, then preserves it with Godot's `ResourceLoader` and
`ResourceSaver` APIs while saving the custom mapping. Verification checks the
updated imported sample, the retained custom mapping and values, and `PoseClip`
source/snapshot isolation. The temporary project is deleted after the run.
