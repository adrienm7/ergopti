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
local HotstringLanguages = require("hotstrings.languages")
local ConfigOutdated = require("config_outdated")
local BindingIdentity = require("config_binding_identity")
local PersonalFiles = require("hotstrings.personal_files")
local PersonalAdoption = require("infra.personal_file_adoption")
local Agent     = require("llm.agent")
local WrapPreferences = require("menu.wrap_preferences")
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
	-- One of the manifest's enum values: take_value reports any other as outdated.
	magic_key_source                     = { sec = "hotstrings", enum = true                           },
	-- Dynamic hotstrings sub-section
	dynamichotstrings_enabled            = { sec = "hotstrings", path = "dynamic", key = "enabled"      },
	dynamichotstrings_user_code_enabled  = { sec = "hotstrings", path = "dynamic.user_code", key = "enabled" },
	dynamichotstrings_user_code_time_activation_seconds = {
		sec = "hotstrings", path = "dynamic.user_code", key = "time_activation_seconds",
	},
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

	-- ── LLM ────────────────────────────────────────────────────────────────
	llm_enabled                          = { sec = "llm", key = "enabled"                           },
	llm_backend                          = { sec = "llm", path = "models", key = "selected"       },
	llm_model_mlx                        = { sec = "llm", path = "models", key = "mlx"            },
	llm_model_ollama                     = { sec = "llm", path = "models", key = "ollama"         },
	llm_active_profile                   = { sec = "llm", path = "profiles", key = "active"        },
	llm_num_predictions                  = { sec = "llm", path = "profiles", key = "num_predictions" },
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
	-- The AI agent (modules/llm/agent_runner.lua): System 1 and System 2 backends and the mode
	llm_agent_system1                    = { sec = "llm", key = "agent_system1"                     },
	llm_agent_system2                    = { sec = "llm", key = "agent_system2"                     },
	llm_agent_mode                       = { sec = "llm", key = "agent_mode"                        },

	-- ── Layout ─────────────────────────────────────────────────────────────
	layout_number_row_mode               = { sec = "layout", key = "direct_access_digits", enum = true },
	layout_pause_switch_enabled          = { sec = "layout", key = "pause_switch_enabled"    },
	layout_on_pause                      = { sec = "layout", key = "on_pause"                },
	layout_on_resume                     = { sec = "layout", key = "on_resume"               },

	-- ── Shortcuts ──────────────────────────────────────────────────────────
	shortcuts                            = { sec = "shortcuts", key = "enabled"              },
	chatgpt_url                          = { sec = "shortcuts"                                },
	script_control_enabled               = { sec = "shortcuts", path = "script_control", key = "chords_enabled" },

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
	llm_agent_disabled_apps  = { sec = "llm",        key = "agent_disabled_apps"        },
	-- Shortcuts nested tables
	shortcut_keys            = { sec = "shortcuts",  key = "keys"                       },
	script_control_shortcuts = { sec = "shortcuts",  key = "script_control"             },
	wrap_symbol_states       = WrapPreferences.locations.wrap_symbol_states,
	custom_wrap_symbols      = WrapPreferences.locations.custom_wrap_symbols,
}

--- Nested tables whose every child is a manifest-declared setting. A child the
--- manifest no longer declares, or whose value it no longer accepts (the
--- removed at_hash hotkey under [shortcuts.keys]), is outdated: it never
--- reaches the state, so no replay can refuse it, and the shared rule warns
--- once and leaves it for the config cleanup.
local MANIFEST_CHILD_TABLES = {
	shortcut_keys            = true,
	script_control_shortcuts = true,
	gesture_modes            = true,
	gesture_sensitivities    = true,
}

--- Whether a persisted action id names an action this build no longer runs.
--- The gesture action catalogue judges it once the gesture module has loaded
--- it, which boot does before loading preferences; without it nothing can be
--- proved retired. It is never loaded from here: its initialization belongs
--- to its owner, not to a configuration reader.
--- @param value any Persisted action id.
--- @return boolean retired
--- @return string|nil detail
function M.action_is_retired(value)
	if value == "none" then return false end
	if type(value) ~= "string" then return true, "the value is not an action id" end
	local catalogue = package.loaded["modules.gestures.actions"]
	if type(catalogue) ~= "table" or type(catalogue.is_assignable) ~= "function" then return false end
	if catalogue.is_assignable(value) == true then return false end
	return true, "action '" .. value .. "' no longer exists"
end

--- Owner check of one [gestures.action_parameters] entry: its name must end in
--- an action that still takes a parameter, and its value must still fit that
--- parameter (a removed wrap pair, a retired language). The gesture catalogue
--- judges it once loaded, as for retired actions; without it, or when its own
--- validator cannot judge, every entry is kept. Bare gesture bindings are
--- judged only after their actual owner publishes its slot catalogue; other
--- binding domains remain with their own owners.
--- @param key string Persisted parameter key.
--- @param value any Persisted value.
--- @return boolean known
--- @return string|nil detail
local function action_parameter_fits(key, value)
	local catalogue = package.loaded["modules.gestures.actions"]
	if type(catalogue) ~= "table" or type(catalogue.split_action_parameter_key) ~= "function"
		or type(catalogue.validate_action_parameter) ~= "function" then return true end
	local binding, action = catalogue.split_action_parameter_key(key)
	if not action then return false, "no action parameter of this build has this name" end
	if type(catalogue.action_parameter_binding_fits) == "function" then
		local fits, detail = catalogue.action_parameter_binding_fits(binding)
		if fits == false then return false, detail or BindingIdentity.RETIRED_GESTURE end
	end
	local judged, valid = pcall(catalogue.validate_action_parameter, action, value)
	if judged and not valid then return false, "the value no longer fits its action's parameter" end
	return true
end

--- Owner check of one [hotstrings.delays] entry: a delay the keymap still
--- declares (set_delay refuses any other), holding a number (it replaces any
--- other value by the default in silence). The keymap judges it once loaded,
--- which boot does before loading preferences; without it every entry is kept.
--- @param key string Persisted delay key.
--- @param value any Persisted value.
--- @return boolean known
--- @return string|nil detail
local function delay_fits(key, value)
	local keymap = package.loaded["modules.keymap"]
	if type(keymap) ~= "table" or type(keymap.DELAYS_DEFAULT) ~= "table" then return true end
	if keymap.DELAYS_DEFAULT[key] == nil then return false, "no hotstring delay of this build has this name" end
	if tonumber(value) == nil then return false, "the value is not a number of seconds" end
	return true
end

