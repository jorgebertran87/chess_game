#!/bin/bash
# Run the Windows game (via Wine) directly on the HOST's display — the game
# window appears on your own desktop.
#
# The container talks to the host X server through the mounted X11 socket
# (DISPLAY is passed in from the host) and renders on the host GPU via the
# mounted /dev/dri render node (DXVK -> Vulkan -> Intel GPU). On a Wayland host,
# DISPLAY=:0 is Xwayland, which exposes DRI3 + Present — exactly what DXVK needs.
#
# Required on the host:
#   xhost +local:                                  # let the container connect
#   docker run --rm --device /dev/dri \
#     -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix wine
set -u

export DISPLAY=${DISPLAY:-:0}
export USE_DXVK=${USE_DXVK:-1}
# Render geometry. The game runs inside a Wine virtual-desktop window of this
# size on your desktop (override with -e GAME_W/GAME_H).
export GAME_W=${GAME_W:-1920}; export GAME_H=${GAME_H:-1080}
export DESK_W=${DESK_W:-$GAME_W}; export DESK_H=${DESK_H:-$GAME_H}
# Default to windowed so it's a normal window on your desktop instead of taking
# over the whole screen. Set FS_MODE=1 SCREEN_FS=1 for borderless fullscreen.
export FS_MODE=${FS_MODE:-3}
export SCREEN_FS=${SCREEN_FS:-0}

# --- Make sure the host X server is actually reachable.
if ! xdpyinfo >/dev/null 2>&1; then
    echo "[entrypoint] ERROR: cannot reach the host X server at DISPLAY=$DISPLAY." >&2
    echo "[entrypoint]   - On the host, allow local connections:  xhost +local:" >&2
    echo "[entrypoint]   - Pass the display + socket to docker run:" >&2
    echo "[entrypoint]       -e DISPLAY=\$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix" >&2
    exit 1
fi

# --- Renderer selection.
export GPU=${GPU:-intel}
if [ "$GPU" = "nvidia" ]; then
    # Opt-in NVIDIA dGPU path. Driver libs + /dev/nvidia* are injected by the
    # NVIDIA Container Toolkit (--gpus all); DXVK renders on the dGPU via Vulkan
    # and the NVIDIA driver PRIME-copies the result to the Intel-driven display.
    if [ -e /dev/nvidiactl ]; then
        echo "[entrypoint] NVIDIA dGPU path; rendering on the NVIDIA GPU via DXVK (PRIME offload)."
        echo "[entrypoint] GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
        export USE_DXVK=1
    else
        echo "[entrypoint] GPU=nvidia but no /dev/nvidiactl in the container." >&2
        echo "[entrypoint]   Start with the NVIDIA Container Toolkit (--gpus all) and install" >&2
        echo "[entrypoint]   nvidia-container-toolkit on the host. Falling back to Intel/software." >&2
        export GPU=intel
        if [ -e /dev/dri/renderD128 ]; then
            echo "[entrypoint] Falling back to DXVK on the Intel GPU."
        else
            export USE_DXVK=0
        fi
    fi
elif [ -e /dev/dri/renderD128 ]; then
    echo "[entrypoint] GPU render node found; using DXVK on the host GPU."
    echo "[entrypoint] GPU: $(glxinfo 2>/dev/null | grep 'OpenGL renderer' | sed 's/.*: //')"
else
    echo "[entrypoint] /dev/dri/renderD128 missing (no --device /dev/dri?) — software rendering (WineD3D)."
    export USE_DXVK=0
fi

# --- Hand off to the Wine prefix setup + launch. Runs as root inside the
#     container; X access is granted on the host via `xhost +local:`.
export HOME=/root WINEPREFIX=/root/.wine
echo "[entrypoint] Launching on host display $DISPLAY ..."
exec bash /run-game.sh
