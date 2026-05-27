--- ui/menu/preferences.lua

--- ==============================================================================
--- MODULE: Menu Preferences
--- DESCRIPTION:
--- Manages the persistence of the global state to and from the disk. The
--- format is TOML — see lib/toml_codec for the encoder/decoder. The file
--- lives at <config_dir>/hammerspoon/config.toml; legacy config.json is
--- no longer read or written.
---
--- FEATURES & RATIONALE:
--- 1. Single Source of Truth: every menu toggle, gesture assignment,
---    section-state, terminator, and shortcut binding is round-tripped
---    through one TOML file. No JSON shadow store, no per-feature
---    side files.
--- 2. Dynamic Hydration: defaults from each module's DEFAULT_STATE
---    table are folded into the live state at boot; the on-disk TOML
---    overlays user overrides on top.
--- 3. Stable diffs: the encoder sorts keys within each section so two
---    saves of the same state produce byte-identical TOML. Helpful for
---    git-tracked configs and for spotting menu-driven mutations.
--- 4. Hierarchical TOML: the on-disk layout mirrors the menu tree.
---    Flat state keys are translated on write/read so the TOML is
---    clean (no prefixes, consistent ``enabled`` flags, proper grouping):
---    [gestures], [hotstrings], [hotstrings.dynamic], [hotstrings.editor],
---    [metrics], [llm], [shortcuts], [shortcuts.keys], etc.
---
--- DEPENDENCIES:
--- - lib.toml_codec
--- ==============================================================================

local M = {}
local hs        = hs
local TomlCodec = require("lib.toml_codec")


--- Top-level TOML section names in the order they appear on disk.
local SECTIONS = { "gestures", "hotstrings", "metrics", "llm", "shortcuts", "updater" }

