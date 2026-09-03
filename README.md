# GodotSpace

GodotSpace is a monorepo for the Godot XR/MR application and its local AI
services.

## Layout

- `GodotSpace/`: the Godot 4.4 project, including multiplayer, XR, voice, task
  UI, and realtime reconstruction features.
- `Model/`: the Qwen Agent Gateway, knowledge/tool-call harnesses, local FunASR
  service, model launch scripts, benchmarks, and service tests.
- `docs/`: repository-level documentation.

The `Model/` directory was imported with its original Git history by using a
non-squashed subtree merge. It is now maintained in this repository; do not
initialize another Git repository inside it.

## Common entry points

Open the Godot editor from PowerShell:

```powershell
& 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe' `
  --editor --path .\GodotSpace
```

Run the local service tests from WSL:

```bash
cd /mnt/f/GodotSpace/Model
source .venv/bin/activate
python -m unittest discover -s agent_service/tests -v
python -m unittest discover -s asr_service/tests -v
```

See `GodotSpace/Assets/ARSpace/Scripts/RealtimeReconstruction/README.md` and
`Model/README.md` for subsystem-specific setup and validation.
