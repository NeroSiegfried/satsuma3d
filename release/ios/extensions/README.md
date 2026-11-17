# Bundled extensions

Extensions the iPad app ships in its system repository (`<version>/extensions/system`), so they
need no download. `bl_ui.native_addons` turns them on once, on the first launch.

| Extension | Version | Source | License |
|---|---|---|---|
| LoopTools (`looptools`) | 4.7.7 | extensions.blender.org, archive sha256 `ff1ca3b3fff73094379da8b1fa2c1acbc9d88d26b7dfc73bb9de5941a6b50108` | GPL-2.0-or-later |

Each must be pure Python: iPadOS runs no code that is not signed into the app.