--- Maps every flat state key (as used in memory throughout the codebase) to
--- its on-disk location. Fields:
---   sec:  top-level TOML section
---   path: optional sub-section within sec (dot-separated, e.g. "dynamic")
---   key:  disk key name — defaults to the flat key when absent
--- This layer lets the TOML be clean (no ``llm_``, ``keylogger_`` prefixes,
--- consistent ``enabled`` flags) while the in-memory state stays unchanged.
local KEY_MAP = {
	-- ── Gestures ──────────────────────────────────────────────────────────
	-- Gesture slot scalars are merged into [gestures] via NESTED_KEY_MAP.
	gestures                             = { sec = "gestures",   key = "enabled"                      },
	gesture_space_wrap                   = { sec = "gestures",   key = "space_wrap"                   },

	-- ── Hotstrings ─────────────────────────────────────────────────────────
	keymap                               = { sec = "hotstrings", key = "enabled"                      },
	expansion_delay                      = { sec = "hotstrings"                                        },
	personal_info                        = { sec = "hotstrings", path = "modules", key = "personal_info" },
	preview_ai_enabled                   = { sec = "hotstrings"                                        },
	preview_autocorrect_enabled          = { sec = "hotstrings"                                        },
	preview_colored_tooltips             = { sec = "hotstrings"                                        },
	preview_star_enabled                 = { sec = "hotstrings"                                        },
	trigger_char                         = { sec = "hotstrings"                                        },
	-- Dynamic hotstrings sub-section
	dynamichotstrings_enabled            = { sec = "hotstrings", path = "dynamic", key = "enabled"      },
	dynamichotstrings_date               = { sec = "hotstrings", path = "dynamic", key = "date"         },
	dynamichotstrings_datefr             = { sec = "hotstrings", path = "dynamic", key = "datefr"       },
	dynamichotstrings_datelongfr         = { sec = "hotstrings", path = "dynamic", key = "datelongfr"   },
	dynamichotstrings_ibanprefixes       = { sec = "hotstrings", path = "dynamic", key = "ibanprefixes" },
	dynamichotstrings_phoneprefixes      = { sec = "hotstrings", path = "dynamic", key = "phoneprefixes"},
	dynamichotstrings_ssnprefixes        = { sec = "hotstrings", path = "dynamic", key = "ssnprefixes"  },
	-- Editor sub-section (scalars only; tables go through NESTED_KEY_MAP)
	custom_close_on_add                  = { sec = "hotstrings", path = "editor", key = "close_on_add"   },
	custom_default_section               = { sec = "hotstrings", path = "editor", key = "default_section" },

	-- ── Metrics (formerly Keylogger) ───────────────────────────────────────
	keylogger_enabled                    = { sec = "metrics", key = "enabled"                       },
	keylogger_encrypt                    = { sec = "metrics", key = "encrypt"                       },
	keylogger_float_colors               = { sec = "metrics", key = "float_colors"                  },
	keylogger_float_graph                = { sec = "metrics", key = "float_graph"                   },
	keylogger_float_wpm                  = { sec = "metrics", key = "float_wpm"                     },
	keylogger_menubar_colors             = { sec = "metrics", key = "menubar_colors"                 },
	keylogger_menubar_wpm                = { sec = "metrics", key = "menubar_wpm"                    },
	keylogger_private_filter_enabled     = { sec = "metrics", key = "private_filter_enabled"        },
	keylogger_secure_filter_enabled      = { sec = "metrics", key = "secure_filter_enabled"         },
	keylogger_system_auth_filter_enabled = { sec = "metrics", key = "system_auth_filter_enabled"   },
	metrics_shortcut                     = { sec = "metrics", key = "shortcut"                      },
	apps_time_shortcut                   = { sec = "metrics", key = "apps_shortcut"                 },

	-- ── LLM ────────────────────────────────────────────────────────────────
	llm_enabled                          = { sec = "llm", key = "enabled"                           },
	llm_backend                          = { sec = "llm", path = "models", key = "selected"       },
	llm_model_mlx                        = { sec = "llm", path = "models", key = "mlx"            },
	llm_model_ollama                     = { sec = "llm", path = "models", key = "ollama"         },
	llm_active_profile                   = { sec = "llm", path = "profiles", key = "active"        },
	llm_num_predictions                  = { sec = "llm", path = "profiles", key = "num_predictions" },
	llm_trigger_shortcut                 = { sec = "llm", path = "trigger", key = "shortcut"       },
	llm_debounce                         = { sec = "llm", path = "trigger", key = "debounce"       },
	llm_instant_on_word_end              = { sec = "llm", path = "trigger", key = "instant_on_word_end" },
	llm_after_hotstring                  = { sec = "llm", path = "trigger", key = "after_hotstring" },
	llm_url_bar_filter_enabled           = { sec = "llm", path = "trigger", key = "url_bar_filter_enabled" },
	llm_secure_field_filter_enabled      = { sec = "llm", path = "trigger", key = "secure_filter_enabled" },
	llm_context_length                   = { sec = "llm", path = "generation", key = "context_length" },
	llm_min_words                        = { sec = "llm", path = "generation", key = "min_words"   },
	llm_max_words                        = { sec = "llm", path = "generation", key = "max_words"   },
	llm_temperature                      = { sec = "llm", path = "generation", key = "temperature" },
	llm_auto_raise_temp                  = { sec = "llm", path = "generation", key = "auto_raise_temp" },
	llm_reset_on_nav                     = { sec = "llm", path = "generation", key = "reset_on_nav" },
	llm_sequential_mode                  = { sec = "llm", path = "generation", key = "sequential_mode" },
	llm_show_info_bar                    = { sec = "llm", path = "display", key = "show_info_bar" },
	llm_streaming                        = { sec = "llm", path = "display", key = "streaming"     },
	llm_streaming_multi                  = { sec = "llm", path = "display", key = "streaming_multi" },
	llm_pred_indent                      = { sec = "llm", path = "display", key = "pred_indent"   },
	llm_arrow_nav_enabled                = { sec = "llm", path = "navigation", key = "arrow_nav_enabled" },
	llm_val_modifiers                    = { sec = "llm", path = "navigation", key = "val_modifiers" },

	-- ── Shortcuts ──────────────────────────────────────────────────────────
	shortcuts                            = { sec = "shortcuts", key = "enabled"              },
	chatgpt_url                          = { sec = "shortcuts"                                },
	script_control_enabled               = { sec = "shortcuts", path = "script_control", key = "enabled" },

	-- ── Updater ────────────────────────────────────────────────────────────
	update_channel                       = { sec = "updater",  key = "channel"               },
}

