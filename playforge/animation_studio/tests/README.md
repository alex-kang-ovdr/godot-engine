# Animation Studio coexistence fixture

This directory is a minimal Godot project for headless runtime checks. It builds its rig and animations in GDScript, so no editor import or external assets are needed. The test preloads the runtime script directly from `res://addons/animation_studio/pose_modifier.gd`.

Run from the engine checkout root with its editor binary:

```powershell
bin/godot.windows.editor.x86_64.console.exe --headless --quit-after 600 --path playforge/animation_studio res://tests/coexistence.tscn
```

The fixture binds after entering the scene tree, drives `AnimationPlayer` and `Skeleton3D` manually in fixed 0.25-second steps, and checks native animation time, source asset integrity, event/property tracks, root motion, same-frame downstream modifier visibility, and stop/cutscene/resume behavior. A second rig queues source and target skeleton updates in order, then checks that `RetargetModifier3D` passes changing source rotations to the target and `TwoBoneIK3D` moves the hand closer to its goal in the same tick. The scene emits `PFTEST` JSON records and exits nonzero on an assertion failure; `--quit-after 600` bounds load/parse failures.
