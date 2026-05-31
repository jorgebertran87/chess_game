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

# --- Persistent shader caches (live in the prefix volume, so they survive --rm).
#     Compiling pipelines once instead of every launch is the difference between
#     a stuttery cold start and a smooth warm one.
export DXVK_STATE_CACHE_PATH=${DXVK_STATE_CACHE_PATH:-$WINEPREFIX/cache/dxvk}
export MESA_SHADER_CACHE_DIR=${MESA_SHADER_CACHE_DIR:-$WINEPREFIX/cache/mesa}
mkdir -p "$DXVK_STATE_CACHE_PATH" "$MESA_SHADER_CACHE_DIR" 2>/dev/null

# --- Initialize the Wine prefix once (timeout-guarded so it can't hang forever).
#     With a persisted prefix volume this runs only on the very first launch;
#     every subsequent start skips straight to the game.
if [ ! -f "$WINEPREFIX/.initialized" ]; then
    echo "[run-game] Initializing Wine prefix at $WINEPREFIX (first run only) ..."
    timeout 150 wineboot --init 2>/dev/null || wineserver -w 2>/dev/null
    touch "$WINEPREFIX/.initialized"
    echo "[run-game] Wine prefix ready."
else
    # Prefix already initialized; if the Wine build changed (e.g. an image
    # rebuild), let Wine quietly update the prefix in place.
    WINE_VER_NOW=$(wine --version 2>/dev/null)
    if [ "$(cat "$WINEPREFIX/.wine_version" 2>/dev/null)" != "$WINE_VER_NOW" ]; then
        echo "[run-game] Wine changed to $WINE_VER_NOW; updating prefix ..."
        timeout 120 wineboot -u 2>/dev/null || true
    fi
fi
wine --version 2>/dev/null > "$WINEPREFIX/.wine_version"

# --- Expose the game (copied to the Linux path /game) as C:\game.
ln -sfn /game "$WINEPREFIX/drive_c/game"

# Detect the main game executable (the Unity player .exe, not the crash handler)
# and the Unity product name (basename without .exe), used for the registry path.
GAME_EXE=$(find /game -maxdepth 1 -name '*.exe' ! -iname 'UnityCrashHandler*' | head -1)
if [ -z "$GAME_EXE" ]; then
    echo "[run-game] ERROR: no game executable found in /game" >&2
    exit 1
fi
GAME_BASENAME=$(basename "$GAME_EXE")
PRODUCT="${GAME_BASENAME%.exe}"

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
    UREG="HKCU\\Software\\DefaultCompany\\$PRODUCT"
    wine reg add "$UREG" /v "Screenmanager Fullscreen mode_h3630240806"   /t REG_DWORD /d "$FS_MODE" /f 2>/dev/null
    wine reg add "$UREG" /v "Screenmanager Is Fullscreen mode_h3981298716" /t REG_DWORD /d "$IS_FS"   /f 2>/dev/null
    wine reg add "$UREG" /v "Screenmanager Resolution Width_h182942802"    /t REG_DWORD /d "$GAME_W"  /f 2>/dev/null
    wine reg add "$UREG" /v "Screenmanager Resolution Height_h2627697771"  /t REG_DWORD /d "$GAME_H"  /f 2>/dev/null
    echo "$PREF_SIG" > "$WINEPREFIX/.screen_prefs"
fi