--- Maps nested-table flat state keys to their on-disk location.
--- Fields:
---   sec:            top-level TOML section
---   key:            dot-separated sub-key within the section
---   merge_into_sec: when true, each entry of the table is written as a
---                   scalar directly in the parent section (used for
---                   gesture slots merged flat into [gestures])
local NESTED_KEY_MAP = {
	-- Gesture slots merged flat into [gestures] (no sub-section header)
	gesture_actions          = { sec = "gestures",   merge_into_sec = true             },
	gesture_modes            = { sec = "gestures",   key = "modes"                     },
	gesture_sensitivities    = { sec = "gestures",   key = "sensitivities"             },
	-- Hotstrings nested tables
	hotstrings               = { sec = "hotstrings", key = "groups"                    },
	section_states           = { sec = "hotstrings", key = "modules"                   },
	terminator_states        = { sec = "hotstrings", key = "terminator_states"          },
	sections_order_overrides = { sec = "hotstrings", key = "order_overrides"            },
	custom_editor_shortcut   = { sec = "hotstrings", key = "editor.shortcut"            },
	custom_terminators       = { sec = "hotstrings", key = "terminators"                },
	-- Metrics nested tables
	keylogger_disabled_apps  = { sec = "metrics",    key = "disabled_apps"              },
	-- LLM nested tables
	llm_disabled_apps        = { sec = "llm",        key = "trigger.disabled_apps"      },
	llm_nav_modifiers        = { sec = "llm",        key = "navigation.nav_modifiers"   },
	llm_profile_shortcuts    = { sec = "llm",        key = "profiles.shortcuts"         },
	llm_user_models          = { sec = "llm",        key = "models.user_models"         },
	llm_user_profiles        = { sec = "llm",        key = "profiles.user_profiles"     },
	-- Shortcuts nested tables
	shortcut_keys            = { sec = "shortcuts",  key = "keys"                       },
	script_control_shortcuts = { sec = "shortcuts",  key = "script_control"             },
}

--- Set of known top-level section names for fast lookup.
local _known_sections = {}
for _, s in ipairs(SECTIONS) do _known_sections[s] = true end

--- Reverse scalar map: "sec:[path.]disk_key" → flat_key (built from KEY_MAP).
local _reverse_scalar = {}
for flat_key, spec in pairs(KEY_MAP) do
	local disk_key = spec.key or flat_key
	local lookup   = spec.sec .. ":" .. (spec.path and (spec.path .. ".") or "") .. disk_key
	_reverse_scalar[lookup] = flat_key
end

--- Reverse nested map: "sec:nested.key" → flat_key (built from NESTED_KEY_MAP).
local _reverse_nested = {}
for flat_key, spec in pairs(NESTED_KEY_MAP) do
	if not spec.merge_into_sec then
		_reverse_nested[spec.sec .. ":" .. spec.key] = flat_key
	end
end




-- ===================================
--- ===================================
-- ======= 1/ Helper Functions =======
--- ===================================
-- ===================================

--- Extracts the group name from a file path or name.
--- @param file string The file name or path.
--- @return string The extracted group name.
function M.get_group_name(file)
	if type(file) ~= "string" then return "" end
	return file:match("^(.*)%.lua$") or file:match("^(.*)%.toml$") or file
end


