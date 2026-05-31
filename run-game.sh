#!/bin/bash
# Wine prefix setup + game launch. User/display-agnostic: the caller exports
# WINEPREFIX, HOME, DISPLAY and (for the GPU path) the Wayland env, then runs
# this as the right user. Reads USE_DXVK, GAME_W/H, DESK_W/H from the env.
set -u

export WINEARCH=${WINEARCH:-win64}
export WINEDEBUG=${WINEDEBUG:--all}
GAME_W=${GAME_W:-1920}; GAME_H=${GAME_H:-1080}
DESK_W=${DESK_W:-$GAME_W}; DESK_H=${DESK_H:-$GAME_H}
USE_DXVK=${USE_DXVK:-0}
# Unity FullScreenMode: 1=FullScreenWindow (borderless, fills the display, no
# title bar), 3=Windowed. Borderless needs a DRI3/Present-capable X server
# (Xwayland) so the display can be driven at the requested size; on the plain
# Xvfb software path it falls back to windowed to avoid the fatal mode switch.
FS_MODE=${FS_MODE:-1}
SCREEN_FS=${SCREEN_FS:-1}

# Disable winemenubuilder (deadlocks wineboot --init in a headless container)
# and the Mono/Gecko auto-installers during prefix setup.
export WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree=;mscorwks="

# --- Initialize the Wine prefix once (timeout-guarded so it can't hang forever)
if [ ! -f "$WINEPREFIX/.initialized" ]; then
    echo "[run-game] Initializing Wine prefix at $WINEPREFIX ..."
    timeout 150 wineboot --init 2>/dev/null || wineserver -w 2>/dev/null
    touch "$WINEPREFIX/.initialized"
    echo "[run-game] Wine prefix ready."
fi

# --- Expose the game (copied to the Linux path /game) as C:\game.
ln -sfn /game "$WINEPREFIX/drive_c/game"
if [ ! -e "$WINEPREFIX/drive_c/game/game.exe" ]; then
    echo "[run-game] ERROR: game not found at C:\\game" >&2
fi

# --- Suppress the Mono installer dialog.
if [ ! -f "$WINEPREFIX/.mono_suppressed" ]; then
    wine reg add "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" /v Install  /t REG_DWORD /d 1      /f 2>/dev/null
    wine reg add "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full" /v Release /t REG_DWORD /d 461808  /f 2>/dev/null
    touch "$WINEPREFIX/.mono_suppressed"
fi

# --- Seed Unity screen prefs (resolution + fullscreen mode). Re-applied whenever
#     the requested geometry/mode changes, so resizing doesn't need a fresh prefix.
PREF_SIG="${GAME_W}x${GAME_H}:${FS_MODE}"
IS_FS=$([ "$FS_MODE" = "3" ] && echo 0 || echo 1)
if [ "$(cat "$WINEPREFIX/.screen_prefs" 2>/dev/null)" != "$PREF_SIG" ]; then
    UREG="HKCU\\Software\\DefaultCompany\\game"
    wine reg add "$UREG" /v "Screenmanager Fullscreen mode_h3630240806"   /t REG_DWORD /d "$FS_MODE" /f 2>/dev/null
    wine reg add "$UREG" /v "Screenmanager Is Fullscreen mode_h3981298716" /t REG_DWORD /d "$IS_FS"   /f 2>/dev/null
    wine reg add "$UREG" /v "Screenmanager Resolution Width_h182942802"    /t REG_DWORD /d "$GAME_W"  /f 2>/dev/null
    wine reg add "$UREG" /v "Screenmanager Resolution Height_h2627697771"  /t REG_DWORD /d "$GAME_H"  /f 2>/dev/null
    echo "$PREF_SIG" > "$WINEPREFIX/.screen_prefs"
fi

# --- Pick the renderer.
if [ "$USE_DXVK" = "1" ]; then
    # DXVK (D3D -> Vulkan -> Intel GPU). Requires a DRI3-capable X server
    # (Xwayland), which the GPU entrypoint path provides.
    if [ ! -f "$WINEPREFIX/.dxvk_installed" ]; then
        DXVK_DIR=$(find /opt -maxdepth 1 -name "dxvk-*" -type d | head -1)
        cp "$DXVK_DIR"/x64/*.dll "$WINEPREFIX/drive_c/windows/system32/" 2>/dev/null
        cp "$DXVK_DIR"/x32/*.dll "$WINEPREFIX/drive_c/windows/syswow64/" 2>/dev/null
        touch "$WINEPREFIX/.dxvk_installed"
    fi
    export WINEDLLOVERRIDES="mscoree,mscorwks=;d3d11=n,b;d3d10core=n,b;dxgi=n,b;d3d9=n,b"
    export DXVK_HUD=${DXVK_HUD:-devinfo}
    echo "[run-game] Renderer: DXVK (Vulkan / Intel GPU)"
else
    # Built-in WineD3D (D3D -> OpenGL). Works on a plain X server (Xvfb).
    export WINEDLLOVERRIDES="mscoree,mscorwks=;d3d11=b;d3d10core=b;dxgi=b;d3d9=b"
    echo "[run-game] Renderer: WineD3D (OpenGL)"
fi

WINE_BIN=$(command -v wine64 2>/dev/null || command -v wine 2>/dev/null || echo /opt/wine-stable/bin/wine)

MODE_NAME=$([ "$FS_MODE" = "3" ] && echo windowed || echo borderless)
echo "[run-game] Launching game ($MODE_NAME ${GAME_W}x${GAME_H} in ${DESK_W}x${DESK_H} desktop)..."
exec "$WINE_BIN" explorer "/desktop=game,${DESK_W}x${DESK_H}" \
    "C:\\game\\game.exe" \
    -screen-width "$GAME_W" -screen-height "$GAME_H" -screen-fullscreen "$SCREEN_FS"
