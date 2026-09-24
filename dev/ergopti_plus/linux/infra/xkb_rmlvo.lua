--- infra/xkb_rmlvo.lua

--- ==============================================================================
--- MODULE: Session Layout Names (Linux)
--- DESCRIPTION:
--- Reads WHICH layout the session uses (the layout, variant and options names
--- of XKB's rules/model/layout/variant/options tuple) from the places desktops
--- store it, so a keymap can be compiled when none can be dumped.
---
--- WHY THIS EXISTS:
--- `xkbcli dump-keymap-{wayland,x11}` only appeared in libxkbcommon 1.8.0
--- (February 2025). Ubuntu 24.04 ships 1.6, Debian 12 ships 1.5 and Ubuntu
--- 22.04 ships 1.4, so on the default GNOME Wayland session of every current LTS
--- there was no keymap at all, capture refused the keyboard and the daemon
--- exited at boot. `xkbcli compile-keymap` has existed since 1.0 and produces
--- the same text from the names, so the names are the fallback.
---
--- FEATURES & RATIONALE:
--- 1. Pure parsers. Every source is a text format (gsettings' GVariant print,
---    kxkbrc, localectl, /etc/default/keyboard), so each is driven from a
---    fixture; the shell-outs live in the adapter that calls this.
--- 2. The ACTIVE layout only. A multi-layout session is compiled for its first
---    (GNOME: most recently used) layout, because capture and injection model
---    one group; compiling "fr,us" would type group-1 characters from group 2.
--- 3. Non-XKB input sources are skipped. GNOME lists IBus engines beside XKB
---    layouts, and ('ibus', 'mozc-jp') names no keymap.
--- ==============================================================================

local M = {}




-- ====================================
-- ====================================
-- ======= 1/ Helpers =================
-- ====================================
-- ====================================

--- Trims surrounding whitespace.
--- @param text string
--- @return string
local function trim(text)
	return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Splits a comma list, dropping empty items.
--- @param text string|nil
--- @return table
local function split_commas(text)
	local items = {}
	for item in tostring(text or ""):gmatch("[^,]+") do
		local value = trim(item)
		if value ~= "" then items[#items + 1] = value end
	end
	return items
end

--- Builds a descriptor, or nil when the layout name is unusable.
---
--- Names reach a shell command, so anything outside XKB's own name alphabet is
--- refused here rather than quoted later: a layout named with a quote or a
--- space is not a layout XKB could load anyway.
--- @param layout string|nil
--- @param variant string|nil
--- @param options string|nil
--- @param source string
--- @return table|nil { layout, variant, options, source }
local function descriptor(layout, variant, options, source)
	layout = trim(layout or "")
	variant = trim(variant or "")
	options = trim(options or "")
	if layout == "" or not layout:match("^[%w_%-]+$") then return nil end
	if variant ~= "" and not variant:match("^[%w_%-]+$") then variant = "" end
	if options ~= "" and not options:match("^[%w_%-:,]+$") then options = "" end
	return { layout = layout, variant = variant, options = options, source = source }
end




-- ====================================
-- ====================================
-- ======= 2/ Parsers =================
-- ====================================
-- ====================================

--- Parses GNOME's input sources, e.g. `[('xkb', 'fr+ergopti'), ('ibus', 'x')]`.
--- @param sources_text string `gsettings get … sources` (or mru-sources) output.
--- @param options_text string|nil `gsettings get … xkb-options` output.
--- @return table|nil
function M.parse_gnome(sources_text, options_text)
	for kind, id in tostring(sources_text or ""):gmatch("%(%s*'([^']*)'%s*,%s*'([^']*)'%s*%)") do
		if kind == "xkb" then
			local layout, variant = id:match("^([^+]+)%+(.+)$")
			local options = {}
			for option in tostring(options_text or ""):gmatch("'([^']*)'") do
				options[#options + 1] = option
			end
			return descriptor(layout or id, variant, table.concat(options, ","), "gnome")
		end
	end
	return nil
end

--- Parses KDE Plasma's ~/.config/kxkbrc.
---
--- Plasma ignores the lists unless `Use=true`, so this does too: a stale list
--- left behind by a previous configuration is not the layout the session uses.
--- @param text string File contents.
--- @return table|nil
function M.parse_kxkbrc(text)
	local in_layout, fields = false, {}
	for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local section = line:match("^%s*%[([^%]]+)%]%s*$")
		if section then
			in_layout = section == "Layout"
		elseif in_layout then
			local key, value = line:match("^%s*([%w]+)%s*=(.*)$")
			if key then fields[key] = trim(value) end
		end
	end
	if fields.Use ~= "true" then return nil end
	local layouts = split_commas(fields.LayoutList)
	if #layouts == 0 then return nil end
	-- VariantList is index-aligned with LayoutList and keeps empty slots, so the
	-- first field is read directly rather than through split_commas.
	local variant = (fields.VariantList or ""):match("^([^,]*)")
	return descriptor(layouts[1], variant, fields.Options, "kxkbrc")
end

--- Parses `localectl status`.
--- @param text string
--- @return table|nil
function M.parse_localectl(text)
	text = tostring(text or "")
	local layout = text:match("X11 Layout:%s*([^\n]+)")
	if not layout then return nil end
	local variant = text:match("X11 Variant:%s*([^\n]+)")
	local options = text:match("X11 Options:%s*([^\n]+)")
	return descriptor(split_commas(layout)[1], variant and split_commas(variant)[1] or nil,
		options, "localectl")
end

--- Parses a shell-style `XKBLAYOUT="fr"` file (/etc/default/keyboard,
--- /etc/vconsole.conf).
--- @param text string
--- @return table|nil
function M.parse_keyboard_defaults(text)
	local fields = {}
	for key, value in tostring(text or ""):gmatch("(XKB%u+)%s*=%s*\"?([^\"\n]*)\"?") do
		fields[key] = value
	end
	local layouts = split_commas(fields.XKBLAYOUT)
	if #layouts == 0 then return nil end
	return descriptor(layouts[1], (fields.XKBVARIANT or ""):match("^([^,]*)"),
		fields.XKBOPTIONS, "keyboard-defaults")
end

--- Reads the XKB_DEFAULT_* variables wlroots compositors honour.
--- @param getenv function|nil Defaults to os.getenv.
--- @return table|nil
function M.from_env(getenv)
	getenv = getenv or os.getenv
	local layouts = split_commas(getenv("XKB_DEFAULT_LAYOUT"))
	if #layouts == 0 then return nil end
	return descriptor(layouts[1], (getenv("XKB_DEFAULT_VARIANT") or ""):match("^([^,]*)"),
		getenv("XKB_DEFAULT_OPTIONS"), "env")
end




-- ====================================
-- ====================================
-- ======= 3/ Compilation =============
-- ====================================
-- ====================================

--- The `xkbcli compile-keymap` command for a descriptor.
---
--- Rules and model are left to the library's defaults (evdev/pc105), which is
--- what every desktop compiles with; naming them would only add a way to differ.
--- @param desc table From one of the parsers.
--- @return string
function M.compile_command(desc)
	local parts = { "xkbcli compile-keymap", "--layout " .. desc.layout }
	if desc.variant and desc.variant ~= "" then parts[#parts + 1] = "--variant " .. desc.variant end
	if desc.options and desc.options ~= "" then parts[#parts + 1] = "--options " .. desc.options end
	return table.concat(parts, " ") .. " 2>/dev/null"
end

return M
