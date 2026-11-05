-- ui/tooltip/surface_guard.lua
--- Retains shared tooltip native ownership across preview module reloads.
--- A debt belongs to the exact preview and renderer that created it; a
--- replacement may not overwrite the surface until that owner settles it.
return { debt = nil, cleanup_busy = false, render_busy = false }
