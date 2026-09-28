--- infra/preferences.lua

--- ==============================================================================
--- MODULE: Menu Preferences
--- DESCRIPTION:
--- Manages the persistence of the global state to and from the disk. The
--- format is TOML — see infra/toml_codec for the encoder/decoder. The file
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
local TomlCodec = require("infra.toml.codec")
local TomlWriter = require("toml_codec.writer")
local Logger    = require("infra.logger")
local FileSystem = require("adapters.file_system")
local Manifest = require("infra.manifest_reader")
local LOG       = "preferences"


--- Top-level TOML section names in the order they appear on disk.
local SECTIONS = { "gestures", "hotstrings", "metrics", "llm", "shortcuts", "layout", "updater", "ui" }

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
	repeat_key_enabled                   = { sec = "hotstrings", key = "repeat_key_enabled"           },
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
	llm_debounce                         = { sec = "llm", path = "trigger", key = "debounce_ms", units_per_state = 1000 },
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

	-- ── Layout ─────────────────────────────────────────────────────────────
	layout_pause_switch_enabled          = { sec = "layout", key = "pause_switch_enabled"    },
	layout_on_pause                      = { sec = "layout", key = "on_pause"                },
	layout_on_resume                     = { sec = "layout", key = "on_resume"               },

	-- ── Shortcuts ──────────────────────────────────────────────────────────
	shortcuts                            = { sec = "shortcuts", key = "enabled"              },
	chatgpt_url                          = { sec = "shortcuts"                                },
	script_control_enabled               = { sec = "shortcuts", path = "script_control", key = "enabled" },

	-- ── Updater ────────────────────────────────────────────────────────────
	update_channel                       = { sec = "updater",  key = "channel"               },
	update_check_interval_seconds        = { sec = "updater",  key = "check_interval_seconds" },

	-- ── Interface ──────────────────────────────────────────────────────────
	menubar_icon                         = { sec = "ui"                                        },
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
	-- binding__action → value, e.g. tap_3__open_url = "https://…".
	gesture_action_parameters = { sec = "gestures",  key = "action_parameters"         },
	-- Hotstrings nested tables
	-- Per-category expansion delays. Written by the Hotstrings menu into
	-- state.delays and read back at boot by menu_state, but absent from BOTH
	-- maps: save_prefs therefore dropped every one of them, and the value the
	-- user had just set was gone at the next reload with no diagnostic.
	delays                   = { sec = "hotstrings", key = "delays"                    },
	hotstrings               = { sec = "hotstrings", key = "groups"                    },
	section_states           = { sec = "hotstrings", key = "modules"                   },
	terminator_states        = { sec = "hotstrings", key = "terminator_states"          },
	sections_order_overrides = { sec = "hotstrings", key = "order_overrides"            },
	custom_editor_shortcut   = { sec = "hotstrings", key = "editor.shortcut"            },
	custom_terminators       = { sec = "hotstrings", key = "terminators"                },
	custom_delimiters        = { sec = "hotstrings", key = "delimiters"                 },
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

--- Resolves an owned persisted scalar to its existing menu-state key.
--- @param path string Canonical configuration path.
--- @return string|nil key Existing owner key, or nil for an unknown path.
function M.flat_key_for(path)
	local section, key = path:match("^([^.]+)%.(.+)$")
	if not section then return nil end
	return _reverse_scalar[section .. ":" .. key] or _reverse_nested[section .. ":" .. key]
end

--- Converts a scalar at its persistence boundary, preserving native units in memory.
--- @param spec table Existing scalar ownership declaration.
--- @param value any Scalar value.
--- @param reading boolean True when reading canonical disk units.
--- @return any converted Native or persisted representation.
local function scalar_units(spec, value, reading)
	if not spec or not spec.units_per_state then return value end
	assert(type(value) == "number" and value == value and value >= 0 and value < math.huge,
		"configuration duration must be a finite non-negative number")
	local result = reading and value / spec.units_per_state or value * spec.units_per_state
	assert(result < math.huge, "configuration duration overflows its canonical units")
	return result
end

--- Resolves canonical defaults/operations into the units used by their native owner.
--- @param path string Canonical configuration path.
--- @param value any Value expressed in persisted units.
--- @return any converted Native state value.
function M.state_value_for(path, value)
	local key = assert(M.flat_key_for(path), "configuration path has no preference owner: " .. path)
	return scalar_units(KEY_MAP[key], value, true)
end





-- ===================================
-- ===================================
-- ======= 1/ Helper Functions =======
-- ===================================
-- ===================================