--- The prompt profile ids a document can name: the shipped built-ins and the
--- document's own [llm.profiles] user_profiles, plus the legacy ids the active
--- profile's owner still migrates silently. nil when the shipped list cannot
--- be read: nothing can then be proved gone, and every reference is kept.
--- @param grouped table Decoded config.toml.
--- @return table|nil ids Set of profile ids.
--- @return table|nil legacy Set of legacy ids the active profile may hold.
local function known_profile_ids(grouped)
	local Selector = require("llm.profile_selector")
	local builtins = Selector.load_built_in_profiles()
	if type(builtins) ~= "table" or #builtins == 0 then return nil, nil end
	local ids, legacy = {}, {}
	for _, profile in ipairs(builtins) do
		if type(profile) == "table" and type(profile.id) == "string" then ids[profile.id] = true end
	end
	for old in pairs(Selector.load_legacy_ids()) do legacy[old] = true end
	local llm = type(grouped.llm) == "table" and grouped.llm or {}
	local profiles = type(llm.profiles) == "table" and llm.profiles or {}
	for _, profile in ipairs(type(profiles.user_profiles) == "table" and profiles.user_profiles or {}) do
		if type(profile) == "table" and type(profile.id) == "string" then ids[profile.id] = true end
	end
	return ids, legacy
end

--- Value rules of owners that accept more than the manifest's Lua type. The
--- gesture owner coerces a sensitivity with tonumber (set_sensitivity: a hand
--- edit or an AHK migration can persist "4.5"), so a numeric string is a value
--- it applies, not an outdated one. A script-control slot takes an action id
--- the catalogue still offers.
local OWNER_VALUE_RULES = {
	gesture_sensitivities = function(value)
		local number = tonumber(value)
		if type(number) == "number" and number > 0 then return true end
		return false, "the value is not a positive number"
	end,
	script_control_shortcuts = function(value)
		local retired, detail = M.action_is_retired(value)
		return not retired, detail
	end,
}

--- Whether a manifest-declared child of a nested table still holds a value
--- this build accepts.
--- @param nested_fk string Flat key of the nested table.
--- @param path string Canonical dotted path of the child.
--- @param value any Persisted value.
--- @return boolean known
--- @return string|nil detail Why the child is outdated.
local function manifest_child_fits(nested_fk, path, value)
	return ConfigOutdated.manifest_value_fits(Manifest.find_entry_by_path(path), value, "hs",
		OWNER_VALUE_RULES[nested_fk])
end

-- Built-in terminator keys, from the generated catalogue the registry loads.
local BUILTIN_TERMINATORS = {}
for _, def in ipairs(require("keymap.terminators_catalogue")) do
	if type(def.key) == "string" then BUILTIN_TERMINATORS[def.key] = true end
end

--- Builds the owner check of [hotstrings.terminator_states]: a state belongs to
--- a built-in terminator or to a custom one the same file still defines.
--- @param document table Decoded config.toml.
--- @return function is_known `is_known(key, enabled)`.
local function terminator_state_owner(document)
	local custom = {}
	local hotstrings = type(document.hotstrings) == "table" and document.hotstrings or {}
	local defs = type(hotstrings.terminators) == "table" and hotstrings.terminators or {}
	for _, def in ipairs(defs) do
		if type(def) == "table" and type(def.key) == "string" then custom[def.key] = true end
	end
	return function(key, enabled)
		if not BUILTIN_TERMINATORS[key] and not custom[key] then
			return false, "no built-in or custom delimiter has this key"
		end
		if type(enabled) ~= "boolean" then return false, "the value is not a boolean" end
		return true
	end
end

--- Owner check of one [hotstrings.groups] or [hotstrings.modules.<id>] choice:
--- the hotstring projection applies true or false only.
--- @param _ string Choice id.
--- @param value any Persisted value.
--- @return boolean known
--- @return string|nil detail
local function boolean_choice(_, value)
	if type(value) == "boolean" then return true end
	return false, "a hotstring choice takes true or false"
end

--- Partitions [hotstrings.modules]: each child is one category's table of
--- section choices. A child of another shape (an older build's
--- `magickey = true`) is outdated as a whole; inside a table, each section
--- choice is kept only when it is a boolean.
--- @param prefix table Path segments of the modules table.
--- @param modules table Persisted children.
--- @param mark function|nil Cleanup mark(...segments).
--- @return table kept Well-formed section choices, by category.
local function partition_section_choices(prefix, modules, mark)
	local kept = {}
	for id, sections in pairs(modules) do
		local path = { prefix[1], prefix[2], id }
		if type(id) ~= "string" or id == "" then
			ConfigOutdated.report(path, "not a text key")
		elseif type(sections) ~= "table" or #sections > 0 then
			ConfigOutdated.report(path, "section choices are not a table")
		else
			kept[id] = ConfigOutdated.partition(path, sections, boolean_choice, mark)
		end
	end
	return kept
end

--- Distinguishes the settings namespace from arrays using actual source evidence.
--- @param value any Section-order namespace.
--- @param shapes table|nil Canonical document receipt.
--- @return boolean
local function section_orders_are_map(value, shapes)
	if type(value) ~= "table" then return false end
	local origin = require("toml_codec.leaf_rows").source_origin(value)
	if origin then return not origin.array end
	if shapes then return shapes.arrays[value] ~= true end
	return #value == 0
end

--- Checks intrinsic section-order shape without judging unpublished group ids.
--- @param value any Persisted per-category section order.
--- @param shapes table|nil Canonical receipt of the original document.
--- @return boolean fits
--- @return string|nil detail
local function section_order_fits(value, shapes)
	if type(value) ~= "table" then return false, "section order is not a list" end
	local origin = require("toml_codec.leaf_rows").source_origin(value)
	if (origin and not origin.array) or (shapes and shapes.arrays[value] ~= true) then
		return false, "section order is not an array"
	end
	local count = 0
	for index, entry in pairs(value) do
		if type(index) ~= "number" or index < 1 or index ~= math.floor(index) then
			return false, "section order is not a dense list"
		end
		if type(entry) ~= "string" then return false, "section order entries are not text" end
		count = count + 1
	end
	for index = 1, count do
		if value[index] == nil then return false, "section order is not a dense list" end
	end
	return true
end

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

--- Whether a persisted value can cross its unit boundary (scalar_units asserts
--- the same rule on every conversion).
--- @param spec table|nil Scalar ownership declaration.
--- @param value any Persisted value.
--- @return boolean fits
--- @return string|nil detail Why the value is outdated.
local function persisted_units_fit(spec, value)
	if not spec or not spec.units_per_state then return true end
	if type(value) ~= "number" or value ~= value or value < 0 or value >= math.huge then
		return false, "the value is not a finite non-negative number"
	end
	return true
end