--- Partitions a flat state dict into the menu-mirroring layout used on
--- disk. All in-memory keys are translated via KEY_MAP / NESTED_KEY_MAP:
--- prefixes stripped, sections renamed, enable flags normalised to ``enabled``.
--- @param flat table The flat state dictionary.
--- @return table A nested table ready for ``TomlCodec.encode``.
local function group_for_disk(flat)
	-- Seed every known section so all appear in the output even when empty
	local grouped = {}
	for _, s in ipairs(SECTIONS) do grouped[s] = {} end

	-- Helper: write a value at a dot-separated path inside a parent table
	local function set_path(parent, dotpath, value)
		local parts = {}
		for p in dotpath:gmatch("[^%.]+") do parts[#parts + 1] = p end
		local t = parent
		for i = 1, #parts - 1 do
			if type(t[parts[i]]) ~= "table" then t[parts[i]] = {} end
			t = t[parts[i]]
		end
		t[parts[#parts]] = value
	end

	for k, v in pairs(flat) do
		local nested = NESTED_KEY_MAP[k]
		local scalar  = KEY_MAP[k]
		if nested then
			if nested.merge_into_sec then
				-- Gesture slots: each entry becomes a scalar in the parent section
				if type(v) == "table" then
					for slot, action in pairs(v) do
						grouped[nested.sec][slot] = action
					end
				end
			elseif type(v) == "table" then
				set_path(grouped[nested.sec], nested.key, v)
			end
		elseif scalar then
			local disk_key = scalar.key or k
			if scalar.path then
				local sub = grouped[scalar.sec]
				if type(sub[scalar.path]) ~= "table" then sub[scalar.path] = {} end
				sub[scalar.path][disk_key] = v
			else
				grouped[scalar.sec][disk_key] = v
			end
		end
	end
	return grouped
end


--- Flattens a grouped (sectioned) dict back into the flat layout the
--- in-memory state expects. Translates all disk keys back to flat state
--- keys via the reverse maps.
--- @param grouped table The dict decoded from disk.
--- @return table A flat state dictionary.
local function flatten_from_disk(grouped)
	if type(grouped) ~= "table" then return {} end
	local flat = {}

	for sec_name, sec_val in pairs(grouped) do
		if _known_sections[sec_name] and type(sec_val) == "table" then
			for disk_key, disk_val in pairs(sec_val) do
				if type(disk_val) == "table" then
					-- Could be: a known nested table, a sub-path table, or (rarely)
					-- a nested table inside [gestures] — treat those as action slots.
					local nested_fk = _reverse_nested[sec_name .. ":" .. disk_key]
					if nested_fk then
						flat[nested_fk] = disk_val
					elseif sec_name == "gestures" then
						-- Defensive: a table inside [gestures] is treated as gesture_actions
						if not flat.gesture_actions then flat.gesture_actions = {} end
						for slot, action in pairs(disk_val) do
							flat.gesture_actions[slot] = action
						end
					else
						-- Sub-path table (e.g. hotstrings.dynamic, hotstrings.editor):
						-- walk each inner key through the reverse scalar and nested maps.
						for inner_key, inner_val in pairs(disk_val) do
							if type(inner_val) == "table" then
								-- Depth-3 nested table (e.g. hotstrings.editor.shortcut)
								local nfk = _reverse_nested[sec_name .. ":" .. disk_key .. "." .. inner_key]
								if nfk then flat[nfk] = inner_val end
							else
								local lookup = sec_name .. ":" .. disk_key .. "." .. inner_key
								local fk     = _reverse_scalar[lookup]
								if fk then flat[fk] = inner_val end
							end
						end
					end
				else
					-- Scalar value
					if sec_name == "gestures" and disk_key ~= "enabled" then
						-- Gesture action slot merged into [gestures]
						if not flat.gesture_actions then flat.gesture_actions = {} end
						flat.gesture_actions[disk_key] = disk_val
					else
						local lookup = sec_name .. ":" .. disk_key
						local fk     = _reverse_scalar[lookup]
						if fk then flat[fk] = disk_val end
					end
				end
			end
		end
	end
	return flat
end




-- ==================================
--- ==================================
-- ======= 2/ State Hydration =======
--- ==================================
-- ==================================

--- Constructs the initial state by aggregating defaults from all modules.
--- @param hotfiles table List of hotstring files.
--- @param menu_mods table Loaded UI menu modules.
--- @param core_mods table Loaded core modules.
--- @return table The initialized state dictionary.
function M.build_initial_state(hotfiles, menu_mods, core_mods)
	local state = {
		hotstrings               = {},
		sections_order_overrides = {},
		terminator_states        = {},
		delays                   = {},
	}

	local function load_defaults(mod)
		if type(mod) == "table" and type(mod.DEFAULT_STATE) == "table" then
			for k, v in pairs(mod.DEFAULT_STATE) do
				if state[k] == nil then state[k] = v end
			end
		end
	end

	for _, mod in pairs(menu_mods) do load_defaults(mod) end
	for _, mod in pairs(core_mods) do load_defaults(mod) end

	for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
		local name = M.get_group_name(f)
		if name ~= "" then state.hotstrings[name] = true end
	end

	return state
end




-- ==================================
--- ==================================
-- ======= 3/ Disk Operations =======
--- ==================================
-- ==================================

--- Load preferences from the TOML configuration file and normalise
--- it to the flat dict the rest of the codebase expects.
--- @param prefs_file string Path to <config_dir>/hammerspoon/config.toml.
--- @return table The decoded preferences (empty when the file is absent or invalid).
function M.load(prefs_file)
	local ok, fh = pcall(io.open, prefs_file, "r")
	if not ok or not fh then return {} end

	local content = fh:read("*a")
	pcall(function() fh:close() end)

	local dec_ok, tbl = pcall(TomlCodec.decode, content)
	if not dec_ok or type(tbl) ~= "table" then return {} end

	return flatten_from_disk(tbl)
end

--- Save the current state to the TOML configuration file. Atomic via
--- .tmp + rename so a crash mid-write cannot leave a half-written
--- file on disk.
--- @param prefs_file string Path to the config.toml file.
--- @param state table The current global state.
--- @param hotfiles table List of hotstring files.
--- @param core_mods table Loaded core modules.
function M.save(prefs_file, state, hotfiles, core_mods)
	local existing = {}

	for k, v in pairs(state) do
		existing[k] = v
	end

	local section_states = {}
	local keymap = core_mods.keymap
	for _, f in ipairs(type(hotfiles) == "table" and hotfiles or {}) do
		local name = M.get_group_name(f)
		local secs = keymap and type(keymap.get_sections) == "function" and keymap.get_sections(name) or nil
		if type(secs) == "table" then
			section_states[name] = {}
			for _, sec in ipairs(secs) do
				if type(sec) == "table" and sec.name ~= "-" and not sec.is_module_placeholder then
					local is_en = keymap and type(keymap.is_section_enabled) == "function"
								  and keymap.is_section_enabled(name, sec.name) or false
					section_states[name][sec.name] = is_en
				end
			end
		end
	end
	existing.section_states = section_states

	local gestures = core_mods.gestures
	existing.gesture_actions = (gestures and type(gestures.get_all_actions) == "function") and gestures.get_all_actions() or {}
	existing.gesture_modes = (gestures and type(gestures.get_all_modes) == "function") and gestures.get_all_modes() or {}
	existing.gesture_sensitivities = (gestures and type(gestures.get_all_sensitivities) == "function") and gestures.get_all_sensitivities() or {}
	existing.gesture_space_wrap = (gestures and type(gestures.get_space_wrap) == "function") and gestures.get_space_wrap() or true

	existing.shortcut_keys = {}
	local shortcuts_mod = core_mods.shortcuts_mod
	if shortcuts_mod and type(shortcuts_mod.list_shortcuts) == "function" then
		local ok, list = pcall(shortcuts_mod.list_shortcuts)
		if ok and type(list) == "table" then
			for _, s in ipairs(list) do
				if type(s) == "table" and s.id then
					existing.shortcut_keys[s.id] = s.enabled
				end
			end
		end
	end

	local ok, encoded = pcall(TomlCodec.encode, group_for_disk(existing))
	if not ok or type(encoded) ~= "string" then return end

	local tmp_path = prefs_file .. ".tmp"
	local file_ok, fh = pcall(io.open, tmp_path, "w")
	if not file_ok or not fh then return end
	fh:write(encoded)
	pcall(function() fh:close() end)
	-- os.rename overwrites existing files on POSIX (Hammerspoon is macOS-only).
	pcall(os.rename, tmp_path, prefs_file)
	
	-- Reformat using centralized Python formatter for consistent styling
	local _src = debug.getinfo(1, "S").source:sub(2)
	local _script_dir = _src:match("^(.*[/\\])")
	local _repo_root = _script_dir:gsub("static[/\\]drivers[/\\].*$", ""):gsub("[/\\]$", "")
	local _format_script = _repo_root .. "/tools/format_toml.py"
	pcall(os.execute, string.format("python3 '%s' '%s' 2>&1", _format_script, prefs_file))
end

--- Merges the saved disk state into the current memory state.
--- @param state table The current global state.
--- @param saved table The dictionary loaded from disk.
function M.merge_saved_data(state, saved)
	if type(saved) ~= "table" then return end

	local exclude_keys = { 
		section_states = true, gesture_actions = true, 
		gesture_modes = true, gesture_sensitivities = true,
		shortcut_keys = true, hotstrings = true, script_control_shortcuts = true 
	}

	for k, v in pairs(saved) do
		if v ~= nil and not exclude_keys[k] then
			state[k] = v
		end
	end

	if type(saved.hotstrings) == "table" then
		for name in pairs(state.hotstrings) do
			if saved.hotstrings[name] ~= nil then
				state.hotstrings[name] = saved.hotstrings[name]
			end
		end
	end

	if type(saved.script_control_shortcuts) == "table" then
		if type(state.script_control_shortcuts) ~= "table" then state.script_control_shortcuts = {} end
		for k, v in pairs(saved.script_control_shortcuts) do
			state.script_control_shortcuts[k] = v
		end
	end

	if type(saved.terminator_states) == "table" then
		state.terminator_states = saved.terminator_states
	end
end

return M
