#!/bin/bash
# Orchestrator: bring up a display + VNC, then hand off to run-game.sh.
#
# Two display stacks:
#   USE_GPU=1 (default): sway (headless wlroots backend on the Intel *render
#       node*, no DRM master -> coexists with the host GNOME session) + Xwayland.
#       Xwayland is a real X server exposing DRI3 + Present, so DXVK can render
#       on the Intel GPU. VNC via wayvnc (captures the sway output).
#   USE_GPU=0: Xvfb + openbox + x11vnc. Software rendering via WineD3D. No GPU,
#       but works anywhere (no /dev/dri needed).
#
# A real Xorg + modesetting (KMS) is intentionally NOT used: it requires DRM
# master on the GPU, which the host's compositor already holds, so it fails with
# "drmSetMaster: Permission denied". Xwayland on the render node sidesteps that.

export USE_GPU=${USE_GPU:-1}
# GPU path defaults to DXVK; software path defaults to WineD3D.
export USE_DXVK=${USE_DXVK:-$USE_GPU}
# Display geometry. 1920x1080 (16:9) fills a widescreen browser edge-to-edge;
# the game's 4:3 UI pillarboxes itself within it. Desktop defaults to the game
# size so borderless fills it exactly (no Wine window chrome). Override to taste,
# e.g. GAME_W=1440 GAME_H=1080 for native 4:3.
export GAME_W=${GAME_W:-1920}; export GAME_H=${GAME_H:-1080}
export DESK_W=${DESK_W:-$GAME_W}; export DESK_H=${DESK_H:-$GAME_H}

rm -f /tmp/.X*-lock /tmp/.X11-unix/X* 2>/dev/null

banner() {
    echo ""
    echo "=========================================="
    echo "  Open your browser at:"
    echo "  http://localhost:6080/vnc.html"
    echo "  Renderer: $([ "$USE_DXVK" = 1 ] && echo 'DXVK (Intel GPU)' || echo 'WineD3D (software)')"
    echo "=========================================="
    echo ""
}

# Make noVNC scale the remote framebuffer to fit the browser window (otherwise
# the fixed-size display is shown 1:1 and clipped). This noVNC build ignores
# defaults.json/mandatory.json and persists the "resize" setting in the browser's
# localStorage (default "off", which then wins over any default). So we inject an
# inline script that forces localStorage["resize"]="scale" before noVNC's
# deferred module reads it — overriding any previously stored value on each load.
NOVNC_HTML=/usr/share/novnc/vnc.html
if [ -f "$NOVNC_HTML" ] && ! grep -q FORCE_SCALE "$NOVNC_HTML"; then
    sed -i "s#<head>#<head><script>/*FORCE_SCALE*/try{localStorage.setItem('resize','scale');}catch(e){}</script>#" "$NOVNC_HTML"
fi

if [ "$USE_GPU" = "1" ]; then
    # ---------- GPU stack: sway (headless) + Xwayland + wayvnc ----------
    PLAYER=player
    PUID=$(id -u "$PLAYER")
    export XDG_RUNTIME_DIR=/run/user/$PUID
    mkdir -p "$XDG_RUNTIME_DIR"
    chown "$PLAYER:$PLAYER" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

    # sway must run unprivileged; give the player the GPU render node.
    if [ -e /dev/dri/renderD128 ]; then
        chmod a+rw /dev/dri/renderD128 2>/dev/null
    else
        echo "[entrypoint] ERROR: /dev/dri/renderD128 missing — run with: --device /dev/dri" >&2
        echo "[entrypoint] Falling back to software (USE_GPU=0)." >&2
        exec env USE_GPU=0 USE_DXVK=0 "$0"
    fi

    # sway is only the GPU compositor host; disable its built-in (rootless)
    # Xwayland — a rootless X root is empty (windows are Wayland surfaces), which
    # is exactly what made VNC gray. We run our own rootful Xwayland instead.
    cat > /tmp/sway.cfg <<EOF
xwayland disable
output HEADLESS-1 resolution ${DESK_W}x${DESK_H}
default_border none
EOF
    chown "$PLAYER" /tmp/sway.cfg

    echo "[entrypoint] Starting sway (headless, Intel render node)..."
    runuser -u "$PLAYER" -- env \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_RENDERER=gles2 \
        WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 WLR_RENDERER_ALLOW_SOFTWARE=0 \
        sway -c /tmp/sway.cfg > /var/log/sway.log 2>&1 &

    # Wait for the Wayland socket.
    for i in $(seq 1 40); do
        [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break
        sleep 0.5
    done

    # Our own ROOTFUL Xwayland: one composited X root (so x11vnc can capture it),
    # still GPU-accelerated with DRI3 + Present so DXVK renders on the Intel GPU.
    # -ac disables access control (single-user container) so x11vnc/Wine connect.
    echo "[entrypoint] Starting rootful Xwayland (:0)..."
    runuser -u "$PLAYER" -- env \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY=wayland-1 \
        Xwayland :0 -ac -noreset > /var/log/xwayland.log 2>&1 &

    echo "[entrypoint] Waiting for Xwayland..."
    for i in $(seq 1 40); do
        runuser -u "$PLAYER" -- env DISPLAY=:0 XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
            xdpyinfo >/dev/null 2>&1 && break
        sleep 0.5
    done
    echo "[entrypoint] GPU: $(runuser -u "$PLAYER" -- env DISPLAY=:0 XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" glxinfo 2>/dev/null | grep 'OpenGL renderer' | sed 's/.*: //')"

    # VNC: x11vnc captures the rootful Xwayland root; websockify serves noVNC.
    runuser -u "$PLAYER" -- env \
        DISPLAY=:0 XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        x11vnc -display :0 -nopw -forever -shared -noxdamage -quiet \
        > /var/log/x11vnc.log 2>&1 &
    websockify --web /usr/share/novnc 6080 localhost:5900 >/var/log/websockify.log 2>&1 &

    banner
    # Launch the game as the player, on the Xwayland display.
    exec runuser -u "$PLAYER" -- env \
        DISPLAY=:0 XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY=wayland-1 \
        HOME="/home/$PLAYER" WINEPREFIX="/home/$PLAYER/.wine" \
        USE_DXVK="$USE_DXVK" GAME_W="$GAME_W" GAME_H="$GAME_H" \
        DESK_W="$DESK_W" DESK_H="$DESK_H" \
        bash /run-game.sh

else
    # ---------- Software stack: Xvfb + openbox + x11vnc ----------
    export DISPLAY=:99
    Xvfb :99 -screen 0 "${DESK_W}x${DESK_H}x24" -dpi 96 &
    echo "[entrypoint] Waiting for Xvfb..."
    for i in $(seq 1 30); do
        xdpyinfo -display :99 >/dev/null 2>&1 && break
        sleep 0.5
    done
    openbox &
    x11vnc -display :99 -nopw -forever -shared -quiet >/var/log/x11vnc.log 2>&1 &
    websockify --web /usr/share/novnc 6080 localhost:5900 >/var/log/websockify.log 2>&1 &

    banner
    # Software/Xvfb path can't do a borderless display switch -> force windowed.
    exec env DISPLAY=:99 HOME=/root WINEPREFIX=/root/.wine \
        USE_DXVK="$USE_DXVK" GAME_W="$GAME_W" GAME_H="$GAME_H" \
        DESK_W="$DESK_W" DESK_H="$DESK_H" FS_MODE=3 SCREEN_FS=0 \
        bash /run-game.sh
fi
