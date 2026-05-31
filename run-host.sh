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

# Allow local (same-host) clients — i.e. the container over the mounted socket.
xhost +local: >/dev/null

# Pass through any of these tunables if the caller set them.
envs=()
for v in GAME_W GAME_H DESK_W DESK_H FS_MODE SCREEN_FS USE_DXVK; do
    [ -n "${!v:-}" ] && envs+=(-e "$v=${!v}")
done

gpu=()
[ -e /dev/dri ] && gpu=(--device /dev/dri)

# --net host: lets the container reach the host X server's abstract socket
#   (@/tmp/.X11-unix/X0) directly — works even when the daemon's /tmp differs
#   from your session's. The bind-mount is the fallback path-socket for plain
#   hosts where the abstract namespace isn't shared.
docker rm -f "$NAME" >/dev/null 2>&1 || true
exec docker run --rm --name "$NAME" \
    --net host \
    -e DISPLAY="$DISPLAY" \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    "${gpu[@]}" "${envs[@]}" \
    "$IMAGE"
