# 120F

an iOS tweak that's capable of arbitrarily modifying graphical related settings in Limbus Company by leveraging public classes found in Assembly CSharp.

the sole purpose of this tweak is to give more flexibility and fine-tuning capabilities regarding graphical settings targeting performance.

## What's included

- Independent Normal/Combat FPS targeting by calling `UnityEngine.Application.set_targetFrameRate` directly through IL2CPP - not by spoofing a `CADisplayLink`. A display link is just UnityFramework's own frame pacer, downstream of Unity's real `targetFrameRate`; Unity resyncs it on virtually every scene/config reload (most visibly loading screens), which would silently revert a spoofed value. Writing `targetFrameRate` itself removes that footgun. There's no timer re-asserting the value against something fighting it, either - a scene-state poll (`FPS120Controller`, originally written just to flip Menu/Combat FPS on entering/leaving a battle node) now also detects the transition back to a non-battle scene and re-pushes every setting in the panel, not just FPS, since a loading screen resets far more than the frame rate.
- A pull-tab debug panel (`GraphicsDebugOverlay.m`) for live-tuning render settings: texture mip limit, render scale, MSAA, HDR, extended URP Post FX (Motion Blur, Chromatic Aberration, Vignette, Film Grain, Lens Distortion, White Balance, Saturation, Tonemapping), and Camera AA (antialiasing mode/quality/dithering).
- A Mods section (same panel) for swapping in desktop-coded FMOD `.bank` mods on mobile - see `BankTransplant.h`/`.m`. **Theory-stage**: splicing is implemented and should be mechanically correct, but whether a spliced bank actually plays depends on the mobile FMOD runtime having Vorbis linked in, which hasn't been confirmed on-device yet.

None of this touches `LocalGameOptionData` or the save system - values are live/in-memory only, and opening the game's own settings menu and hitting Apply will stomp them back to the last saved preset. See the header comment in `GraphicsDebugOverlay.m` for the full list of caveats (e.g. Bloom controls were confirmed dead in-game and removed; Camera AA is unvalidated against the live binary since a UI-heavy gacha/VN game may route battle/story through untagged cameras).

## Layout

- `GDScripts.h` / `.m` - every IL2CPP-mediated engine call in the tweak: frame rate and the scene-state poll (`FPS120Controller`), QualitySettings/urpAsset (texture mip, render scale, MSAA, HDR), the URP Volume Post FX stack, renderer features, and camera AA/dithering. Also owns the hardcoded setting defaults, the current-value globals every row in the panel reads/writes, and JSON settings persistence. This is the only file that reaches into the game's managed classes.
- `GraphicsDebugOverlay.m` - UI only. Builds the panel and calls into `GDScripts.h` to read/write each control's current value and push a change to the engine.
- `IL2CppBridge.h` / `.m` - low-level, feature-agnostic wrapper around the handful of `libil2cpp` C API entry points (class/method/field lookup, invoke). `GDScripts.m` is its only caller.
- `fps120.m` - dylib entry point/startup glue only: waits for the runtime to be ready, then hands off to `FPS120Controller` and configures the Unity view's Metal layer.
- `BankTransplant.h` / `.m` - imports a modded (desktop, Vorbis-coded) FMOD `.bank` by decoding each Vorbis sample, re-encoding it to the Mobile client's FADPCM format, rebuilding the stock FSB5 sample headers, and replacing the matching stock `.bank` under `Documents/Assets/Sound/FMODBuilds/Mobile`. The original stock bank is backed up once before modification. `FSB5VorbisSetupTable.bin` supplies the FMOD Vorbis setup packets required by the decoder, and the build embeds that table into the tweak dylib. `GraphicsDebugOverlay.m`'s Mods section (Import Bank Mod / Restore Originals) is the only caller.

`GameEngineControl.h`/`.m` doesn't exist - earlier versions of this README described it as the intended home for the engine calls above, but it was never actually built. `GDScripts.h`/`.m` is that file, under a different name.
