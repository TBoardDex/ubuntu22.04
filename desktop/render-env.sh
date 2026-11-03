# Sourced by /bin/sh; keep the choice consistent across GDM, GNOME and apps.
# Renderer variables belong to this integration; discard stale login values.
unset LD_LIBRARY_PATH LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER COGL_DRIVER COGL_RENDERER
if [ "$(cat /etc/rockchip-desktop-renderer 2>/dev/null)" = mali ]; then
    export LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali
    export COGL_DRIVER=gles2 COGL_RENDERER=EGL_XLIB
else
    export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
fi
