# Game — in the browser

Runs the Windows Unity build of the game headlessly inside Docker
(via Wine) and streams it to your browser over noVNC. With a GPU exposed it
renders on the Intel GPU through **DXVK** (Direct3D → Vulkan); otherwise it
falls back to software rendering.

```
Browser ──http://localhost:6080──▶ noVNC ─▶ x11vnc ─▶ Xwayland (DRI3) ─▶ Wine + DXVK ─▶ Intel GPU
                                                         └─ sway (headless compositor on the render node)
```

## Prerequisites

- **Docker**
- For GPU rendering: a host GPU whose DRM render node is available at
  `/dev/dri/renderD128` (passed in with `--device /dev/dri`). Tested with Intel
  UHD Graphics. No GPU? It still works — see [Software mode](#software-mode).

## Quick start

```bash
# 1. Build the image (first build downloads Wine + Mesa, takes a few minutes)
docker build -f Dockerfile.wine -t wine .

# 2. Run it
docker run -d --name game --device /dev/dri -p 6080:6080 wine

# 3. Open the game in your browser
#    http://localhost:6080/vnc.html
```

The first launch initializes the Wine prefix, so give it ~30–60 s before the
menu appears. Follow startup progress with:

```bash
docker logs -f game
```

Stop / start / remove:

```bash
docker stop game
docker start game
docker rm -f game
```

## Configuration

Pass these with `-e NAME=value` on `docker run`:

| Variable             | Default     | Meaning                                                        |
|----------------------|-------------|----------------------------------------------------------------|
| `GAME_W` / `GAME_H`  | `1920` / `1080` | Render resolution. `1440`/`1080` gives native 4:3.         |
| `USE_GPU`            | `1`         | `1` = GPU (sway + Xwayland + DXVK). `0` = software (Xvfb + WineD3D). |
| `USE_DXVK`           | `= USE_GPU` | Force the renderer independently of `USE_GPU`.                 |
| `FS_MODE`            | `1`         | Unity fullscreen mode: `1` = borderless (fills view), `3` = windowed. |
| `SCREEN_FS`          | `1`         | Unity `-screen-fullscreen` flag (`1`/`0`).                     |

Examples:

```bash
# Native 4:3 resolution
docker run -d --name game --device /dev/dri -p 6080:6080 -e GAME_W=1440 -e GAME_H=1080 wine

# Windowed (with title bar) instead of borderless
docker run -d --name game --device /dev/dri -p 6080:6080 -e FS_MODE=3 -e SCREEN_FS=0 wine
```

### Software mode

No GPU (or `/dev/dri` not available)? Run without the device and force the
software path — slower, but works anywhere:

```bash
docker run -d --name game -p 6080:6080 -e USE_GPU=0 wine
```

If `/dev/dri/renderD128` is missing, the GPU path automatically falls back to
software on its own.

## How it works

A traditional `Xorg` can't be used for the GPU here — it needs **DRM master**,
which the host's desktop compositor already holds. Instead:

- **sway** runs headless on the GPU's **render node** (no DRM master needed, so
  it coexists with the host session) and acts as the GPU compositor.
- A **rootful Xwayland** runs on top — a real X server exposing **DRI3 + Present**,
  which is what DXVK needs to render on the GPU. Rootful (vs. sway's built-in
  rootless Xwayland) gives a single composited X root that **x11vnc** can capture.
- **x11vnc → websockify → noVNC** delivers it to the browser, scaled to fit.

See `entrypoint.sh` (display + VNC orchestration) and `run-game.sh` (Wine prefix
setup + game launch) for the details.

## Troubleshooting

- **Browser shows gray / "Failed to connect":** give it a moment on first boot,
  then refresh. Check `docker logs game` for `Launching game`.
- **Image is clipped, not scaled:** force-refresh the page (Ctrl+Shift+R) — the
  scale-to-fit setting is applied via the served `vnc.html`.
- **`/dev/dri/renderD128 missing`** in the logs: you didn't pass `--device /dev/dri`,
  or the host has no usable GPU; it falls back to software automatically.
- **Confirm GPU rendering:** `docker logs game | grep GPU:` should show your GPU
  (e.g. `Mesa Intel(R) UHD Graphics`), and the in-game HUD shows the Vulkan device.