--- Extracts the group name from a file path or name.
--- @param file string The file name or path.
--- @return string The extracted group name.
function M.get_group_name(file)
	if type(file) ~= "string" then return "" end
	-- Strip directory path if present
	local name = file:match("([^/\\]+)$") or file
	-- Strip extension
	return name:match("^(.*)%.lua$") or name:match("^(.*)%.toml$") or name
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
			v = scalar_units(scalar, v, false)
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

--- Builds leaf updates without claiming ownership of neighboring disk values.
--- @param flat table Complete desired preference snapshot.
--- @return table updates Explicit set/delete batch.
local function sparse_updates(flat)
	local updates = {}
	local table_paths = {}
	for _, spec in pairs(NESTED_KEY_MAP) do
		if not spec.merge_into_sec then table_paths[spec.sec .. "." .. spec.key] = true end
	end
	local function visit(node, path)
		for key, value in pairs(node) do
			local leaf = path == "" and key or path .. "." .. key
			if type(value) == "table" and #value == 0 and next(value) ~= nil then
				visit(value, leaf)
			elseif type(value) ~= "table" or next(value) ~= nil or table_paths[leaf] then
				if Manifest.has_default(leaf) then
					updates[#updates + 1] = Manifest.sparse_operation(leaf, value)
				else
					updates[#updates + 1] = { section = path, key = key, value = value }
				end
			end
		end
	end
	visit(group_for_disk(flat), "")
	table.sort(updates, function(a, b) return a.section .. "." .. a.key < b.section .. "." .. b.key end)
	return updates
end


--- Flattens a grouped (sectioned) dict back into the flat layout the
--- in-memory state expects. Translates all disk keys back to flat state
--- keys via the reverse maps.
--- @param grouped table The dict decoded from disk.
--- @param mark function|nil mark(...segments), called for every disk path the
---   flat state takes; the unused-key cleanup offers only the paths never marked.
--- @return table A flat state dictionary.
local function flatten_from_disk(grouped, mark)
	if type(grouped) ~= "table" then return {} end
	local flat = {}
	local function take(...)
		if mark then mark(...) end
	end

	for sec_name, sec_val in pairs(grouped) do
		if _known_sections[sec_name] and type(sec_val) == "table" then
			for disk_key, disk_val in pairs(sec_val) do
				if type(disk_val) == "table" then
					-- Could be: a known nested table, a sub-path table, or (rarely)
					-- a nested table inside [gestures] — treat those as action slots.
					-- First try the scalar reverse map: some flat keys (e.g. metrics_shortcut,
					-- apps_time_shortcut) map to a top-level section:key but their on-disk value
					-- is a structured table {mods, key}. Without this early check they fall into
					-- the sub-path branch which iterates inner keys and finds nothing.
					local top_scalar_fk = _reverse_scalar[sec_name .. ":" .. disk_key]
					if top_scalar_fk then
						flat[top_scalar_fk] = disk_val
						take(sec_name, disk_key)
					end
					local nested_fk = _reverse_nested[sec_name .. ":" .. disk_key]
					if nested_fk then
						flat[nested_fk] = disk_val
						take(sec_name, disk_key)
					elseif top_scalar_fk then
						-- Already handled above — skip sub-path processing
					elseif sec_name == "gestures" then
						-- Unknown nested tables belong to their own reader. They must
						-- survive sparse saves without becoming native gesture slots.
					else
						-- Sub-path table (e.g. hotstrings.dynamic, hotstrings.editor):
						-- walk each inner key through the reverse scalar and nested maps.
						for inner_key, inner_val in pairs(disk_val) do
							if type(inner_val) == "table" then
								-- TOML arrays decode as Lua sequences (#t > 0). Treat them
								-- as scalars (llm_val_modifiers, …), not depth-3 maps.
								if #inner_val > 0 then
									local lookup = sec_name .. ":" .. disk_key .. "." .. inner_key
									local fk     = _reverse_scalar[lookup] or _reverse_nested[lookup]
									if fk then
										flat[fk] = inner_val
										take(sec_name, disk_key, inner_key)
									end
								else
									-- Structured scalar (e.g. llm.trigger.shortcut = {mods,key})
									-- or depth-3 nested maps (hotstrings.editor.*).
									local lookup = sec_name .. ":" .. disk_key .. "." .. inner_key
									local fk     = _reverse_scalar[lookup]
									if fk then
										flat[fk] = inner_val
										take(sec_name, disk_key, inner_key)
									else
										local nfk = _reverse_nested[lookup]
										if nfk then
											flat[nfk] = inner_val
											take(sec_name, disk_key, inner_key)
										end
									end
								end
							else
								local lookup = sec_name .. ":" .. disk_key .. "." .. inner_key
								local fk     = _reverse_scalar[lookup]
								if fk then
									flat[fk] = inner_val
									take(sec_name, disk_key, inner_key)
								end
							end
						end
					end
				else
					-- Scalar value
					if sec_name == "gestures" and disk_key ~= "enabled" then
						-- Check the reverse map first: keys like space_wrap have a flat
						-- state entry (gesture_space_wrap) via KEY_MAP and must not be
						-- merged into gesture_actions — that would create a phantom slot
						-- and leave the real state key un-restored on reload.
						local lookup = sec_name .. ":" .. disk_key
						local fk     = _reverse_scalar[lookup]
						if fk then
							flat[fk] = disk_val
							take(sec_name, disk_key)
						elseif Manifest.has_default("gestures." .. disk_key) then
							-- Gesture action slot (tap_2, pinch_2, etc.) merged into [gestures]
							if not flat.gesture_actions then flat.gesture_actions = {} end
							flat.gesture_actions[disk_key] = disk_val
							take(sec_name, disk_key)
						end
					else
						local lookup = sec_name .. ":" .. disk_key
						local fk     = _reverse_scalar[lookup]
						if fk then
							flat[fk] = disk_val
							take(sec_name, disk_key)
						end
					end
				end
			end
		end
	end
	for key, value in pairs(flat) do flat[key] = scalar_units(KEY_MAP[key], value, true) end
	return flat
end





-- ==================================
-- ==================================
-- ======= 2/ State Hydration =======
-- ==================================
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
		if name ~= "" then state.hotstrings[name] = false end
	end

	return state
end





-- ==================================
-- ==================================
-- ======= 3/ Disk Operations =======
-- ==================================
-- ==================================

-- Exact source bytes are retained per destination because the menu edits a
-- full-document model long after boot. A last-moment check inside the adapter
-- cannot detect an external edit that landed before save() was called.
local _source_snapshots = {}

--- Classifies one preference source without interpreting its contents.
--- @param prefs_file string Destination path.
--- @return table|nil snapshot Exact `ok`/`absent` source classification.
local function classify_source(prefs_file)
	local content, read_status = FileSystem.read_with_status(prefs_file)
	if read_status == "ok" and type(content) == "string" then
		return { status = "ok", content = content }
	end
	if read_status == "absent" then return { status = "absent" } end
	return nil
end

--- Compares two exact source classifications.
--- @param left table|nil First source snapshot.
--- @param right table|nil Second source snapshot.
--- @return boolean equal Whether both snapshots describe the same bytes/state.
local function same_source(left, right)
	return type(left) == "table"
		and type(right) == "table"
		and left.status == right.status
		and (left.status ~= "ok" or left.content == right.content)
end

--- The top-level tables and values of the current file that Preferences does
--- not own: [_meta] (the schema version the boot migration stamps), the expert
--- [script] and [features] layers config_overrides reads, and any table another
--- reader keeps here. A save carries them over unchanged; replacing the file
--- with the owned sections alone erased them at the first menu change. A file
--- the save creates gets the rows its creators must write instead (the schema
--- stamp the boot migration registered through toml_codec.writer).
--- @param prefs_file string Destination path.
--- @param source table Exact source classification `{ status, content? }`.
--- @return table|nil tables `{ [name] = value }`, nil when the file is not TOML.
--- @return string|nil detail
local function unowned_tables(prefs_file, source)
	if source.status ~= "ok" then
		local out = {}
		for _, row in ipairs(TomlWriter.create_rows(prefs_file) or {}) do
			local node = out
			for segment in row.section:gmatch("[^%.]+") do
				if type(node[segment]) ~= "table" then node[segment] = {} end
				node = node[segment]
			end
			node[row.key] = row.value
		end
		return out
	end
	local ok, decoded = pcall(TomlCodec.decode, source.content)
	if not ok or type(decoded) ~= "table" then
		return nil, "the current config.toml is not valid TOML, so the tables it holds cannot be kept"
	end
	local out = {}
	for name, value in pairs(decoded) do
		if not _known_sections[name] then out[name] = value end
	end
	return out
end

--- Adopts a demonstrably changed, valid external source as the baseline for a
--- later explicit save. The rejected candidate never overwrites the external
--- winner; malformed or unreadable bytes never become overwrite authority.
--- @param prefs_file string Destination path.
--- @param expected_source table Snapshot used by the rejected publication.
--- @return boolean adopted Whether the exact external source became the baseline.
local function adopt_changed_source(prefs_file, expected_source)
	local current_source = classify_source(prefs_file)
	if type(current_source) ~= "table" or same_source(expected_source, current_source) then
		return false
	end
	if current_source.status == "ok" then
		local decode_ok, decoded = pcall(TomlCodec.decode, current_source.content)
		if not decode_ok or type(decoded) ~= "table" then return false end
	end
	_source_snapshots[prefs_file] = current_source
	return true
end

--- Load preferences from the TOML configuration file and normalise
--- it to the flat dict the rest of the codebase expects.
--- @param prefs_file string Path to <config_dir>/hammerspoon/config.toml.
--- Returns a SECOND value distinguishing the three outcomes this used to
--- collapse into one silent empty table:
---   absent   - no file at all, a genuine fresh install
---   corrupt  - the file exists but could not be read or decoded
---   ok       - decoded normally
---
--- The distinction is load-bearing. The caller derives `config_absent` from
--- `next(saved) == nil`, and on a fresh install that flag legitimately triggers
--- a factory seed AND a save. A corrupt file produced exactly the same empty
--- table, so a typo in the expert [script]/[features] layer, a merge-conflict
--- marker, or a torn write from a cloud-synced directory made the driver
--- factory-reset every group and then OVERWRITE the recoverable file with
--- defaults - permanently, since preferences.save only keeps a .bak on Windows.
---
--- The karabiner loader already fixed this exact class; this parallel loader
--- never received it.
--- @return table The decoded preferences (empty when the file is absent or invalid).
--- @return string "ok" | "absent" | "corrupt"
function M.load(prefs_file)
	local content, read_status = FileSystem.read_with_status(prefs_file)
	if read_status ~= "ok" then
		if read_status == "absent" then
			_source_snapshots[prefs_file] = { status = "absent" }
			return {}, "absent"
		end
		_source_snapshots[prefs_file] = nil
		Logger.error(LOG, "config.toml could not be read; treating it as corrupt "
			.. "(failure content withheld).")
		return {}, "corrupt"
	end

	local dec_ok, tbl = pcall(TomlCodec.decode, content)
	if not dec_ok or type(tbl) ~= "table" then
		_source_snapshots[prefs_file] = nil
		-- Loud, and never silently overwritten. The user's settings are still on
		-- disk and are recoverable by hand; treating this as "fresh install" is
		-- what destroys them.
		Logger.error(LOG,
			"config.toml exists but could not be decoded (failure content withheld). Keeping it "
				.. "untouched and running with in-memory defaults for this session - fix the file, "
				.. "or delete it to start from factory settings.")
		return {}, "corrupt"
	end

	local flattened, values = pcall(flatten_from_disk, tbl)
	if not flattened then
		_source_snapshots[prefs_file] = nil
		Logger.error(LOG, "config.toml contains an invalid owned setting; keeping its source untouched.")
		return {}, "corrupt"
	end
	_source_snapshots[prefs_file] = { status = "ok", content = content }
	return values, "ok"
end

--- Marks every config.toml path load() takes into the flat state, through the
--- very walk load() uses.
--- @param decoded table Decoded config.toml.
--- @param mark function mark(...segments) from config_unused_keys.
function M.mark_config_reads(decoded, mark)
	if type(mark) ~= "function" then error("Preferences.mark_config_reads needs a mark function", 2) end
	flatten_from_disk(decoded, mark)
end

--- Moves the save baseline past an unused-key cleanup. The cleanup removes
--- only paths load() never reads, so the in-memory state still describes the
--- new bytes; without this the next save would find the file "changed
--- externally" and refuse the user's change. The baseline moves only when it
--- still holds exactly the bytes the cleanup replaced.
--- @param prefs_file string Path to config.toml.
--- @param previous string Bytes the cleanup replaced.
--- @param content string Bytes the cleanup published.
--- @return boolean adopted
function M.adopt_cleanup(prefs_file, previous, content)
	local baseline = _source_snapshots[prefs_file]
	if type(baseline) ~= "table" or baseline.status ~= "ok" or baseline.content ~= previous
		or type(content) ~= "string" then
		return false
	end
	_source_snapshots[prefs_file] = { status = "ok", content = content }
	return true
end

--- Captures the exact source acknowledged by load or the last publication.
--- @param path string Configuration path.
--- @return table|nil snapshot Classified source snapshot.
function M.source_snapshot(path)
	local source = _source_snapshots[path]
	return source and { status = source.status, content = source.content } or nil
end

--- Exchanges the acknowledged source under the shared writer admission fence.
--- The caller retains the inverse until its conditional publication commits.
--- @param path string Configuration path.
--- @param expected table Exact previous classified source.
--- @param replacement table Classified candidate or rollback source.
--- @return boolean exchanged
function M.replace_source(path, expected, replacement)
	local current = _source_snapshots[path]
	local function valid(source)
		return type(source) == "table" and ((source.status == "absent" and source.content == nil)
			or (source.status == "ok" and type(source.content) == "string"))
	end
	if not valid(expected) or not valid(replacement) or not valid(current)
		or current.status ~= expected.status or current.content ~= expected.content then return false end
	_source_snapshots[path] = { status = replacement.status, content = replacement.content }
	return true
end

--- Clones persisted values so nested menu tables cannot mutate an acknowledged
--- rollback snapshot after it has been captured.
--- @param value any Value to clone.
--- @return any clone
local function clone_value(value)
	if type(value) ~= "table" then return value end
	local clone = {}
	for key, child in pairs(value) do clone[clone_value(key)] = clone_value(child) end
	return clone
end

--- Reconciles leaf operations with existing inline gesture tables without
--- replacing unknown neighbors. Both ordinary saves and scopes use this owner.
--- @param source table Exact classified source snapshot.
--- @param updates table Owned set/delete leaf operations.
--- @return table updates Equivalent strict-writer operations.
function M.prepare_gesture_updates(source, updates)
	local scanned, detail = require("toml_codec.record_scanner").scan_records(source.content or "", { quoted_headers = true })
	if not scanned then return false, detail end
	local decoded = TomlCodec.decode(source.content or "")
	local disk_gestures = decoded.gestures or {}
	local inline, candidates, rows = {}, {}, {}
	for _, record in ipairs(scanned.records) do
		if record.addressable and record.section == "gestures"
			and (record.key == "action_parameters" or record.key == "modes" or record.key == "sensitivities") then
			inline["gestures." .. record.key] = record.key
		end
	end
	for _, row in ipairs(updates) do
		local key = inline[row.section]
		local empty_runtime_table = row.section == "gestures" and type(row.value) == "table"
			and next(row.value) == nil and (row.key == "action_parameters" or row.key == "modes" or row.key == "sensitivities")
		if empty_runtime_table then
			-- Empty runtime ownership cannot authorize replacing an entire source
			-- table: unknown or other-domain neighbors may still be stored there.
		elseif key then
			assert(type(disk_gestures[key]) == "table", "scope owned table is malformed")
			local candidate = candidates[key] or clone_value(disk_gestures[key])
			candidates[key] = candidate
			if row.delete then candidate[row.key] = nil else candidate[row.key] = clone_value(row.value) end
		else rows[#rows + 1] = row end
	end
	for key, candidate in pairs(candidates) do
		rows[#rows + 1] = next(candidate) == nil and { section = "gestures", key = key, delete = true }
			or { section = "gestures", key = key, value = candidate }
	end
	return rows
end

--- Captures the complete flat preference snapshot represented by memory and
--- runtime-owned registries. This is the exact payload save() serializes and the
--- rollback owner later re-applies when publication fails.
--- @param state table The current global state.
--- @param hotfiles table List of hotstring files.
--- @param core_mods table Loaded core modules.
--- @return table snapshot Detached flat preference snapshot.
function M.snapshot(state, hotfiles, core_mods)
	state = type(state) == "table" and state or {}
	core_mods = type(core_mods) == "table" and core_mods or {}
	local existing = clone_value(state)

	local section_states = {}
	local keymap = core_mods.keymap
	if keymap and type(keymap.is_repeat_feature_enabled) == "function" then
		existing.repeat_key_enabled = keymap.is_repeat_feature_enabled()
	end
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
	existing.gesture_actions = clone_value(
		(gestures and type(gestures.get_all_actions) == "function") and gestures.get_all_actions() or {}
	)
	existing.gesture_modes = clone_value(
		(gestures and type(gestures.get_all_modes) == "function") and gestures.get_all_modes() or {}
	)
	existing.gesture_sensitivities = clone_value(
		(gestures and type(gestures.get_all_sensitivities) == "function")
			and gestures.get_all_sensitivities() or {}
	)
	existing.gesture_action_parameters = clone_value(
		(gestures and type(gestures.get_all_action_parameters) == "function")
			and gestures.get_all_action_parameters() or {}
	)
	if gestures and type(gestures.get_space_wrap) == "function" then
		existing.gesture_space_wrap = gestures.get_space_wrap()
	else
		existing.gesture_space_wrap = true
	end

	existing.shortcut_keys = {}
	local shortcuts_mod = core_mods.shortcuts_mod
	if shortcuts_mod and type(shortcuts_mod.list_shortcuts) == "function" then
		local ok, list = pcall(shortcuts_mod.list_shortcuts)
		if ok and type(list) == "table" then
			for _, shortcut in ipairs(list) do
				-- Runtime dispatchers derive their state from assignments; only
				-- manifest-declared preferences belong in the saved key map.
				if type(shortcut) == "table" and type(shortcut.id) == "string"
					and Manifest.has_default("shortcuts.keys." .. shortcut.id) then
					existing.shortcut_keys[shortcut.id] = shortcut.enabled
				end
			end
		end
	end

	return clone_value(existing)
end

--- Save the current state to the TOML configuration file. Atomic via
--- .tmp + rename so a crash mid-write cannot leave a half-written
--- file on disk. The sections Preferences owns come from the state; every
--- other top-level table of the file it replaces is carried over unchanged.
--- @param prefs_file string Path to the config.toml file.
--- @param state table The current global state.
--- @param hotfiles table List of hotstring files.
--- @param core_mods table Loaded core modules.
--- @param snapshot_view function|nil Transforms the complete runtime snapshot for disk.
--- @return boolean committed
--- @return table|nil persisted Snapshot written to disk.
--- @return table|nil runtime Snapshot before session-only preservation.
function M.save(prefs_file, state, hotfiles, core_mods, snapshot_view)
	if snapshot_view ~= nil and type(snapshot_view) ~= "function" then
		error("snapshot_view must be a function", 2)
	end
	if type(prefs_file) ~= "string" or prefs_file == "" then
		Logger.error(LOG, "Cannot save preferences without a destination path.")
		return false
	end
	-- The boot migration could not version this file (a newer schema, a failed
	-- migration): this session never writes it.
	local refusal = TomlWriter.write_refusal(prefs_file)
	if refusal then
		Logger.error(LOG, "Preferences NOT saved: writes to '%s' are refused for this session (%s).",
			prefs_file, refusal)
		return false
	end
	local runtime = M.snapshot(state, hotfiles, core_mods)
	local existing = runtime
	if snapshot_view then
		existing = snapshot_view(clone_value(runtime))
		if type(existing) ~= "table" then error("snapshot_view must return a table", 2) end
	end
	local expected_source = _source_snapshots[prefs_file]
	if type(expected_source) ~= "table" then
		expected_source = classify_source(prefs_file)
		if type(expected_source) ~= "table" then
			Logger.error(LOG, "Cannot classify '%s' before saving preferences.",
				tostring(prefs_file))
			return false
		end
		_source_snapshots[prefs_file] = expected_source
	end

	local ok, updates = pcall(function()
		return M.prepare_gesture_updates(expected_source, sparse_updates(existing))
	end)
	if not ok then
		-- A silent return here looks exactly like a successful save until the next
		-- reload restores the previous file and the user's change is simply gone.
		Logger.error(LOG, "Cannot prepare preferences — settings NOT saved: %s.", tostring(updates))
		return false
	end

	local write_ok, written, detail, encoded = pcall(
		TomlWriter.batch_write,
		prefs_file,
		updates,
		FileSystem,
		expected_source
	)
	if not write_ok or written ~= true then
		if adopt_changed_source(prefs_file, expected_source) then
			Logger.warn(LOG, "Preferences changed externally; the stale save was refused. "
				.. "Review the external edit, then repeat the setting change to save it.")
		else
			Logger.error(LOG, "Cannot atomically replace '%s' — settings NOT saved.",
				tostring(prefs_file))
		end
		return false
	end
	_source_snapshots[prefs_file] = { status = "ok", content = encoded }
	return true, existing, runtime
end

--- Merges the saved disk state into the current memory state.
--- @param state table The current global state.
--- @param saved table The dictionary loaded from disk.
function M.merge_saved_data(state, saved)
	if type(saved) ~= "table" then return end

	local exclude_keys = { 
		section_states = true, gesture_actions = true, 
		gesture_modes = true, gesture_sensitivities = true, gesture_action_parameters = true,
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
