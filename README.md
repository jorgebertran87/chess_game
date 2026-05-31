# Game — on your own display

Runs the Windows Unity build of the game inside Docker (via Wine) and draws it
**directly onto the host's display** — the game window opens on your own desktop.
With the host GPU exposed it renders on the Intel GPU through **DXVK**
(Direct3D → Vulkan); otherwise it falls back to software rendering.

```
Wine + DXVK ─▶ host X server (Xwayland, DRI3/Present) ─▶ Intel GPU ─▶ your desktop
   (in the container)            (on the host, via the mounted X11 socket + /dev/dri)
```

## Performance

The launch path is tuned so the game starts fast and runs smoothly:

- **wine-staging + fsync/esync.** Uses the kernel `futex_waitv` fast-sync path
  (`WINEFSYNC=1`, esync fallback) instead of the slow server-side synchronization
  — a big CPU win for the multithreaded Unity runtime. `run-host.sh` raises the
  open-file limit, which esync needs.
- **DXVK 2.4.1.** Uses `VK_EXT_graphics_pipeline_library` on Intel ANV, so shaders
  compile in the background instead of hitching the frame.
- **Persistent Wine prefix + shader caches.** The prefix, the DXVK pipeline state
  cache, and the Mesa pipeline cache live in a named Docker volume
  (`game-wineprefix`). The **first** launch does the one-time prefix/DXVK setup
  (~30–60 s); **every launch after that is near-instant** and free of
  recompile stutter. (Previously, `--rm` discarded all of this on every run.)

Reset everything (force a clean first-run setup) with:

```bash
docker volume rm game-wineprefix
```

## Prerequisites

- **Docker**
- A running X server on the host. On a Wayland desktop (GNOME/KDE Wayland),
  **Xwayland** already provides this at `DISPLAY=:0` — nothing to install.
- For GPU rendering: the host GPU's DRM render node at `/dev/dri/renderD128`,
  passed in with `--device /dev/dri`. No GPU? It falls back to software.

## Quick start

```bash
# 1. Build the image (first build downloads Wine + Mesa, takes a few minutes)
docker build -f Dockerfile.wine -t wine .

# 2. Run it — the game window opens on your desktop
./run-host.sh
```

`run-host.sh` runs `xhost +local:` (so the container may connect to your X
server) and then starts the container with the host X11 socket and GPU render
node mounted. The first launch initializes the Wine prefix, so give it ~30–60 s
before the window appears.

### Manual run (what the script does)

```bash
# Let local clients (the container) talk to your X server.
xhost +local:

docker run --rm --name game \
    --net host \
    --device /dev/dri \
    -e DISPLAY=$DISPLAY \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    wine
```

`--net host` is what makes this robust: it lets the container reach the X
server's **abstract** socket (`@/tmp/.X11-unix/X0`) in the host network
namespace. That matters because the Docker daemon's `/tmp` is not always the
same `/tmp` as your desktop session — e.g. here the daemon's `/tmp/.X11-unix`
held an unrelated `X99`, not your real `X0`, so the bind-mount alone connected
to the wrong (or no) display. With `--net host` the connection uses the abstract
socket directly; the `-v /tmp/.X11-unix` bind-mount stays only as a fallback
path-socket for plain hosts where the abstract namespace isn't shared.

Stop it with `Ctrl-C`, or `docker rm -f game` from another terminal.
When you're done, you can revoke the X access grant with `xhost -local:`.

## Configuration

Pass these with `-e NAME=value` (or as env vars to `run-host.sh`):

| Variable             | Default     | Meaning                                                        |
|----------------------|-------------|----------------------------------------------------------------|
| `GAME_W` / `GAME_H`  | `1920` / `1080` | Render resolution. `1440`/`1080` gives native 4:3.         |
| `USE_DXVK`           | `1`         | `1` = DXVK on the host GPU. `0` = software (WineD3D).          |
| `FS_MODE`            | `3`         | Unity fullscreen mode: `3` = windowed (a window on your desktop), `1` = borderless. |
| `SCREEN_FS`          | `0`         | Unity `-screen-fullscreen` flag (`1`/`0`).                     |
| `GPU`                | `intel`     | `intel` = host iGPU via `/dev/dri`. `nvidia` = render on the NVIDIA dGPU (see below). |
| `DXVK_HUD`           | *(off)*     | DXVK overlay, e.g. `fps` or `fps,devinfo,gpuload`. Off by default (it costs frames). |
| `WINEFSYNC` / `WINEESYNC` | `1` / `1` | Wine fast-sync backends. Leave on; harmless if the kernel lacks them. |
| `PREFIX_VOL`         | `game-wineprefix` | Docker volume holding the Wine prefix + shader caches. |

