#!/bin/bash
# Launch the game on THIS host's display via the Docker image.
# Grants the container access to the host X server, then runs it with the host
# X11 socket and GPU render node mounted. The game window opens on your desktop.
#
#   ./run-host.sh                # windowed, GPU (DXVK)
#   GAME_W=1440 GAME_H=1080 ./run-host.sh   # native 4:3
#   FS_MODE=1 SCREEN_FS=1 ./run-host.sh      # borderless fullscreen
#   USE_DXVK=0 ./run-host.sh                 # force software rendering
set -euo pipefail

IMAGE=${IMAGE:-wine}
NAME=${NAME:-game}
DISPLAY=${DISPLAY:-:0}
# Named volume that holds the initialized Wine prefix + the DXVK/Mesa shader
# caches. Persisting it is what makes warm launches near-instant: the first run
# does the one-time wineboot/DXVK setup, every run after reuses it.
PREFIX_VOL=${PREFIX_VOL:-game-wineprefix}

# Allow local (same-host) clients — i.e. the container over the mounted socket.
xhost +local: >/dev/null

# GPU target: 'intel' (default, host iGPU via /dev/dri) or 'nvidia' (dGPU via the
# NVIDIA Container Toolkit + PRIME render offload).
GPU=${GPU:-intel}

# Pass through any of these tunables if the caller set them.
envs=(-e "GPU=$GPU")
for v in GAME_W GAME_H DESK_W DESK_H FS_MODE SCREEN_FS USE_DXVK \
         DXVK_HUD WINEFSYNC WINEESYNC WINEDEBUG; do
    [ -n "${!v:-}" ] && envs+=(-e "$v=${!v}")
done

# /dev/dri is kept in both cases: on the NVIDIA path the Intel-backed X server
# still presents the PRIME-copied frame, and it gives a graceful fallback.
gpu=()
[ -e /dev/dri ] && gpu=(--device /dev/dri)

if [ "$GPU" = "nvidia" ]; then
    # Render on the NVIDIA dGPU. Requires the NVIDIA driver + container toolkit.
    # Check the driver actually responds (on Optimus laptops the dGPU is often
    # powered down or the module isn't loaded, so nvidia-smi can exist yet fail).
    if ! nvidia-smi -L >/dev/null 2>&1; then
        echo "[run-host] WARNING: the NVIDIA driver is not responding on the host" >&2
        echo "[run-host]   (nvidia-smi failed). The GPU path will fail. Ensure the driver" >&2
        echo "[run-host]   is installed and the module is loaded (Optimus: wake the dGPU)." >&2
    fi
    # Prefer the registered 'nvidia' runtime. snap-packaged Docker REJECTS the
    # legacy '--gpus' hook ("invoking the NVIDIA Container Runtime Hook directly
    # is not supported"), so --runtime=nvidia is the portable choice. The image
    # sets NVIDIA_VISIBLE_DEVICES/NVIDIA_DRIVER_CAPABILITIES=all.
    if docker info 2>/dev/null | grep -qiE 'runtimes:.*nvidia'; then
        gpu+=(--runtime=nvidia)
    else
        echo "[run-host] WARNING: no 'nvidia' Docker runtime registered. Install" >&2
        echo "[run-host]   nvidia-container-toolkit + 'nvidia-ctk runtime configure'." >&2
        echo "[run-host]   Trying --gpus all (works only on non-snap Docker)." >&2
        gpu+=(--gpus all)
    fi
    # NOTE: device/compute injection works, but rendering also needs the NVIDIA
    # *graphics* libraries (Vulkan ICD) injected. That requires a CDI spec from
    # 'sudo nvidia-ctk cdi generate' (or the toolkit's graphics capability). See
    # the NVIDIA section of the README. If they're absent, the container falls
    # back to the Intel GPU automatically.
    echo "[run-host] GPU target: NVIDIA dGPU (runtime=nvidia, PRIME offload)."
else
    echo "[run-host] GPU target: Intel iGPU (DXVK on /dev/dri)."
fi

# --net host: lets the container reach the host X server's abstract socket
#   (@/tmp/.X11-unix/X0) directly — works even when the daemon's /tmp differs
#   from your session's. The bind-mount is the fallback path-socket for plain
#   hosts where the abstract namespace isn't shared.
docker rm -f "$NAME" >/dev/null 2>&1 || true
exec docker run --rm --name "$NAME" \
    --net host \
    --ulimit nofile=1048576:1048576 \
    -e DISPLAY="$DISPLAY" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "$PREFIX_VOL":/root/.wine \
    "${gpu[@]}" "${envs[@]}" \
    "$IMAGE"