# --- NVIDIA PRIME render offload (opt-in: GPU=nvidia). Forces the Vulkan device
#     onto the NVIDIA dGPU and lets its driver copy the rendered frame back to the
#     Intel-driven X server. The NVIDIA Optimus implicit layer (NVIDIA_only) hides
#     the Intel GPU from Vulkan enumeration so DXVK can only pick the dGPU. Driver
#     libraries + the ICD/layer JSON are injected by the NVIDIA Container Toolkit.
if [ "${GPU:-intel}" = "nvidia" ]; then
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __VK_LAYER_NV_optimus=NVIDIA_only
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    unset MESA_LOADER_DRIVER_OVERRIDE
    # Use the injected NVIDIA Vulkan ICD instead of the baked-in Intel one.
    NV_ICD=$(ls /usr/share/vulkan/icd.d/nvidia_icd*.json \
                /etc/vulkan/icd.d/nvidia_icd*.json 2>/dev/null | head -1)
    if [ -n "$NV_ICD" ]; then export VK_ICD_FILENAMES="$NV_ICD"; else unset VK_ICD_FILENAMES; fi
    # Persist NVIDIA's GLSL/pipeline cache in the prefix volume too.
    export __GL_SHADER_DISK_CACHE=1
    export __GL_SHADER_DISK_CACHE_PATH="$MESA_SHADER_CACHE_DIR"
    echo "[run-game] GPU target: NVIDIA dGPU (PRIME offload, ICD=${VK_ICD_FILENAMES:-auto})"
fi

# --- Pick the renderer.
if [ "$USE_DXVK" = "1" ]; then
    # DXVK (D3D -> Vulkan -> Intel GPU). Requires a DRI3-capable X server
    # (Xwayland), which the GPU entrypoint path provides.
    # Version the marker so a DXVK upgrade in a rebuilt image reinstalls the
    # DLLs into an already-persisted prefix instead of keeping the old ones.
    DXVK_MARKER="$WINEPREFIX/.dxvk_installed_${DXVK_VERSION:-unknown}"
    if [ ! -f "$DXVK_MARKER" ]; then
        DXVK_DIR=$(find /opt -maxdepth 1 -name "dxvk-*" -type d | sort -V | tail -1)
        cp "$DXVK_DIR"/x64/*.dll "$WINEPREFIX/drive_c/windows/system32/" 2>/dev/null
        cp "$DXVK_DIR"/x32/*.dll "$WINEPREFIX/drive_c/windows/syswow64/" 2>/dev/null
        rm -f "$WINEPREFIX"/.dxvk_installed* 2>/dev/null
        touch "$DXVK_MARKER"
        echo "[run-game] Installed DXVK $(basename "$DXVK_DIR")"
    fi
    export WINEDLLOVERRIDES="mscoree,mscorwks=;d3d11=n,b;d3d10core=n,b;dxgi=n,b;d3d9=n,b"
    # HUD off by default (it costs frames). Opt in with -e DXVK_HUD=fps,devinfo.
    export DXVK_HUD=${DXVK_HUD:-}
    GPU_LABEL=$([ "${GPU:-intel}" = "nvidia" ] && echo "NVIDIA dGPU" || echo "Intel GPU")
    echo "[run-game] Renderer: DXVK ${DXVK_VERSION:-} (Vulkan / $GPU_LABEL)  fsync=${WINEFSYNC:-0} esync=${WINEESYNC:-0}"
else
    # Built-in WineD3D (D3D -> OpenGL). Works on a plain X server (Xvfb).
    export WINEDLLOVERRIDES="mscoree,mscorwks=;d3d11=b;d3d10core=b;dxgi=b;d3d9=b"
    echo "[run-game] Renderer: WineD3D (OpenGL)"
fi

WINE_BIN=$(command -v wine64 2>/dev/null || command -v wine 2>/dev/null || echo /opt/wine-staging/bin/wine)

MODE_NAME=$([ "$FS_MODE" = "3" ] && echo windowed || echo borderless)
echo "[run-game] Launching game ($MODE_NAME ${GAME_W}x${GAME_H} in ${DESK_W}x${DESK_H} desktop)..."
exec "$WINE_BIN" explorer "/desktop=game,${DESK_W}x${DESK_H}" \
    "C:\\game\\$GAME_BASENAME" \
    -screen-width "$GAME_W" -screen-height "$GAME_H" -screen-fullscreen "$SCREEN_FS"