Examples:

```bash
# Native 4:3 resolution
GAME_W=1440 GAME_H=1080 ./run-host.sh

# Borderless fullscreen (takes over the screen)
FS_MODE=1 SCREEN_FS=1 ./run-host.sh

# Force software rendering
USE_DXVK=0 ./run-host.sh

# Render on the NVIDIA dGPU instead of the Intel iGPU (opt-in, see below)
GPU=nvidia ./run-host.sh
```

The game runs inside a Wine virtual-desktop window of `GAME_W`×`GAME_H`, so it
stays a single, well-behaved window on your desktop regardless of mode.

### NVIDIA dGPU (opt-in, experimental)

`GPU=nvidia ./run-host.sh` renders the game on a discrete NVIDIA GPU via Vulkan
and PRIME render offload — DXVK draws on the dGPU and the NVIDIA driver copies
each frame back to the Intel-driven display. The default (`GPU=intel`) is
unchanged.

```
DXVK ─▶ NVIDIA dGPU (Vulkan, NVIDIA_only) ─▶ PRIME copy ─▶ Intel-backed X server ─▶ desktop
```

Prerequisites on the **host**:

1. The proprietary **NVIDIA driver** installed and the module loaded — verify
   with `nvidia-smi -L`. On an Optimus laptop the dGPU is often powered down;
   wake it / set a PRIME profile that keeps it available.
2. The **NVIDIA Container Toolkit** installed and configured for Docker, with a
   **CDI spec generated** so the GL/Vulkan (graphics) libraries are injected, not
   just compute:
   ```bash
   sudo apt-get install -y nvidia-container-toolkit
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml   # graphics libs + ICD
   sudo systemctl restart docker     # (snap Docker: sudo snap restart docker)
   ```

`run-host.sh` then starts the container with `--runtime=nvidia` (the portable
choice — **snap-packaged Docker rejects `--gpus all`**) and forces Vulkan onto
the dGPU (`__NV_PRIME_RENDER_OFFLOAD=1`, `__VK_LAYER_NV_optimus=NVIDIA_only`). If
the NVIDIA graphics libraries aren't injected, the container falls back to the
Intel GPU automatically.

> **Status (verified):** on this machine the driver works and `--runtime=nvidia`
> injects the GPU device + `nvidia-smi`, but **graphics injection was incomplete**
> without a generated CDI spec — the NVIDIA Vulkan ICD failed to initialize, so
> DXVK couldn't use the dGPU. Step 2's `cdi generate` is what supplies the
> Vulkan ICD + the full, version-matched library set (assembling it by hand is
> brittle and breaks on driver updates). PRIME-offload presentation to an
> Intel-backed X server also varies by driver version — hence "experimental".
> For a lightweight game the Intel default is more than enough.

## How it works

The container is a plain X client of the host:

- `--net host` + `DISPLAY=$DISPLAY` lets Wine connect to the **host's X server**
  through its **abstract** socket (`@/tmp/.X11-unix/X0`), which lives in the host
  network namespace. The `-v /tmp/.X11-unix` bind-mount is a fallback path-socket
  for hosts that don't share the abstract namespace. On Wayland that X server is
  **Xwayland**, which exposes **DRI3 + Present** — what DXVK needs for GPU
  rendering.
- `--device /dev/dri` gives the container the host GPU's render node, so DXVK
  renders on the Intel GPU and the result is composited into your session like
  any other window.
- `xhost +local:` authorizes the container's connection (single-user desktop).

See `entrypoint.sh` (host-display checks + renderer selection) and `run-game.sh`
(Wine prefix setup + game launch).

## Troubleshooting

- **`cannot reach the host X server`:** run `xhost +local:` on the host, and make
  sure you passed `--net host -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix`.
  `run-host.sh` does all of this for you. If it still fails, the daemon's `/tmp`
  likely differs from your session's `/tmp` (so the bind-mounted socket is the
  wrong one) — `--net host` is what works around that by using the abstract
  socket; confirm you didn't drop it.
- **No window appears:** first boot initializes the Wine prefix; wait a bit, then
  check `docker logs game` for `Launching game`.
- **`/dev/dri/renderD128 missing`** in the logs: you didn't pass `--device /dev/dri`,
  or the host has no usable GPU — it falls back to software automatically.
- **Confirm GPU rendering:** `docker logs game | grep GPU:` should show your GPU
  (e.g. `Mesa Intel(R) UHD Graphics`), and the in-game HUD shows the Vulkan device.
