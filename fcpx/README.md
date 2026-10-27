# CorridorKey for Final Cut Pro (FxPlug 4)

A Final Cut Pro / Motion effect that keys clips with CorridorKey 2.0 on Apple
Silicon.

```
Final Cut Pro ──FxPlug 4 (XPC, sandboxed)──► CorridorKey Renderer.pluginkit
                                                  │  frames over 127.0.0.1:47823
                                                  ▼
                                    ck_server.py  (PyTorch on MPS, model stays loaded)
```

An FxPlug runs as a sandboxed XPC service and can't host PyTorch and ~5 GB of
weights, so the effect hands frames to a local render server. The server caches
frames, per-frame foundation features and results by content hash, so scrubbing
back and forth and re-rendering are cheap.

## Requirements

- Apple Silicon Mac, macOS 14+ (MPS bfloat16). 32 GB+ of unified memory is
  recommended for 4K; 16 GB works at 1080p with small temporal windows.
- Final Cut Pro 10.6.6+ (or Motion 5.6.4+)
- Xcode 15+, and the **FxPlug SDK**:
  <https://developer.apple.com/download/all/?q=FxPlug>. It installs into
  `/Library/Developer/Frameworks` and `/Library/Developer/SDKs`.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## 1. Set up the model (once)

From the repository root (keep it somewhere like `~/CorridorKey2.0`, not in
`~/Documents` or `~/Desktop`, so the login agent isn't blocked by macOS privacy
prompts):

```sh
python3 -m venv venv
source venv/bin/activate
pip install torch==2.9.1 torchvision==0.24.1      # macOS wheels include MPS
pip install -r requirements.txt
python scripts/download_weights.py                 # ~5 GB
python ck_server.py                                # Ctrl-C once it says "model ready on mps"
```

The command-line tool works on the Mac too now (`python infer.py --input clip.mov
--output_dir out`). It picks CUDA, then MPS, then CPU, or you can choose with
`--device`.

## 2. Build and install the effect

```sh
cd fcpx
./build.sh                          # or: DEVELOPMENT_TEAM=XXXXXXXXXX ./build.sh
```

This generates `CorridorKeyFxPlug.xcodeproj`, builds it, copies
`CorridorKey.app` to `~/Applications`, and launches it once. Launching the app
is what registers the plug-in with PlugInKit.

In the app window:

1. Set **CorridorKey folder** to this repository. Python defaults to
   `<folder>/venv/bin/python`.
2. Tick **Start server automatically at login**. This installs a LaunchAgent
   so the server is running whenever Final Cut Pro is. You can use
   **Start Server** instead, but that server stops when you quit the app.
3. Click **Install Final Cut Pro Effect**. This copies the Motion template to
   `~/Movies/Motion Templates.localized/Effects.localized/CorridorKey/`.

Restart Final Cut Pro. The effect is in the Effects browser under
**CorridorKey**.

## Using it

| Parameter | What it does |
|---|---|
| Output | **Composite**: keyed foreground with alpha (premultiplied, despilled). **Matte**: the alpha as grey. **Foreground**: the predicted unmixed foreground, opaque. **Orientation Check**: see below. |
| Temporal Window | How many neighbouring frames the model sees (1/5/9/17). Each is one stage-1 window centred on the frame being rendered, the same as one Hann window in the CLI. Bigger windows are steadier but slower and use more memory. 5 is a good default. 17 at 4K needs a lot of RAM. |
| Despill | 0 = none, 1 = full (same as `--despill_strength`). |
| Matte Black/White Point | Optional levels on the matte. |
| Hint Mode / Hint Matte | Drop a matte clip (roto, garbage matte, rough key) into **Hint Matte**. **Matte Clip** uses it on every frame (`--hint_video`). **First Frame Only** uses it only at the clip's first frame (`--hint_first_frame`). **Hint Channel** reads luminance or alpha. **Hint Trust** is `--hint_quality`. |
| Flip Vertical | Only if the Orientation Check says so. |
| Server Port | Must match the app. Default 47823. |

**Orientation Check**: set Output to it once. A white arrow should appear at the
top-left of the viewer, pointing up. If it shows up at the bottom pointing
down, the host is giving the model upside-down frames (which hurts quality).
Tick **Flip Vertical** to fix it.

If the server isn't running, the effect shows the clip with a **dark red cast**
instead of failing the render. Start the server and re-render.

Rendering is roughly seconds per frame, not real time. Let Final Cut Pro
background-render, or export. Results are cached, so a second pass over the
same frames is fast as long as the server stays up.

## How it maps to the CLI

- Frames arrive as scene-linear RGB (the effect asks for
  `kFxImageColorInfo_RGB_LINEAR`), so this is the CLI's `--frame_dir_linear`
  path, and HDR values above 1.0 survive. Rec. 2020 wide-gamut libraries are
  converted to Rec. 709 for the model and back again.
- No carried Hann hints and no clip-long RVM state: FCP asks for frames in any
  order, so each frame is keyed from its own window. RVM runs fresh over each
  window.
- Full-resolution, no tiling (`kFxPropertyKey_NeedsFullBuffer`).

## Building without XcodeGen

Create a project from Apple's **FxPlug 4** Xcode template (installed with the
SDK). Then:

1. Replace the template's plug-in sources with `Plugin/*.{h,m}`, and the
   wrapper app's sources with `App/*.{h,m}` plus `Plugin/CKClient.{h,m}`.
2. Use `Plugin/Info.plist` and `Plugin/Plugin.entitlements` for the XPC
   target, and add `Metal`, `IOSurface`, `Accelerate` and `CoreMedia`.
3. Add `App/Resources/Motion Templates` to the app target as a folder
   reference.

## Troubleshooting

- `pluginkit -m -p FxPlug | grep -i corridor` should list the renderer. If it
  doesn't, launch `~/Applications/CorridorKey.app` once more.
- Plug-in logs: Console.app, filter on `CorridorKey`. Server log:
  `~/Library/Logs/CorridorKey/ck_server.log`.
- Check the server and protocol without Final Cut Pro:
  `python scripts/test_frame_server.py`. This runs a tiny random-weight model
  on CPU and tests the windowing, caching and socket protocol.
- **If the effect doesn't show up in Final Cut Pro, or its controls are
  missing:** the bundled `.moef` template was written by hand, and Motion
  hasn't opened it yet. Rebuild it in Motion (about 2 minutes):
  1. Open Motion and choose **Final Cut Effect**.
  2. Apply Filters ▸ CorridorKey ▸ CorridorKey to *Effect Source*.
  3. In the Inspector, use each group's pop-up to **Publish** Key, Hint and
     Advanced.
  4. Save it as "CorridorKey" in the category "CorridorKey".

## Credits and license

The Motion template structure is adapted from
[Gyroflow Toolbox](https://github.com/latenitefilms/GyroflowToolbox)
(© Chris Hocking, MIT).

Everything else here falls under CorridorKey's license (see `../LICENSE`).
Anything you release that's built on it has to be free, use the same license,
and keep the CorridorKey name.
