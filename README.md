# ZSingularity

an iOS tweak that's capable of arbitrarily modifying graphical related settings in Limbus Company by leveraging public classes found in Assembly CSharp.

It also possesses a cosmetic mod loader, a feature exclusive to desktop, now brought to the iPhone. It works by sending over the bundles into a private repo with AssetTools.NET running, the workflow re-encodes and re-targets the bundle for us, then returns it for us to load it in

the sole purpose of this tweak is to give more flexibility and fine-tuning capabilities regarding graphical settings targeting performance.

## What's included

- Independent Normal/Combat FPS targeting by calling `UnityEngine.Application.set_targetFrameRate` directly through IL2CPP - not by spoofing a `CADisplayLink`. A display link is just UnityFramework's own frame pacer, downstream of Unity's real `targetFrameRate`; Unity resyncs it on virtually every scene/config reload (most visibly loading screens), which would silently revert a spoofed value. Writing `targetFrameRate` itself removes that footgun. There's no timer re-asserting the value against something fighting it, either - a scene-state poll (`FPS120Controller`, originally written just to flip Menu/Combat FPS on entering/leaving a battle node) now also detects the transition back to a non-battle scene and re-pushes every setting in the panel, not just FPS, since a loading screen resets far more than the frame rate.
- A pull-tab debug panel (`GraphicsDebugOverlay.m`) for live-tuning render settings: texture mip limit, render scale, MSAA, HDR, extended URP Post FX (Motion Blur, Chromatic Aberration, Vignette, Film Grain, Lens Distortion, White Balance, Saturation, Tonemapping), and Camera AA (antialiasing mode/quality/dithering).
- A Mods section (same panel) for swapping in desktop-coded FMOD `.bank` mods on mobile - see `BankTransplant.h`/`.m`. The mobile client plays Vorbis-coded FSB5 samples natively, so this is a direct file swap - no re-encoding.

None of this touches `LocalGameOptionData` or the save system - values are live/in-memory only, and opening the game's own settings menu and hitting Apply will stomp them back to the last saved preset. See the header comment in `GraphicsDebugOverlay.m` for the full list of caveats (e.g. Bloom controls were confirmed dead in-game and removed; Camera AA is unvalidated against the live binary since a UI-heavy gacha/VN game may route battle/story through untagged cameras).

## Layout

- `GDScripts.h` / `.m` - every IL2CPP-mediated engine call in the tweak: frame rate and the scene-state poll (`FPS120Controller`), QualitySettings/urpAsset (texture mip, render scale, MSAA, HDR), the URP Volume Post FX stack, renderer features, and camera AA/dithering. Also owns the hardcoded setting defaults, the current-value globals every row in the panel reads/writes, and JSON settings persistence. This is the only file that reaches into the game's managed classes.
- `GraphicsDebugOverlay.m` - UI only. Builds the panel and calls into `GDScripts.h` to read/write each control's current value and push a change to the engine.
- `IL2CppBridge.h` / `.m` - low-level, feature-agnostic wrapper around the handful of `libil2cpp` C API entry points (class/method/field lookup, invoke). `GDScripts.m` is its only caller.
- `fps120.m` - dylib entry point/startup glue only: waits for the runtime to be ready, then hands off to `FPS120Controller` and configures the Unity view's Metal layer.
- `BankTransplant.h` / `.m` - imports a modded FMOD `.bank` by directly replacing the matching stock `.bank` under `Documents/Assets/Sound/FMODBuilds/Mobile` with the modded file's bytes as-is - no decoding, re-encoding, or header rebuilding, since the mobile client already plays Vorbis-coded FSB5 samples natively. The original stock bank is backed up once before modification. `GraphicsDebugOverlay.m`'s Mods section (Import Bank Mod / Restore Originals) is the only caller.

- `PatchManifestNetwork.h` / `.m` - hooks the game's own `NSURLSession` delegate to intercept its FMOD manifest fetch (`FmodPatchInfo.json`) in flight and zero out every entry's Hash/Size in the response's `Files` dictionary before it reaches the game, so locally-swapped assets don't fail its integrity check. Deactivates itself for the rest of the session once it's patched a manifest once. It works passively at the network layer whenever the game itself fetches the manifest - it isn't called directly by `BankTransplant.m`.
- `LZ4BlockDecoder.h` / `.m` - from-scratch decoder for raw LZ4/LZ4HC blocks (the format UnityFS bundles actually contain, not the `.lz4` frame format). Only used by `UnityBundleCAB.m`, to decompress a bundle's blocks-info blob.
- `UnityBundleCAB.h` / `.m` - reads a UnityFS archive's own directory table to recover its real identity: the `CAB-<hash>` name stored as node[0], which is the one reliable way to tell a bundle's own name apart from the many other CAB strings referenced inside it (shared dependencies). Back in this build after being retired along with the old `BundleTransplant.m` - see `UnityCacheLocator.h` for its new caller.
- `UnityCacheLocator.h` / `.m` - the CAB-based bundle lookup this project used to have, reimplemented as its own class: reads the CAB off a modded/doctored bundle, then searches `Library/UnityCache/Shared` for a cached file that reports the same CAB as its own identity. Lets the doctor pipeline (`BundleDoctorService.h`/`BundleDoctorInstaller.h`) skip the manual "pick the stock bundle" file-picker step when a match is found, falling back to that picker otherwise.

`GameEngineControl.h`/`.m` doesn't exist - earlier versions of this README described it as the intended home for the engine calls above, but it was never actually built. `GDScripts.h`/`.m` is that file, under a different name.


Bank-kind mods (`BankTransplant.h`/`.m`, a direct FMOD `.bank` byte swap with no Unity object parsing involved) and the network manifest patch (`PatchManifestNetwork.h`/`.m`) are unaffected and still work.