--- Owners' rules for scalars whose value set is closed beyond the manifest's
--- Lua type. The agent's modes are shared with every driver (llm.agent).
local SCALAR_VALUE_RULES = {
	dynamichotstrings_user_code_enabled = function(value)
		if type(value) == "boolean" then return true end
		return false, "the programmable hotstring gate is not a boolean"
	end,
	dynamichotstrings_user_code_time_activation_seconds = function(value)
		if type(value) == "number" and value == value and value >= 0 and value < math.huge then return true end
		return false, "the activation interval is not a finite non-negative number"
	end,
	llm_agent_mode = function(value)
		if Agent.MODES[value] then return true end
		return false, "'" .. tostring(value) .. "' is no longer an agent mode"
	end,
}

--- Whether a persisted scalar still holds a value its owner accepts: its own
--- rule, or membership of its manifest enum (ui.menubar_icon). A retired value
--- reaching the state was replayed into a refusal (an agent mode's boot ERROR)
--- or drawn with an ERROR; it is outdated configuration instead.
--- @param flat_key string Flat state key.
--- @param value any Persisted value.
--- @return boolean fits
--- @return string|nil detail Why the value is outdated.
local function scalar_value_fits(flat_key, value)
	if SCALAR_VALUE_RULES[flat_key] then return SCALAR_VALUE_RULES[flat_key](value) end
	local spec = KEY_MAP[flat_key]
	if not spec then return true end
	local path = spec.sec .. "." .. (spec.path and (spec.path .. ".") or "") .. (spec.key or flat_key)
	local entry = Manifest.find_entry_by_path(path)
	if type(entry) ~= "table" or entry.type ~= "enum" then return true end
	return ConfigOutdated.manifest_value_fits(entry, value, "hs")
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
		if k == "wrap_symbol_states" or k == "custom_wrap_symbols" then
			-- The typed Wrap policy plans these source-preserving rows separately.
		elseif nested then
			if nested.merge_into_sec then
				-- Gesture slots: each entry becomes a scalar in the parent section
				if type(v) == "table" then
					for slot, action in pairs(v) do
						grouped[nested.sec][slot] = action
					end
				end
			elseif type(v) == "table" then
				-- Copy into the section: [shortcuts.script_control] also holds the
				-- `chords_enabled` scalar. Storing the state table itself let that scalar
				-- be written INTO the live key-slot table, which then handed a
				-- boolean to the script-control setter as if it were a key slot.
				local owned = {}
				for inner_key, inner_val in pairs(v) do
					if not _reverse_scalar[nested.sec .. ":" .. nested.key .. "." .. inner_key] then
						owned[inner_key] = inner_val
					end
				end
				local parts = {}
				for part in nested.key:gmatch("[^%.]+") do parts[#parts + 1] = part end
				local target = grouped[nested.sec]
				for i = 1, #parts - 1 do
					if type(target[parts[i]]) ~= "table" then target[parts[i]] = {} end
					target = target[parts[i]]
				end
				local leaf = parts[#parts]
				if type(target[leaf]) ~= "table" then target[leaf] = {} end
				for inner_key, inner_val in pairs(owned) do target[leaf][inner_key] = inner_val end
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
			local segments = require("toml_codec.key_path").parse(path, true)
			if segments and #segments == 3 and segments[1] == "hotstrings" and segments[2] == "modules"
				and PersonalFiles.components(segments[3]) then
				segments[#segments + 1] = key
				leaf = require("toml_codec.key_path").render(segments)
			end
			if type(value) == "table" and #value == 0 and next(value) ~= nil then
				visit(value, leaf)
			elseif type(value) ~= "table" or next(value) ~= nil or table_paths[leaf] then
				local canonical = PersonalFiles.preference_default(leaf) ~= nil
				local path_parts = canonical and require("toml_codec.key_path").parse(leaf, true)
				local id = path_parts and path_parts[3]
				local personal = canonical and require("infra.personal_hotstrings").adoption(id)
				if canonical and (not personal or not personal.admitted) then
					-- Unavailable sources own no disk preference leaves in this snapshot.
				elseif personal and personal.admitted and personal.legacy_name and value == true then
					assert(require("infra.personal_hotstrings").adoption_current(personal) == true,
						"personal legacy source changed before preferences publication")
					updates[#updates + 1] = require("hotstrings.personal_adoption").preference_row(personal,
						path_parts[2] == "modules" and path_parts[4] or nil, value)
				elseif Manifest.has_default(leaf) then
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
local function flatten_from_disk(grouped, mark, shapes)
	if type(grouped) ~= "table" then return {} end
	local flat = {}
	if shapes then
		flat = WrapPreferences.project(grouped, shapes, mark, ConfigOutdated.report)
	end
	local function take(...)
		if mark then mark(...) end
	end
	--- Takes one owned value, unless it cannot cross its unit boundary: such a
	--- leaf (`debounce_ms = "fast"`) is outdated on its own, and used to make
	--- the whole file load as corrupt.
	-- The profile ids this document can name, read once and only when needed.
	local profile_ids, legacy_profile_ids, profile_ids_read = nil, nil, false
	local function document_profile_ids()
		if not profile_ids_read then
			profile_ids, legacy_profile_ids = known_profile_ids(grouped)
			profile_ids_read = true
		end
		return profile_ids, legacy_profile_ids
	end
	local function take_value(flat_key, value, ...)
		local fits, detail = persisted_units_fit(KEY_MAP[flat_key], value)
		local spec = KEY_MAP[flat_key]
		if fits and spec and spec.enum then
			-- A value the manifest no longer lists (a key a newer build added, a
			-- hand edit) is outdated on its own, never a guess at another key.
			fits, detail = ConfigOutdated.manifest_value_fits(
				Manifest.find_entry_by_path(table.concat({ ... }, ".")), value, "hs")
		end
		if fits then fits, detail = scalar_value_fits(flat_key, value) end
		if fits and flat_key == "llm_active_profile" then
			-- A deleted or renamed profile silently ran "basic" at every prediction.
			local ids, legacy = document_profile_ids()
			if ids and not ids[value] and not legacy[value] then
				fits, detail = false, "no built-in or user profile has this id"
			end
		end
		if not fits then
			ConfigOutdated.report({ ... }, detail)
			return
		end
		local ids = flat_key == "llm_profile_shortcuts" and type(value) == "table" and document_profile_ids() or nil
		if ids then
			-- A shortcut of a deleted profile was unbound with a WARNING at every
			-- boot and never removed from disk.
			flat[flat_key] = ConfigOutdated.partition({ ... }, value, function(id, shortcut)
				if not ids[id] then return false, "no built-in or user profile has this id" end
				if type(shortcut) ~= "table" then return false, "a profile shortcut is a table of mods and key" end
				return true
			end, mark)
			return
		end
		flat[flat_key] = value
		take(...)
	end

	-- Only declared scalar paths gain ownership when a feature nests below a
	-- family table. Unknown neighbors and arrays remain with their own readers.
	local function take_scalar_descendants(section, path, node, parts)
		for key, value in pairs(node) do
			local child_path = path .. "." .. key
			local child_parts = {}
			for index, part in ipairs(parts) do child_parts[index] = part end
			child_parts[#child_parts + 1] = key
			local flat_key = _reverse_scalar[section .. ":" .. child_path]
			if flat_key then
				take_value(flat_key, value, table.unpack(child_parts))
			elseif type(value) == "table" and #value == 0 then
				take_scalar_descendants(section, child_path, value, child_parts)
			end
		end
	end

	for sec_name, sec_val in pairs(grouped) do
		if _known_sections[sec_name] and type(sec_val) == "table" then
			for disk_key, disk_val in pairs(sec_val) do
				if type(disk_val) == "table" then
					-- Could be: a known nested table, a sub-path table, or (rarely)
					-- a nested table inside [gestures] — treat those as action slots.
					-- First try the scalar reverse map: an owned scalar may map to a
					-- top-level section:key while its on-disk value
					-- is a structured table {mods, key}. Without this early check they fall into
					-- the sub-path branch which iterates inner keys and finds nothing.
					local top_scalar_fk = _reverse_scalar[sec_name .. ":" .. disk_key]
					if top_scalar_fk then
						take_value(top_scalar_fk, disk_val, sec_name, disk_key)
					end
					local nested_fk = _reverse_nested[sec_name .. ":" .. disk_key]
					if nested_fk then
						-- A scalar can share the table (shortcuts.script_control.chords_enabled):
						-- it goes to its own state key, never into the nested map.
						local owned = {}
						for inner_key, inner_val in pairs(disk_val) do
							local scalar_fk = _reverse_scalar[sec_name .. ":" .. disk_key .. "." .. inner_key]
							if scalar_fk then
								take_value(scalar_fk, inner_val, sec_name, disk_key, inner_key)
							else
								owned[inner_key] = inner_val
							end
						end
						if MANIFEST_CHILD_TABLES[nested_fk] then
							local prefix = sec_name .. "." .. disk_key .. "."
							flat[nested_fk] = ConfigOutdated.partition({ sec_name, disk_key }, owned,
								function(id, value) return manifest_child_fits(nested_fk, prefix .. id, value) end, mark)
						elseif nested_fk == "terminator_states" then
							flat[nested_fk] = ConfigOutdated.partition({ sec_name, disk_key }, owned,
								terminator_state_owner(grouped), mark)
						elseif nested_fk == "hotstrings" then
							-- The hotstring projection asserts booleans: an old-shape
							-- choice reaching it failed the boot hotstrings sync.
							flat[nested_fk] = ConfigOutdated.partition({ sec_name, disk_key }, owned,
								boolean_choice, mark)
						elseif nested_fk == "section_states" then
							flat[nested_fk] = partition_section_choices({ sec_name, disk_key }, owned, mark)
						elseif nested_fk == "sections_order_overrides" then
							if not section_orders_are_map(disk_val, shapes) then
								ConfigOutdated.report({ sec_name, disk_key }, "section orders are not a table of settings")
								flat[nested_fk] = {}
							else
								flat[nested_fk] = ConfigOutdated.partition({ sec_name, disk_key }, owned,
									function(_, value) return section_order_fits(value, shapes) end, mark)
							end
						elseif nested_fk == "delays" then
							-- A retired delay was ignored by set_delay and saved back
							-- at every save, never offered.
							flat[nested_fk] = ConfigOutdated.partition({ sec_name, disk_key }, owned, delay_fits, mark)
						elseif nested_fk == "gesture_action_parameters" then
							-- The boot replay dropped these in silence and the whole
							-- table was marked, so none was ever offered.
							flat[nested_fk] = ConfigOutdated.partition({ sec_name, disk_key }, owned,
								action_parameter_fits, mark)
						else
							take_value(nested_fk, owned, sec_name, disk_key)
						end
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
									if fk and fk ~= "custom_wrap_symbols" and fk ~= "wrap_symbol_states" then
										take_value(fk, inner_val, sec_name, disk_key, inner_key)
									end
								else
									-- Structured scalar (a table value mapped to one flat key)
									-- or depth-3 nested maps (hotstrings.editor.*).
									local lookup = sec_name .. ":" .. disk_key .. "." .. inner_key
									local fk     = _reverse_scalar[lookup]
									if fk and fk ~= "custom_wrap_symbols" and fk ~= "wrap_symbol_states" then
										take_value(fk, inner_val, sec_name, disk_key, inner_key)
									else
										local nfk = _reverse_nested[lookup]
										if nfk and nfk ~= "custom_wrap_symbols" and nfk ~= "wrap_symbol_states" then
											take_value(nfk, inner_val, sec_name, disk_key, inner_key)
										else
											take_scalar_descendants(sec_name, disk_key .. "." .. inner_key,
												inner_val, { sec_name, disk_key, inner_key })
										end
									end
								end
							else
								local lookup = sec_name .. ":" .. disk_key .. "." .. inner_key
								local fk     = _reverse_scalar[lookup]
								if fk then
									take_value(fk, inner_val, sec_name, disk_key, inner_key)
								elseif _reverse_nested[lookup] == "llm_user_models" then
									-- A neutral runtime list cannot authorize deleting an
									-- obsolete scalar through the ordinary sparse save.
									ConfigOutdated.report({ sec_name, disk_key, inner_key }, "a list of user model records is expected here")
								end
							end
						end
					end
				else
					-- Scalar value
					if sec_name == "gestures" and disk_key ~= "enabled" then
						-- Check the reverse map first: a [gestures] scalar with its own
						-- flat state entry in KEY_MAP must not be merged into
						-- gesture_actions — that would create a phantom slot and leave
						-- the real state key un-restored on reload.
						local lookup = sec_name .. ":" .. disk_key
						local fk     = _reverse_scalar[lookup]
						if fk then
							take_value(fk, disk_val, sec_name, disk_key)
						elseif Manifest.has_default("gestures." .. disk_key) then
							-- Gesture action slot (tap_2, pinch_2, etc.) merged into [gestures].
							-- A retired action is outdated: warned once and left for the
							-- cleanup, instead of a refused set_action at every load.
							local retired, detail = M.action_is_retired(disk_val)
							if retired then
								ConfigOutdated.report({ sec_name, disk_key }, detail)
							else
								if not flat.gesture_actions then flat.gesture_actions = {} end
								flat.gesture_actions[disk_key] = disk_val
								take(sec_name, disk_key)
							end
						end
					else
						local lookup = sec_name .. ":" .. disk_key
						local fk     = _reverse_scalar[lookup]
						if fk then
							take_value(fk, disk_val, sec_name, disk_key)
						elseif _reverse_nested[lookup] then
							-- A scalar where this build keeps a table of settings
							-- (an older build's `groups = "…"`): nothing reads it.
							ConfigOutdated.report({ sec_name, disk_key }, "a table of settings is expected here")
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
local _save_receipts = {}
local _owned_publications = {}
-- Paths load() judged outdated, per destination: never read into the state,
-- which holds their default instead. An ordinary save must not turn that
-- default into a delete of the outdated value, which belongs to the config
-- cleanup that offers it (as Windows full saves keep boot-outdated entries);
-- a value the user sets there replaces it and ends the exemption.
local _load_outdated = {}

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
	assert(not _owned_publications[prefs_file], "preference publication is still active")
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

	local dec_ok, tbl, shapes = pcall(require("toml_codec.leaf_rows").decode_source, content)
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

	local values
	local flattened, outdated = pcall(ConfigOutdated.collect_reports, function()
		values = flatten_from_disk(tbl, nil, shapes)
	end)
	if not flattened then
		_source_snapshots[prefs_file] = nil
		Logger.error(LOG, "config.toml contains an invalid owned setting; keeping its source untouched.")
		return {}, "corrupt"
	end
	_source_snapshots[prefs_file] = { status = "ok", content = content }
	_load_outdated[prefs_file] = outdated
	return values, "ok"
end

--- Reads current canonical preferences without adopting overwrite authority.
--- This view is admission evidence only; load/save alone own source snapshots.
--- @param prefs_file string Canonical configuration path.
--- @return table|nil flat Current owned preferences, nil on a refused view.
--- @return table|nil source Exact classified bytes read for this view.
function M.current_view(prefs_file)
	if type(prefs_file) ~= "string" or prefs_file == "" or _owned_publications[prefs_file] then return nil end
	local called, values, source = pcall(function()
		local current = classify_source(prefs_file)
		if not current then return nil end
		if current.status == "absent" then return {}, current end
		local decoded, shapes = require("toml_codec.leaf_rows").decode_source(current.content)
		if type(decoded) ~= "table" then return nil end
		for _, spec in pairs(KEY_MAP) do
			local node = decoded[spec.sec]
			if node ~= nil and type(node) ~= "table" then return nil end
			for segment in (spec.path or ""):gmatch("[^.]+") do
				node = node and node[segment]
				if node ~= nil and type(node) ~= "table" then return nil end
			end
		end
		local flat
		local outdated = ConfigOutdated.collect_reports(function() flat = flatten_from_disk(decoded, nil, shapes) end)
		if next(outdated) ~= nil then return nil end
		for key, value in pairs(flat) do
			local spec = KEY_MAP[key]
			if spec then
				local path = spec.sec .. "." .. (spec.path and (spec.path .. ".") or "") .. (spec.key or key)
				local entry = Manifest.find_entry_by_path(path)
				if entry and entry.type ~= "enum" and type(value) ~= (entry.type == "array" and "table" or entry.type) then return nil end
				if entry and not ConfigOutdated.manifest_value_fits(entry, value, "hs", SCALAR_VALUE_RULES[key]) then return nil end
			end
		end
		return flat, current
	end)
	if not called then return nil end
	return values, source
end

--- Compares classifications issued by the current preferences owner.
--- @param expected table|nil Captured exact source classification.
--- @param current table|nil Current exact source classification.
--- @return boolean matches Whether the admitted source is unchanged.
function M.source_matches(expected, current)
	local function classified(source)
		return type(source) == "table"
			and (source.status == "absent" or (source.status == "ok" and type(source.content) == "string"))
	end
	return classified(expected) and classified(current) and same_source(expected, current)
end

--- Returns detached evidence of this owner's last acknowledged full save.
--- Load, source adoption and cleanup do not issue publication receipts.
--- @param prefs_file string Canonical configuration path.
--- @return table receipt Monotonic id and exact acknowledged source, when any.
function M.publication_receipt(prefs_file)
	local receipt = _save_receipts[prefs_file]
	if not receipt then return { id = 0 } end
	return { id = receipt.id, source = { status = "ok", content = receipt.source.content } }
end

--- Marks every config.toml path load() takes into the flat state, through the
--- very walk load() uses.
--- @param decoded table Decoded config.toml.
--- @param mark function mark(...segments) from config_unused_keys.
function M.mark_config_reads(decoded, mark, shapes)
	if type(mark) ~= "function" then error("Preferences.mark_config_reads needs a mark function", 2) end
	flatten_from_disk(decoded, mark, shapes)
end

--- Flattens a decoded config.toml into menu-state keys through the walk load()
--- uses, so a scope applies exactly what the next boot would read. Table values
--- alias the decoded document, which the caller must not reuse.
--- @param decoded table Decoded config.toml.
--- @return table flat Flat preferences.
function M.flatten_document(decoded, shapes)
	if type(decoded) ~= "table" then error("Preferences.flatten_document needs a decoded document", 2) end
	return flatten_from_disk(decoded, nil, shapes)
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
	if _owned_publications[prefs_file] then return false end
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
	if _owned_publications[path] then return false end
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
	return require("toml_codec.leaf_rows").clone_value(value)
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

--- Detects only the obsolete scalar at the declared optional model-list leaf.
--- Legacy table spellings and record-level policy remain with their owners.
--- @param document table|nil Exact decoded source model.
--- @return boolean obsolete
local function user_models_scalar_is_obsolete(document)
	local llm = type(document) == "table" and document.llm or nil
	local models = type(llm) == "table" and llm.models or nil
	if type(models) ~= "table" then return false end
	return models.user_models ~= nil and type(models.user_models) ~= "table"
end

--- Rewrites only declared LLM leaves inside existing inline preference tables.
--- The scanner owns TOML syntax; this owner clones parsed values and preserves
--- neighboring fields before handing one complete inline value to the writer.
--- @param source table Exact classified source snapshot.
--- @param updates table Manifest-owned leaf operations.
--- @return table rows Addressable operations with inline tables retained.
local function prepare_inline_updates(source, updates, root)
	local scanned, detail = require("toml_codec.record_scanner").scan_records(source.content or "", { quoted_headers = true })
	assert(scanned, detail)
	local LeafRows = require("toml_codec.leaf_rows")
	local decoded = LeafRows.decode_source(source.content or "")
	if root == "llm" and user_models_scalar_is_obsolete(decoded) then
		local preserved = {}
		for _, row in ipairs(updates) do
			local path = require("toml_codec.key_path").parse(row.section, true)
			if path then path[#path + 1] = row.key end
			if path and #path == 3 and path[1] == "llm" and path[2] == "models" and path[3] == "user_models" then
				-- A scope's neutral list is not an explicit obsolete-entry cleanup.
				assert(row.delete or type(row.value) == "table" and next(row.value) == nil,
					"Obsolete user model list 'llm.models.user_models' requires manual source cleanup before replacement")
			else preserved[#preserved + 1] = row end
		end
		updates = preserved
	end
	local inline, candidates, rows = {}, {}, {}
	local function parts(path)
		if root == "hotstrings" then
			return assert(require("toml_codec.key_path").parse(path, true), "invalid semantic hotstring preference path")
		end
		local result = {}
		for key in path:gmatch("[^.]+") do result[#result + 1] = key end
		return result
	end
	local function leaf_path(section, key)
		if root ~= "hotstrings" then return section == "" and key or section .. "." .. key end
		local segments = section == "" and {} or parts(section)
		segments[#segments + 1] = key
		return require("toml_codec.key_path").render(segments)
	end
	for _, record in ipairs(scanned.records) do
		if record.addressable then
			local path = leaf_path(record.section, record.key)
			if path == root or path:sub(1, #root + 1) == root .. "." then
				local value = decoded
				for _, key in ipairs(parts(path)) do value = type(value) == "table" and value[key] or nil end
				-- A list is not a table of settings: no owned leaf lives inside it.
				if type(value) == "table" and #value == 0 then inline[path] = { record = record, value = value } end
			end
		end
	end
	-- Only this owner's actual inline groups need the shared forwarding proof.
	-- The publisher repeats ownership, span, value and native source checks.
	local direct_parents = {}
	if next(inline) ~= nil then
		local direct_detail
		direct_parents, direct_detail = TomlWriter.source_inline_scalar_parents(source.content or "", updates)
		assert(direct_parents, direct_detail)
	end

	for _, row in ipairs(updates) do
		local path = leaf_path(row.section, row.key)
		local parent = row.section
		while parent ~= "" and not inline[parent] do
			if root == "hotstrings" then
				local segments = parts(parent)
				table.remove(segments)
				parent = #segments > 0 and require("toml_codec.key_path").render(segments) or ""
			else parent = parent:match("^(.*)%.[^.]+$") or "" end
		end
		if path == "llm.profiles.shortcuts" and type(row.value) == "table" and next(row.value) == nil then
			-- An empty runtime dictionary owns no unknown profile leaves on disk.
		elseif inline[parent] and not direct_parents[parent] then
			local candidate = candidates[parent] or clone_value(inline[parent].value)
			candidates[parent] = candidate
			local keys, target = parts(path:sub(#parent + 2)), candidate
			local missing, ancestry = false, {}
			for index = 1, #keys - 1 do
				local child = target[keys[index]]
				assert(child == nil or type(child) == "table", "inline preference ownership crosses a scalar")
				if child == nil and row.delete then missing = true; break end
				if child == nil then child = {}; target[keys[index]] = child end
				ancestry[#ancestry + 1] = { parent = target, key = keys[index] }
				target = child
			end
			if not missing then
				if row.delete then target[keys[#keys]] = nil else target[keys[#keys]] = clone_value(row.value) end
				for index = #ancestry, 1, -1 do
					local node = ancestry[index]
					if next(node.parent[node.key]) == nil then node.parent[node.key] = nil else break end
				end
			end
		else rows[#rows + 1] = row end
	end
	for path, candidate in pairs(candidates) do
		local record = inline[path].record
		local path_segments = assert(require("toml_codec.key_path").parse(record.section, true))
		path_segments[#path_segments + 1] = record.key
		local operation = next(candidate) == nil and { path = path_segments, delete = true }
			or { path = path_segments, value = candidate }
		-- Reissue a real same-source row after this native owner transforms the
		-- value; forwarding a stale receipt or a plain model loses future kinds.
		for _, prepared in ipairs(LeafRows.prepare(source.content or "", { operation })) do
			rows[#rows + 1] = prepared
		end
	end
	return rows
end

--- Prepares declared LLM leaves while preserving inline neighbors.
--- @param source table Classified source.
--- @param updates table Owned leaf operations.
--- @return table Prepared writer operations.
function M.prepare_llm_updates(source, updates)
	return prepare_inline_updates(source, updates, "llm")
end

--- The assignment containers of [shortcuts] a write may replace when they
--- hold an older build's plain value: the Shortcuts scope owns both.
M.SHORTCUT_CONTAINERS = { "keyboard", "tap_keys" }

--- Prepares declared shortcut leaves while preserving inline neighbors.
--- @param source table Classified source.
--- @param updates table Owned leaf operations.
--- @param containers table|nil Assignment containers this write fills
---   (`keyboard`, `tap_keys`). A plain value an older build left there (`keyboard
---   = "…"`) would make every row below it unwritable, so the write replaces
---   it. Any other container, and every ordinary save (nil), leaves such a
---   value on disk for the config cleanup, which offers it.
--- @return table Prepared writer operations.
function M.prepare_shortcut_updates(source, updates, containers)
	local rows = {}
	local decoded = TomlCodec.decode(source.content or "")
	local section = type(decoded) == "table" and decoded.shortcuts or nil
	for _, key in ipairs(type(section) == "table" and containers or {}) do
		local value = section[key]
		if value ~= nil and (type(value) ~= "table" or #value > 0) then
			rows[#rows + 1] = { section = "shortcuts", key = key, delete = true }
		end
	end
	for _, row in ipairs(prepare_inline_updates(source, updates, "shortcuts")) do rows[#rows + 1] = row end
	return rows
end

--- Preserves obsolete order rows while admitting only owned order mutations.
--- No catalogue is inferred from a namespace or a currently missing group.
--- @param source table Exact classified source snapshot.
--- @param updates table Proposed leaf operations.
--- @return table updates Source-preserving operations.
local function prepare_order_updates(source, updates)
	local KeyPath = require("toml_codec.key_path")
	local relevant = false
	for _, row in ipairs(updates) do
		local path = KeyPath.parse(row.section, true)
		if path then path[#path + 1] = row.key end
		if path and path[1] == "hotstrings" and path[2] == "order_overrides" then relevant = true end
	end
	if not relevant then return updates end
	local document, shapes = require("toml_codec.leaf_rows").decode_source(source.content or "")
	local hotstrings = type(document.hotstrings) == "table" and document.hotstrings or {}
	local orders = hotstrings.order_overrides
	local malformed_parent = orders ~= nil and not section_orders_are_map(orders, shapes)
	local bad = {}
	if not malformed_parent then
		for id, value in pairs(orders or {}) do
			if type(id) ~= "string" or id == "" or not section_order_fits(value, shapes) then bad[id] = true end
		end
	end
	local function refuse(path)
		error("Obsolete section order '" .. KeyPath.render(path) .. "' requires manual source cleanup before replacement", 0)
	end
	local prepared = {}
	for _, row in ipairs(updates) do
		local path = KeyPath.parse(row.section, true)
		if path then path[#path + 1] = row.key end
		if path and path[1] == "hotstrings" and path[2] == "order_overrides" and #path == 2 and not row.delete then
			assert(section_orders_are_map(row.value), "section orders candidate is not a table of settings")
		end
		if not path or path[1] ~= "hotstrings" or path[2] ~= "order_overrides" then
			prepared[#prepared + 1] = row
		elseif #path == 2 and (row.delete or type(row.value) == "table" and next(row.value) == nil) then
			if not malformed_parent and next(bad) == nil then
				prepared[#prepared + 1] = row
			elseif not malformed_parent then
				for id in pairs(orders) do
					if not bad[id] then prepared[#prepared + 1] = { section = "hotstrings.order_overrides", key = id, delete = true } end
				end
			end
		elseif malformed_parent or #path == 2 and next(bad) ~= nil or bad[path[3]] then
			if not row.delete then refuse(malformed_parent and { "hotstrings", "order_overrides" } or path) end
		else
			assert(#path <= 3, "section order mutations must address a whole text list")
			if not row.delete then
				if #path == 2 then
					assert(section_orders_are_map(row.value), "section orders candidate is not a table of settings")
					for id, value in pairs(row.value) do
						assert(type(id) == "string" and id ~= "", "section order identity is not a nonempty text key")
						assert(section_order_fits(value), "section order candidate is not a text list")
					end
				else
					assert(type(path[3]) == "string" and path[3] ~= "", "section order identity is not a nonempty text key")
					assert(section_order_fits(row.value), "section order candidate is not a text list")
				end
			end
			prepared[#prepared + 1] = row
		end
	end
	return prepared
end

--- Preserves unowned hotstring neighbors while changing declared inline leaves.
--- @param source table Exact classified source.
--- @param updates table Owned leaf operations.
--- @return table Prepared writer operations.
function M.prepare_hotstring_updates(source, updates)
	updates = prepare_order_updates(source, updates)
	local personal = {}
	for _, row in ipairs(updates) do
		local path = require("toml_codec.key_path").parse(row.section, true)
		if path then path[#path + 1] = row.key end
		if path and PersonalFiles.preference_default(require("toml_codec.key_path").render(path)) ~= nil then
			personal[#personal + 1] = row
		end
	end
	assert(require("hotstrings.personal_metadata").exact_rows_available(source.content or "", personal),
		"canonical personal preferences have an ambiguous case alias")
	return prepare_inline_updates(source, updates, "hotstrings")
end

--- Preflights canonical personal choices through this preferences source owner.
--- Native callers separately hold the actual source and registry bindings.
--- @param changes table Declared canonical group/section Boolean choices.
--- @return boolean available
function M.personal_choices_available(changes)
	local path = require("infra.config_paths").get("ConfigTomlPath")
	if type(path) ~= "string" or type(changes) ~= "table" then return false end
	local baseline, current = _source_snapshots[path], classify_source(path)
	if not current or baseline and not same_source(baseline, current) then return false end
	local rows = {}
	for _, choice in ipairs(changes) do
		if PersonalFiles.components(choice.group) then
			if type(choice.enabled) ~= "boolean" or choice.section ~= nil
				and (type(choice.section) ~= "string" or choice.section == "") then return false end
			local record = require("infra.personal_hotstrings").adoption(choice.group)
			if not record or record.admitted ~= true
				or require("infra.personal_hotstrings").adoption_current(record) ~= true then return false end
			rows[#rows + 1] = { section = require("toml_codec.key_path").render(choice.section
				and { "hotstrings", "modules", choice.group } or { "hotstrings", "groups" }),
				key = choice.section or choice.group }
		end
	end
	return require("hotstrings.personal_metadata").exact_rows_available(current.content or "", rows)
end

--- Publishes a domain owner's exact batch and advances the ordinary save baseline.
--- @param path string Canonical configuration path.
--- @param updates table Already validated owned operations.
--- @param source table Exact classified source used by the domain owner.
--- @return boolean committed
function M.publish_owned(path, updates, source)
	if _owned_publications[path] then return false end
	local baseline = _source_snapshots[path]
	if baseline and not same_source(baseline, source) then return false end
	_owned_publications[path] = true
	local called, committed, detail, encoded = pcall(TomlWriter.batch_write, path, updates, FileSystem, source)
	_owned_publications[path] = nil
	if not called or committed ~= true then
		Logger.error(LOG, "Owned preferences were not published: %s.", tostring(called and detail or committed))
		return false
	end
	_source_snapshots[path] = { status = "ok", content = encoded }
	return true
end

--- Projects canonical preferences onto the actual registered hotstring inventory.
--- Disk-only neighbors and UI placeholders acquire no runtime ownership.
--- @param saved table Flat values returned by this preferences reader.
--- @param groups table Registered group names and their current enabled posture.
--- @param get_sections function Returns each group's registered section descriptors.
--- @return table desired Complete group and section posture, with neutral absence.
function M.project_hotstring_preferences(saved, groups, get_sections)
	assert(type(saved) == "table" and type(groups) == "table" and type(get_sections) == "function",
		"hotstring projection needs canonical preferences and a registered inventory")
	assert(saved.hotstrings == nil or type(saved.hotstrings) == "table", "hotstring groups must be a table")
	assert(saved.section_states == nil or type(saved.section_states) == "table", "hotstring sections must be a table")
	local desired = { hotstrings = {}, section_states = {} }
	for name in pairs(groups) do
		assert(type(name) == "string" and name ~= "", "hotstring group identity is invalid")
		local enabled = saved.hotstrings and saved.hotstrings[name]
		local personal_record, personal_sections
		if PersonalFiles.components(name) then
			personal_record = require("infra.personal_hotstrings").adoption(name)
			if personal_record then
				enabled, personal_sections = PersonalAdoption.preferences(personal_record, saved)
			else
				-- Valid provenance alone cannot admit a native mutation or live gate.
				enabled, personal_sections = false, {}
			end
		end
		if enabled == nil then enabled = Manifest.default_for("hotstrings.groups." .. name) end
		assert(type(enabled) == "boolean", "hotstring group preference must be boolean")
		desired.hotstrings[name] = enabled
		local supplied = saved.section_states and saved.section_states[name]
		if personal_sections ~= nil then supplied = personal_sections end
		assert(supplied == nil or type(supplied) == "table", "hotstring section preferences must be a table")
		local sections = get_sections(name)
		assert(sections == nil or type(sections) == "table", "hotstring section inventory is malformed")
		local projected = {}
		for _, section in ipairs(sections or {}) do
			assert(type(section) == "table" and type(section.name) == "string", "hotstring section descriptor is invalid")
			if HotstringLanguages.section_actionable(Manifest.features(), name, section) then
				local selected = supplied and supplied[section.name]
				if PersonalFiles.components(name) and (not personal_record or personal_record.admitted ~= true) then
					selected = false
				end
				if selected == nil then selected = Manifest.default_for(require("toml_codec.key_path").render(
					{ "hotstrings", "modules", name, section.name })) end
				assert(type(selected) == "boolean", "hotstring section preference must be boolean")
				projected[section.name] = selected
			end
		end
		desired.section_states[name] = projected
	end
	return desired
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
				if HotstringLanguages.section_actionable(Manifest.features(), name, sec) then
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

--- The deletes that reset one whole preference table while keeping the entries
--- load() judged outdated below it (see _load_outdated). A table the state
--- holds empty is saved as one delete or `{}`, which replaces the table and
--- every entry on disk, whether inline or behind its own [header], erasing the
--- outdated ones before the cleanup could offer them.
--- @param row table Sparse row of one preference path.
--- @param outdated table Set of outdated dotted paths.
--- @param document table|nil Decoded source.
--- @return table|nil rows Deletes of the entries the state owns, or nil when
---   the row is not such a reset or no outdated entry lies below it.
local function reset_keeping_outdated(row, outdated, document)
	if not row.delete and not (type(row.value) == "table" and next(row.value) == nil) then return nil end
	local function below(prefix)
		for candidate in pairs(outdated) do
			if candidate:sub(1, #prefix + 1) == prefix .. "." then return true end
		end
		return false
	end
	local path = row.section .. "." .. row.key
	if not below(path) then return nil end
	local node = document
	for segment in path:gmatch("[^.]+") do
		if type(node) ~= "table" then return nil end
		node = node[segment]
	end
	-- A list has no id = value entries to keep one by one.
	if type(node) ~= "table" or #node > 0 then return nil end
	local rows = {}
	for key in pairs(node) do
		local child = path .. "." .. tostring(key)
		if not outdated[child] and not below(child) then
			rows[#rows + 1] = { section = path, key = key, delete = true }
		end
	end
	table.sort(rows, function(left, right) return left.key < right.key end)
	return rows
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
	if _owned_publications[prefs_file] then return false end
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

	-- A value load() judged outdated is left for the cleanup: the state holds
	-- its default, whose sparse delete must not erase it (see _load_outdated).
	local outdated = _load_outdated[prefs_file] or {}
	local replaced = {}
	local ok, updates = pcall(function()
		local document, shapes
		if expected_source.status == "ok" then
			document, shapes = require("toml_codec.leaf_rows").decode_source(expected_source.content)
		end
		if user_models_scalar_is_obsolete(document) and existing.llm_user_models ~= nil then
			-- Reject a changed carried snapshot before sparse encoding can omit it
			-- or overwrite the obsolete source without an explicit cleanup.
			assert(type(existing.llm_user_models) == "table" and next(existing.llm_user_models) == nil,
				"Obsolete user model list 'llm.models.user_models' requires manual source cleanup before replacement")
		end
		local hotstrings = document and type(document.hotstrings) == "table" and document.hotstrings or {}
		local orders, desired = hotstrings.order_overrides, existing.sections_order_overrides
		local cleared_orders = {}
		assert(desired == nil or section_orders_are_map(desired), "section orders candidate is not a table of settings")
		if type(desired) == "table" then
			for id, value in pairs(desired) do
				assert(type(id) == "string" and id ~= "", "section order identity is not a nonempty text key")
				local old
				if type(orders) == "table" then old = orders[id] end
				assert(orders == nil or section_orders_are_map(orders, shapes),
					"Obsolete section orders in '" .. prefs_file .. "' require manual source cleanup")
				assert(old == nil or section_order_fits(old, shapes),
					"Obsolete section order '" .. require("toml_codec.key_path").render({ "hotstrings", "order_overrides", id })
						.. "' in '" .. prefs_file .. "' requires manual source cleanup before replacement")
				assert(section_order_fits(value), "section order candidate is not a text list")
				-- Sparse array encoding omits an empty list. A user who clears an
				-- existing order must remove it, while a carried source [] keeps its
				-- exact kind and is not silently replaced by an empty map.
				if old ~= nil and next(old) ~= nil and next(value) == nil then
					cleared_orders[#cleared_orders + 1] = { section = "hotstrings.order_overrides", key = id, delete = true }
				end
			end
		end
		local leaves = {}
		local proposed = sparse_updates(existing)
		for _, row in ipairs(cleared_orders) do proposed[#proposed + 1] = row end
		for _, row in ipairs(WrapPreferences.prepare(expected_source.content or "", existing)) do
			proposed[#proposed + 1] = row
		end
		for _, row in ipairs(proposed) do
			local path = row.section .. "." .. row.key
			local reset = reset_keeping_outdated(row, outdated, document)
			if reset then
				for _, child in ipairs(reset) do leaves[#leaves + 1] = child end
			elseif not (row.delete and outdated[path]) then
				leaves[#leaves + 1] = row
				if outdated[path] then replaced[#replaced + 1] = path end
			end
		end
		return M.prepare_hotstring_updates(expected_source, M.prepare_shortcut_updates(expected_source, M.prepare_llm_updates(expected_source, M.prepare_gesture_updates(expected_source, leaves))))
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
			Logger.error(LOG, "Cannot atomically replace '%s' — settings NOT saved: %s.",
				tostring(prefs_file), tostring(write_ok and detail or written))
		end
		return false
	end
	_source_snapshots[prefs_file] = { status = "ok", content = encoded }
	if type(encoded) == "string" then
		local prior = _save_receipts[prefs_file]
		_save_receipts[prefs_file] = { id = (prior and prior.id or 0) + 1, source = { status = "ok", content = encoded } }
	end
	-- The user's own value replaced the outdated one: its later default is a
	-- real choice again, saved sparsely like any other.
	for _, path in ipairs(replaced) do outdated[path] = nil end
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
