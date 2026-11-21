# Cubev4 client rebuild — binary exporter and loader

This update removes the earlier XML-only build step. It reads the binary `.rbxl` directly with [Lune](https://github.com/lune-org/lune) and exports chunked JSON data for the client reconstruction runtime.

## Files in this update

- `loader.lua` — the one-line bootstrap target. Replace `YOUR_GITHUB_USERNAME` with the account that owns the repository.
- `runtime.lua` — downloads the manifest/chunks and recreates supported Instances locally.
- `export_place.luau` — reads the binary `.rbxl` directly and generates `data/manifest.json` plus `data/chunks/*.json`.
- `build_place.bat` — Windows helper to run the exporter.

## Build the data from the original RBXL (no XML export)

1. Download the Windows x86_64 Lune release from https://github.com/lune-org/lune/releases/tag/v0.11.1 and extract `lune.exe`.
2. Put these three files in one local folder: `lune.exe`, `export_place.luau`, and your original `cubev4forAI(1).rbxl`.
3. Put `build_place.bat` in that same folder and double-click it.
4. The exporter writes `data/manifest.json`, `data/build-report.json`, and `data/chunks/`.
5. Check that `data/manifest.json` exists and lists chunk files. Open `data/build-report.json` to see what was exported and what values were skipped.
6. Upload the entire generated `data/` folder to the root of the GitHub repository. Do not rename `manifest.json` or the `chunks` folder.

You can also run the command manually from PowerShell in the folder:

```powershell
.\lune.exe run .\export_place.luau ".\cubev4forAI(1).rbxl" "."
```

## GitHub changes

Replace the repository's existing `README.md`, `loader.lua`, and `runtime.lua` with the versions from this update. Delete the old `convert_rbxlx.py`; this update uses `export_place.luau` instead. Add `export_place.luau` and `build_place.bat`.

Keep the existing audit and CSV manifests. They are inspection references and are not required by the loader. The recovered script-source ZIP is also an inspection artifact; do not execute it or point the runtime at it.

After the local export succeeds, upload the generated `data/` directory. Only then is the GitHub tree ready for the loadstring step.

## Loadstring form

After replacing the GitHub username in `loader.lua` and committing every file, the loader URL is:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/v4-client-rebuild/main/loader.lua"))()
```

This is a static, client-side reconstruction prototype. It deliberately excludes Script, LocalScript, ModuleScript, remote, and bindable subtrees. It does not translate original server logic into local gameplay code. Some classes/properties cannot be constructed or assigned from a Roblox client, and asset references only work when Roblox makes those assets accessible to the current client. The full morph UI, bone/jiggle behavior, and other original game logic still require separate local rewrites and testing.

The exporter may produce a large `data/` folder. Keep each chunk file below GitHub's per-file limit; the default exporter target is approximately 850 KB per chunk. If the overall repository grows very large, use Git LFS or a separate static file host for the data chunks.

Use only place files and assets that you have permission to reproduce. Executor use may violate Roblox's terms and can put accounts at risk; never execute code from an untrusted repository.
