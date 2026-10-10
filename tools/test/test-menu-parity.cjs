// tools/test/test-menu-parity.cjs

/**
 * ==============================================================================
 * MODULE: Cross-Driver Menu Parity (I3)
 * DESCRIPTION:
 * Projects menu_manifest.json for Windows, macOS and Linux, walks the three
 * resulting menu trees, and asserts they differ only where the manifest says so.
 *
 * WHY A SECOND MENU GATE, NEXT TO test-menu-top-level-parity.cjs:
 * That one compares the TOP LEVEL and stops there — deliberately, because when it
 * was written Linux had no manifest renderer and reading its submenus meant
 * reading 1200 lines of hand-built rows. Everything below the top level was
 * therefore unmeasured, and three defects were living in that gap on 2026-08-04:
 *
 *   tap_holds  — top_level declared it for macOS, every row of tap_holds_menu was
 *                restricted to Windows, and no macOS file builds a tap-hold menu
 *                at all. macOS shipped a top-level entry that opened an EMPTY
 *                submenu. The top-level gate could not see it: it reads the macOS
 *                dispatch chain only from `global_actions` onward, and tap_holds
 *                sits above that boundary.
 *   gestures   — unrestricted at the top level, so visible on Linux, while the
 *                manifest projected exactly ONE row of gestures_menu for Linux:
 *                a bare separator. menu_builder.lua has always built a toggle,
 *                both bulk actions and every slot. Same shape of omission as
 *                kanata/updates/apps, one level deeper.
 *   extensions — a section_header with no platforms, introducing a single row
 *                restricted to Windows. macOS and Linux drew the title with
 *                nothing under it.
 *
 * None of the three is a coding mistake. All three are the manifest declaring a
 * shape no driver has, which is exactly what a manifest cannot be trusted to do
 * unless something checks.
 *
 * WHAT IT HOLDS:
 * 1. Every submenu is reachable, and a parent row visible on a platform opens a
 *    submenu with at least one actionable row THERE.
 * 2. No section header is left without a section on any platform.
 * 3. Every divergence between two platforms traces to a `platforms` field on the
 *    diverging row itself — never to a structural accident.
 * 4. Every i18n key the manifest names resolves in all 21 locales, so a label
 *    tree is a tree of labels and not of raw keys.
 * 5. A row narrower than the menu containing it should say why (`reason_key`),
 *    or be declared not applicable there (`unavailable = "hide"`, the
 *    maintainer's classification of 2026-09-30, which owes no reason).
 *    Ratcheted, because 41 predate this gate.
 * 6. The Lua drivers render an ever-growing share of the manifest through the
 *    shared renderer rather than by hand. Ratcheted upward.
 *
 * WHAT IT DELIBERATELY DOES NOT COMPARE:
 * the rows a `list` provider or a `dynamic` handler produces at runtime. Their
 * content is a function of what the user has installed — five hotstring packs on
 * one machine, twelve on another — so comparing it would compare two machines
 * rather than two drivers. Their PRESENCE is compared, which is the part the
 * manifest owns.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { scriptTokens } = require('../lib/script-source.cjs');
const {
	delegatedMenuSources,
	combineMenuVisibility
} = require('../lib/menu-shared-delegation.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

const PLATFORMS = ['ahk', 'hs', 'linux'];

// Which driver each platform token names. A reader who has to map "hs" to macOS
// themselves reads every failure twice.
const DRIVER_OF = { ahk: 'Windows', hs: 'macOS', linux: 'Linux' };

// Rows that carry no label and cannot be compared by name.
const SEPARATOR = '---';

// Which manifest key each row opens as a submenu. Written out rather than
// derived from the id, because the two disagree often enough (`debug` opens
// `debug_menu`, `keyboard_layout` opens `layout_menu`) that a naming rule would
// be a rule with four exceptions — and a missing entry here would silently make
// a whole submenu unreachable, which is one of the things being checked.

const OPENS_SUBMENU = {
	keyboard_slots: [
		{
			menu: 'keyboard_group_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_keyboard_slots.lua' }
		},
		{
			menu: 'slot_binding_frame',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		}
	],
	tap_keys: {
		menu: 'slot_binding_frame',
		platforms: ['linux'],
		kind: 'compose',
		native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
	},
	script_control_shortcuts: {
		menu: 'slot_binding_frame',
		platforms: ['linux'],
		kind: 'compose',
		native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
	},
	gesture_slots_linux: {
		menu: 'slot_binding_frame',
		platforms: ['linux'],
		kind: 'compose',
		native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
	},
	magic_key_source: {
		menu: 'magic_key_source_menu',
		platforms: ['ahk', 'hs', 'linux'],
		kind: 'submenu'
	},
	magic_key_source_heading: {
		menu: 'magic_key_source_children',
		platforms: ['ahk', 'hs', 'linux'],
		kind: 'submenu'
	},
	// The empty native Input Sources provider composes its actual shared command.
	active_layouts: {
		menu: 'layout_active_source_empty_commands',
		platforms: ['hs'],
		kind: 'compose',
		native_sources: { hs: 'macos/ui/menu/menu_keyboard_layout.lua' }
	},
	apps_installed: {
		menu: 'apps_empty_rows',
		platforms: ['hs'],
		kind: 'compose',
		native_sources: { hs: 'macos/ui/menu/menu_apps.lua' }
	},
	system_gesture_status: [
		{
			menu: 'gesture_system_status_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/gesture_conflicts.ahk',
				hs: 'macos/ui/menu/menu_gestures.lua'
			}
		},
		{
			menu: 'gesture_system_status_windows_frame',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: { ahk: 'windows/ui/gesture_conflicts.ahk' }
		},
		{
			menu: 'gesture_system_status_macos_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{
			menu: 'gesture_system_status_linux_frame',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/gesture_conflicts.lua' }
		}
	],
	gesture_system_unknown_children: [
		{
			menu: 'gesture_system_windows_children',
			platforms: ['ahk'],
			kind: 'submenu',
			native_sources: { ahk: 'windows/ui/gesture_conflicts.ahk' }
		},
		{
			menu: 'gesture_system_linux_children',
			platforms: ['linux'],
			kind: 'submenu',
			native_sources: { linux: 'linux/ui/gesture_conflicts.lua' }
		}
	],
	gesture_system_clear_children: [
		{
			menu: 'gesture_system_windows_children',
			platforms: ['ahk'],
			kind: 'submenu',
			native_sources: { ahk: 'windows/ui/gesture_conflicts.ahk' }
		},
		{
			menu: 'gesture_system_macos_children',
			platforms: ['hs'],
			kind: 'submenu',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_system_conflict_children: [
		{
			menu: 'gesture_system_windows_children',
			platforms: ['ahk'],
			kind: 'submenu',
			native_sources: { ahk: 'windows/ui/gesture_conflicts.ahk' }
		},
		{
			menu: 'gesture_system_macos_children',
			platforms: ['hs'],
			kind: 'submenu',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_system_cached_slots: {
		menu: 'gesture_system_slot_windows_frame',
		platforms: ['ahk'],
		kind: 'compose',
		native_sources: { ahk: 'windows/ui/gesture_conflicts.ahk' }
	},
	gesture_system_cached_overlap: {
		menu: 'gesture_system_slot_linux_frame',
		platforms: ['linux'],
		kind: 'compose',
		native_sources: { linux: 'linux/ui/gesture_conflicts.lua' }
	},
	selection_operations: [
		'selection_caps_word_control',
		{
			menu: 'selection_case_boundary',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		},
		'selection_case_commands',
		{
			menu: 'selection_helper_boundary',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		},
		'selection_helper_commands'
	],
	// Every native live-mode provider renders the shared fixed Off choice.
	llm_live_mode: [
		'llm_live_controls',
		{
			menu: 'llm_live_off_boundary',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/live_mode_panel.lua' }
		}
	],
	agent_system1: [
		{
			menu: 'agent_system1_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		},
		{
			menu: 'agent_download_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		},
		'agent_system_controls',
		{
			menu: 'agent_server_empty_status',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		},
		'agent_system_model_controls',
		{
			menu: 'agent_system_model_installed_controls',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		},
		{
			menu: 'agent_system_model_missing_controls',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		}
	],
	agent_system2: [
		{
			menu: 'agent_system2_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		},
		{
			menu: 'agent_download_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		},
		'agent_system_controls',
		{
			menu: 'agent_server_empty_status',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		},
		'agent_system_model_controls',
		{
			menu: 'agent_system_model_installed_controls',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		},
		{
			menu: 'agent_system_model_missing_controls',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		}
	],
	configuration: 'configuration_menu',
	debug: 'debug_menu',
	shortcuts: [
		'shortcuts_menu',
		{
			menu: 'shortcut_wrap_frame',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'shortcut_chatgpt_editor_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_shortcuts.lua' }
		},
		{
			menu: 'shortcut_wrap_live_control',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		},
		{
			menu: 'linux_shortcuts_absent_rows',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		}
	],
	personal_shortcuts: {
		menu: 'personal_shortcuts_frame',
		platforms: ['ahk'],
		kind: 'compose',
		native_sources: { ahk: 'windows/ui/menu/menu_init.ahk' }
	},
	extensions_shortcuts: [
		{
			menu: 'shortcut_extension_boundary',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		},
		{
			menu: 'shortcut_extension_error_frame',
			platforms: ['ahk', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'shortcut_extension_empty_frame',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: { ahk: 'windows/ui/menu/menu_shortcuts.ahk' }
		}
	],
	// Native wrap providers compose these fixed fragments into their existing picker.
	wrap_symbols_menu: [
		{
			menu: 'wrap_symbols_global_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		},
		{
			menu: 'wrap_symbols_group_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		},
		{
			menu: 'wrap_symbols_custom_separator',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		},
		{
			menu: 'wrap_symbols_custom_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		},
		{
			menu: 'wrap_symbols_add_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		}
	],
	metrics: [
		'metrics_menu',
		{
			menu: 'linux_metrics_absent_rows',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		}
	],
	// Its native state branches compose readouts into the existing Metrics menu.
	metrics_migration: ['metrics_migration_unavailable_rows', 'metrics_migration_idle_rows'].map(
		(menu) => ({
			menu,
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		})
	),
	keyboard_layout: 'layout_menu',
	number_row_policy: 'number_row_policy_rows',
	hotstrings: [
		'hotstrings_menu',
		{
			menu: 'linux_hotstrings_absent_rows',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		}
	],
	// The personal provider renders the shared editor command head on every driver.
	hotstring_personal: [
		{
			menu: 'hotstring_personal_default_parent',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			selected_group: {
				ahk: {
					row: {
						type: 'group',
						id: 'personal_default_caption',
						i18n: 'menu.hotstrings.default_category_prefix',
						caption_getter: 'personal_default_label',
						caption_layout: 'prefix',
						caption_joiner: ''
					},
					owner_signature: '_HS_PersonalRows(Options := unset) {',
					call: 'DefaultCaption := MenuRenderer_GroupRow("hotstring_personal_default_parent", "personal_default_caption", DefaultSectionMenu, Map("personal_default_label", (*) => CurDefaultLabel))',
					handoff: 'DefaultParent := [DefaultCaption]',
					consumer: '"personal_default_parent", (*) => DefaultParent,'
				}
			},
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_custom.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstring_personal_legacy_shortcut',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_hotstrings_custom.lua' }
		},
		'personal_hotstring_commands',
		'personal_file_controls',
		'personal_file_unavailable',
		'personal_directory_unavailable',
		{
			menu: 'hotstring_personal_default_frame',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_custom.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstring_personal_controls_frame',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_custom.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstring_personal_content_frame',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_custom.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstring_personal_file_frame',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_custom.lua'
			}
		},
		{
			menu: 'hotstring_personal_directory_frame',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_custom.lua'
			}
		}
	],
	personal_default_caption: 'hotstring_personal_default_frame',
	// Lua category providers build the parent; Windows publishes its child inline.
	hotstring_category_sections: [
		{ menu: 'programmable_hotstring_entry', platforms: ['hs', 'linux'] },
		{ menu: 'programmable_hotstrings', platforms: ['ahk'] }
	],
	programmable_hotstrings: {
		menu: 'programmable_hotstrings',
		platforms: ['hs', 'linux']
	},
	// Each standard category provider opens the shared explicit command head.
	hotstring_categories_standard: 'hotstring_category_menu',
	gestures: [
		'gestures_menu',
		{
			menu: 'linux_gestures_absent_rows',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		}
	],
	gesture_slots_2: [
		{
			menu: 'gesture_swipe_slot_menu',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{ menu: 'gesture_slot_mode_commands', platforms: ['hs'] },
		{
			menu: 'gesture_sensitivity_head',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{
			menu: 'gesture_change_action',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_slots_3: [
		{
			menu: 'gesture_swipe_slot_menu',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{ menu: 'gesture_slot_mode_commands', platforms: ['hs'] },
		{
			menu: 'gesture_sensitivity_head',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{
			menu: 'gesture_change_action',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_slots_4: [
		{
			menu: 'gesture_swipe_slot_menu',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{ menu: 'gesture_slot_mode_commands', platforms: ['hs'] },
		{
			menu: 'gesture_sensitivity_head',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{
			menu: 'gesture_change_action',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_slots_5: [
		{
			menu: 'gesture_swipe_slot_menu',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{ menu: 'gesture_slot_mode_commands', platforms: ['hs'] },
		{
			menu: 'gesture_sensitivity_head',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{
			menu: 'gesture_change_action',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_mode_options: {
		menu: 'gesture_slot_mode_commands',
		platforms: ['hs']
	},
	gesture_sensitivity_options: {
		menu: 'gesture_sensitivity_head',
		platforms: ['hs'],
		kind: 'compose',
		native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
	},
	tap_holds: [
		'tap_holds_menu',
		{
			menu: 'tap_hold_karabiner_off_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		},
		{
			menu: 'tap_hold_guardian_approval_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		},
		{
			menu: 'tap_hold_guardian_unavailable_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		},
		{
			menu: 'tap_hold_login_items_open_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		},
		{
			menu: 'tap_hold_legacy_rules_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		},
		{
			menu: 'tap_hold_action_picker_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		}
	],
	// Both hand providers render this declared fixed command under every native key.
	tap_hold_keys_left: 'tap_hold_key_rows',
	tap_hold_keys_right: 'tap_hold_key_rows',
	tap_hold_key_delay: 'tap_hold_key_delay_rows',
	key_combinations: [
		'key_combinations_group',
		{
			menu: 'tap_hold_action_picker_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		}
	],
	// Both drivers render each pair's declaration: Windows opens it at the
	// pointer, while macOS hangs it under the cached pair row.
	key_combination_rows_left: {
		menu: 'key_combination_pair_menu',
		platforms: ['ahk', 'hs']
	},
	key_combination_rows_right: {
		menu: 'key_combination_pair_menu',
		platforms: ['ahk', 'hs']
	},
	// « Raccourcis de gestion du script », the script chords of the three drivers.
	script_control: 'script_control_group',
	accented_letters: 'accented_letters_group',
	hotstring_extensions: [
		{
			menu: 'hotstring_extension_content_frame',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/builder.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstring_extension_bulk_controls',
			platforms: ['hs', 'linux'],
			kind: 'compose',
			native_sources: {
				hs: 'macos/ui/menu/menu_hotstrings.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstring_extension_empty_file',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: { ahk: 'windows/ui/menu/menu_hotstrings.ahk' }
		},
		{
			menu: 'hotstrings_parameter_boundary',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/builder.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		}
	],
	hotstrings_params: 'hotstrings_params_group',
	word_expanders: [
		'word_expanders_menu',
		{
			menu: 'hotstrings_word_expander_parent',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_management.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstrings_word_expander_frame',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_management.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstrings_parameter_boundary',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_management.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		}
	],
	// The actual Magic trigger provider consumes this frame; Linux alone owns reset.
	magic_key_config: {
		menu: 'hotstrings_magic_trigger_frame',
		platforms: ['ahk', 'hs', 'linux'],
		kind: 'compose',
		native_sources: {
			ahk: 'windows/ui/menu/menu_hotstrings.ahk',
			hs: 'macos/ui/menu/menu_hotstrings_management.lua',
			linux: 'linux/ui/menu/menu_builder.lua'
		}
	},
	magic_key_reset_if_custom: {
		menu: 'hotstrings_magic_trigger_reset',
		platforms: ['linux'],
		kind: 'compose',
		native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
	},
	// The native delay providers open the same declared configuration command.
	delays_colors: [
		'hotstrings_delays_menu',
		{
			menu: 'hotstrings_delays_parent',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_management.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstrings_delays_frame',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_hotstrings.ahk',
				hs: 'macos/ui/menu/menu_hotstrings_management.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		}
	],
	// Both Lua preview providers consume the same declared coloured checkbox.
	preview_bubbles: [
		{
			menu: 'hotstrings_preview_parent',
			platforms: ['hs', 'linux'],
			kind: 'compose',
			native_sources: {
				hs: 'macos/ui/menu/menu_hotstrings_management.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		{
			menu: 'hotstrings_preview_frame',
			platforms: ['hs', 'linux'],
			kind: 'compose',
			native_sources: {
				hs: 'macos/ui/menu/menu_hotstrings_management.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		'preview_magic_control',
		'preview_presence_controls',
		'preview_colored_control'
	],
	// Custom entries expose this head nested on Windows/macOS and inline on Linux.
	word_expander_entries: 'word_expander_custom_menu',
	// The model provider publishes its fixed browser command on every driver.
	llm_models: [
		'llm_model_commands',
		{
			menu: 'llm_api_empty_status',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/llm_backend_rows.lua' }
		},
		{
			menu: 'llm_api_add_provider_group',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/llm_backend_rows.lua' }
		},
		{
			menu: 'llm_api_add_separator',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/llm_backend_rows.lua' }
		},
		{
			menu: 'llm_backend_choice_boundary',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/llm_backend_rows.lua' }
		}
	],
	// The backend/model providers render the active API-entry command head.
	llm_backend: [
		'llm_api_active_commands',
		{
			menu: 'llm_api_add_provider_group',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/api_panel.lua' }
		},
		{
			menu: 'llm_api_add_separator',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/api_panel.lua' }
		},
		{
			menu: 'llm_backend_choice_boundary',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_models.ahk' }
		}
	],
	llm_model: [
		{
			menu: 'llm_model_header_boundary',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
				hs: 'macos/ui/menu/menu_llm/models_selector.lua'
			}
		},
		{
			menu: 'llm_api_empty_status',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_api_entries.ahk' }
		},
		{
			menu: 'llm_model_hardware_boundary',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
				hs: 'macos/ui/menu/menu_llm/models_selector.lua'
			}
		},
		{
			menu: 'llm_model_family_boundary',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
				hs: 'macos/ui/menu/menu_llm/models_selector.lua'
			}
		},
		{
			menu: 'llm_model_origin_boundary',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
				hs: 'macos/ui/menu/menu_llm/models_selector.lua'
			}
		},
		'llm_api_active_commands',
		{
			menu: 'llm_api_add_command',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_api_entries.ahk' }
		},
		{
			menu: 'llm_api_add_separator',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_api_entries.ahk' }
		},
		{
			menu: 'llm_user_model_controls',
			platforms: ['hs'],
			kind: 'submenu',
			native_sources: { hs: 'macos/ui/menu/menu_llm/models_selector.lua' }
		},
		{
			menu: 'llm_model_specs_frame',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
				hs: 'macos/ui/menu/menu_llm/models_selector.lua'
			}
		},
		{
			menu: 'llm_model_caps_frame',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
				hs: 'macos/ui/menu/menu_llm/models_selector.lua'
			}
		}
	],
	// All three profile providers render the shared Create/Clone command head.
	llm_profile: [
		'llm_profile_commands',
		{ menu: 'llm_custom_profile_controls', platforms: ['hs', 'linux'] },
		{
			menu: 'llm_profile_windows_frame',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_profiles.ahk' }
		},
		{
			menu: 'llm_profile_lua_frame',
			platforms: ['hs', 'linux'],
			kind: 'compose',
			native_sources: {
				hs: 'macos/ui/menu/menu_llm/profiles_manager.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		}
	],
	// Optional category-file providers return this declared opening command.
	hotstring_category_file: 'hotstring_file_commands',
	llm_display: [
		'llm_display_menu',
		{
			menu: 'llm_display_provider_boundary',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk' }
		}
	],
	// Native prediction modifier providers consume the shared child records.
	llm_navigation: 'llm_navigation_rows',
	llm_trigger: [
		{
			menu: 'llm_trigger_provider_boundary',
			platforms: ['ahk', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		},
		'llm_trigger_menu',
		{
			menu: 'llm_numeric_custom_rows',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		}
	],
	llm_generation_settings: [
		'llm_generation_menu',
		{
			menu: 'llm_generation_count_boundary',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk',
				hs: 'macos/ui/menu/menu_llm/init.lua'
			}
		},
		{
			menu: 'llm_generation_context_boundary',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk'
			}
		},
		{
			menu: 'llm_generation_words_boundary',
			platforms: ['ahk'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk'
			}
		}
	],
	// Linux uses the same generation child inline, through its dynamic handler.
	llm_generation: [
		'llm_generation_menu',
		{
			menu: 'llm_numeric_custom_rows',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		}
	],
	// The language selector. Its rows inherit `top_level/language`'s visibility,
	// which is every driver — the DECLARATION is narrower than that, and says why
	// in its own reason_key rather than through this map.
	language: 'language_menu',
	// The Applications submenu. Its rows inherit `top_level/apps`'s visibility —
	// macOS and Linux — and each declaration inside is narrower than that, for the
	// reason each carries.
	apps: 'apps_menu',
	// The About submenu, declared 2026-08-07. Visible on all three, with the same
	// rows: Linux folded its top-level Updates submenu into it in 2026-09.
	about: 'about_menu',
	// The About updater provider renders the registry-backed channel choice.
	about_updates: [
		'about_update_channel_menu',
		'about_update_frequency_menu',
		'about_source_menu',
		{
			menu: 'about_version_separator',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_init.ahk',
				hs: 'macos/ui/menu/menu_about.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		}
	],
	// The LLM submenu, which had no manifest tree at all until 2026-08-06: the
	// top-level row has existed on all three drivers since the feature shipped
	// and each built the submenu beneath it by hand, so the section and its six
	// subsections described capabilities with no rows behind them.
	llm: [
		'llm_menu',
		{
			menu: 'linux_llm_absent_rows',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		}
	],
	// The AI agent submenu (_shared/modules/llm/agent.json), on every driver.
	agent_disabled_apps: {
		menu: 'agent_excluded_apps_frame',
		platforms: ['hs'],
		kind: 'compose',
		native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
	},
	agent: [
		'agent_menu',
		{
			menu: 'agent_panel_frame',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_llm/agent_panel.lua' }
		}
	]
};

// Complete finite LLM frames consume actual native children; the graph admits only their genuine calls.
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_model_action_rows',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
		hs: 'macos/ui/menu/menu_llm/models_selector.lua'
	}
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_model_identity_rows',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
		hs: 'macos/ui/menu/menu_llm/models_selector.lua'
	}
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_model_spec_rows',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
		hs: 'macos/ui/menu/menu_llm/models_selector.lua'
	}
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_model_capability_rows',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
		hs: 'macos/ui/menu/menu_llm/models_selector.lua'
	}
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_model_hardware_rows',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
		hs: 'macos/ui/menu/menu_llm/models_selector.lua'
	}
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_model_picker_head',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
		hs: 'macos/ui/menu/menu_llm/models_selector.lua'
	}
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_model_picker_default',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
		hs: 'macos/ui/menu/menu_llm/models_selector.lua'
	}
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_model_add_command',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_models.ahk',
		hs: 'macos/ui/menu/menu_llm/models_selector.lua'
	}
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_model_hf_token_command',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/models_selector.lua' }
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_saved_models_frame',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/models_selector.lua' }
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_thinking_info',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_main.ahk',
		hs: 'macos/ui/menu/menu_llm/init.lua'
	}
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_after_model_boundary',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/init.lua' }
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_mlx_port_frame',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/init.lua' }
});
OPENS_SUBMENU.llm_backend.push({
	menu: 'llm_install_warning_frame',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_main.ahk' }
});
OPENS_SUBMENU.llm.push({
	menu: 'llm_native_parent',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/init.lua' },
	completed_parent: { hs: 'llm' }
});
OPENS_SUBMENU.llm_parent_content = 'llm_menu';
for (const kind of ['llm', 'agent']) {
	OPENS_SUBMENU[kind].push({
		menu: kind === 'llm' ? 'llm_native_parent_linux' : 'agent_native_parent',
		platforms: ['linux'],
		kind: 'compose',
		native_sources: { linux: 'linux/ui/menu/ai_parent.lua' },
		completed_linux_ai_parent: kind
	});
}
OPENS_SUBMENU.llm_parent_linux = 'llm_menu';
OPENS_SUBMENU.agent_parent_linux = 'agent_menu';

OPENS_SUBMENU.llm.push({
	menu: 'llm_download_shortcut_frame',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/init.lua' }
});
OPENS_SUBMENU.llm_profile.push({
	menu: 'llm_after_profile_boundary',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_main.ahk',
		hs: 'macos/ui/menu/menu_llm/init.lua'
	}
});
OPENS_SUBMENU.llm_profile.push({
	menu: 'llm_profile_app_override_frame',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_profiles.ahk' }
});
OPENS_SUBMENU.llm_navigation = [
	OPENS_SUBMENU.llm_navigation,
	{
		menu: 'llm_modifier_picker_frame',
		platforms: ['hs'],
		kind: 'compose',
		native_sources: { hs: 'macos/ui/menu/menu_llm/settings_manager.lua' }
	}
];
OPENS_SUBMENU.llm_backend.push({
	menu: 'llm_api_selection_frame',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/api_panel.lua' }
});
OPENS_SUBMENU.llm_backend.push({
	menu: 'llm_api_active_boundary',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/api_panel.lua' }
});
OPENS_SUBMENU.llm_backend.push({
	menu: 'llm_api_system1_frame',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/api_panel.lua' }
});
OPENS_SUBMENU.llm_model.push({
	menu: 'llm_api_edit_command',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_api_entries.ahk' }
});
OPENS_SUBMENU.llm_generation_settings.push({
	menu: 'llm_generation_count_control',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk',
		hs: 'macos/ui/menu/menu_llm/init.lua'
	}
});
OPENS_SUBMENU.llm_generation_settings.push({
	menu: 'llm_generation_count_reset_control',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/init.lua' }
});
OPENS_SUBMENU.llm_generation_settings.push({
	menu: 'llm_generation_native_controls',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_llm/init.lua' }
});
OPENS_SUBMENU.llm_generation_settings.push({
	menu: 'llm_generation_context_controls',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk' }
});
OPENS_SUBMENU.llm_generation_settings.push({
	menu: 'llm_generation_word_controls',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk' }
});
OPENS_SUBMENU.llm_generation_settings.push({
	menu: 'llm_native_numeric_reset',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk' }
});
OPENS_SUBMENU.llm_generation_settings.push({
	menu: 'llm_generation_temperature_controls',
	platforms: ['ahk', 'hs'],
	kind: 'compose',
	native_sources: {
		ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk',
		hs: 'macos/ui/menu/menu_llm/temperature_panel.lua'
	}
});
OPENS_SUBMENU.llm_trigger.push({
	menu: 'llm_trigger_debounce_control',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk' }
});
OPENS_SUBMENU.llm_display.push({
	menu: 'llm_display_inline_control',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_settings.ahk' }
});
// Actual macOS switching uses genuine canonical parents and native picker data.
OPENS_SUBMENU.layout_switching = {
	menu: 'layout_switching_frame',
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_keyboard_layout.lua' }
};
OPENS_SUBMENU.layout_pause_picker = {
	menu: 'layout_switch_picker_frame',
	platforms: ['hs'],
	kind: 'submenu',
	native_sources: { hs: 'macos/ui/menu/menu_keyboard_layout.lua' }
};
OPENS_SUBMENU.layout_resume_picker = {
	menu: 'layout_switch_picker_frame',
	platforms: ['hs'],
	kind: 'submenu',
	native_sources: { hs: 'macos/ui/menu/menu_keyboard_layout.lua' }
};

// Compose before PERSONAL_DEFAULT_GROUP_PROOF; preserve all current genuine edges.
const layoutOwner = (menu) => ({
	menu,
	platforms: ['hs'],
	kind: 'compose',
	native_sources: { hs: 'macos/ui/menu/menu_keyboard_layout.lua' },
	forwarded_template: { hs: 'layout' }
});
OPENS_SUBMENU.keyboard_layout = [
	OPENS_SUBMENU.keyboard_layout,
	layoutOwner('layout_native_parent')
];
OPENS_SUBMENU.layout_parent_content = 'layout_menu';
OPENS_SUBMENU.custom_layouts = layoutOwner('layout_native_record_choice');
OPENS_SUBMENU.active_layouts = [
	OPENS_SUBMENU.active_layouts,
	layoutOwner('layout_native_record_choice')
];
OPENS_SUBMENU.layout_picker_choices = layoutOwner('layout_native_record_choice');
OPENS_SUBMENU.layout_bundle = [
	'layout_bundle_installed',
	'layout_bundle_update',
	'layout_bundle_install',
	'layout_bundle_in_list',
	'layout_bundle_update_install_first',
	'layout_bundle_upgrade',
	'layout_bundle_upgrade_to',
	'layout_bundle_variant_parent',
	'layout_bundle_install_first',
	'layout_bundle_frame'
].map(layoutOwner);
OPENS_SUBMENU.layout_variant_choices = [
	'layout_bundle_variant_added',
	'layout_bundle_variant_add'
].map(layoutOwner);

// Preserve the existing macOS excluded-applications route and add actual Linux frames.
OPENS_SUBMENU.agent_disabled_apps = [
	...(Array.isArray(OPENS_SUBMENU.agent_disabled_apps)
		? OPENS_SUBMENU.agent_disabled_apps
		: [OPENS_SUBMENU.agent_disabled_apps]),
	{
		menu: 'agent_linux_disabled_apps_frame',
		platforms: ['linux'],
		kind: 'compose',
		native_sources: { linux: 'linux/ui/menu/agent_rows.lua' }
	},
	{
		menu: 'agent_linux_disabled_apps_children',
		platforms: ['linux'],
		kind: 'compose',
		native_sources: { linux: 'linux/ui/menu/agent_rows.lua' }
	}
];
// The actual Windows dynamic slot publishes the declared picker command.
OPENS_SUBMENU.agent_disabled_apps.push({
	menu: 'agent_windows_disabled_apps_command',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_agent.ahk' }
});
OPENS_SUBMENU.agent_disabled_app_records = {
	menu: 'agent_linux_disabled_app_remove',
	platforms: ['linux'],
	kind: 'compose',
	native_sources: { linux: 'linux/ui/menu/agent_rows.lua' }
};

// Preserve every existing platform route and add actual complete Linux frames.
for (const system of ['system1', 'system2']) {
	const key = 'agent_' + system;
	OPENS_SUBMENU[key] = [
		...(Array.isArray(OPENS_SUBMENU[key]) ? OPENS_SUBMENU[key] : [OPENS_SUBMENU[key]]),
		{
			menu: 'agent_linux_' + system + '_frame',
			platforms: ['linux', 'ahk'],
			kind: 'compose',
			native_sources: {
				linux: 'linux/ui/menu/agent_rows.lua',
				ahk: 'windows/ui/menu/menu_llm/menu_agent.ahk'
			}
		},
		{
			menu: 'agent_linux_system_children',
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/agent_rows.lua' }
		}
	];
}
OPENS_SUBMENU.agent_system_backend_rows = {
	menu: 'agent_linux_system_backend_record',
	platforms: ['linux'],
	kind: 'compose',
	native_sources: { linux: 'linux/ui/menu/agent_rows.lua' }
};
OPENS_SUBMENU.agent_system_model_rows = {
	menu: 'agent_system_model_controls',
	platforms: ['linux'],
	kind: 'compose',
	native_sources: { linux: 'linux/ui/menu/agent_rows.lua' }
};
OPENS_SUBMENU.agent_system_off_rows = 'agent_system_controls';

// Actual Windows dynamic profile emitter composes its finished native child and boundary.
OPENS_SUBMENU.llm_profile.push({
	menu: 'llm_profile_parent_frame_ahk',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_main.ahk' }
});
OPENS_SUBMENU.llm_profile.push({
	menu: 'llm_profile_parent_ahk',
	platforms: ['ahk'],
	kind: 'compose',
	selected_group: {
		ahk: {
			row: {
				type: 'group',
				id: 'llm_profile_parent',
				i18n: 'menu.profiles.profile_label_prefix',
				caption_getter: 'llm_profile_parent_caption',
				disabled_when: ['llm_profile_parent_ready'],
				platforms: ['ahk'],
				unavailable: 'hide'
			},
			owner_signature: '_LLM_Menu_ProfileParentRows(NativeChild, Caption, Disabled) {',
			call: 'Parent := MenuRenderer_GroupRow("llm_profile_parent_ahk", "llm_profile_parent", NativeChild, Getters)',
			handoff: 'ParentRows := [Parent]',
			consumer: 'Map("llm_profile_parent_rows", (*) => ParentRows)'
		}
	},
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_main.ahk' }
});
OPENS_SUBMENU.llm_profile_parent = [
	'llm_profile_commands',
	{
		menu: 'llm_profile_windows_frame',
		platforms: ['ahk'],
		kind: 'compose',
		native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_profiles.ahk' }
	}
];

// Existing native catalogue data owns brands and choices; the consumed shared frames own presentation.
for (const menu of [
	'llm_backend_option_caption_frame_ahk',
	'llm_backend_ollama_port_frame_ahk',
	'llm_backend_child_frame_ahk'
]) {
	OPENS_SUBMENU.llm_backend.push({
		menu,
		platforms: ['ahk'],
		kind: 'compose',
		native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_models.ahk' }
	});
}

// Actual native selected provider parent and its complete warning publication frame.
OPENS_SUBMENU.llm_backend.push({
	menu: 'llm_backend_parent_frame_ahk',
	platforms: ['ahk'],
	kind: 'compose',
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_main.ahk' }
});
OPENS_SUBMENU.llm_backend.push({
	menu: 'llm_backend_parent_ahk',
	platforms: ['ahk'],
	kind: 'compose',
	selected_group: {
		ahk: {
			row: {
				type: 'group',
				id: 'llm_backend_parent',
				caption_source: 'native',
				caption_getter: 'llm_backend_parent_caption',
				disabled_when: ['llm_backend_parent_ready'],
				platforms: ['ahk'],
				unavailable: 'hide'
			},
			owner_signature: '_LLM_Menu_BackendParentRows(NativeChild, Caption, Disabled, WarningRows) {',
			call: 'Parent := MenuRenderer_GroupRow("llm_backend_parent_ahk", "llm_backend_parent", NativeChild, Getters)',
			handoff: 'ParentRows := [Parent]',
			consumer:
				'Map("llm_backend_parent_rows", (*) => ParentRows,\n\t\t\t"llm_backend_warning_rows", (*) => Admission["warning_rows"])'
		}
	},
	native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_main.ahk' }
});
OPENS_SUBMENU.llm_backend_parent = [
	{
		menu: 'llm_backend_choice_boundary',
		platforms: ['ahk'],
		kind: 'compose',
		native_sources: { ahk: 'windows/ui/menu/menu_llm/menu_models.ahk' }
	}
];

const PERSONAL_DEFAULT_GROUP_PROOF = OPENS_SUBMENU.hotstring_personal[0].selected_group.ahk;

/**
 * The native personal provider must actually consume its declared command head.
 * A graph edge alone would conceal a provider that stopped rendering the row.
 * @param {string} text Native provider source.
 * @param {string} driver Host source syntax.
 * @returns {boolean}
 */
// The actual language provider composes the checkbox, completed frame and native parent.
const {
	hotstringLanguagePublication,
	files: languageOwnerFiles
} = require('../lib/menu-hotstring-language-binding.cjs');
OPENS_SUBMENU.hotstring_languages = [
	{ menu: 'hotstring_scope_checkbox', platforms: ['ahk', 'hs', 'linux'] },
	{ menu: 'hotstring_language_frame', platforms: ['ahk', 'hs', 'linux'] },
	{ menu: 'hotstring_language_parent_windows', platforms: ['ahk'] },
	{ menu: 'hotstring_language_parent_lua', platforms: ['hs', 'linux'] }
].map((edge) => ({
	...edge,
	kind: 'compose',
	hotstring_language_owner: true,
	native_sources: Object.fromEntries(
		edge.platforms.map((platform) => [platform, languageOwnerFiles[platform][0]])
	)
}));

function personalCommandReference(text, driver) {
	const method = driver === 'windows' ? 'MenuRenderer_CommandRow' : 'ManifestMenu\\.command_row';
	return new RegExp(
		method + '\\(\\s*"personal_hotstring_commands"\\s*,\\s*"personal_hotstring_open_editor"\\s*,'
	).test(text.replace(/^\s*(?:;|--).*$/gm, ''));
}

// Independent call shapes also reject the right command under the wrong head.
for (const [driver, method] of [
	['windows', 'MenuRenderer_CommandRow'],
	['macos', 'ManifestMenu.command_row'],
	['linux', 'ManifestMenu.command_row']
]) {
	const call = `${method}("personal_hotstring_commands", "personal_hotstring_open_editor", commands)`;
	if (!personalCommandReference(call, driver))
		throw new Error(`Missed ${driver} command reference.`);
	for (const broken of [
		call.replace('personal_hotstring_commands', 'another_menu'),
		call.replace('personal_hotstring_open_editor', 'another_command'),
		call.replace(method, 'UnownedCommandRow'),
		(driver === 'windows' ? '; ' : '-- ') + call
	]) {
		if (personalCommandReference(broken, driver))
			throw new Error(`Admitted broken ${driver} reference.`);
	}
}

const errors = [];

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const MENU_KEYS = Object.keys(manifest).filter((k) => Array.isArray(manifest[k]));

for (const [driver, relative] of [
	['windows', 'windows/ui/menu/menu_hotstrings.ahk'],
	['macos', 'macos/ui/menu/menu_hotstrings_custom.lua'],
	['linux', 'linux/ui/menu/menu_builder.lua']
]) {
	if (!personalCommandReference(fs.readFileSync(path.join(SP, relative), 'utf8'), driver))
		errors.push(
			`${driver}: the personal provider no longer renders its shared editor command head.`
		);
}

// Floors. A parse that silently yielded nothing would make every comparison
// below vacuously true, and the suite would go green on an empty menu.
if (MENU_KEYS.length < 10) {
	errors.push(
		`the manifest declares ${MENU_KEYS.length} menu(s) — expected at least 10. The parse is broken ` +
			'and every check below is vacuous.'
	);
}

// ==================================================
// ==================================================
// ======= 1/ Projecting the manifest ===============
// ==================================================
// ==================================================

/**
 * Whether a row is visible on a platform.
 *
 * A row with no `platforms` is visible everywhere. That default is what makes an
 * UNDECLARED difference impossible to express, and therefore makes any difference
 * this gate finds a real one.
 * @param {object} row The manifest row.
 * @param {string} platform "ahk", "hs" or "linux".
 * @returns {boolean}
 */
function visibleOn(row, platform) {
	if (!row || typeof row !== 'object') return false;
	if (!Array.isArray(row.platforms)) return true;
	return row.platforms.includes(platform);
}

/**
 * Whether a row is a separator.
 *
 * Two spellings, both live: the submenus carry `type = "---"`, while top_level
 * and debug_menu carry bare `{ id = "---" }` rows with no type at all. Reading
 * only one of the two made every top-level separator look like an actionable row
 * with a duplicate identity.
 * @param {object} row The manifest row.
 * @returns {boolean}
 */
function isSeparator(row) {
	return row.type === SEPARATOR || row.id === SEPARATOR;
}

/**
 * The identity of a row: what makes it THIS row rather than another.
 *
 * Type plus whatever the row is keyed by, not the rendered label. A row that
 * changed id while keeping its label is a different row wired to a different
 * handler, and comparing labels alone would call the two equal. `feature` rows
 * have no id at all — they are keyed by the manifest `path` they toggle — so
 * leaving that out collapsed every feature row in a menu onto one identity.
 * @param {object} row The manifest row.
 * @returns {string}
 */
function identityOf(row) {
	const parts = [row.type || 'ref'];
	if (row.id) parts.push(`#${row.id}`);
	if (row.path) parts.push(`:${row.path}`);
	const key = row.i18n || row.category;
	if (key) parts.push(`@${key}`);
	return parts.join(' ');
}

/**
 * The rows of one menu visible on one platform, in manifest order.
 * @param {string} menuKey A manifest array key.
 * @param {string} platform "ahk", "hs" or "linux".
 * @returns {object[]}
 */
function project(menuKey, platform, visiting = new Set(), rowId) {
	if (visiting.has(menuKey)) throw new Error(`cyclic menu include: ${menuKey}`);
	if (!Array.isArray(manifest[menuKey])) throw new Error(`missing menu include: ${menuKey}`);
	let declaration = manifest[menuKey];
	if (rowId !== undefined) {
		const selected = declaration.filter((row) => row.id === rowId);
		if (typeof rowId !== 'string' || rowId === '' || selected.length !== 1)
			throw new Error(`invalid direct menu row selector: ${menuKey}.${rowId}`);
		declaration = selected;
	}
	visiting.add(menuKey);
	const rows = [];
	for (const row of declaration) {
		if (!visibleOn(row, platform)) continue;
		if (row.type === 'include') rows.push(...project(row.section, platform, visiting, row.row_id));
		else rows.push(row);
	}
	visiting.delete(menuKey);
	return rows;
}

// Includes are transparent: hidden tails add no clickable row, while a
// duplicated included command still has the same actionable identity.
{
	const assert = require('node:assert/strict');
	const root = manifest.tap_hold_key_rows;
	assert.equal(project('tap_hold_key_rows', 'ahk').length, 5);
	assert.equal(project('tap_hold_key_rows', 'hs').length, 6);
	assert.equal(project('tap_hold_key_rows', 'linux').length, 5);
	const original = root.slice();
	try {
		root.push({ type: 'include', section: 'tap_hold_key_head' });
		const identities = actionable('tap_hold_key_rows', 'ahk').map(identityOf);
		assert(
			identities.length > new Set(identities).size,
			'nested duplicate commands remain detectable'
		);
		root.splice(0, root.length, {
			type: 'include',
			section: 'tap_hold_key_rows'
		});
		assert.throws(() => project('tap_hold_key_rows', 'ahk'), /cyclic menu include/);
		root.splice(0, root.length, {
			type: 'include',
			section: 'absent_child_template'
		});
		assert.throws(() => project('tap_hold_key_rows', 'ahk'), /missing menu include/);
	} finally {
		root.splice(0, root.length, ...original);
	}
}

/**
 * The rows a user can actually act on: everything that is not a separator.
 * @param {string} menuKey A manifest array key.
 * @param {string} platform "ahk", "hs" or "linux".
 * @returns {object[]}
 */
function actionable(menuKey, platform) {
	return project(menuKey, platform).filter(
		(row) => !isSeparator(row) && !['label', 'section_header'].includes(row.type)
	);
}

// ==================================================
// ==================================================
// ======= 2/ The submenu graph =====================
// ==================================================
// ==================================================

// Where each menu can be reached from, and on which platforms — a submenu is
// only as visible as the row that opens it. `tap_holds_menu` restricted to
// Windows is not a Windows-only menu by its own rows; it is one because the row
// opening it says so, and its children inherit that without repeating it.
const reachableOn = { top_level: PLATFORMS.slice() };
const openedBy = {};
const reachedByKinds = {};

/** Distinguishes actual composed readouts from a clicked, empty submenu. */
function isComposedFragment(rows, kinds) {
	if (kinds.size !== 1 || !kinds.has('compose') || rows.length === 0) return false;
	return rows.every((row) => {
		if (
			['label', 'section_header'].includes(row.type) &&
			(Object.hasOwn(row, 'caption_getter') ||
				Object.hasOwn(row, 'caption_getters') ||
				Object.hasOwn(row, 'caption_layout') ||
				Object.hasOwn(row, 'caption_joiner'))
		) {
			try {
				const english = JSON.parse(fs.readFileSync(path.join(LOCALES, 'en.json'), 'utf8'));
				require('../lib/menu-row-availability.cjs').validateChildTemplates(
					{ composed_caption: [row] },
					(key) => (Object.hasOwn(english, key) ? english[key] : undefined)
				);
				return true;
			} catch {
				return false;
			}
		}
		if (row.type === SEPARATOR)
			return Object.keys(row).every((key) => ['type', 'platforms', 'unavailable'].includes(key));
		return (
			['label', 'section_header'].includes(row.type) &&
			typeof row.id === 'string' &&
			row.id !== '' &&
			typeof row.i18n === 'string' &&
			row.i18n !== '' &&
			Object.keys(row).every((key) =>
				['type', 'id', 'i18n', 'platforms', 'unavailable'].includes(key)
			)
		);
	});
}

// A real translated format is inert composition, never an empty clicked submenu.
{
	const assert = require('node:assert/strict');
	for (const type of ['label', 'section_header']) {
		const row = {
			type,
			id: 'actual_model_backend',
			i18n: 'menu.llm.model_backend',
			caption_getter: 'actual_backend'
		};
		assert.equal(isComposedFragment([row], new Set(['compose'])), true);
		assert.equal(isComposedFragment([row], new Set(['submenu'])), false);
		assert.equal(isComposedFragment([row], new Set(['compose', 'submenu'])), false);
		for (const fields of [
			{ i18n: 'menu.metrics.status' },
			{ i18n: 'menu.llm.prediction_count_label_one' },
			{ i18n: 'missing_native_translation' },
			{ caption_getter: '' },
			{ caption_getter: 0 },
			{ caption_getter: ['actual_backend'] },
			{ type: 'feature', path: 'llm.enabled' },
			{ action: 'undeclared_native_callback' },
			{ checked_when: ['native_checked'] }
		])
			assert.equal(isComposedFragment([{ ...row, ...fields }], new Set(['compose'])), false);
	}
}

// Explicit affixes remain inert composition only under the genuine canonical owner.
{
	const assert = require('node:assert/strict');
	const prefix = {
		type: 'label',
		id: 'native_error',
		i18n: 'common.error_prefix',
		caption_getter: 'native_name',
		caption_layout: 'prefix',
		caption_joiner: ''
	};
	const suffix = {
		...prefix,
		i18n: 'common.error_title',
		caption_layout: 'suffix',
		caption_joiner: ' — '
	};
	for (const row of [prefix, suffix]) {
		assert.equal(isComposedFragment([row], new Set(['compose'])), true);
		assert.equal(isComposedFragment([row], new Set(['submenu'])), false);
		assert.equal(isComposedFragment([row], new Set(['compose', 'submenu'])), false);
	}
	for (const changes of [
		{ caption_layout: 'infix' },
		{ caption_layout: false },
		{ caption_joiner: 7 },
		{ caption_joiner: '\n' },
		{ caption_getter: undefined },
		{ i18n: 'future.unknown' },
		{ i18n: 'menu.llm.hw_header' },
		{ type: 'section_header' },
		{ type: 'command' },
		{ callback: 'foreign' },
		{ children: [] },
		{ id: '' }
	])
		assert.equal(isComposedFragment([{ ...prefix, ...changes }], new Set(['compose'])), false);
}

const {
	publishesMenuTemplate: publishesTemplate,
	publishesSelectedMenuGroup
} = require('../lib/menu-shared-delegation.cjs');
// The actual completed IA parent is admitted through its real caller and child.
{
	const assert = require('node:assert/strict');
	const { nativeLlmParentPublication } = require('../lib/menu-native-llm-parent-binding.cjs');
	const source = fs.readFileSync(path.join(SP, 'macos/ui/menu/menu_llm/init.lua'), 'utf8');
	const builder = fs.readFileSync(path.join(SP, 'macos/ui/menu/builder.lua'), 'utf8');
	const rows = manifest.llm_native_parent;
	const credits = (
		candidate = source,
		caller = builder,
		definition = rows,
		top = manifest.top_level,
		...platformArgs
	) =>
		nativeLlmParentPublication(
			candidate,
			caller,
			definition,
			top,
			platformArgs.length === 0 ? 'hs' : platformArgs[0]
		);
	assert.equal(
		credits(),
		true,
		'actual imported parent binds its completed child to the real top-level caller'
	);
	// Admission preserves the complete untrusted definition: only the exact
	// reviewed Linux counterpart may accompany the unchanged HS declaration.
	assert.equal(credits(source, builder, [rows[0]]), true);
	assert.equal(
		credits(source, builder, [...rows, { type: 'group', id: 'foreign', platforms: ['linux'] }]),
		false
	);
	assert.equal(credits(source, builder, [...rows, rows[0]]), false);
	if (rows.length === 2) {
		for (const mutation of [
			{ id: 'foreign' },
			{ i18n: 'common.error_title' },
			{ disabled_when: [] },
			{ disabled_reason_key: undefined },
			{ checked_when: ['foreign'] },
			{ platforms: ['hs'] },
			{ unavailable: 'disable' },
			{ action: 'foreign' }
		])
			assert.equal(credits(source, builder, [rows[0], { ...rows[1], ...mutation }]), false);
		assert.equal(credits(source, builder, [rows[1], rows[0]]), false);
	}
	const controls = [
		[
			'local ManifestMenu     = require("infra.manifest_menu")',
			'local ManifestMenu     = require("foreign.renderer")',
			'foreign parent import'
		],
		[
			'return ManifestMenu.group_row("llm_native_parent", "llm_parent_content", main_menu, {',
			'return Foreign.group_row("llm_native_parent", "llm_parent_content", main_menu, {',
			'foreign caption owner'
		],
		[
			'return ManifestMenu.group_row("llm_native_parent", "llm_parent_content", main_menu, {',
			'return ManifestMenu.group_row("llm_native_parent", "foreign_parent", main_menu, {',
			'foreign row identity'
		],
		[
			'return ManifestMenu.group_row("llm_native_parent", "llm_parent_content", main_menu, {',
			'return ManifestMenu.group_row("llm_native_parent", "llm_parent_content", {}, {',
			'discarded native child'
		],
		[
			'llm_parent_enabled = function() return state.llm_enabled or nil end,',
			'llm_parent_enabled = function() return state.llm_enabled == true end,',
			'lost original absent checked field'
		],
		[
			'main_menu = ManifestMenu.build("llm_menu", "LLM", handlers, group_builders, render_ctx, list_providers) or {}',
			'main_menu = {}',
			'unused child producer'
		],
		[
			'llm_toggle = toggle_action,',
			'llm_toggle = function() return false end,',
			'foreign switch callback'
		],
		[
			'build_item          = build_item,',
			'build_item          = function() return {} end,',
			'unused parent exporter'
		],
		[
			'local ok, result = xpcall(create_menu, debug.traceback, deps)',
			'local ok, result = true, {}',
			'unused real handler factory'
		]
	];
	assert.equal(
		controls.length,
		9,
		'all independently authored actual native-owner withdrawal controls remain registered'
	);
	for (const [before, after, reason] of controls) {
		assert.equal(source.split(before).length - 1, 1, reason + ': exact actual source preimage');
		const candidate = source.replace(before, after);
		assert.notEqual(candidate, source, reason + ': actual source changes');
		assert.equal(credits(candidate), false, reason);
	}
	const callerControls = [
		[
			'local ManifestMenu = require("infra.manifest_menu")',
			'local ManifestMenu = require("foreign.renderer")'
		],
		['return ManifestMenu.get_root()', 'return {}'],
		['for _, entry in ipairs(declared) do', 'for _, entry in ipairs({}) do'],
		['::continue::', '::foreign_continue::'],
		[
			'local ok_b, llm_item = pcall(ctx.llm_handler.build_item)',
			'local ok_b, llm_item = true, nil'
		],
		['return llm_item and { llm_item } or {}', 'return {}'],
		['for _, row in ipairs(children) do', 'for _, row in ipairs({}) do'],
		['local rendered = separator_render(items, "top_level")', 'local rendered = {}']
	];
	callerControls.push(
		[
			'local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry }',
			'local projected = { id = "foreign", greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry }'
		],
		['table.insert(result, projected)', 'table.insert(result, {})'],
		[
			'local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry }\n\t\tif entry.disabled == true then',
			'local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry }\n\t\tif false then'
		],
		[
			'projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, entry.reason_key',
			'projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, "foreign"'
		]
	);
	assert.equal(
		callerControls.length,
		12,
		'all original eight and four current projection withdrawals remain registered'
	);
	for (const [before, after] of callerControls) {
		assert.equal(builder.split(before).length - 1, 1, 'exact current caller preimage');
		assert.equal(
			credits(source, builder.replace(before, after)),
			false,
			'actual caller/result transport must remain live'
		);
	}
	for (const candidate of ['', JSON.stringify(source), '--[=[\n' + source + '\n]=]'])
		assert.equal(credits(candidate), false, 'no quoted/comment-only or absent parent source route');
	for (const caller of ['', JSON.stringify(builder), '--[=[\n' + builder + '\n]=]'])
		assert.equal(
			credits(source, caller),
			false,
			'no quoted/comment-only or absent native caller route'
		);
	for (const definition of [
		[],
		[rows[0], rows[0]],
		[{ ...rows[0], type: 'command' }],
		[{ ...rows[0], checked_when: [] }],
		[{ ...rows[0], platforms: ['linux'] }],
		[{ ...rows[0], id: 'foreign_parent' }]
	])
		assert.equal(
			credits(source, builder, definition),
			false,
			'missing, ambiguous or foreign canonical parent earns no credit'
		);
	assert.equal(
		credits(
			source,
			builder,
			rows,
			manifest.top_level.filter((row) => row.id !== 'llm')
		),
		false,
		'withdrawn real top-level owner earns no live credit'
	);
	for (const platform of ['ahk', 'linux', 'HS', '', undefined])
		assert.equal(
			credits(source, builder, rows, manifest.top_level, platform),
			false,
			'parent proof is native HS only'
		);
	assert.equal(
		credits(
			source +
				'\n-- ManifestMenu.group_row("llm_native_parent", "llm_parent_content", fake, {})\n' +
				'local inert_parent_text = "ManifestMenu.group_row(\\\"llm_native_parent\\\", \\\"llm_parent_content\\\", fake, {})"\n'
		),
		true,
		'inert text neither supplies nor withdraws executable parent authority'
	);
	// The upstream disabled-row projection preserves the actual binding; the
	// prior direct append remains a supported, independently recorded source form.
	const projection = `		local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry }
		if entry.disabled == true then
			projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, entry.reason_key
		end
		table.insert(result, projected)`;
	const historicalProjection = `		table.insert(result, { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry })`;
	assert.equal(builder.split(projection).length - 1, 1, 'exact current projected-row preimage');
	assert.equal(
		credits(source, builder.replace(projection, historicalProjection)),
		true,
		'the historical executable top-level projection remains supported'
	);
	const projectionControls = [
		[
			projection,
			projection.replace('id = entry.id', 'id = "foreign"'),
			'foreign projected identity'
		],
		[
			projection,
			projection.replace('entry.greyed_when_paused == true', 'false'),
			'lost pause metadata'
		],
		[
			projection,
			projection.replace('if entry.disabled == true then', 'if false then'),
			'dead disabled forwarding'
		],
		[
			projection,
			projection.replace(
				'true, entry.i18n, entry.reason_key',
				'false, entry.i18n, entry.reason_key'
			),
			'lost disabled flag'
		],
		[
			projection,
			projection.replace('true, entry.i18n, entry.reason_key', 'true, "foreign", entry.reason_key'),
			'foreign disabled label'
		],
		[
			projection,
			projection.replace('true, entry.i18n, entry.reason_key', 'true, entry.i18n, "foreign"'),
			'foreign disabled reason'
		],
		['table.insert(result, projected)', 'table.insert(result, {})', 'discarded projected object'],
		[
			'table.insert(result, projected)',
			'projected = {}\n\t\ttable.insert(result, projected)',
			'rebound projected object'
		],
		[
			'table.insert(result, projected)',
			'do local projected = {}\n\t\ttable.insert(result, projected) end',
			'shadowed projected object'
		],
		[projection, 'if false then\n' + projection + '\nend', 'unreachable projection'],
		[
			'table.insert(result, projected)',
			'table.insert({}, projected)',
			'foreign append destination'
		],
		['\n\treturn _top_level_cache\nend', '\n\treturn {}\nend', 'discarded completed projection']
	];
	assert.equal(
		projectionControls.length,
		12,
		'all projected transport refusal controls registered'
	);
	for (const [before, after, reason] of projectionControls) {
		assert.equal(builder.split(before).length - 1, 1, reason + ': exact source preimage');
		const candidate = builder.replace(before, after);
		assert.notEqual(candidate, builder, reason + ': actual source changes');
		assert.equal(credits(source, candidate), false, reason);
		assert.equal(credits(source, builder), true, reason + ': genuine source inverse restores');
	}
	assert.equal(
		credits(
			source,
			builder.replace('local projected = {', '-- retained comment\n\t\tlocal projected = {')
		),
		true,
		'comments and formatting do not replace executable authority'
	);
	const declaredCustodyControls = [
		['local _dl_item = nil', 'do local rendered = {} return rendered end\nlocal _dl_item = nil'],
		['local _dl_item = nil', 'rendered = {}\nlocal _dl_item = nil'],
		['local _dl_item = nil', 'if true then rendered = {} end\nlocal _dl_item = nil'],
		[
			'local function separator_facade_current()',
			'local function foreign_separator_facade_current()'
		],
		[
			'local separator_render = type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")',
			'local separator_render = type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")\nseparator_facade_current = function() return true end'
		],
		['local receive, declared = separator_factory()', 'local receive, declared = ForeignFactory()'],
		[
			'local separator_render = type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")',
			'local separator_render = Foreign.render_rows'
		],
		['rawget(separator_modules, "infra.manifest_menu") == ManifestMenu', 'true'],
		['rawget(ManifestMenu, "top_level_separator_receiver") == separator_factory', 'true'],
		['local children = builders[id]() or {}', 'local children = {}'],
		[
			'local children = builders[id]() or {}',
			'local children = builders[id]() or {}\nchildren = {}'
		],
		[
			'if not separator_facade_current() or not receive("current") then return {} end',
			'if false then return {} end'
		],
		[
			'if not separator_facade_current() or type(_top_level_separator_receiver) ~= "function"',
			'if type(_top_level_separator_receiver) ~= "function"'
		],
		[
			'local rendered = separator_render(items, "top_level")',
			'local rendered = separator_render({}, "top_level")'
		]
	];
	for (const [before, after] of declaredCustodyControls) {
		assert.equal(
			builder.split(before).length - 1,
			1,
			'exact retained facade/result custody preimage'
		);
		assert.equal(
			credits(source, builder.replace(before, after)),
			false,
			'withdrawn actual declared source, facade or completed child refuses parent ownership'
		);
		assert.equal(
			credits(),
			true,
			'exact original declared custody inverse restores parent ownership'
		);
	}
	assert.equal(credits(), true, 'exact source repair restores the genuine live parent');
}

// A selected row never grants authority to additional, unconsumed group siblings.
{
	const assert = require('node:assert/strict');
	const source = fs.readFileSync(path.join(SP, 'windows/ui/menu/menu_hotstrings.ahk'), 'utf8');
	const key = 'hotstring_personal_default_parent',
		rows = manifest[key];
	const credits = (candidate, definition = rows) =>
		publishesSelectedMenuGroup(candidate, '.ahk', key, definition, PERSONAL_DEFAULT_GROUP_PROOF);
	assert.equal(
		credits(source),
		true,
		'the actual singleton parent call, captured child and frame binding are executable in their genuine owner'
	);
	for (const definition of [
		[],
		[rows[0], rows[0]],
		[{ ...rows[0], type: 'command' }],
		[{ ...rows[0], id: 'foreign_parent' }],
		[{ ...rows[0], i18n: 'future.unowned' }],
		[{ ...rows[0], caption_getter: 'foreign_getter' }]
	])
		assert.equal(
			credits(source, definition),
			false,
			'missing, malformed, foreign or multirow selected declarations earn no whole-section credit'
		);
	const actualCall =
		'DefaultCaption := MenuRenderer_GroupRow("hotstring_personal_default_parent", "personal_default_caption",\n\t\t\tDefaultSectionMenu, Map("personal_default_label", (*) => CurDefaultLabel))';
	assert(
		source.includes(actualCall),
		'the actual two-line native caption capture is present before mutation'
	);
	for (const candidate of [
		source.replace(actualCall, 'DefaultCaption := false'),
		source.replace(
			actualCall,
			"AuditText := '\n(\n" + actualCall + "\n)\n'\nDefaultCaption := false"
		),
		source.replace(actualCall, '/* ' + actualCall + ' */\nDefaultCaption := false'),
		source.replace(actualCall, 'DefaultCaption := false') +
			'\n_ForeignPersonalProjection() {\n' +
			actualCall +
			'\n}\n',
		source.replace('DefaultParent := [DefaultCaption]', 'DefaultParent := []'),
		source.replace(
			'"personal_default_parent", (*) => DefaultParent,',
			'"personal_default_parent", (*) => [],'
		),
		source.replace(
			'MenuRenderer_GroupRow("hotstring_personal_default_parent", "personal_default_caption"',
			'MenuRenderer_GroupRow("hotstring_personal_default_parent", "foreign_parent"'
		)
	])
		assert.equal(
			credits(candidate),
			false,
			'missing, data-only, foreign-owner or misbound native projections earn no credit'
		);
	assert.equal(
		credits(source),
		true,
		'exact original source repair restores the selected publication'
	);
	assert.equal(
		publishesTemplate(
			'MenuRenderer_GroupRow("hotstring_personal_default_parent", "personal_default_caption", Child, Getters)',
			'.ahk',
			key
		),
		false,
		'the original whole-template predicate does not silently credit selected projections'
	);
}

// An inert readout is admissible only through composition. A clicked parent,
// including one sharing the same target, still owes a usable child on that OS.
const readout = { type: 'label', id: 'readout', i18n: 'menu.metrics.status' };
const separator = { type: SEPARATOR };
const header = {
	type: 'section_header',
	id: 'readout_header',
	i18n: 'menu.metrics.status'
};
for (const rows of [
	[readout],
	[separator],
	[readout, separator],
	[header],
	[header, readout, separator]
]) {
	if (!isComposedFragment(rows, new Set(['compose'])))
		throw new Error('Rejected a declared composed readout.');
	for (const kinds of [new Set(), new Set(['submenu']), new Set(['compose', 'submenu'])]) {
		if (isComposedFragment(rows, kinds)) throw new Error('Accepted an empty clicked submenu.');
	}
}
for (const rows of [
	[],
	[{ ...readout, callback: 'invoke' }],
	[{ ...readout, id: '' }],
	[{ ...readout, i18n: '' }],
	[{ type: 'check', id: 'readout', i18n: 'menu.metrics.status' }],
	[{ ...separator, id: 'command' }],
	[{ ...header, children: [] }],
	[{ ...header, callback: 'invoke' }],
	[{ ...header, caption_getter: 'read' }],
	[{ ...header, id: '' }],
	[readout, { type: 'section_header', i18n: 'menu.metrics.status' }]
]) {
	if (isComposedFragment(rows, new Set(['compose'])))
		throw new Error('Accepted an undeclared composed readout shape.');
}
const platformKinds = {
	linux: new Set(['compose']),
	ahk: new Set(['submenu'])
};
if (
	!isComposedFragment([readout], platformKinds.linux) ||
	isComposedFragment([readout], platformKinds.ahk)
)
	throw new Error('Composition leaked across platform projections.');
for (const [extension, method, comment] of [
	['.lua', 'ManifestMenu.template_rows', '-- '],
	['.ahk', 'MenuRenderer_TemplateRows', '; ']
]) {
	const call = `${method}("declared_readout", options)`;
	if (!publishesTemplate(call, extension, 'declared_readout'))
		throw new Error(`Missed executable ${extension} template publication.`);
	for (const source of [
		comment + call,
		JSON.stringify(call),
		call.replace('declared_readout', 'another_readout'),
		call.replace(method, 'Unowned.template_rows'),
		'Foreign.' + call,
		'Foreign:' + call,
		call.replace('"declared_readout"', '"declared_readout" .. suffix'),
		`function ${call}`
	]) {
		if (publishesTemplate(source, extension, 'declared_readout'))
			throw new Error(`Credited non-publication ${extension} template evidence.`);
	}
}

/** Command-only fragments may be published through a genuine typed include closure. */
function publishesIncludedCommands(source, extension, section, declarations, platform) {
	const { nativeTemplateBinding } = require('../lib/menu-template-binding.cjs');
	const rows = declarations[section];
	if (!Array.isArray(rows) || rows.length === 0) return false;
	const visible = rows.filter((row) => !row.platforms || row.platforms.includes(platform));
	return (
		visible.length > 0 &&
		visible.every(
			(row) =>
				row.type === 'command' &&
				typeof row.id === 'string' &&
				row.id !== '' &&
				nativeTemplateBinding(
					source,
					extension,
					section,
					row.id,
					1,
					[{ src: source }],
					declarations,
					platform
				)
		)
	);
}

// Linux excluded-app frames owe typed genuine command, caption and child providers.
{
	const assert = require('node:assert/strict');
	const { nativeTemplateBinding } = require('../lib/menu-template-binding.cjs');
	const file = 'linux/ui/menu/agent_rows.lua';
	const native = fs.readFileSync(path.join(SP, file), 'utf8');
	const owners = [
		['agent_linux_disabled_app_remove', 'agent_disabled_app_remove', 1],
		['agent_linux_disabled_app_remove', 'agent_disabled_app_caption', 2],
		['agent_linux_disabled_apps_children', 'agent_disabled_app_records', 3],
		['agent_linux_disabled_app_current', 'agent_disabled_app_current', 1],
		['agent_linux_disabled_app_current', 'agent_disabled_app_current_caption', 2],
		['agent_linux_disabled_app_add', 'agent_disabled_app_add', 1],
		['agent_linux_disabled_apps_frame', 'agent_disabled_apps', 3],
		['agent_linux_disabled_apps_frame', 'agent_disabled_apps_count', 2]
	];
	for (const [section, key, port] of owners) {
		const credits = (source, declarations = manifest, inputPort = port) =>
			nativeTemplateBinding(
				source,
				'.lua',
				section,
				key,
				inputPort,
				[{ src: source }],
				declarations,
				'linux'
			);
		assert.equal(credits(native), true, `${section}/${key}: actual native typed owner`);
		assert.equal(
			credits(native.replaceAll(key, 'withdrawn_' + key)),
			false,
			'withdrawn actual owner earns no credit'
		);
		assert.equal(
			credits(native.replaceAll('ManifestMenu.template_rows', 'Foreign.template_rows')),
			false,
			'foreign receiver cannot publish the canonical frames'
		);
		assert.equal(credits(JSON.stringify(native)), false, 'quoted source is inert');
		assert.equal(
			credits(native, manifest, port === 1 ? 3 : 1),
			false,
			'typed ports cannot exchange their roles'
		);
		const withdrawn = { ...manifest };
		delete withdrawn[section];
		assert.equal(credits(native, withdrawn), false, 'a missing target invalidates publication');
		assert.equal(
			credits(native),
			true,
			'exact physical owner restoration recovers the same binding'
		);
	}
	for (const section of ['agent_linux_disabled_app_current', 'agent_linux_disabled_app_add']) {
		for (const mutation of ['missing', 'redirected', 'cycle', 'wrong_type']) {
			const changed = structuredClone(manifest);
			if (mutation === 'missing') delete changed[section];
			if (mutation === 'redirected')
				changed.agent_linux_disabled_apps_children = changed.agent_linux_disabled_apps_children.map(
					(row) => (row.section === section ? { ...row, section: 'unowned_app_frame' } : row)
				);
			if (mutation === 'cycle')
				changed[section].push({
					type: 'include',
					section: 'agent_linux_disabled_apps_children'
				});
			if (mutation === 'wrong_type') changed[section][0].type = 'list';
			assert.equal(
				publishesIncludedCommands(native, '.lua', section, changed, 'linux'),
				false,
				'a broken required include cannot acquire typed command credit'
			);
		}
	}
}

// Exact native getter/command/list ports remain necessary evidence, never backend authority.
{
	const assert = require('node:assert/strict');
	const { nativeTemplateBinding } = require('../lib/menu-template-binding.cjs');
	const linux = 'linux/ui/menu/agent_rows.lua';
	const owners = [
		[linux, 'linux', '.lua', 'agent_linux_system_backend_record', 'agent_system_backend', 1],
		[linux, 'linux', '.lua', 'agent_linux_system_backend_record', 'agent_system_backend_label', 2],
		[
			linux,
			'linux',
			'.lua',
			'agent_linux_system_backend_record',
			'agent_system_backend_selected',
			2
		],
		[linux, 'linux', '.lua', 'agent_linux_system_children', 'agent_system_off_rows', 3],
		[linux, 'linux', '.lua', 'agent_linux_system_children', 'agent_system_backend_rows', 3],
		[linux, 'linux', '.lua', 'agent_linux_system_children', 'agent_system_model_rows', 3],
		[linux, 'linux', '.lua', 'agent_linux_system1_frame', 'agent_system1', 3],
		[linux, 'linux', '.lua', 'agent_linux_system2_frame', 'agent_system2', 3],
		[
			linux,
			'linux',
			'.lua',
			'agent_linux_system1_frame',
			'agent_system_backend_current_caption',
			2
		],
		[
			linux,
			'linux',
			'.lua',
			'agent_linux_system2_frame',
			'agent_system_backend_current_caption',
			2
		],
		[linux, 'linux', '.lua', 'agent_system_model_controls', 'agent_system_model_caption', 2],
		[
			'windows/ui/menu/menu_llm/menu_agent.ahk',
			'ahk',
			'.ahk',
			'agent_system_model_controls',
			'agent_system_model_caption',
			2
		],
		...[
			'agent_system_model_controls',
			'agent_system_model_installed_controls',
			'agent_system_model_missing_controls'
		].map((section) => [
			'macos/ui/menu/menu_llm/agent_panel.lua',
			'hs',
			'.lua',
			section,
			'agent_system_model_caption',
			2
		])
	];
	for (const [file, platform, extension, section, key, port] of owners) {
		const source = fs.readFileSync(path.join(SP, file), 'utf8');
		const credit = (native, declarations = manifest, role = port) =>
			nativeTemplateBinding(
				native,
				extension,
				section,
				key,
				role,
				[{ src: native }],
				declarations,
				platform
			);
		assert.equal(credit(source), true, `${file}/${section}/${key}: actual native owner`);
		assert.equal(
			credit(source.replaceAll(key, 'withdrawn_' + key)),
			false,
			'withdrawn port earns no authority'
		);
		assert.equal(credit(JSON.stringify(source)), false, 'quoted source is inert');
		assert.equal(
			credit(source, manifest, port === 1 ? 3 : 1),
			false,
			'command/getter/list roles cannot exchange'
		);
		const missing = { ...manifest };
		delete missing[section];
		assert.equal(credit(source, missing), false, 'a missing declared target refuses publication');
		const foreign = source
			.replaceAll('ManifestMenu.template_rows', 'Foreign.template_rows')
			.replaceAll('MenuRenderer_TemplateRows', 'Foreign_TemplateRows')
			.replaceAll('require("infra.manifest_menu").template_rows', 'Foreign.template_rows');
		assert.equal(
			credit(foreign),
			false,
			'foreign native receiver cannot publish the canonical frame'
		);
		assert.equal(credit(source), true, 'exact physical restoration repairs the same owner');
	}
}

// Actual system-status routes owe native typed callback/provider owners. This is
// static necessary evidence, not certification of registry/desktop availability.
{
	const assert = require('node:assert/strict');
	const { nativeTemplateBinding } = require('../lib/menu-template-binding.cjs');
	assert.deepEqual(
		OPENS_SUBMENU.system_gesture_status[0],
		{
			menu: 'gesture_system_status_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/gesture_conflicts.ahk',
				hs: 'macos/ui/menu/menu_gestures.lua'
			}
		},
		'the original independently published controls edge is retained'
	);
	const owners = [
		{
			file: 'windows/ui/gesture_conflicts.ahk',
			platform: 'ahk',
			section: 'gesture_system_status_unknown',
			key: 'gesture_system_unknown_children',
			port: 3
		},
		{
			file: 'windows/ui/gesture_conflicts.ahk',
			platform: 'ahk',
			section: 'gesture_system_status_clear',
			key: 'gesture_system_clear_children',
			port: 3
		},
		{
			file: 'windows/ui/gesture_conflicts.ahk',
			platform: 'ahk',
			section: 'gesture_system_status_conflicts',
			key: 'gesture_system_conflict_children',
			port: 3
		},
		{
			file: 'windows/ui/gesture_conflicts.ahk',
			platform: 'ahk',
			section: 'gesture_system_windows_children',
			key: 'gesture_system_cached_slots',
			port: 3
		},
		{
			file: 'windows/ui/gesture_conflicts.ahk',
			platform: 'ahk',
			section: 'gesture_system_status_controls',
			key: 'gesture_system_refresh',
			port: 1
		},
		{
			file: 'windows/ui/gesture_conflicts.ahk',
			platform: 'ahk',
			section: 'gesture_system_slot_unknown',
			key: 'gesture_system_open_unknown_slot',
			port: 1
		},
		{
			file: 'windows/ui/gesture_conflicts.ahk',
			platform: 'ahk',
			section: 'gesture_system_slot_configured',
			key: 'gesture_system_open_configured_slot',
			port: 1
		},
		{
			file: 'windows/ui/gesture_conflicts.ahk',
			platform: 'ahk',
			section: 'gesture_system_slot_not_configured',
			key: 'gesture_system_open_not_configured_slot',
			port: 1
		},
		{
			file: 'macos/ui/menu/menu_gestures.lua',
			platform: 'hs',
			section: 'gesture_system_status_clear',
			key: 'gesture_system_clear_children',
			port: 3
		},
		{
			file: 'macos/ui/menu/menu_gestures.lua',
			platform: 'hs',
			section: 'gesture_system_status_conflicts',
			key: 'gesture_system_conflict_children',
			port: 3
		},
		{
			file: 'macos/ui/menu/menu_gestures.lua',
			platform: 'hs',
			section: 'gesture_system_macos_children',
			key: 'gesture_system_cached_conflicts',
			port: 3
		},
		{
			file: 'macos/ui/menu/menu_gestures.lua',
			platform: 'hs',
			section: 'gesture_system_status_controls',
			key: 'gesture_system_refresh',
			port: 1
		},
		{
			file: 'macos/ui/menu/menu_gestures.lua',
			platform: 'hs',
			section: 'gesture_system_pinch_enabled',
			key: 'gesture_system_open_enabled_pinch',
			port: 1
		},
		{
			file: 'macos/ui/menu/menu_gestures.lua',
			platform: 'hs',
			section: 'gesture_system_pinch_disabled',
			key: 'gesture_system_open_disabled_pinch',
			port: 1
		},
		{
			file: 'macos/ui/menu/menu_gestures.lua',
			platform: 'hs',
			section: 'gesture_system_pinch_unknown',
			key: 'gesture_system_open_unknown_pinch',
			port: 1
		},
		{
			file: 'linux/ui/gesture_conflicts.lua',
			platform: 'linux',
			section: 'gesture_system_status_unknown',
			key: 'gesture_system_unknown_children',
			port: 3
		},
		{
			file: 'linux/ui/gesture_conflicts.lua',
			platform: 'linux',
			section: 'gesture_system_linux_children',
			key: 'gesture_system_cached_overlap',
			port: 3
		},
		{
			file: 'linux/ui/gesture_conflicts.lua',
			platform: 'linux',
			section: 'gesture_system_slot_unknown',
			key: 'gesture_system_open_unknown_slot',
			port: 1
		}
	];
	for (const owner of owners) {
		const native = fs.readFileSync(path.join(SP, owner.file), 'utf8');
		const extension = path.extname(owner.file);
		const credits = (candidate, declarations = manifest, port = owner.port) =>
			nativeTemplateBinding(
				candidate,
				extension,
				owner.section,
				owner.key,
				port,
				[{ src: candidate }],
				declarations,
				owner.platform
			);
		assert.equal(
			credits(native),
			true,
			`${owner.file}/${owner.section}/${owner.key}: actual native typed owner`
		);
		const needle = '"' + owner.key + '"';
		assert.equal(
			native.split(needle).length - 1,
			1,
			'the independently reviewed native binding is unique'
		);
		assert.equal(
			credits(native.replace(needle, '"withdrawn_' + owner.key + '"')),
			false,
			'a withdrawn actual callback/provider earns no typed owner credit'
		);
		assert.equal(
			credits(
				native.replaceAll(
					extension === '.ahk' ? 'MenuRenderer_TemplateRows' : 'ManifestMenu.template_rows',
					extension === '.ahk' ? 'Foreign_TemplateRows' : 'Foreign.template_rows'
				)
			),
			false,
			'a foreign native receiver cannot publish the shared declarations'
		);
		assert.equal(
			credits(JSON.stringify(native)),
			false,
			'quoted native source is data, not a producer'
		);
		assert.equal(
			credits(native, manifest, owner.port === 1 ? 3 : 1),
			false,
			'command callbacks and cached child providers cannot exchange typed ports'
		);
		const withdrawn = { ...manifest };
		delete withdrawn[owner.section];
		assert.equal(
			credits(native, withdrawn),
			false,
			'a removed required target invalidates the real include closure'
		);
		assert.equal(credits(native), true, 'exact owner restoration recovers the typed binding');
	}
}

// Preserve the original refresh edge through its actual typed included publisher.
{
	const assert = require('node:assert/strict');
	for (const [platform, file, child] of [
		['ahk', 'windows/ui/gesture_conflicts.ahk', 'gesture_system_windows_children'],
		['hs', 'macos/ui/menu/menu_gestures.lua', 'gesture_system_macos_children']
	]) {
		const native = fs.readFileSync(path.join(SP, file), 'utf8');
		const extension = path.extname(file);
		const credits = (candidate, declarations = manifest) =>
			publishesIncludedCommands(
				candidate,
				extension,
				'gesture_system_status_controls',
				declarations,
				platform
			);
		assert.equal(credits(native), true, 'the original controls edge has a genuine typed publisher');
		assert.equal(
			credits(native.replaceAll('"gesture_system_refresh"', '"withdrawn_refresh"')),
			false
		);
		assert.equal(credits(native.replaceAll('"' + child + '"', '"withdrawn_children"')), false);
		assert.equal(credits(JSON.stringify(native)), false);
		for (const mutation of ['missing', 'redirected', 'cycle', 'wrong_type', 'empty']) {
			const changed = structuredClone(manifest);
			if (mutation === 'missing') delete changed.gesture_system_status_controls;
			if (mutation === 'redirected')
				changed[child] = changed[child].map((row) =>
					row.section === 'gesture_system_status_controls'
						? { ...row, section: 'withdrawn_controls' }
						: row
				);
			if (mutation === 'cycle') changed[child].push({ type: 'include', section: child });
			if (mutation === 'wrong_type') changed.gesture_system_status_controls[0].type = 'list';
			if (mutation === 'empty') changed.gesture_system_status_controls = [];
			assert.equal(
				credits(native, changed),
				false,
				mutation + ' ownership earns no included command credit'
			);
		}
	}
}

// A root presentation is reached by its real native producer, never a synthetic clicked row.
{
	const assert = require('node:assert/strict');
	const { nativeBadgeRootComposition } = require('../lib/menu-native-root-binding.cjs');
	const controls = require('./fixtures/badge-root-completed-counterexamples.cjs');
	const target = 'macos_canvas_badge_frame';
	const sourceFiles = [
		'macos/ui/menu/init.lua',
		'macos/ui/menu/builder.lua',
		'macos/ui/menu/canvas_badge.lua',
		'macos/ui/menu/menu_llm/init.lua'
	];
	const sources = Object.fromEntries(
		sourceFiles.map((file) => [file, fs.readFileSync(path.join(SP, file), 'utf8')])
	);
	const admits = (candidate, declarations = manifest, platform = 'hs') =>
		nativeBadgeRootComposition(candidate, declarations, platform);
	// The previous physical source/control corpus is frozen independently, never rebuilt from LIVE.
	const {
		nativeBadgeRootComposition: predecessorAdmits
	} = require('../lib/menu-native-root-binding-predecessor.cjs');
	const predecessorControls = require('./fixtures/badge-root-counterexamples.cjs');
	const predecessorPath = path.join(__dirname, 'fixtures/badge-root-predecessor');
	const predecessorSources = Object.fromEntries(
		sourceFiles
			.slice(0, 3)
			.map((file) => [
				file,
				fs.readFileSync(path.join(predecessorPath, file.replaceAll('/', '_') + '.txt'), 'utf8')
			])
	);
	const predecessorManifest = JSON.parse(
		fs.readFileSync(path.join(predecessorPath, 'menu_manifest.json'), 'utf8')
	);
	assert.equal(
		predecessorControls.length,
		60,
		'all historical independent controls remain registered'
	);
	assert.equal(
		predecessorAdmits(predecessorSources, predecessorManifest, 'hs'),
		true,
		'the genuine historical physical route was admitted'
	);
	for (const control of predecessorControls) {
		const source = predecessorSources[control.path];
		assert.equal(
			source.split(control.before).length - 1,
			1,
			control.reason + ': immutable historical physical preimage'
		);
		const changed = source.replace(control.before, control.after);
		assert.notEqual(changed, source, control.reason + ': historical source actually changes');
		assert.equal(
			predecessorAdmits(
				{ ...predecessorSources, [control.path]: changed },
				predecessorManifest,
				'hs'
			),
			false,
			control.reason
		);
	}
	assert.equal(
		controls.length,
		78,
		'all original 74 completed-root obligations and four current projection controls execute'
	);
	assert.equal(
		admits(sources),
		true,
		'the actual LIVE completed root must be admitted before negative controls'
	);
	// The live badge root uses the same exact owner projection policy as the IA parent.
	const builder = sources['macos/ui/menu/builder.lua'];
	const withBuilder = (candidate) => admits({ ...sources, 'macos/ui/menu/builder.lua': candidate });
	const projection = `		local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry }
		if entry.disabled == true then
			projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, entry.reason_key
		end
		table.insert(result, projected)`;
	const historicalProjection = `		table.insert(result, { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry })`;
	assert.equal(
		builder.split(projection).length - 1,
		1,
		'badge root: exact current projected-row preimage'
	);
	assert.equal(
		withBuilder(builder.replace(projection, historicalProjection)),
		true,
		'badge root: the historical executable top-level projection remains supported'
	);
	const projectionControls = [
		[
			projection,
			projection.replace('id = entry.id', 'id = "foreign"'),
			'foreign projected identity'
		],
		[
			projection,
			projection.replace('entry.greyed_when_paused == true', 'false'),
			'lost pause metadata'
		],
		[
			projection,
			projection.replace('if entry.disabled == true then', 'if false then'),
			'dead disabled forwarding'
		],
		[
			projection,
			projection.replace(
				'true, entry.i18n, entry.reason_key',
				'false, entry.i18n, entry.reason_key'
			),
			'lost disabled flag'
		],
		[
			projection,
			projection.replace('true, entry.i18n, entry.reason_key', 'true, "foreign", entry.reason_key'),
			'foreign disabled label'
		],
		[
			projection,
			projection.replace('true, entry.i18n, entry.reason_key', 'true, entry.i18n, "foreign"'),
			'foreign disabled reason'
		],
		['table.insert(result, projected)', 'table.insert(result, {})', 'discarded projected object'],
		[
			'table.insert(result, projected)',
			'projected = {}\n\t\ttable.insert(result, projected)',
			'rebound projected object'
		],
		[
			'table.insert(result, projected)',
			'do local projected = {}\n\t\ttable.insert(result, projected) end',
			'shadowed projected object'
		],
		[projection, 'if false then\n' + projection + '\nend', 'unreachable projection'],
		[
			'table.insert(result, projected)',
			'table.insert({}, projected)',
			'foreign append destination'
		],
		['\n\treturn _top_level_cache\nend', '\n\treturn {}\nend', 'discarded completed projection']
	];
	assert.equal(
		projectionControls.length,
		12,
		'all 12 badge root projected transport refusals remain registered'
	);
	for (const [before, after, reason] of projectionControls) {
		assert.equal(builder.split(before).length - 1, 1, reason + ': exact source preimage');
		const candidate = builder.replace(before, after);
		assert.notEqual(candidate, builder, reason + ': actual source changes');
		assert.equal(withBuilder(candidate), false, reason);
		assert.equal(withBuilder(builder), true, reason + ': genuine source inverse restores');
	}
	// Original independent obligations and expected refusals remain immutable. Only the
	// current executable coordinates follow the already reviewed retained native route.
	const forwardBadgeSourceControl = (control) => {
		if (
			control.path === 'macos/ui/menu/menu_llm/init.lua' &&
			control.reason === 'actual finished native download callback disconnected'
		) {
			return { ...control, before: 'return item', after: 'item.fn = function() end\nreturn item' };
		}
		if (control.path !== 'macos/ui/menu/builder.lua') return control;
		const forward = (text) =>
			text
				.replaceAll('local data = load_manifest()', 'local receive, declared = separator_factory()')
				.replaceAll('data = { top_level = {} }', 'declared = {}')
				.replaceAll('data, ignored = { top_level = {} }, nil', 'declared, ignored = {}, nil')
				.replaceAll('ipairs(data.top_level)', 'ipairs(declared)')
				.replaceAll('ipairs(data.unrelated_root)', 'ipairs({})')
				.replaceAll(
					'_top_level_cache = result',
					'_top_level_cache, _top_level_separator_receiver = result, receive'
				)
				.replaceAll('ManifestMenu.render_rows', 'separator_render')
				.replaceAll(
					'greyed_when_paused = entry.greyed_when_paused == true }',
					'greyed_when_paused = entry.greyed_when_paused == true, declared_entry = entry }'
				);
		return { ...control, before: forward(control.before), after: forward(control.after) };
	};
	for (const control of controls.map(forwardBadgeSourceControl)) {
		const source = sources[control.path];
		assert.equal(
			source.split(control.before).length - 1,
			1,
			control.reason + ': exact physical counterexample preimage'
		);
		const changed = source.replace(control.before, control.after);
		assert.notEqual(changed, source, control.reason + ': source was actually changed');
		assert.equal(admits({ ...sources, [control.path]: changed }), false, control.reason);
	}
	const declaredRootControls = [
		[
			'rawget(ManifestMenu, "top_level_separator_receiver")',
			'rawget(ManifestMenu, "foreign_receiver")',
			'declared root owner withdrawn'
		],
		[
			'rawget(separator_modules, "infra.manifest_menu") == ManifestMenu',
			'true',
			'declared root module custody withdrawn'
		],
		[
			'local receive, declared = separator_factory()',
			'local receive, declared = separator_factory()\n declared = {}',
			'actual declared source replaced'
		],
		[
			'local children = builders[id]() or {}',
			'local children = {}',
			'actual declared native children discarded'
		],
		[
			'local _dl_item = nil',
			'do local rendered = {} return rendered end\n local _dl_item = nil',
			'scoped foreign native root returned after admission'
		]
	];
	for (const [before, after, reason] of declaredRootControls) {
		// Both raw facade capture and equality intentionally read the same member.
		assert.equal(
			builder.split(before).length - 1,
			reason === 'declared root owner withdrawn' ? 2 : 1,
			reason + ': genuine source coordinates'
		);
		const candidate = builder.replaceAll(before, after);
		assert.notEqual(candidate, builder, reason + ': source actually changes');
		assert.equal(withBuilder(candidate), false, reason);
		assert.equal(withBuilder(builder), true, reason + ': genuine inverse');
	}
	for (const file of sourceFiles) {
		assert.equal(admits({ ...sources, [file]: '' }), false, 'missing physical route owner');
		assert.equal(
			admits({ ...sources, [file]: JSON.stringify(sources[file]) }),
			false,
			'quoted physical source supplies no route'
		);
		assert.equal(
			admits({ ...sources, [file]: '--[=[\n' + sources[file] + '\n]=]' }),
			false,
			'comment-only physical source supplies no route'
		);
	}
	for (const platform of ['ahk', 'linux', 'HS', '', undefined]) {
		assert.equal(
			nativeBadgeRootComposition(sources, manifest, platform),
			false,
			'root edge only exists on its actual native platform'
		);
	}
	for (const section of [
		target,
		'macos_canvas_badge_paused',
		'macos_canvas_badge_active',
		'macos_canvas_badge_root',
		'macos_download_root',
		'llm_download_shortcut_frame',
		'top_level'
	]) {
		const withdrawn = { ...manifest };
		delete withdrawn[section];
		assert.equal(admits(sources, withdrawn), false, 'missing actual canonical root or descendant');
	}
	const wrongOs = {
		...manifest,
		macos_canvas_badge_active: manifest.macos_canvas_badge_active.map((row) => ({
			...row,
			platforms: ['linux']
		}))
	};
	assert.equal(
		admits(sources, wrongOs),
		false,
		'wrong-platform caption cannot supply the native root'
	);
	const quotedDecoy = {
		...sources,
		'macos/ui/menu/builder.lua':
			sources['macos/ui/menu/builder.lua'] +
			'\n-- pcall(CanvasBadge.prepend_to, rendered, ctx, function())\nlocal inert_badge_quote = "pcall(CanvasBadge.prepend_to, rendered, ctx, function())"\n'
	};
	const admitted = admits(sources);
	assert.equal(
		admits(quotedDecoy),
		admitted,
		'inert quoted/comment decoys neither create nor withdraw an actual route'
	);
	if (admitted) {
		for (const completedTarget of [target, 'macos_canvas_badge_root', 'macos_download_root']) {
			reachableOn[completedTarget] = combineMenuVisibility(
				PLATFORMS,
				reachableOn[completedTarget],
				['hs']
			);
			openedBy[completedTarget] =
				'top_level/native Builder.generate → native_composition → CanvasBadge.prepend_to';
			reachedByKinds[completedTarget] = { hs: new Set(['compose']) };
		}
	} else {
		errors.push(
			'top_level/native badge: physical root composition refused; declaration remains unreachable'
		);
	}
}

// Additive source-only fragment for existing test-menu-parity.cjs and
// test-menu-category-coverage.cjs; UNRUN. Original controls remain unchanged.
// Loader belongs in tools/lib/menu-native-startup-binding.cjs, exported there.
// It reads actual installed sources/artifact; no generated expected artifact.
{
	const assert = require('node:assert/strict');
	const { nativeStartupRows, startupInputs } = require('../lib/menu-native-startup-binding.cjs');
	const startup = startupInputs(ROOT, manifest);
	const expected = [
		manifest.tray_startup_suspend[0],
		manifest.top_level.find((row) => row.id === 'reload' && row.platforms?.includes('ahk')),
		manifest.top_level.find((row) => row.id === 'quit' && row.platforms?.includes('ahk')),
		manifest.tray_startup_inert_frame[0]
	];
	assert(expected.every(Boolean), 'actual startup declaration identities exist');
	const admitted = () => nativeStartupRows(startup, 'ahk');
	assert.deepEqual(
		[...admitted()],
		expected,
		'actual canonical generator/include/callee/typed result/native publication route'
	);
	assert.equal(nativeStartupRows(startup, 'hs').size, 0, 'Windows startup is not a macOS route');
	assert.equal(nativeStartupRows(startup, 'linux').size, 0, 'Windows startup is not a Linux route');
	function mutateSource(key, before, after) {
		assert.equal(
			startup.sources[key].split(before).length - 1,
			1,
			'owned negative control has exactly one genuine source preimage'
		);
		return {
			...startup,
			sources: { ...startup.sources, [key]: startup.sources[key].replace(before, after) }
		};
	}
	const helper = 'windows/infra/tray_bootstrap.ahk';
	const entry = 'windows/ErgoptiPlus.ahk';
	const dispatcher = 'windows/infra/menu_dispatcher.ahk';
	const controls = [
		[
			'withdraw native include',
			mutateSource(
				helper,
				'#Include ../../_shared/modules/menu/startup_tray_projection.ahk',
				'; #Include ../../_shared/modules/menu/startup_tray_projection.ahk'
			)
		],
		[
			'quoted include decoy',
			mutateSource(
				helper,
				'#Include ../../_shared/modules/menu/startup_tray_projection.ahk',
				'QuotedInclude := "#Include ../../_shared/modules/menu/startup_tray_projection.ahk"'
			)
		],
		[
			'dead cold default call',
			mutateSource(entry, '_InstallSafeBootstrapTray()', 'if false\n\t_InstallSafeBootstrapTray()')
		],
		[
			'replace genuine callee',
			mutateSource(
				helper,
				'Authority := SharedStartupTrayProjection(_I18nLocale)',
				'Authority := OtherStartupProjection(_I18nLocale)'
			)
		],
		['discard typed result', mutateSource(helper, 'return Prepared', 'return []')],
		['AHK return line split', mutateSource(helper, 'return Prepared', 'return\nPrepared')],
		[
			'substitute callback ownership',
			mutateSource(helper, 'Callback: Commands[CommandId]', 'Callback: Commands["quit"]')
		],
		[
			'substitute native row transport',
			mutateSource(
				helper,
				'Register.Call(MenuObj, Row.Label, Row.Callback)',
				'Register.Call(MenuObj, Row.Label, _TrayBootstrapNoOp)'
			)
		],
		[
			'lose disabled inert publication',
			mutateSource(helper, 'MenuObj.Disable(Label)', '; MenuObj.Disable(Label)')
		],
		[
			'different native menu receiver',
			mutateSource(
				dispatcher,
				'MenuObj.Add(ItemName, Wrapper)',
				'A_TrayMenu.Add(ItemName, Wrapper)'
			)
		],
		[
			'shadow shared projection',
			{
				...startup,
				sources: {
					...startup.sources,
					[entry]: startup.sources[entry] + '\nSharedStartupTrayProjection := (*) => Map()\n'
				}
			}
		],
		[
			'duplicate producer definition',
			{
				...startup,
				sources: {
					...startup.sources,
					[helper]:
						startup.sources[helper] +
						'\n_TrayBootstrapProjectedRows(Surface, Commands) { return [] }\n'
				}
			}
		],
		[
			'invent readiness',
			mutateSource(helper, 'return Prepared', '_DriverReady := true\n\treturn Prepared')
		],
		['missing generated owner', { ...startup, generated: '' }],
		[
			'changed generated native DATA',
			{ ...startup, generated: startup.generated + '\nExtraStartupAuthority := true\n' }
		]
	];
	const generatorControls = [
		[
			'withdraw actual import',
			"import startupProjection from '../lib/codegen-startup-tray.cjs';",
			"// import startupProjection from '../lib/codegen-startup-tray.cjs';"
		],
		[
			'dead generator statement',
			'const startupAhk = startupProjection.render(parsed.menu, startupPolicy, startupLocales);',
			'if (false) { const startupAhk = startupProjection.render(parsed.menu, startupPolicy, startupLocales); }'
		],
		[
			'foreign source policy',
			"shared('modules/menu/startup_tray.toml')",
			"shared('modules/menu/foreign.toml')"
		],
		[
			'foreign output owner',
			"shared('modules/menu/startup_tray_projection.ahk')",
			"shared('modules/menu/foreign.ahk')"
		],
		[
			'fake produced result',
			'startupProjection.render(parsed.menu, startupPolicy, startupLocales)',
			"'fake projection'"
		],
		[
			'quoted callee decoy',
			'const startupAhk = startupProjection.render(parsed.menu, startupPolicy, startupLocales);',
			'const startupAhk = "startupProjection.render(parsed.menu, startupPolicy, startupLocales)";'
		]
	];
	for (const [name, before, after] of generatorControls) {
		assert.equal(
			startup.generator.split(before).length - 1,
			1,
			name + ' genuine generator preimage'
		);
		controls.push([name, { ...startup, generator: startup.generator.replace(before, after) }]);
	}
	const capabilities = require('../lib/codegen-startup-tray.cjs');
	assert.doesNotThrow(() =>
		capabilities.validateCommandCapabilities(
			capabilities.resolveRows(startup.manifest, startup.policy.commands, 'command')
		)
	);
	for (const command of ['foreign', 'suspend']) {
		const changedCommands = structuredClone(startup.manifest);
		const reload = changedCommands.top_level.find(
			(row) => row.id === 'reload' && row.platforms?.includes('ahk')
		);
		assert(reload, 'genuine Windows canonical Reload owner exists');
		reload.command = command;
		assert.throws(
			() =>
				capabilities.validateCommandCapabilities(
					capabilities.resolveRows(changedCommands, startup.policy.commands, 'command')
				),
			'the actual resolved canonical capability data must refuse before generated drift'
		);
		controls.push([
			'actual resolved capability ' + command + ' must refuse',
			{ ...startup, manifest: changedCommands }
		]);
	}
	const withdrawn = structuredClone(startup.manifest);
	withdrawn.tray_startup_inert_frame = [];
	controls.push(['canonical source withdrawn', { ...startup, manifest: withdrawn }]);
	const reordered = structuredClone(startup.policy);
	reordered.commands.rows.reverse();
	controls.push(['foreign startup source order', { ...startup, policy: reordered }]);
	for (const [name, candidate] of controls)
		assert.equal(nativeStartupRows(candidate, 'ahk').size, 0, name + ' must refuse ownership');
	const decoys = {
		...startup,
		sources: {
			...startup.sources,
			[helper]: startup.sources[helper] + '\n; return []\nDecoy := "return []"\n'
		},
		generator: startup.generator + '\n// startupAhk = fake;\n'
	};
	assert.deepEqual(
		[...nativeStartupRows(decoys, 'ahk')],
		expected,
		'unrelated quoted/comment decoys do not create or withdraw genuine route ownership'
	);
	assert.deepEqual(
		[...admitted()],
		expected,
		'source controls never mutate the actual source owner'
	);
}

// Actual cold executable entrypoints compose this separate recovery root.
// This is not a clicked submenu or an invented OPENS_SUBMENU parent identity.
{
	const proof = require('../lib/menu-native-startup-binding.cjs');
	const startup = proof.startupInputs(ROOT, manifest);
	const owned = proof.nativeStartupRows(startup, 'ahk');
	for (const section of ['tray_startup_suspend', 'tray_startup_inert_frame']) {
		const rows = manifest[section];
		if (!Array.isArray(rows) || rows.length === 0 || !rows.every((row) => owned.has(row))) {
			errors.push(`cold Windows startup: physical ownership refused for ${section}`);
			continue;
		}
		reachableOn[section] = combineMenuVisibility(PLATFORMS, reachableOn[section], ['ahk']);
		openedBy[section] = 'actual ErgoptiPlus.ahk cold/recovery root entrypoint';
		reachedByKinds[section] = { ahk: new Set(['compose']) };
	}
}

// Actual Linux parents require their reviewed algorithm AND native producer/caller.
const linuxAiSources = Object.fromEntries(
	[
		'linux/ui/menu/ai_parent.lua',
		'linux/ui/menu/agent_rows.lua',
		'linux/ui/menu/menu_builder.lua'
	].map((file) => [file, fs.readFileSync(path.join(SP, file), 'utf8')])
);
const { nativeLinuxAiParentPublication } = require('../lib/menu-native-llm-parent-binding.cjs');
{
	const assert = require('node:assert/strict');
	for (const kind of ['llm', 'agent']) {
		const parentFrame = kind === 'llm' ? 'llm_native_parent_linux' : 'agent_native_parent';
		const admits = (sources = linuxAiSources, root = manifest, platform = 'linux') =>
			nativeLinuxAiParentPublication(sources, root, kind, platform);
		assert.equal(
			admits(),
			true,
			'actual Linux completed ' + kind + ' producer reaches the genuine tray'
		);

		// The adopted unavailable top row is an inert declaration projection, before Quit.
		const builderFile = 'linux/ui/menu/menu_builder.lua';
		const builder = linuxAiSources[builderFile];
		const disabledBranch = `				elseif row.disabled == true then
					rows[#rows + 1] = { label = i18n_safe(row.i18n), disabled = true,
						disabled_reason_key = row.reason_key }
`;
		assert.equal(
			builder.split(disabledBranch).length - 1,
			1,
			'exact adopted disabled top-row branch'
		);
		const withBuilder = (source) => admits({ ...linuxAiSources, [builderFile]: source });
		assert.equal(
			withBuilder(builder.replace(disabledBranch, '')),
			true,
			'historical native top-row route remains supported'
		);
		const disabledControls = [
			[
				disabledBranch,
				disabledBranch.replace('disabled = true', 'disabled = false'),
				'lost disabled flag'
			],
			[
				disabledBranch,
				disabledBranch.replace('i18n_safe(row.i18n)', '"foreign"'),
				'foreign caption'
			],
			[disabledBranch, disabledBranch.replace('row.reason_key', '"foreign"'), 'foreign reason'],
			[
				disabledBranch,
				disabledBranch.replaceAll('row.', 'foreign_row.'),
				'foreign declaration row'
			],
			[
				disabledBranch,
				disabledBranch.replace('rows[#rows + 1]', 'row = {}\n					rows[#rows + 1]'),
				'rebound declaration row'
			],
			[
				disabledBranch,
				disabledBranch.replace('row.disabled == true', 'false and row.disabled == true'),
				'dead disabled branch'
			],
			[
				disabledBranch + '				elseif id == "quit" then\n					quit_row = build(ctx)\n',
				'				elseif id == "quit" then\n					quit_row = build(ctx)\n' + disabledBranch,
				'reordered native branch'
			],
			[disabledBranch, disabledBranch + disabledBranch, 'multiple disabled appends'],
			[
				disabledBranch,
				disabledBranch.replace('i18n_safe(row.i18n)', 'i18n_safe(row.reason_key)'),
				'wrong caption input'
			],
			[
				disabledBranch,
				disabledBranch.replace(
					'disabled_reason_key = row.reason_key',
					'disabled_reason_key = row.reason_key, action = function() return true end'
				),
				'disabled row gains action'
			],
			[
				disabledBranch,
				disabledBranch.replace('rows[#rows + 1]', 'foreign_rows[#foreign_rows + 1]'),
				'foreign append destination'
			],
			[
				'for _, row in ipairs(declared) do\n',
				'for _, row in ipairs(declared) do\nlocal row = { id = "llm", disabled = true }\n',
				'shadowed declared source row'
			],
			[
				'\t\t\tlocal id = row.id\n',
				'\t\t\tlocal id = row.id\nid = "llm"\n',
				'rebound declared source identity'
			],
			[
				'function M.build(ctx)\n',
				'function M.build(ctx)\nlocal i18n_safe = function(key) return key end\n',
				'shadowed native caption owner'
			],
			[
				'local ok, i18n = pcall(require, "infra.i18n")',
				'local ok, i18n = pcall(require, "foreign.i18n")',
				'foreign caption import'
			],
			[
				'function i18n_safe(key)\n',
				'function i18n_safe(key)\ndo return "foreign" end\n',
				'bypassed caption owner'
			]
		];
		assert.equal(
			disabledControls.length,
			16,
			'all bounded disabled top-row controls remain registered'
		);
		for (const [before, after, reason] of disabledControls) {
			assert.equal(builder.split(before).length - 1, 1, reason + ': exact current preimage');
			const changed = builder.replace(before, after);
			assert.notEqual(changed, builder, reason + ': actual source changes');
			assert.equal(withBuilder(changed), false, reason + ': no native parent credit');
			assert.equal(withBuilder(builder), true, reason + ': actual inverse restores');
		}

		for (const [before, after, reason] of [
			[
				'local declared = ManifestMenu.get_array("top_level")',
				'local declared = {}',
				'canonical declared root replaced'
			],
			[
				'not rawequal(declared, source_rows)',
				'false',
				'declared source identity refusal withdrawn'
			],
			[
				'rawget(separator_modules, "infra.manifest_menu") == ManifestMenu',
				'true',
				'actual module custody withdrawn'
			],
			[
				'local rendered = separator_render(rows, "top_level")',
				'local rendered = separator_render({}, "top_level")',
				'finished native root discarded'
			],
			[
				'receive_separator("linux_quit_last")',
				'receive_separator("foreign_boundary")',
				'Quit-last declared boundary disconnected'
			],
			['getmetatable(ManifestMenu) == nil', 'true', 'facade metatable refusal withdrawn']
		]) {
			assert.equal(builder.split(before).length - 1, 1, reason + ': actual source preimage');
			assert.equal(withBuilder(builder.replace(before, after)), false, reason);
			assert.equal(withBuilder(builder), true, reason + ': genuine source inverse');
		}

		assert.equal(admits(linuxAiSources, manifest, 'hs'), false);
		for (const file of Object.keys(linuxAiSources)) {
			assert.equal(
				admits({ ...linuxAiSources, [file]: '' }),
				false,
				'withdrawn whole executable body'
			);
		}
		for (const section of [parentFrame, kind + '_menu', 'top_level']) {
			const missing = { ...manifest };
			delete missing[section];
			assert.equal(admits(linuxAiSources, missing), false, 'withdrawn actual shared source');
		}
		const duplicate = {
			...manifest,
			[parentFrame]: [...manifest[parentFrame], manifest[parentFrame].at(-1)]
		};
		assert.equal(
			admits(linuxAiSources, duplicate),
			false,
			'duplicate native group cannot own the parent'
		);
		const topDuplicate = {
			...manifest,
			top_level: [...manifest.top_level, manifest.top_level.find((row) => row.id === kind)]
		};
		assert.equal(admits(linuxAiSources, topDuplicate), false, 'duplicate genuine tray declaration');
		const producerFile =
			kind === 'agent' ? 'linux/ui/menu/agent_rows.lua' : 'linux/ui/menu/menu_builder.lua';
		const replacements = [
			[
				producerFile,
				'local NativeParent = require("ui.menu.ai_parent")',
				'local NativeParent = require("foreign.owner")'
			],
			[
				producerFile,
				'local parent = NativeParent.begin(ManifestMenu, "' +
					kind +
					'", ctx' +
					(kind === 'agent' ? ', AgentSettings)' : ')'),
				'local parent = nil'
			],
			[
				producerFile,
				'return NativeParent.finish(parent, ' + (kind === 'agent' ? 'children' : 'items') + ')',
				'return NativeParent.finish(parent, {})'
			],
			[
				producerFile,
				'return NativeParent.finish(parent, ' + (kind === 'agent' ? 'children' : 'items') + ')',
				'if false then return NativeParent.finish(parent, ' +
					(kind === 'agent' ? 'children' : 'items') +
					') end return nil'
			],
			['linux/ui/menu/menu_builder.lua', '["' + kind + '"]', '["withdrawn_' + kind + '"]'],
			['linux/ui/menu/menu_builder.lua', 'rows[#rows + 1] = build(ctx)', 'build(ctx)'],
			[
				'linux/ui/menu/menu_builder.lua',
				'local rendered = separator_render(rows, "top_level")',
				'local rendered = {}'
			],
			[
				'linux/ui/menu/ai_parent.lua',
				'local current_enabled = enabled(ticket)',
				'local current_enabled = ticket.enabled'
			],
			[
				'linux/ui/menu/ai_parent.lua',
				'if not current(ticket) or not unchanged(native_children)',
				'if not unchanged(native_children)'
			],
			['linux/ui/menu/ai_parent.lua', 'not unchanged(getter_snapshot)', 'false'],
			['linux/ui/menu/ai_parent.lua', 'not rawequal(rawget(row, "submenu"), children)', 'false'],
			['linux/ui/menu/ai_parent.lua', 'api_method(renderer, method)', 'renderer[method]'],
			['linux/ui/menu/ai_parent.lua', 'return row\nend', 'return { label = "synthetic" }\nend']
		];
		const disabledRow =
			'elseif row.disabled == true then\n\t\t\t\t\trows[#rows + 1] = { label = i18n_safe(row.i18n), disabled = true,\n\t\t\t\t\t\tdisabled_reason_key = row.reason_key }';
		for (const [before, after] of [
			['elseif row.disabled == true then', 'elseif false then'],
			['disabled = true,', 'disabled = false,'],
			['disabled_reason_key = row.reason_key', 'disabled_reason_key = "foreign"'],
			['label = i18n_safe(row.i18n)', 'label = "synthetic"']
		]) {
			assert.equal(
				disabledRow.split(before).length - 1,
				1,
				'closed disabled branch mutation exists'
			);
			replacements.push([
				'linux/ui/menu/menu_builder.lua',
				disabledRow,
				disabledRow.replace(before, after)
			]);
		}
		if (kind === 'agent')
			replacements.push(
				[producerFile, 'llm.set_agent_mode(id)', 'true'],
				[
					producerFile,
					'local children = ManifestMenu.build("agent_menu", "Agent", handlers, nil, menu_ctx, {})',
					'local children = {}'
				],
				[
					producerFile,
					'local NativeParent = require("ui.menu.ai_parent")',
					'local NativeParent = require("ui.menu.ai_parent")\nlocal NativeParent = {}'
				]
			);

		replacements.push(
			[
				'linux/ui/menu/menu_builder.lua',
				'function M.build(ctx)\n',
				'function M.build(ctx)\ndo return {} end\n'
			],
			[
				'linux/ui/menu/menu_builder.lua',
				'local build = builders[id]',
				'local build = builders[id]\nlocal build = function() return nil end'
			]
		);
		if (kind === 'agent')
			replacements.push(
				[
					producerFile,
					'function M.build(ctx, dialogs)\n',
					'function M.build(ctx, dialogs)\ndo return nil end\n'
				],
				[
					producerFile,
					'local NativeParent = require("ui.menu.ai_parent")',
					'local NativeParent = require("ui.menu.ai_parent")\nNativeParent.finish = function() return nil end'
				],
				[
					producerFile,
					'local NativeParent = require("ui.menu.ai_parent")',
					'local NativeParent = require("ui.menu.ai_parent")\nNativeParent["finish"] = function() return { label = "synthetic" } end'
				],
				[
					producerFile,
					'local committed = llm.set_agent_mode(id) == true',
					'do return false end\nlocal committed = llm.set_agent_mode(id) == true'
				]
			);
		else
			replacements.push(
				[
					producerFile,
					'local function _build_llm(ctx)\n',
					'local function _build_llm(ctx)\ndo return nil end\n'
				],
				[
					producerFile,
					'local NativeParent = require("ui.menu.ai_parent")',
					'local NativeParent = require("ui.menu.ai_parent")\nNativeParent.finish = function() return nil end'
				],
				[
					producerFile,
					'if llm.toggle then llm.toggle(ctx.on_menu_changed) end',
					'do return end\nif llm.toggle then llm.toggle(ctx.on_menu_changed) end'
				]
			);

		replacements.push(
			[
				'linux/ui/menu/menu_builder.lua',
				'local function _build_agent(ctx)\n',
				'local function _build_agent(ctx)\ndo return nil end\n'
			],
			[
				'linux/ui/menu/menu_builder.lua',
				'\nreturn M\n',
				'\nM.build = function() return {} end\nreturn M\n'
			],
			[
				'linux/ui/menu/agent_rows.lua',
				'\nreturn M\n',
				'\nM.build = function() return nil end\nreturn M\n'
			],
			[
				'linux/ui/menu/menu_builder.lua',
				'\nreturn M\n',
				'\nM["build"] = function() return {} end\nreturn M\n'
			],
			[
				'linux/ui/menu/agent_rows.lua',
				'\nreturn M\n',
				'\nrawset(M, "build", function() return nil end)\nreturn M\n'
			]
		);
		if (kind === 'agent')
			replacements.push([
				producerFile,
				'local function changed()\n',
				'local function changed()\ndo return nil end\n'
			]);
		replacements.push(
			[
				'linux/ui/menu/menu_builder.lua',
				'local NumberRowPolicy = require("layout.number_row_policy")',
				'local NumberRowPolicy = require("foreign.owner")'
			],
			[
				'linux/ui/menu/menu_builder.lua',
				'NumberRowPolicy.native_rows(ManifestMenu',
				'foreign_native_rows(ManifestMenu'
			],
			[
				'linux/ui/menu/menu_builder.lua',
				'local function _grey_for_pause(row)\n',
				'local function _grey_for_pause(row)\ndo return nil end\n'
			],
			[
				'linux/ui/menu/menu_builder.lua',
				'local function _row_is_for_linux(row)\n',
				'local function _row_is_for_linux(row)\ndo return false end\n'
			],
			[
				'linux/ui/menu/menu_builder.lua',
				'\nreturn M\n',
				'\nlocal unrelated = error("withdrawing real module")\nreturn M\n'
			],
			[producerFile, 'local llm = ctx.llm', 'local llm = ctx.llm\nctx.llm = nil']
		);
		replacements.push(
			[
				'linux/ui/menu/menu_builder.lua',
				'["agent"]           = _build_agent,',
				'["agent"]           = _build_agent,\n["agent"] = function() return nil end,'
			],
			[
				'linux/ui/menu/menu_builder.lua',
				'rows[#rows + 1] = build(ctx)',
				'rows[#rows + 1] = build(ctx) and {}'
			],
			[
				'linux/ui/menu/agent_rows.lua',
				'local children = ManifestMenu.build("agent_menu", "Agent", handlers, nil, menu_ctx, {})',
				'local children = ManifestMenu.build("agent_menu", "Agent", handlers, nil, menu_ctx, {}) and { { title = "synthetic" } }'
			],
			[
				'linux/ui/menu/agent_rows.lua',
				'\tend\n\tlocal handlers = {}',
				'\tend\n\tlocal changed = function() return nil end\n\tlocal handlers = {}'
			],
			[
				'linux/ui/menu/agent_rows.lua',
				'local children = ManifestMenu.build(',
				'menu_ctx.commands.agent_mode = function() return false end\nlocal children = ManifestMenu.build('
			],
			[
				'linux/ui/menu/menu_builder.lua',
				'local rendered = ManifestMenu\n\t\tand ManifestMenu.build("llm_menu"',
				'llm_ctx.commands["llm_toggle"] = function() return false end\nlocal rendered = ManifestMenu\n\t\tand ManifestMenu.build("llm_menu"'
			]
		);
		replacements.push([
			'linux/ui/menu/menu_builder.lua',
			'\nreturn M\n',
			'\nlocal foreign = require("foreign.native_owner")\nreturn M\n'
		]);
		const nativeBeginRefusal =
			'local parent = NativeParent.begin(ManifestMenu, "' +
			kind +
			'", ctx' +
			(kind === 'agent' ? ', AgentSettings)' : ')') +
			'\n\tif not parent then return nil end';
		for (const statement of [
			'error("owned native publication refused")',
			'rawset(ctx, "llm", nil)',
			'pcall(rawset, ctx, "llm", nil)',
			'local mutate = rawset; mutate(ctx, "llm", nil)'
		])
			replacements.push([producerFile, nativeBeginRefusal, nativeBeginRefusal + '\n' + statement]);
		for (const expression of [
			'; (function() error("owned immediate producer refused") end)()',
			'; (_G.error)("owned indirect producer refused")',
			'; _G["error"]("owned computed producer refused")',
			'; (_G.error) "owned literal-argument producer refused"'
		])
			replacements.push([producerFile, nativeBeginRefusal, nativeBeginRefusal + '\n' + expression]);

		const completedFinish =
			'return NativeParent.finish(parent, ' + (kind === 'agent' ? 'children' : 'items') + ')';
		const childName = kind === 'agent' ? 'children' : 'items';
		for (const statement of [
			childName + '[1] = nil',
			childName + ' = {}',
			'local ' + childName + ' = {}',
			'local retained_child_alias = ' + childName + '; retained_child_alias[1] = nil',
			'local mutate_child = function() ' + childName + '[1] = nil end; mutate_child()',
			childName + '[#' + childName + ' + 1] = {}'
		])
			replacements.push([producerFile, completedFinish, statement + '\n\t' + completedFinish]);
		if (kind === 'llm') {
			for (const statement of [
				'rendered[1] = nil',
				'rendered = {}',
				'local rendered = {}',
				'local retained_rendered_alias = rendered',
				'local items = {}; items[1] = nil'
			])
				replacements.push([producerFile, completedFinish, statement + '\n\t' + completedFinish]);
			replacements.push([
				producerFile,
				'return NativeParent.finish(parent, ManifestMenu.render_rows(status_rows, "linux_llm_absent_rows"))',
				'status_rows[1] = nil\n\t\treturn NativeParent.finish(parent, ManifestMenu.render_rows(status_rows, "linux_llm_absent_rows"))'
			]);
		}

		for (const statement of [
			'local llm = nil',
			'local shadow_marker, llm = nil, nil',
			'local ctx = {}',
			'local parent = {}',
			'local native_alias = llm; native_alias.toggle = nil',
			'local context_alias = ctx; context_alias.llm = nil',
			'local ticket_alias = parent; ticket_alias.enabled = false',
			'local shadowed = function(llm) return llm end',
			'local nested = function() local llm = nil end'
		])
			replacements.push([
				producerFile,
				'local llm = ctx.llm',
				'local llm = ctx.llm\n\t' + statement
			]);

		const rootRegistration =
			kind === 'agent' ? 'local handlers = {}' : 'local dynamic_handlers = {}';
		const rootName = kind === 'agent' ? 'handlers' : 'dynamic_handlers';
		for (const statement of ['local ' + rootName + ' = {}', rootName + ' = {}'])
			replacements.push([producerFile, rootRegistration, rootRegistration + '\n\t' + statement]);
		if (kind === 'llm')
			for (const statement of ['local enabled = false', 'enabled = false'])
				replacements.push([
					producerFile,
					'local enabled = parent.enabled',
					'local enabled = parent.enabled\n\t' + statement
				]);

		for (const statement of [
			'local native_alias = ctx.llm; native_alias.toggle = nil',
			'local NativeParent = require("foreign.native_owner")',
			'local captured = function(NativeParent) return NativeParent end',
			'local ManifestMenu = require("foreign.native_renderer")',
			'local captured = function(ManifestMenu) return ManifestMenu end',
			'local AgentSettings = require("foreign.native_settings")'
		])
			replacements.push([
				producerFile,
				'local llm = ctx.llm',
				'local llm = ctx.llm\n\t' + statement
			]);

		const agentRegistrationFile = 'linux/ui/menu/agent_rows.lua';
		const nativeCallbackEnd = '\t\t\t\treturn committed\n\t\t\tend,\n\t\t},';
		for (const field of [
			'agent_mode = false',
			'["agent_mode"] = false',
			'["agent_" .. "mode"] = false',
			'[command_key] = false'
		])
			replacements.push([
				agentRegistrationFile,
				nativeCallbackEnd,
				'\t\t\t\treturn committed\n\t\t\tend,\n\t\t\t' + field + ',\n\t\t},'
			]);
		replacements.push([
			agentRegistrationFile,
			'\tlocal menu_ctx = {\n\t\tcommands = {',
			'\tlocal menu_ctx = {\n\t\tcommands = false and {'
		]);
		replacements.push([
			agentRegistrationFile,
			'\tlocal menu_ctx = {\n\t\tcommands = {',
			'\tlocal menu_ctx = false and {\n\t\tcommands = {'
		]);
		replacements.push([
			agentRegistrationFile,
			'\t\tstate_getters = {',
			'\t\tstate_getters = false and {'
		]);
		replacements.push([
			agentRegistrationFile,
			'["llm.agent_mode"] = AgentSettings.get_mode,',
			'["llm.agent_mode"] = AgentSettings.get_mode, ["llm.agent_mode"] = false,'
		]);
		replacements.push([
			agentRegistrationFile,
			'\n\t}\n\tlocal children = ManifestMenu.build',
			'\n\t\tcommands = {},\n\t}\n\tlocal children = ManifestMenu.build'
		]);
		replacements.push([
			agentRegistrationFile,
			'\n\t}\n\tlocal children = ManifestMenu.build',
			'\n\t\t["state_getters"] = {},\n\t}\n\tlocal children = ManifestMenu.build'
		]);
		for (const [file, before, after] of replacements) {
			assert.ok(
				linuxAiSources[file].includes(before),
				'mutation must change actual production: ' + before
			);
			assert.equal(
				admits({
					...linuxAiSources,
					[file]: linuxAiSources[file].replace(before, after)
				}),
				false,
				'actual producer/source mutation: ' + before
			);
		}
		const quoted = {
			...linuxAiSources,
			'linux/ui/menu/ai_parent.lua':
				linuxAiSources['linux/ui/menu/ai_parent.lua'] + '\n-- foreign owner comment\n'
		};
		assert.equal(
			admits(quoted),
			true,
			'inert comments do not provide or withdraw an executable route'
		);
	}
}

// Fixed native parent obligations retain the original state and absence contracts.
{
	const assert = require('node:assert/strict');
	const proof = require('../lib/menu-native-llm-parent-binding.cjs');
	const macFile = 'macos/ui/menu/builder.lua';
	const layoutFile = 'macos/ui/menu/menu_keyboard_layout.lua';
	const linuxFile = 'linux/ui/menu/menu_builder.lua';
	const mac = fs.readFileSync(path.join(SP, macFile), 'utf8');
	const layout = fs.readFileSync(path.join(SP, layoutFile), 'utf8');
	const linux = fs.readFileSync(path.join(SP, linuxFile), 'utf8');
	const admitsMac = (source) => proof.nativeMacLayoutTopLevelPublication(source, layout, manifest);
	const admitsLinux = (source) => proof.nativeLinuxTapHoldAbsentPublication(source, manifest);
	assert.equal(
		admitsMac(mac),
		true,
		'actual canonical Layout parent consumes its native absence reader'
	);
	assert.equal(
		admitsLinux(linux),
		true,
		'actual missing TapHold engine publishes its declared inert leaf'
	);
	const mutate = (source, before, after) => {
		assert.equal(
			source.split(before).length - 1,
			1,
			'actual fixed parent mutation has one source owner'
		);
		return source.replace(before, after);
	};
	assert.equal(
		admitsMac(
			mutate(
				mac,
				'local builders = {',
				'local unrelated = { module_rows, other = 1, collect }\nlocal builders = {'
			)
		),
		true,
		'constructor data reads do not shadow the genuine fixed native parent functions'
	);
	for (const [before, after] of [
		[
			'ManifestMenu.group_receiver("top_level", "keyboard_layout")',
			'ManifestMenu.group_receiver("top_level", "shortcuts")'
		],
		[
			'if not receive then return {} end\n\t\t\tlocal rows = module_rows("keyboard_layout")',
			'if false then return {} end\n\t\t\tlocal rows = module_rows("keyboard_layout")'
		],
		['layout_enabled = function() return nil end', 'layout_enabled = function() return false end'],
		[
			'local parent = receive(submenu, { layout_enabled',
			'local parent = receive({}, { layout_enabled'
		],
		['return collect(key .. ".build", mod.build, arg or ctx)', 'return {}'],
		[
			'local result = Logger.build(LOG, label, fn, arg)',
			'local result = { label = "Foreign", submenu = {} }'
		],
		[
			'local builders = {',
			'local function module_rows(ignored) return { {submenu = {}} } end\nlocal builders = {'
		],
		[
			'local builders = {',
			'local function collect(ignored) return { {submenu = {}} } end\nlocal builders = {'
		],
		['local builders = {', 'local module_rows\nlocal builders = {'],
		[
			'for _, entry in ipairs(load_top_level()) do',
			'builders.keyboard_layout = function() return {} end\nfor _, entry in ipairs(load_top_level()) do'
		],
		[
			'for _, entry in ipairs(load_top_level()) do',
			'builders["keyboard_layout"] = function() return {} end\nfor _, entry in ipairs(load_top_level()) do'
		],
		[
			'for _, entry in ipairs(load_top_level()) do',
			'local builders = {}\nfor _, entry in ipairs(load_top_level()) do'
		],
		[
			'for _, entry in ipairs(load_top_level()) do',
			'builders = {}\nfor _, entry in ipairs(load_top_level()) do'
		],
		[
			'for _, entry in ipairs(load_top_level()) do',
			'local unused = builders\nfor _, entry in ipairs(load_top_level()) do'
		],
		[
			'local children = builders[id]() or {}',
			'builders.keyboard_layout = function() return {} end\nlocal children = builders[id]() or {}'
		],
		[
			'\n\t}\n\n\tlocal items = {}\n\tfor _, entry in ipairs(load_top_level()) do',
			'\n\t\tkeyboard_layout = function(ignored) return {} end,\n\t}\n\n\tlocal items = {}\n\tfor _, entry in ipairs(load_top_level()) do'
		],
		['local builders = {', 'local ignored, module_rows\nlocal builders = {'],
		[
			'local builders = {',
			'module_rows, Foreign.slot = function() return { {submenu = {}} } end, nil\nlocal builders = {'
		],
		[
			'local builders = {',
			'module_rows, Foreign[1] = function() return {} end, nil\nlocal builders = {'
		],
		[
			'local builders = {',
			'module_rows, (Foreign).slot = function() return {} end, nil\nlocal builders = {'
		],
		[
			'local builders = {',
			'module_rows, Factory().slot = function() return {} end, nil\nlocal builders = {'
		],
		[
			'local builders = {',
			'local function unrelated(module_rows) return {} end\nlocal builders = {'
		],
		[
			'local builders = {',
			'for ignored, module_rows in pairs({}) do break end\nlocal builders = {'
		],
		['local builders = {', 'local ignored, collect\nlocal builders = {'],
		[
			'local builders = {',
			'collect, Foreign.slot = function() return { {submenu = {}} } end, nil\nlocal builders = {'
		],
		[
			'local builders = {',
			'collect, Foreign[1] = function() return {} end, nil\nlocal builders = {'
		],
		[
			'local builders = {',
			'collect, (Foreign).slot = function() return {} end, nil\nlocal builders = {'
		],
		[
			'local builders = {',
			'collect, Factory().slot = function() return {} end, nil\nlocal builders = {'
		],
		['local builders = {', 'local function unrelated(collect) return {} end\nlocal builders = {'],
		['local builders = {', 'for ignored, collect in pairs({}) do break end\nlocal builders = {'],
		[
			'local builders = {',
			'module_rows, ignored = function() return {} end, nil\nlocal builders = {'
		],
		[
			'return parent and { parent } or {}\n\t\tend,\n\t\t["hotstrings"]',
			'return {}\n\t\tend,\n\t\t["hotstrings"]'
		]
	])
		assert.equal(
			admitsMac(mutate(mac, before, after)),
			false,
			'genuine Layout receiving route: ' + before
		);
	for (const [before, after] of [
		[
			'ManifestMenu.template_rows("linux_tap_holds_absent_parent", {}, {}, {})',
			'ManifestMenu.template_rows("linux_hotstrings_absent_rows", {}, {}, {})'
		],
		[
			'if not declared or #declared ~= 1 then return nil end\n\t\treturn declared[1]',
			'if false then return nil end\n\t\treturn declared[1]'
		],
		['return declared[1]\n\tend\n\tlocal Writer', 'return {}\n\tend\n\tlocal Writer'],
		['["tap_holds"]       = _build_tap_holds,', '["tap_holds"]       = _build_shortcuts,'],
		['local rendered = separator_render(rows, "top_level")', 'local rendered = {}']
	])
		assert.equal(
			admitsLinux(mutate(linux, before, after)),
			false,
			'genuine inert leaf transport: ' + before
		);
	assert.equal(
		proof.nativeMacLayoutTopLevelPublication(mac, layout, { ...manifest, top_level: {} }),
		false,
		'a malformed canonical top-level source cannot supply a native parent'
	);
	const missing = { ...manifest };
	delete missing.linux_tap_holds_absent_parent;
	assert.equal(
		proof.nativeLinuxTapHoldAbsentPublication(linux, missing),
		false,
		'withdrawn absent declaration has no native publication credit'
	);
	const foreign = {
		...manifest,
		linux_tap_holds_absent_parent: [
			{ ...manifest.linux_tap_holds_absent_parent[0], type: 'group', rows: [] }
		]
	};
	assert.equal(
		proof.nativeLinuxTapHoldAbsentPublication(linux, foreign),
		false,
		'the absent inert leaf cannot become an empty submenu'
	);
	// This is the physical root's compose branch, not a fictitious clickable parent.
	if (admitsLinux(linux)) {
		const section = 'linux_tap_holds_absent_parent';
		reachableOn[section] = combineMenuVisibility(PLATFORMS, reachableOn[section], ['linux']);
		openedBy[section] = 'actual missing-engine TapHold branch in Linux native tray root';
		reachedByKinds[section] = { linux: new Set(['compose']) };
	}
}

// The physical Linux root composes both header branches before its captured final render.
// These are actual native root frames, not fictitious clicked submenu parents.
{
	const assert = require('node:assert/strict');
	const { nativeLinuxHeaderPublication } = require('../lib/menu-native-llm-parent-binding.cjs');
	const source = linuxAiSources['linux/ui/menu/menu_builder.lua'];
	const admits = (candidate = source, declarations = manifest, platform = 'linux') =>
		nativeLinuxHeaderPublication(candidate, declarations, platform);
	assert.equal(admits(), true, 'actual physical Linux root retains both guarded header frames');
	for (const platform of ['hs', 'ahk', 'Linux', undefined]) {
		assert.equal(
			nativeLinuxHeaderPublication(source, manifest, platform),
			false,
			'header publication belongs only to the actual Linux root'
		);
	}
	for (const [reason, change] of [
		[
			'missing canonical top-level root',
			(declarations) => {
				delete declarations.top_level;
			}
		],
		[
			'empty canonical top-level root',
			(declarations) => {
				declarations.top_level = [];
			}
		],
		[
			'missing actual top-level record identity',
			(declarations) => {
				declarations.top_level = [{}];
			}
		],
		[
			'repeated actual top-level record',
			(declarations) => {
				declarations.top_level.push(declarations.top_level[0]);
			}
		],
		[
			'non-data root array getter',
			(declarations) => {
				Object.defineProperty(declarations.top_level, '0', {
					get() {
						throw new Error('root getter');
					}
				});
			}
		],
		[
			'non-data root declaration getter',
			(declarations) => {
				Object.defineProperty(declarations, 'top_level', {
					get() {
						throw new Error('root getter');
					}
				});
			}
		],
		[
			'non-data frame getter',
			(declarations) => {
				Object.defineProperty(declarations, 'linux_tray_active_header', {
					get() {
						throw new Error('frame getter');
					}
				});
			}
		],
		[
			'non-data frame row getter',
			(declarations) => {
				Object.defineProperty(declarations.linux_tray_active_header, '0', {
					get() {
						throw new Error('row getter');
					}
				});
			}
		],
		[
			'non-data caption getter',
			(declarations) => {
				Object.defineProperty(declarations.linux_tray_active_header[0], 'i18n', {
					get() {
						throw new Error('caption getter');
					}
				});
			}
		],
		[
			'non-data platform getter',
			(declarations) => {
				Object.defineProperty(declarations.linux_tray_paused_header[0].platforms, '0', {
					get() {
						throw new Error('platform getter');
					}
				});
			}
		],
		[
			'custom frame record prototype',
			(declarations) => {
				Object.setPrototypeOf(declarations.linux_tray_paused_header[0], { foreign: true });
			}
		],
		[
			'extra frame array property',
			(declarations) => {
				declarations.linux_tray_active_header.foreign = true;
			}
		]
	]) {
		const declarations = structuredClone(manifest);
		change(declarations);
		assert.equal(admits(source, declarations), false, reason + ': native plain root refuses');
		assert.equal(admits(), true, reason + ': genuine inverse retained');
	}
	for (const section of ['linux_tray_active_header', 'linux_tray_paused_header']) {
		for (const [reason, change] of [
			[
				'missing frame',
				(root) => {
					delete root[section];
				}
			],
			[
				'empty frame',
				(root) => {
					root[section] = [];
				}
			],
			[
				'duplicate frame',
				(root) => {
					root[section].push({ ...root[section][0] });
				}
			],
			[
				'foreign kind',
				(root) => {
					root[section][0].type = 'group';
				}
			],
			[
				'foreign identity',
				(root) => {
					root[section][0].id = 'foreign_header';
				}
			],
			[
				'missing caption',
				(root) => {
					root[section][0].i18n = '';
				}
			],
			[
				'foreign reader',
				(root) => {
					root[section][0].caption_getter = 'foreign_version';
				}
			],
			[
				'foreign caption recipe',
				(root) => {
					root[section][0].caption_layout = 'suffix';
				}
			],
			[
				'foreign caption joiner',
				(root) => {
					root[section][0].caption_joiner = ':';
				}
			],
			[
				'foreign platform',
				(root) => {
					root[section][0].platforms = ['hs'];
				}
			],
			[
				'foreign availability',
				(root) => {
					root[section][0].unavailable = 'disable';
				}
			],
			[
				'invented submenu',
				(root) => {
					root[section][0].rows = [];
				}
			]
		]) {
			const declarations = structuredClone(manifest);
			change(declarations);
			assert.notDeepEqual(declarations, manifest, section + ': ' + reason + ' changed source');
			assert.equal(admits(source, declarations), false, section + ': ' + reason + ' refuses');
			assert.equal(admits(), true, section + ': ' + reason + ' genuine inverse retained');
		}
	}
	for (const [before, after, reason] of [
		['function M.build(ctx)', 'function M.foreign(ctx)', 'withdrawn genuine root export'],
		[
			'local header, header_current = _build_header(ctx)',
			'local header, header_current = Foreign.header(ctx)',
			'disconnected physical header consumer'
		],
		[
			'local rendered = separator_render(rows, "top_level")',
			'local rendered = rows',
			'withdrawn captured native render'
		],
		[
			'or not header_current() then return {} end\n\treturn rendered',
			'then return {} end\n\treturn rendered',
			'withdrawn final physical header receipt'
		]
	]) {
		assert.equal(source.split(before).length - 1, 1, reason + ': actual unique coordinate');
		const candidate = source.replace(before, after);
		assert.notEqual(candidate, source, reason + ': actual source changed');
		assert.equal(candidate.replace(after, before), source, reason + ': exact source inverse');
		assert.equal(admits(candidate), false, reason + ': physical ownership refuses');
		assert.equal(admits(), true, reason + ': genuine inverse retained');
	}
	if (admits()) {
		for (const section of ['linux_tray_active_header', 'linux_tray_paused_header']) {
			reachableOn[section] = combineMenuVisibility(PLATFORMS, reachableOn[section], ['linux']);
			openedBy[section] = 'actual guarded Linux header branch in the exported native tray root';
			reachedByKinds[section] = { linux: new Set(['compose']) };
		}
	}
}

// Physical withdrawal controls prevent graph entries from becoming decorative orphan exemptions.
{
	const assert = require('node:assert/strict');
	const controls = require('./fixtures/hotstring-language-owner-counterexamples.cjs')(SP, manifest);
	assert(controls > 100, 'actual source/declaration refusal controls must all execute');
}

// The editor is composed into existing category providers, not opened as a submenu.
// This credits only the reviewed leaf and immediate transport, not a whole native parent.
const personalInfoProviders = {
	hs: { id: 'hotstring_categories_standard', file: 'macos/ui/menu/menu_hotstrings.lua' },
	linux: { id: 'hotstring_categories_dynamic', file: 'linux/ui/menu/menu_builder.lua' }
};
const personalInfoSources = Object.fromEntries(
	Object.entries(personalInfoProviders).map(([platform, { file }]) => [
		platform,
		fs.readFileSync(path.join(SP, file), 'utf8')
	])
);

/** Requires the actual guarded producer and its one typed command declaration. */
function personalInfoProviderComposition(source, declarations, platform) {
	if (!Object.hasOwn(personalInfoProviders, platform)) return false;
	const section = 'personal_info_editor_frame',
		key = 'personal_info_editor_open';
	const rows = declarations?.[section];
	if (!Array.isArray(rows) || rows.length !== 1) return false;
	const row = rows[0];
	if (
		!row ||
		typeof row !== 'object' ||
		Array.isArray(row) ||
		Object.keys(row).length !== 5 ||
		!['type', 'id', 'i18n', 'platforms', 'unavailable'].every((name) => Object.hasOwn(row, name)) ||
		row.type !== 'command' ||
		row.id !== key ||
		row.i18n !== 'menu.shortcuts.edit_personal_info' ||
		row.unavailable !== 'hide' ||
		!Array.isArray(row.platforms) ||
		row.platforms.length !== 2 ||
		row.platforms[0] !== 'hs' ||
		row.platforms[1] !== 'linux'
	)
		return false;
	const parents = declarations.hotstrings_menu;
	const matches = Array.isArray(parents)
		? parents.filter((parent) => parent.id === personalInfoProviders[platform].id)
		: [];
	if (matches.length !== 1 || matches[0].type !== 'list' || !visibleOn(matches[0], platform))
		return false;
	const proof = require('../lib/menu-native-personal-info-binding.cjs');
	if (proof.retainedPersonalInfoTemplateCallOffset(source, platform) < 0) return false;
	return require('../lib/menu-template-binding.cjs').nativeTemplateBinding(
		source,
		'.lua',
		section,
		key,
		1,
		[{ src: source }],
		declarations,
		platform
	);
}

{
	const assert = require('node:assert/strict');
	for (const [platform, source] of Object.entries(personalInfoSources)) {
		const admits = (candidate = source, declarations = manifest, owner = platform) =>
			personalInfoProviderComposition(candidate, declarations, owner);
		assert.equal(admits(), true, platform + ': actual guarded editor provider composition');
		assert.equal(
			admits(source, manifest, platform === 'hs' ? 'linux' : 'hs'),
			false,
			'another driver cannot borrow the actual typed producer'
		);
		for (const candidate of ['', JSON.stringify(source), '--[=[\n' + source + '\n]=]'])
			assert.equal(admits(candidate), false, 'missing, quoted or comment-only producer');
		for (const [before, after, reason] of [
			['local renderer = ManifestMenu', 'local renderer = Foreign', 'foreign native facade'],
			[
				'local root, source = root_owner(), array_owner("personal_info_editor_frame")',
				'local root, source = root_owner(), array_owner("foreign_frame")',
				'foreign source getter'
			],
			[
				'local editor = template("personal_info_editor_frame", {',
				'local editor = template("foreign_frame", {',
				'foreign actual template call'
			],
			[
				'personal_info_editor_open = function()',
				'foreign_command = function()',
				'foreign callback key'
			],
			[
				'local function personal_info_editor_source()',
				'local _ENV = Foreign\nlocal function personal_info_editor_source()',
				'withdrawn lexical namespace'
			],
			[
				platform === 'hs' ? 'items[#items + 1] = row' : 'if valid then sub[1] = row end',
				platform === 'hs' ? 'items[#items + 1] = {}' : 'if valid then sub[1] = {} end',
				'actual returned command discarded'
			]
		]) {
			assert.equal(source.split(before).length - 1, 1, reason + ': exact genuine coordinate');
			const candidate = source.replace(before, after);
			assert.notEqual(candidate, source, reason + ': actual source changes');
			assert.equal(admits(candidate), false, reason);
			assert.equal(admits(), true, reason + ': genuine inverse');
		}
		for (const alter of [
			(declarations) => {
				delete declarations.personal_info_editor_frame;
			},
			(declarations) => {
				declarations.personal_info_editor_frame = [];
			},
			(declarations) => {
				declarations.personal_info_editor_frame[0].id = 'foreign_command';
			},
			(declarations) => {
				declarations.personal_info_editor_frame[0].type = 'group';
			},
			(declarations) => {
				declarations.personal_info_editor_frame[0].platforms = ['ahk'];
			},
			(declarations) => {
				declarations.personal_info_editor_frame[0].i18n = 'foreign_caption';
			},
			(declarations) => {
				declarations.personal_info_editor_frame[0].rows = [];
			},
			(declarations) => {
				declarations.hotstrings_menu = declarations.hotstrings_menu.filter(
					(parent) => parent.id !== personalInfoProviders[platform].id
				);
			},
			(declarations) => {
				declarations.hotstrings_menu.push(
					declarations.hotstrings_menu.find(
						(parent) => parent.id === personalInfoProviders[platform].id
					)
				);
			},
			(declarations) => {
				declarations.hotstrings_menu.find(
					(parent) => parent.id === personalInfoProviders[platform].id
				).platforms = ['ahk'];
			}
		]) {
			const declarations = structuredClone(manifest);
			alter(declarations);
			assert.equal(
				admits(source, declarations),
				false,
				'withdrawn or foreign actual declaration/parent'
			);
			assert.equal(admits(), true, 'declaration controls preserve actual canonical inputs');
		}
	}
	for (const platform of ['ahk', 'HS', '', undefined])
		assert.equal(
			personalInfoProviderComposition(personalInfoSources.hs, manifest, platform),
			false,
			'only the actual two Lua producer platforms have composition evidence'
		);
}

// Iterated to a fixed point rather than walked once: the graph is shallow today
// but a group nested inside a group would make a single pass depth-dependent,
// and a check that silently depends on declaration order is a check that breaks
// on an unrelated edit.
for (let pass = 0; pass < MENU_KEYS.length + 1; pass += 1) {
	let changed = false;
	for (const menuKey of MENU_KEYS) {
		const parentVisibility = reachableOn[menuKey];
		if (!parentVisibility) continue;
		for (const row of manifest[menuKey]) {
			// Only the actual reachable category list can transport this declared command.
			if (menuKey === 'hotstrings_menu' && row.type === 'list') {
				for (const [platform, provider] of Object.entries(personalInfoProviders)) {
					if (
						row.id !== provider.id ||
						!parentVisibility.includes(platform) ||
						!visibleOn(row, platform) ||
						!personalInfoProviderComposition(personalInfoSources[platform], manifest, platform)
					)
						continue;
					const target = 'personal_info_editor_frame';
					const before = (reachableOn[target] || []).join(',');
					const combined = combineMenuVisibility(PLATFORMS, reachableOn[target], [platform]);
					if (before !== combined.join(',')) {
						reachableOn[target] = combined;
						changed = true;
					}
					openedBy[target] = `${menuKey}/${row.id}/actual guarded editor producer`;
					if (!reachedByKinds[target]) reachedByKinds[target] = {};
					if (!reachedByKinds[target][platform]) reachedByKinds[target][platform] = new Set();
					reachedByKinds[target][platform].add('compose');
				}
			}
			const published = row.type === 'include' ? row.section : OPENS_SUBMENU[row.id];
			if (!published) continue;
			// One provider can publish multiple independently declared children.
			// Every existing platform restriction still applies to its own edge.
			for (const opened of Array.isArray(published) ? published : [published]) {
				const target = typeof opened === 'string' ? opened : opened.menu;
				const only = typeof opened === 'string' ? PLATFORMS : opened.platforms;
				const kind = row.type === 'include' || opened.kind === 'compose' ? 'compose' : 'submenu';
				if (
					opened.completed_linux_ai_parent !== undefined &&
					(opened.completed_linux_ai_parent !== row.id ||
						!nativeLinuxAiParentPublication(linuxAiSources, manifest, row.id, 'linux'))
				) {
					errors.push(`${menuKey}/${row.id}: actual completed Linux AI publication refused`);
					continue;
				}

				const effective = PLATFORMS.filter(
					(p) =>
						visibleOn(row, p) &&
						parentVisibility.includes(p) &&
						only.includes(p) &&
						(row.type !== 'include' || project(target, p).length > 0)
				);
				for (const platform of effective) {
					if (!reachedByKinds[target]) reachedByKinds[target] = {};
					if (!reachedByKinds[target][platform]) reachedByKinds[target][platform] = new Set();
					reachedByKinds[target][platform].add(kind);
					if (row.type === 'include') continue;
					const file = opened.native_sources?.[platform];
					if (kind !== 'compose' && file === undefined) continue;
					const driver = { ahk: 'windows', hs: 'macos', linux: 'linux' }[platform];
					if (
						typeof file !== 'string' ||
						!file.startsWith(driver + '/') ||
						!(opened.completed_linux_ai_parent === row.id && platform === 'linux'
							? nativeLinuxAiParentPublication(linuxAiSources, manifest, row.id, platform)
							: opened.hotstring_language_owner
								? hotstringLanguagePublication(
										Object.fromEntries(
											languageOwnerFiles[platform].map((file) => [
												file,
												fs.readFileSync(path.join(SP, file), 'utf8')
											])
										),
										manifest,
										platform,
										target
									)
								: opened.completed_parent?.[platform] === 'llm'
									? require('../lib/menu-native-llm-parent-binding.cjs').nativeLlmParentPublication(
											fs.readFileSync(path.join(SP, file), 'utf8'),
											fs.readFileSync(path.join(SP, 'macos/ui/menu/builder.lua'), 'utf8'),
											manifest[target],
											manifest.top_level,
											platform
										)
									: opened.forwarded_template?.[platform] === 'layout'
										? require('../lib/menu-native-layout-binding.cjs').nativeLayoutTemplatePublication(
												fs.readFileSync(path.join(SP, file), 'utf8'),
												target,
												manifest[target]
											)
										: opened.selected_group?.[platform]
											? publishesSelectedMenuGroup(
													fs.readFileSync(path.join(SP, file), 'utf8'),
													path.extname(file),
													target,
													manifest[target],
													opened.selected_group[platform]
												)
											: publishesTemplate(
													fs.readFileSync(path.join(SP, file), 'utf8'),
													path.extname(file),
													target
												) ||
												publishesIncludedCommands(
													fs.readFileSync(path.join(SP, file), 'utf8'),
													path.extname(file),
													target,
													manifest,
													platform
												))
					)
						errors.push(
							`${menuKey}/${row.id}: ${kind} ${target} has no native template publication on ${platform}`
						);
				}
				const before = (reachableOn[target] || []).join(',');
				const combined = combineMenuVisibility(PLATFORMS, reachableOn[target], effective);
				if (before !== combined.join(',')) {
					reachableOn[target] = combined;
					changed = true;
				}
				openedBy[target] = `${menuKey}/${row.id}`;
			}
		}
	}
	if (!changed) break;
}

for (const menuKey of MENU_KEYS) {
	if (reachableOn[menuKey]) continue;
	errors.push(
		`the manifest declares the menu "${menuKey}" and no row anywhere opens it. Either a row lost its ` +
			`id, or the menu is dead data every gate still counts. If it is opened by a row this gate does ` +
			'not know about, add it to OPENS_SUBMENU — an unmapped parent makes the whole submenu invisible ' +
			'to every check below.'
	);
}

// A parent row a user can click, opening a submenu with nothing in it. This is
// the shape all three of the defects in the header took.
for (const menuKey of MENU_KEYS) {
	const visibility = reachableOn[menuKey];
	if (!visibility || menuKey === 'top_level') continue;
	for (const platform of visibility) {
		if (actionable(menuKey, platform).length > 0) continue;
		if (
			isComposedFragment(
				project(menuKey, platform),
				reachedByKinds[menuKey]?.[platform] || new Set()
			)
		)
			continue;
		errors.push(
			`${DRIVER_OF[platform]}: "${openedBy[menuKey]}" is visible, and the "${menuKey}" it opens ` +
				`projects no actionable row for ${DRIVER_OF[platform]} — the user clicks an entry and gets an ` +
				'empty menu. Either restrict the row that opens it, or widen the rows inside it to the ' +
				'platform that already shows the parent.'
		);
	}
}

// ==================================================
// ==================================================
// ======= 3/ No heading without a section ==========
// ==================================================
// ==================================================

// A section_header is a disabled row whose whole purpose is to introduce the
// rows beneath it. When its content is restricted and the header is not, the
// header survives alone and reads to the user as a section the driver failed to
// fill. Cheaper to check than to explain in a bug report.
for (const menuKey of MENU_KEYS) {
	const visibility = reachableOn[menuKey] || PLATFORMS;
	for (const platform of visibility) {
		const rows = project(menuKey, platform);
		// Native providers compose these validated inert fragments into their actual lists.
		// A standalone heading in such a fragment is not an empty clicked submenu.
		if (isComposedFragment(rows, reachedByKinds[menuKey]?.[platform] || new Set())) continue;
		rows.forEach((row, index) => {
			if ((row.type || 'ref') !== 'section_header') return;
			let under = 0;
			for (let j = index + 1; j < rows.length; j += 1) {
				const type = rows[j].type || 'ref';
				if (type === 'section_header' || type === SEPARATOR) break;
				under += 1;
			}
			if (under > 0) return;
			errors.push(
				`${DRIVER_OF[platform]}: the header "${row.i18n}" in ${menuKey} introduces nothing — every ` +
					`row it heads is restricted away from ${DRIVER_OF[platform]}. Restrict the header with its ` +
					'content.'
			);
		});
	}
}

// ==================================================
// ==================================================
// ======= 4/ Every divergence is declared ==========
// ==================================================
// ==================================================

// NOT CHECKED HERE, deliberately: that the shared rows appear in the same ORDER
// on two platforms. One manifest array per menu means the order is a single list
// filtered three ways, so the three projections are subsequences of one sequence
// and cannot disagree. A first draft of this gate checked it anyway; mutating a
// row to a different position left it green, because moving the row moves it for
// all three at once. A check that cannot fail is worse than no check — it reads
// as protection.
//
// What CAN diverge is a row appearing twice under one identity: two entries the
// user cannot tell apart, and one handler lookup that resolves to the first. That
// is what found `feature` rows being keyed by `path` rather than by `id`.
let comparedRows = 0;

for (const menuKey of MENU_KEYS) {
	comparedRows += actionable(menuKey, PLATFORMS[0]).length;
}

if (comparedRows === 0) {
	errors.push(
		'no rows were compared — the projection is broken, not the tree. A comparison that silently ' +
			'examines nothing is the exact failure this gate exists to prevent.'
	);
}

// Duplicate identities inside one menu: two rows the user cannot tell apart and
// that every id-keyed handler lookup resolves to the same branch.
for (const menuKey of MENU_KEYS) {
	for (const platform of reachableOn[menuKey] || PLATFORMS) {
		const seen = new Set();
		for (const row of actionable(menuKey, platform)) {
			const id = identityOf(row);
			if (seen.has(id)) {
				errors.push(
					`${menuKey}: "${id}" appears twice for ${DRIVER_OF[platform]}. Two rows with one identity ` +
						'means one handler and two entries, and the second is unreachable.'
				);
			}
			seen.add(id);
		}
	}
}

// ==================================================
// ==================================================
// ======= 5/ Every label resolves ==================
// ==================================================
// ==================================================

// A menu row whose key is missing from a locale renders the raw key. Checked in
// every shipped locale rather than in the reference one, because the reference
// is the one that never has the gap. `disabled_reason_key` is why
// `disabled_when` greys a row, which the greyed row shows.
const LABEL_FIELDS = ['i18n', 'reason_key', 'disabled_reason_key'];

const namedKeys = [];
for (const menuKey of MENU_KEYS) {
	for (const row of manifest[menuKey]) {
		for (const field of LABEL_FIELDS) {
			if (typeof row[field] === 'string') namedKeys.push({ menuKey, row, field, key: row[field] });
		}
	}
}

const localeFiles = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
if (localeFiles.length < 15) {
	errors.push(
		`read ${localeFiles.length} locale file(s) — the scan is broken, so nothing below is checked`
	);
}

for (const file of localeFiles) {
	const table = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
	for (const entry of namedKeys) {
		if (table[entry.key] !== undefined) continue;
		errors.push(
			`${file}: "${entry.key}" (${entry.menuKey}, ${entry.field}) has no translation — the menu will ` +
				'show the key itself to every user of that language.'
		);
	}
}

// ==================================================
// ==================================================
// ======= 6/ A hidden row says why =================
// ==================================================
// ==================================================

// Only rows narrower than the menu holding them are counted. A row inside
// tap_holds_menu need not repeat "Windows only" — the row that opens the menu
// already carries it, and demanding the reason on all five children turns a real
// signal into noise nobody reads.
const unreasoned = [];
for (const menuKey of MENU_KEYS) {
	const parentVisibility = reachableOn[menuKey] || PLATFORMS;
	for (const row of manifest[menuKey]) {
		if ((row.type || 'ref') === SEPARATOR) continue;
		if (isSeparator(row)) continue;
		const own = Array.isArray(row.platforms) ? row.platforms : PLATFORMS;
		const narrower = parentVisibility.filter((p) => !own.includes(p));
		if (narrower.length === 0 || row.reason_key || row.unavailable === 'hide') continue;
		unreasoned.push(
			`${menuKey}/${row.id || row.i18n || row.category || row.type} hidden on ` +
				`${narrower.map((p) => DRIVER_OF[p]).join(', ')}`
		);
	}
}

// Frozen at the measurement of 2026-08-04. Convention S wants the row present
// and greyed with its reason rather than absent, and these rows predate that;
// making them all red at once would mean this gate could only land by being
// silenced. It may fall, never rise:
//   41 → 40 when hotstring_extensions stopped claiming to be Windows-only
//   40 → 39 when repeat_key did the same. macOS had shipped both the engine and
//        the toggle all along, so the restriction recorded who wrote it first
//        rather than what the platforms can do; Linux now has it too.
//   39 → 37 on 2026-08-06 when the floating WPM widget and its colour toggle
//        stopped being Windows-and-macOS-only. Same story a third time: the
//        restriction was true when written — that driver had no floating widget
//        at all — and stopped being true when linux/ui/wpm/widget.lua drew one on
//        the GTK surface the preview bubble already uses.
//   37 → 36 on 2026-08-06 when wrap_symbols_menu stopped claiming to be
//        Windows-only. macOS and Linux had both been drawing the picker the
//        whole time, in a different position each; it is one shared row now.
// 36 → 0 on 2026-08-07. Every row narrower than the menu it sits in now says
// why, in twenty-one languages, and two of the thirty-six turned out not to need
// a reason at all: the metrics and gestures category toggles were restricted to
// platforms that were not the only ones drawing them — Windows builds both, from
// these very keys — so the honest fix was to widen the declaration rather than
// to explain a divergence that did not exist.
//
// This is now a HARD ZERO, not a ratchet with room in it. A new row hidden from
// a platform its menu is visible on fails this gate until it states its reason;
// the user of that driver can otherwise not tell "not supported here" from
// "forgotten".
const UNREASONED_BASELINE = 0;

if (process.argv.includes('--list-unreasoned')) {
	for (const u of unreasoned) console.log('  ' + u);
}
if (unreasoned.length > UNREASONED_BASELINE) {
	errors.push(
		`${unreasoned.length} row(s) are hidden from a platform their menu is visible on, with no ` +
			`reason_key (baseline ${UNREASONED_BASELINE}). The user of that driver cannot tell "not ` +
			`implemented here" from "removed":\n      ` +
			unreasoned.slice(UNREASONED_BASELINE).join('\n      ')
	);
}
if (unreasoned.length < UNREASONED_BASELINE) {
	errors.push(
		`only ${unreasoned.length} unreasoned hidden row(s) remain (baseline ${UNREASONED_BASELINE}) — ` +
			'lower the baseline in this file to lock the improvement in.'
	);
}

// ==================================================
// ==================================================
// ======= 7/ The drivers render it, not retype it ==
// ==================================================
// ==================================================

// The point of a manifest is that the menu exists once. Both Lua drivers bind
// the same shared renderer through infra/manifest_menu, so the number of menu
// keys each one passes to it is a direct measure of how much of its menu is
// still hand-built. Windows is excluded: its AHK loader exposes one function per
// key (MenuManifest_LoadDebugMenu and friends) instead of taking the key as an
// argument, so the same count would mean something different there.
// linux raised 4 → 5 on 2026-08-05: the shortcuts submenu now dispatches through
// the renderer. That is what let `extensions_shortcuts` lose its platforms =
// ["ahk"] restriction — the manifest had refused to promise a row to a menu that
// could not answer by id, and both Lua drivers had implemented the row for
// months while the manifest said neither had the concept.
// linux raised 5 → 7 on 2026-08-05: the kanata and updates submenus became the
// first blocks of menu_builder.lua whose rows the renderer MATERIALISES, through
// `list` providers. Routing a menu through the renderer and moving its rows out of the
// driver are two different things, and only the second one moves the bypass
// ratchet — this number counts the first.
// linux raised 8 → 9 on 2026-08-06: the debug submenu. It had never read the
// manifest at all — it wrote out three rows while the manifest declared five for
// this platform, so `open_today_log` and `open_error_log` were described, offered
// on the other two drivers and translated in all 21 locales, and simply absent
// here. A driver that does not READ a manifest section cannot notice a row it
// fails to build, which is why "is this menu on the renderer" is worth counting
// separately from "how many of its rows the renderer materialises".
// hs raised 4 → 5 on 2026-08-06: the Karabiner submenu, the largest hand-built
// menu in the project at thirty-six rows and the last one with NOTHING in the
// manifest describing it. Its shape is declared now — process control, the
// destructive resets, the timings, then tap-holds and chords under headers of
// their own — which is also the split the maintainer asked for: the two families
// used to run together under one heading.
// hs raised 5 → 6: the keyboard-layout menu. It renders the manifest's own
// rows now — the section header, its separators, and the active-layouts list
// that was declared for macOS and answered by nobody.
// hs raised 6 → 7: the LLM menu. Its two declared rows — the model picker and
// the generation settings — were built in place, and the separator the manifest
// puts between them was written out by hand as well.
// linux raised 9 → 10 on 2026-08-06: the global-actions submenu. Its three rows
// AND the separator between them were written out by each driver — macOS through
// a chain of `elseif` mapping id → label → action, which was the manifest's own
// table restated in a third language. macOS raised 7 → 8 in the same change,
// for the same menu.
// hs 8 → 9 on 2026-08-07: the hotstrings submenu. It was the last macOS menu
// that read the manifest for nothing at all — the drift gate in
// tests/meta/test_menu_hotstrings_layout_drift_gate.lua exists solely because
// this menu and its declaration could disagree with nothing comparing them.
// hs 9 → 10, linux 10 → 11 on 2026-08-07: the language selector. Three drivers
// listed the same twenty-one locales from the same shared catalogue into a menu
// nothing described.
// hs 10 → 11, linux 11 → 12 on 2026-08-07: the Applications submenu, which had
// no declaration at all and holds different things on the two drivers that have
// it — said out loud now, with the reason attached.
// linux 12 → 13 on 2026-08-07: the layout submenu, the last one this driver did
// not read the manifest for. Its rows came from two names written into the
// builder while the decoder already owned the list.
// hs 11 → 12, linux 13 → 14 on 2026-08-07: the About submenu, which the three
// drivers assembled independently and none declared.
// hs 12 → 13 on 2026-08-07: the debug submenu. It iterated the manifest's own
// debug_menu array and then wrote the label for each id by hand, in a chain of
// `elseif` — so the declaration decided the order and this driver decided
// everything else. Linux has rendered it since 2026-08-06 and Windows since this
// morning; macOS was the last of the three to still spell it out.
// linux 14 → 13, and no loss: its Applications submenu is gone. It held one
// row, the config folder, which moved to the Configuration submenu the three
// drivers render (global_actions became configuration_menu on all of them).
// linux 13 → 12 in 2026-09: the Updates submenu folded into About (about_menu
// renders the same rows on all three drivers), so one menu key went away
// without any row leaving the renderer.
// hs 14 → 15: the « Combinaisons de touches » group under Shortcuts
// (key_combinations_group) renders the Karabiner chords through the renderer.
// hs 15 → 16, linux 13 → 14: « Raccourcis de gestion du script »
// (script_control_group), the script chords the three drivers share.
// hs 16 → 17: every ordered pair reads key_combination_pair_menu; only its
// native slot picker data stays in the driver.
// Explicit hotstring category commands and section lists now have one shared head.
// The three Word Expander controls now share one declared child menu.
// The common AI Info Bar check delegates to a shared display child menu.
// Linux 19 → 20: navigation and validation now use their declared list providers.
const RENDERED_THROUGH_SHARED = { hs: 22, linux: 20 };

const DRIVER_ROOTS = {
	hs: path.join(SP, 'macos'),
	linux: path.join(SP, 'linux')
};

/**
 * The whole Lua source of a driver, concatenated, tests excluded.
 * @param {string} root Absolute path to the driver tree.
 * @returns {string}
 */
function driverSource(root) {
	let out = '';
	const sources = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (entry.name === 'tests' || entry.name === '_generated') continue;
				walk(full);
			} else if (entry.name.endsWith('.lua')) {
				const src = fs.readFileSync(full, 'utf8');
				out += src;
				sources.push({ rel: path.relative(root, full), src });
			}
		}
	};
	walk(root);
	return {
		src: out,
		delegated: delegatedMenuSources(sources, path.join(SP, '_shared', 'lua'))
	};
}

/** Resolve only the actual read-only number-row provider's shared getter owner. */
function numberRowGetterSource(source) {
	const { scriptTokens } = require('../lib/script-source.cjs');
	const contains = (text, expected) => {
		const tokens = scriptTokens(text, '.lua').map((token) => `${token.kind}:${token.value}`);
		return tokens.some((_, index) =>
			expected.every((value, offset) => tokens[index + offset] === value)
		);
	};
	if (
		!contains(source, [
			'identifier:local',
			'identifier:NumberRowPolicy',
			'symbol:=',
			'identifier:require',
			'symbol:(',
			'string:layout.number_row_policy',
			'symbol:)'
		]) ||
		!contains(source, [
			'identifier:NumberRowPolicy',
			'symbol:.',
			'identifier:native_rows',
			'symbol:(',
			'identifier:ManifestMenu',
			'symbol:,',
			'identifier:render_ctx',
			'symbol:.',
			'identifier:commands',
			'symbol:)'
		])
	)
		return '';
	if (
		!contains(source, [
			'identifier:render_ctx',
			'symbol:.',
			'identifier:commands',
			'symbol:[',
			'string:number_row_mode',
			'symbol:]',
			'symbol:=',
			'identifier:function',
			'symbol:(',
			'symbol:)',
			'identifier:return',
			'identifier:false',
			'identifier:end'
		])
	)
		return '';
	const sharedSource = fs.readFileSync(
		path.join(SP, '_shared/lua/layout/number_row_policy.lua'),
		'utf8'
	);
	if (
		!contains(sharedSource, [
			'identifier:function',
			'identifier:M',
			'symbol:.',
			'identifier:native_rows',
			'symbol:(',
			'identifier:renderer',
			'symbol:,',
			'identifier:commands',
			'symbol:)'
		]) ||
		!contains(sharedSource, [
			'identifier:renderer',
			'symbol:.',
			'identifier:choice_row',
			'symbol:(',
			'string:number_row_policy_rows',
			'symbol:,',
			'string:number_row_mode',
			'symbol:,',
			'identifier:commands',
			'symbol:,'
		]) ||
		!contains(sharedSource, [
			'symbol:[',
			'string:layout.direct_access_digits',
			'symbol:]',
			'symbol:=',
			'identifier:function',
			'symbol:(',
			'symbol:)',
			'identifier:return',
			'string:native',
			'identifier:end'
		])
	)
		return '';
	return sharedSource;
}

// Independent literal controls pin the new dependency boundary without changing
// any existing getter checks or menu floors. Comments and quoted code are inert.
{
	const assert = require('node:assert/strict');
	const binding = 'local NumberRowPolicy = require("layout.number_row_policy")';
	const call = 'NumberRowPolicy.native_rows(ManifestMenu, render_ctx.commands)';
	const command = 'render_ctx.commands["number_row_mode"] = function() return false end';
	assert(
		numberRowGetterSource(binding + '\n' + command + '\n' + call).includes(
			'layout.direct_access_digits'
		)
	);
	for (const source of [
		binding,
		call,
		binding + '\n' + call,
		binding + '\n' + command.replace('return false', 'return true') + '\n' + call,
		binding + '\n' + command + '\n' + call.replace('render_ctx.commands', 'other_commands'),
		'-- ' + binding + '\n' + call,
		binding + '\n-- ' + call,
		'local x = [[' + binding + '\n' + call + ']]',
		binding.replace('number_row_policy', 'other_policy') + '\n' + call,
		binding + '\n' + call.replace('ManifestMenu', 'OtherRenderer')
	]) {
		assert.equal(
			numberRowGetterSource(source),
			'',
			'a missing actual shared port cannot borrow its getter'
		);
	}
}

const renderedCounts = {};
for (const [driver, root] of Object.entries(DRIVER_ROOTS)) {
	const { src, delegated } = driverSource(root);
	const keys = new Set([...src.matchAll(/ManifestMenu\.build\(\s*"([a-z_]+)"/g)].map((m) => m[1]));
	// This parent now completes admitted canonical DATA without invoking Build.
	const languageFile = driver === 'hs' ? 'ui/menu/builder.lua' : 'ui/menu/menu_builder.lua';
	if (languageParentSource(fs.readFileSync(path.join(root, languageFile), 'utf8'), driver))
		keys.add('language_menu');
	renderedCounts[driver] = keys.size;

	// A disabled_when / checked_when key with no getter is not a row that stays
	// enabled: resolve_*_when logs an ERROR and returns the SAFE value, so the row
	// silently greys out or silently never ticks. macOS was missing all three
	// metrics_filter_* getters on 2026-08-04 — it read `state.…` inline instead, so
	// the manifest's checked_when was a second declaration nothing consulted, and
	// Linux resolved the same three through the manifest. Two drivers, two answers
	// to where the truth lives, which is the one thing a manifest exists to prevent.
	const needed = new Set();
	for (const menuKey of MENU_KEYS) {
		for (const row of manifest[menuKey]) {
			if (!visibleOn(row, driver)) continue;
			for (const field of ['disabled_when', 'checked_when']) {
				if (Array.isArray(row[field])) for (const key of row[field]) needed.add(key);
			}
			// A choice row ticks the value its driver answers under the feature path.
			if (row.type === 'choice' && typeof row.path === 'string') needed.add(row.path);
		}
	}
	const getterSource =
		src + numberRowGetterSource(src) + delegated.map((source) => source.src).join('\n');
	const absent = [...needed].filter((key) => !getterSource.includes(key));
	if (absent.length > 0) {
		errors.push(
			`${DRIVER_OF[driver]} names no getter for ${absent.length} state key(s) the manifest requires ` +
				`for rows it renders: ${absent.join(', ')}. The resolver logs an error and falls back, so ` +
				'the row is wrong in the menu and right in the manifest.'
		);
	}
	const floor = RENDERED_THROUGH_SHARED[driver];
	if (keys.size < floor) {
		errors.push(
			`${DRIVER_OF[driver]} renders ${keys.size} menu(s) through the shared renderer, down from ` +
				`${floor}. A menu that stops going through the manifest is a menu that starts drifting from ` +
				`the other two. Rendered: ${[...keys].sort().join(', ') || '(none)'}.`
		);
	}
	if (keys.size > floor) {
		errors.push(
			`${DRIVER_OF[driver]} now renders ${keys.size} menu(s) through the shared renderer (baseline ` +
				`${floor}) — raise the baseline in this file so the gain cannot be lost again. Rendered: ` +
				`${[...keys].sort().join(', ')}.`
		);
	}
}

// Startup is an installation action on every driver, immediately above removal.
// Pin its unique shared declaration so neither Configuration nor a native builder
// can silently restore the previous placement.
for (const platform of PLATFORMS) {
	const about = project('about_menu', platform);
	const startup = about[about.length - 2];
	const uninstall = about[about.length - 1];
	if (
		startup?.id !== 'start_at_login' ||
		startup.type !== 'check' ||
		startup.i18n !== 'menu.global.start_at_login' ||
		JSON.stringify(startup.checked_when) !== JSON.stringify(['start_at_login_enabled']) ||
		uninstall?.id !== 'uninstall' ||
		!isSeparator(about[about.length - 3])
	) {
		errors.push(
			`${DRIVER_OF[platform]} must draw the native startup check immediately above Uninstall.`
		);
	}
	const owners = MENU_KEYS.filter((key) =>
		project(key, platform).some((row) => row.id === 'start_at_login')
	);
	if (owners.length !== 1 || owners[0] !== 'about_menu') {
		errors.push(
			`${DRIVER_OF[platform]} startup must appear once, in Updates: ${owners.join(', ') || '(absent)'}.`
		);
	}
}

// ==================================================
// The actual Linux root retains both canonical header frames through final rendering.
{
	const assert = require('node:assert/strict');
	const headerRoot =
		require('../lib/menu-native-llm-parent-binding.cjs').declaredLinuxTopLevelPublication;
	const headerSource = fs.readFileSync(path.join(SP, 'linux/ui/menu/menu_builder.lua'), 'utf8');
	assert.equal(headerRoot(headerSource), true, 'actual complete shared header root is admitted');
	for (const [before, after, reason] of [
		[
			'local header_template = type(ManifestMenu) == "table" and rawget(ManifestMenu, "template_rows")',
			'local header_template = Foreign.template_rows',
			'foreign header projection owner'
		],
		[
			'local header_command = type(ManifestMenu) == "table" and rawget(ManifestMenu, "command_row")',
			'local header_command = Foreign.command_row',
			'foreign header command owner'
		],
		[
			'local header, header_current = _build_header(ctx)',
			'local header, header_current = Foreign.header(ctx)',
			'disconnected actual header consumer'
		],
		[
			'if not header or type(header_current) ~= "function" or not header_current() then return {} end',
			'if false then return {} end',
			'withdrawn initial header receipt'
		],
		[
			'or not header_current() then return {} end\n\treturn rendered',
			'then return {} end\n\treturn rendered',
			'withdrawn post-render header receipt'
		],
		[
			'local function header_facade_current()',
			'local function header_facade_current() local header_template = Foreign.template_rows',
			'shadowed actual header function'
		],
		[
			'local function _build_header(ctx)',
			'local function _build_header(ctx) header_template, Foreign.slot = function() return {} end, nil',
			'complex header-owner rebind'
		],
		[
			'local function _build_header(ctx)',
			'local function _build_header(ctx) local ignored, header_command',
			'bare comma header-owner shadow'
		]
	]) {
		assert.equal(headerSource.split(before).length - 1, 1, reason + ': unique actual coordinate');
		assert.equal(
			headerRoot(headerSource.replace(before, after)),
			false,
			reason + ': genuine source refuses'
		);
		assert.equal(headerRoot(headerSource), true, reason + ': genuine inverse remains admitted');
	}
}

// ==================================================
// ======= 8/ Report ================================
// ==================================================
// ==================================================

if (process.argv.includes('--measure')) {
	console.log(`menus: ${MENU_KEYS.length}`);
	for (const menuKey of MENU_KEYS) {
		const counts = PLATFORMS.map((p) => `${p}=${project(menuKey, p).length}`).join(' ');
		console.log(
			`  ${menuKey.padEnd(24)} ${counts}   reachable on: ${(reachableOn[menuKey] || []).join(',')}`
		);
	}
	console.log(`unreasoned hidden rows: ${unreasoned.length}`);
	console.log(`rendered through the shared renderer: ${JSON.stringify(renderedCounts)}`);
	process.exit(0);
}

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] the three menus differ in ways the manifest does not declare:\x1b[0m'
	);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] menu parity — ${MENU_KEYS.length} menus, ${comparedRows} row(s) projected for Windows; ` +
		`every submenu reachable and non-empty where its parent is visible, no orphaned header, no row ` +
		`duplicated under one identity, ${namedKeys.length} label key(s) resolved in ${localeFiles.length} ` +
		`locales, every disabled_when/checked_when getter present; ` +
		`${unreasoned.length} hidden row(s) still unreasoned (baseline ${UNREASONED_BASELINE}); shared ` +
		`renderer covers macOS ${renderedCounts.hs}, Linux ${renderedCounts.linux} menu(s).\x1b[0m`
);

// Static projection selects the same direct declaration as the actual template include.
{
	const assert = require('node:assert/strict');
	const names = ['__selected_frame_probe', '__selected_commands_probe'];
	for (const key of names) assert(!Object.hasOwn(manifest, key));
	manifest[names[0]] = [{ type: 'include', section: names[1], row_id: 'clone' }];
	manifest[names[1]] = [
		{ type: 'command', id: 'create', i18n: 'menu.profiles.create_profile' },
		{
			type: 'command',
			id: 'clone',
			i18n: 'menu.profiles.clone_builtin',
			platforms: ['hs']
		}
	];
	try {
		assert.deepEqual(
			project(names[0], 'hs').map((row) => row.id),
			['clone']
		);
		assert.deepEqual(project(names[0], 'ahk'), []);
		assert.deepEqual(project(names[0], 'linux'), []);
		for (const selector of ['', false, 'missing', 'Clone']) {
			manifest[names[0]][0].row_id = selector;
			assert.throws(() => project(names[0], 'hs'), /invalid direct menu row selector/);
		}
		manifest[names[0]][0].row_id = 'clone';
		manifest[names[1]][0].id = 'clone';
		assert.throws(() => project(names[0], 'hs'), /invalid direct menu row selector/);
		manifest[names[1]][0].id = 'create';
		delete manifest[names[0]][0].row_id;
		assert.deepEqual(
			project(names[0], 'hs').map((row) => row.id),
			['create', 'clone']
		);
	} finally {
		for (const key of names) delete manifest[key];
	}
}

/** Counts only the actual completed Language child route inside its physical native owner. */
function languageParentSource(source, driver) {
	const assert = require('node:assert/strict');
	function ownerBody(source, signature) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(signature, '.lua');
		const bodies = [];
		for (let start = 0; start < tokens.length; start++) {
			if (
				source
					.slice(source.lastIndexOf('\n', tokens[start].start - 1) + 1, tokens[start].start)
					.trim()
			)
				continue;
			if (
				!wanted.every(
					(token, offset) =>
						tokens[start + offset]?.kind === token.kind &&
						tokens[start + offset]?.value === token.value
				)
			)
				continue;
			// String identity is the physical simple Lua spelling, not an undecoded alias.
			if (
				!wanted.every(
					(token, offset) =>
						token.kind !== 'string' ||
						source.slice(tokens[start + offset].start, tokens[start + offset].end) ===
							signature.slice(token.start, token.end)
				)
			)
				continue;
			const blocks = ['function'];
			let awaitingDo = 0;
			for (let index = start + wanted.length; index < tokens.length; index++) {
				const token = tokens[index];
				if (token.kind !== 'identifier' || ['.', ':'].includes(tokens[index - 1]?.value)) continue;
				if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
					blocks.push(token.value);
					if (['for', 'while'].includes(token.value)) awaitingDo++;
				} else if (token.value === 'do') {
					if (awaitingDo) awaitingDo--;
					else blocks.push('do');
				} else if (token.value === 'end' || token.value === 'until') {
					if (token.value === 'until' && blocks.at(-1) !== 'repeat')
						throw new Error('invalid actual Lua owner');
					blocks.pop();
					if (!blocks.length) {
						bodies.push(source.slice(tokens[start + wanted.length - 1].end, token.start));
						break;
					}
				}
			}
		}
		assert.equal(bodies.length, 1, 'one complete physical native Language owner');
		return bodies[0];
	}
	function hasStatement(source, statement, requiredDepth = 0) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(statement, '.lua');
		let depth = 0,
			awaitingDo = 0;
		const depths = tokens.map((token, index) => {
			const before = depth;
			if (token.kind !== 'identifier' || ['.', ':'].includes(tokens[index - 1]?.value))
				return before;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
			return before;
		});
		return tokens.some(
			(first, index) =>
				depths[index] === requiredDepth &&
				!['.', ':', 'function'].includes(tokens[index - 1]?.value) &&
				wanted.every((token, offset) => {
					const actual = tokens[index + offset];
					return (
						actual?.kind === token.kind &&
						actual.value === token.value &&
						(token.kind !== 'string' ||
							source.slice(actual.start, actual.end) === statement.slice(token.start, token.end))
					);
				})
		);
	}
	const native = [
		[
			'macos/ui/menu/builder.lua',
			'["language"] = function()',
			[
				'if type(i18n.build_language_menu_items) ~= "function" then return {} end',
				'local ok_locales, locales = pcall(i18n.build_language_menu_items)',
				'if not ok_locales then return {} end',
				'local admitted = ManifestMenu.template_rows("language_menu", {}, {}, {',
				'["locales"] = function() return locales end',
				'if not admitted then return {} end',
				'local rendered = ManifestMenu.render_rows(admitted, "language_menu")',
				'local parent = ManifestMenu.group_row("top_level", "language", rendered, {})',
				'return parent and { parent } or {}'
			]
		],
		[
			'linux/ui/menu/menu_builder.lua',
			'local function _build_language(ctx)',
			[
				'local locales = i18n.list_locales()',
				'ManifestMenu.template_rows("language_menu", {}, {}, {',
				'["locales"] = function() return items end',
				'if not admitted then return nil end',
				'local rows = ManifestMenu.render_rows(admitted, "language_menu")',
				'return ManifestMenu.group_row("top_level", "language", rows, {})'
			]
		]
	];

	const index = driver === 'hs' ? 0 : driver === 'linux' ? 1 : -1;
	if (index < 0) return false;
	const [, signature, statements] = native[index];
	try {
		const body = ownerBody(source, signature);
		return statements.every((statement) =>
			hasStatement(
				body,
				statement,
				driver === 'linux' && statement === 'local locales = i18n.list_locales()' ? 1 : 0
			)
		);
	} catch {
		return false;
	}
}

// Actual native bodies provide the positive and unchanged foreign/data/unused-owner controls.
{
	const assert = require('node:assert/strict');
	for (const [driver, file] of [
		['hs', 'macos/ui/menu/builder.lua'],
		['linux', 'linux/ui/menu/menu_builder.lua']
	]) {
		const source = fs.readFileSync(path.join(SP, file), 'utf8');
		assert(
			languageParentSource(source, driver),
			'the actual new Language route has genuine renderer ownership'
		);
		for (const method of ['template_rows', 'render_rows', 'group_row']) {
			const prefix = 'ManifestMenu.' + method;
			const actual = source.indexOf(
				prefix,
				source.indexOf(driver === 'hs' ? '["language"]' : 'local function _build_language(ctx)')
			);
			assert(actual >= 0);
			const foreign = source.slice(0, actual) + 'Foreign.' + source.slice(actual);
			assert.equal(
				languageParentSource(foreign, driver),
				false,
				'foreign receiver cannot lend shared renderer coverage'
			);
			const withdrawn =
				source.slice(0, actual) + 'Withdrawn.' + source.slice(actual + 'ManifestMenu.'.length);
			const loan =
				withdrawn +
				'\nlocal function unused_language_owner()\n' +
				prefix +
				'("language_menu")\nend\n';
			assert.equal(
				languageParentSource(loan, driver),
				false,
				'unused neighbor cannot lend actual Language ownership'
			);
		}
		assert.equal(
			languageParentSource(JSON.stringify(source), driver),
			false,
			'quoted native source is no route'
		);
		assert.equal(
			languageParentSource(
				source
					.split('\n')
					.map((line) => '-- ' + line)
					.join('\n'),
				driver
			),
			false,
			'commented native source is no route'
		);
	}
}

// Debug keeps the real choice renderer, with source-presence admission around the completed child.
(function checkDeclaredDebugParents() {
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const fs = require('node:fs');
	const path = require('node:path');
	const base = path.resolve(__dirname, '../..', 'static/ergopti_plus');
	const menu = JSON.parse(
		fs.readFileSync(path.join(base, '_shared/modules/menu/menu_manifest.json'), 'utf8')
	);
	assert.deepEqual(
		menu.top_level.filter((row) => row.id === 'debug'),
		[{ type: 'group', id: 'debug', i18n: 'menu.debug.title', rows: [] }]
	);
	const hand = JSON.parse(
		fs.readFileSync(path.join(base, '_shared/tests/corpus/menus/debug_parent.json'), 'utf8')
	);
	for (const code of ['en', 'fr']) {
		const locale = JSON.parse(
			fs.readFileSync(path.join(base, '_shared/data/locales', code + '.json'), 'utf8')
		);
		assert.equal(hand[code].parent, locale['menu.debug.title']);
		assert.equal(hand[code].linux[0], locale['menu.debug.log_level'] + ' : ℹ️ INFO');
		assert.equal(hand[code].hs[2], hand[code].linux[0]);
	}
	function tokenDepths(tokens) {
		let depth = 0,
			awaitingDo = 0;
		return tokens.map((token, index) => {
			const before = depth;
			if (
				token.kind !== 'identifier' ||
				(['.', ':'].includes(tokens[index - 1]?.value) &&
					!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
			)
				return before;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
			return before;
		});
	}
	function ownerBody(source, signature) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(signature, '.lua');
		const sourceDepths = tokenDepths(tokens);
		const bodies = [];
		for (let start = 0; start < tokens.length; start++) {
			if (sourceDepths[start] !== 0) continue;
			if (
				source
					.slice(source.lastIndexOf('\n', tokens[start].start - 1) + 1, tokens[start].start)
					.trim()
			)
				continue;
			if (
				!wanted.every(
					(token, offset) =>
						tokens[start + offset]?.kind === token.kind &&
						tokens[start + offset]?.value === token.value
				)
			)
				continue;
			// String identity is the physical simple Lua spelling, not an undecoded alias.
			if (
				!wanted.every(
					(token, offset) =>
						token.kind !== 'string' ||
						source.slice(tokens[start + offset].start, tokens[start + offset].end) ===
							signature.slice(token.start, token.end)
				)
			)
				continue;
			const blocks = ['function'];
			let awaitingDo = 0;
			for (let index = start + wanted.length; index < tokens.length; index++) {
				const token = tokens[index];
				if (
					token.kind !== 'identifier' ||
					(['.', ':'].includes(tokens[index - 1]?.value) &&
						!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
				)
					continue;
				if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
					blocks.push(token.value);
					if (['for', 'while'].includes(token.value)) awaitingDo++;
				} else if (token.value === 'do') {
					if (awaitingDo) awaitingDo--;
					else blocks.push('do');
				} else if (token.value === 'end' || token.value === 'until') {
					if (token.value === 'until' && blocks.at(-1) !== 'repeat')
						throw new Error('invalid actual Lua owner');
					blocks.pop();
					if (!blocks.length) {
						bodies.push(source.slice(tokens[start + wanted.length - 1].end, token.start));
						break;
					}
				}
			}
		}
		assert.equal(bodies.length, 1, 'one complete physical native Debug owner');
		return bodies[0];
	}
	function hasStatement(source, statement, requiredDepth = 0) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(statement, '.lua');
		let depth = 0,
			awaitingDo = 0;
		const depths = tokens.map((token, index) => {
			const before = depth;
			if (
				token.kind !== 'identifier' ||
				(['.', ':'].includes(tokens[index - 1]?.value) &&
					!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
			)
				return before;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
			return before;
		});
		return tokens.some(
			(first, index) =>
				depths[index] === requiredDepth &&
				!['.', ':', 'function'].includes(tokens[index - 1]?.value) &&
				wanted.every((token, offset) => {
					const actual = tokens[index + offset];
					return (
						actual?.kind === token.kind &&
						actual.value === token.value &&
						(token.kind !== 'string' ||
							source.slice(actual.start, actual.end) === statement.slice(token.start, token.end))
					);
				})
		);
	}
	for (const [driver, file, signature, child, finish] of [
		[
			'hs',
			'macos/ui/menu/builder.lua',
			'["debug"] = function()',
			'debug_items',
			'local row = ManifestMenu.group_row("top_level", "debug", debug_items, dbg_ctx.state_getters)'
		],
		[
			'linux',
			'linux/ui/menu/menu_builder.lua',
			'local function _build_debug(ctx)',
			'rows',
			'return ManifestMenu.group_row("top_level", "debug", rows, render_ctx.state_getters)'
		]
	]) {
		const source = fs.readFileSync(path.join(base, file), 'utf8');
		const outer =
			driver === 'hs' ? ownerBody(source, 'function M.generate(ctx, menu_mods, actions)') : source;
		const native = ownerBody(outer, signature);
		const context = driver === 'hs' ? 'dbg_ctx' : 'render_ctx';
		const refused = driver === 'hs' ? '{}' : 'nil';
		const chronology = [
			`local root, top, section, parent, fields = debug_source(ManifestMenu, "${driver}")`,
			`if root == nil then return ${refused} end`,
			`local ${child} = ManifestMenu.build("debug_menu", "Debug", nil, nil, ${context}, {})`,
			`if not debug_dense(${child}, true) then return ${refused} end`,
			`local current_root, current_top, current_section, current_parent = debug_source(ManifestMenu, "${driver}")`,
			`if not rawequal(root, current_root) or not rawequal(top, current_top) or not rawequal(section, current_section) or not rawequal(parent, current_parent) or not debug_parent_unchanged(parent, fields) then return ${refused} end`,
			finish
		];
		const tokens = scriptTokens(native, '.lua'),
			depths = tokenDepths(tokens);
		let previous = -1;
		for (const statement of chronology) {
			const wanted = scriptTokens(statement, '.lua');
			const at = tokens.findIndex(
				(_, index) =>
					index > previous &&
					depths[index] === 0 &&
					wanted.every(
						(token, offset) =>
							tokens[index + offset]?.kind === token.kind &&
							tokens[index + offset]?.value === token.value
					)
			);
			assert(at >= 0, 'actual source/child/recheck/parent chronology');
			previous = at;
		}
		for (const statement of chronology) {
			assert(
				hasStatement(native, statement),
				file + ': actual Debug source/choice/finished-child owner ' + statement
			);
			assert(
				!hasStatement('if false then\n' + native + '\nend', statement),
				'conditional data is not the native owner'
			);
			assert(!hasStatement(JSON.stringify(statement), statement), 'quoted native route refused');
			assert(!hasStatement('-- ' + statement, statement), 'commented route refused');
			if (statement.includes('ManifestMenu.')) {
				const changed = native.replace(
					statement,
					statement.replace('ManifestMenu.', 'Foreign.ManifestMenu.')
				);
				assert(!hasStatement(changed, statement), 'foreign renderer cannot own Debug');
			}
		}
		for (const [name, statements] of [
			[
				'debug_source',
				[
					'local root = renderer.get_root()',
					'local top, children = rawget(root, "top_level"), rawget(root, "debug_menu")',
					'if not debug_dense(top, true) or not debug_dense(children, true) then return nil end',
					'local fields = {}',
					'return root, top, children, parent, fields'
				]
			],
			[
				'debug_dense',
				[
					'if type(value) ~= "table" or getmetatable(value) ~= nil then return false end',
					'return count == maximum'
				]
			],
			['debug_parent_unchanged', ['return true']]
		]) {
			const definition =
				name === 'debug_source'
					? 'local function debug_source(renderer, platform)'
					: name === 'debug_dense'
						? 'local function debug_dense(value, records)'
						: 'local function debug_parent_unchanged(parent, fields)';
			const actual = ownerBody(source, definition);
			assert.throws(
				() => ownerBody('if false then\n' + source + '\nend', definition),
				/physical native Debug owner/
			);
			for (const statement of statements)
				assert(hasStatement(actual, statement), 'actual raw structural helper ' + statement);
			assert.throws(
				() => ownerBody(source.replace(definition, '-- ' + definition), definition),
				/physical native Debug owner/
			);
			assert.throws(
				() => ownerBody(source + '\n' + definition + '\nend\n', definition),
				/physical native Debug owner/
			);
		}
		const withdrawn =
			source.replace(finish, 'return nil') +
			'\nlocal function unused_debug_owner()\n' +
			finish +
			'\nend\n';
		assert(
			!hasStatement(
				ownerBody(
					driver === 'hs'
						? ownerBody(withdrawn, 'function M.generate(ctx, menu_mods, actions)')
						: withdrawn,
					signature
				),
				finish
			),
			'unused function cannot lend parent publication'
		);
		const physicalSignature =
			driver === 'hs'
				? source.match(/^\s*\["debug"\]\s*=\s*function\(\)/m)[0].trimStart()
				: signature;
		assert.throws(
			() =>
				ownerBody(
					driver === 'hs'
						? ownerBody(
								source.replace(physicalSignature, '-- ' + physicalSignature),
								'function M.generate(ctx, menu_mods, actions)'
							)
						: source.replace(physicalSignature, '-- ' + physicalSignature),
					signature
				),
			/physical native Debug owner/
		);
	}
	console.log(
		'[OK] Debug: unique typed parent, actual structural admission and retained full-choice native routes.'
	);
})();
// Configuration keeps the real command renderer, with source-presence admission around the completed child.
(function checkDeclaredConfigurationParents() {
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const fs = require('node:fs');
	const path = require('node:path');
	const base = path.resolve(__dirname, '../..', 'static/ergopti_plus');
	const menu = JSON.parse(
		fs.readFileSync(path.join(base, '_shared/modules/menu/menu_manifest.json'), 'utf8')
	);
	assert.deepEqual(
		menu.top_level.filter((row) => row.id === 'configuration'),
		[
			{
				type: 'group',
				id: 'configuration',
				i18n: 'menu.configuration.title',
				rows: []
			}
		]
	);
	const hand = JSON.parse(
		fs.readFileSync(path.join(base, '_shared/tests/corpus/menus/configuration_parent.json'), 'utf8')
	);
	for (const code of ['en', 'fr']) {
		const locale = JSON.parse(
			fs.readFileSync(path.join(base, '_shared/data/locales', code + '.json'), 'utf8')
		);
		assert.equal(hand[code].parent, locale['menu.configuration.title']);
		assert.deepEqual(hand[code].children, [
			locale['common.restore_recommended'],
			locale['common.clear_to_system'],
			'-',
			locale['menu.global.clean_unused_keys'],
			'-',
			locale['menu.global.config_folder'],
			locale['menu.global.setup_wizard']
		]);
	}
	function tokenDepths(tokens) {
		let depth = 0,
			awaitingDo = 0;
		return tokens.map((token, index) => {
			const before = depth;
			if (
				token.kind !== 'identifier' ||
				(['.', ':'].includes(tokens[index - 1]?.value) &&
					!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
			)
				return before;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
			return before;
		});
	}
	function ownerBody(source, signature) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(signature, '.lua');
		const sourceDepths = tokenDepths(tokens);
		const bodies = [];
		for (let start = 0; start < tokens.length; start++) {
			if (sourceDepths[start] !== 0) continue;
			if (
				source
					.slice(source.lastIndexOf('\n', tokens[start].start - 1) + 1, tokens[start].start)
					.trim()
			)
				continue;
			if (
				!wanted.every(
					(token, offset) =>
						tokens[start + offset]?.kind === token.kind &&
						tokens[start + offset]?.value === token.value
				)
			)
				continue;
			// String identity is the physical simple Lua spelling, not an undecoded alias.
			if (
				!wanted.every(
					(token, offset) =>
						token.kind !== 'string' ||
						source.slice(tokens[start + offset].start, tokens[start + offset].end) ===
							signature.slice(token.start, token.end)
				)
			)
				continue;
			const blocks = ['function'];
			let awaitingDo = 0;
			for (let index = start + wanted.length; index < tokens.length; index++) {
				const token = tokens[index];
				if (
					token.kind !== 'identifier' ||
					(['.', ':'].includes(tokens[index - 1]?.value) &&
						!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
				)
					continue;
				if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
					blocks.push(token.value);
					if (['for', 'while'].includes(token.value)) awaitingDo++;
				} else if (token.value === 'do') {
					if (awaitingDo) awaitingDo--;
					else blocks.push('do');
				} else if (token.value === 'end' || token.value === 'until') {
					if (token.value === 'until' && blocks.at(-1) !== 'repeat')
						throw new Error('invalid actual Lua owner');
					blocks.pop();
					if (!blocks.length) {
						bodies.push(source.slice(tokens[start + wanted.length - 1].end, token.start));
						break;
					}
				}
			}
		}
		assert.equal(bodies.length, 1, 'one complete physical native Configuration owner');
		return bodies[0];
	}
	function hasStatement(source, statement, requiredDepth = 0) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(statement, '.lua');
		let depth = 0,
			awaitingDo = 0;
		const depths = tokens.map((token, index) => {
			const before = depth;
			if (
				token.kind !== 'identifier' ||
				(['.', ':'].includes(tokens[index - 1]?.value) &&
					!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
			)
				return before;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
			return before;
		});
		return tokens.some(
			(first, index) =>
				depths[index] === requiredDepth &&
				!['.', ':', 'function'].includes(tokens[index - 1]?.value) &&
				wanted.every((token, offset) => {
					const actual = tokens[index + offset];
					return (
						actual?.kind === token.kind &&
						actual.value === token.value &&
						(token.kind !== 'string' ||
							source.slice(actual.start, actual.end) === statement.slice(token.start, token.end))
					);
				})
		);
	}
	for (const [driver, file, signature, child, finish] of [
		[
			'hs',
			'macos/ui/menu/builder.lua',
			'["configuration"] = function()',
			'rows',
			'local row = ManifestMenu.group_row("top_level", "configuration", rows, cfg_ctx.state_getters)'
		],
		[
			'linux',
			'linux/ui/menu/menu_builder.lua',
			'local function _build_configuration(ctx)',
			'rows',
			'return ManifestMenu.group_row("top_level", "configuration", rows, render_ctx.state_getters)'
		]
	]) {
		const source = fs.readFileSync(path.join(base, file), 'utf8');
		const outer =
			driver === 'hs' ? ownerBody(source, 'function M.generate(ctx, menu_mods, actions)') : source;
		const native = ownerBody(outer, signature);
		const context = driver === 'hs' ? 'cfg_ctx' : 'render_ctx';
		const refused = driver === 'hs' ? '{}' : 'nil';
		const chronology = [
			`local root, top, section, parent, fields = configuration_source(ManifestMenu, "${driver}")`,
			`if root == nil then return ${refused} end`,
			`local ${child} = ManifestMenu.build("configuration_menu", "Configuration", nil, nil, ${context})`,
			`if not configuration_dense(${child}, true) then return ${refused} end`,
			`local current_root, current_top, current_section, current_parent = configuration_source(ManifestMenu, "${driver}")`,
			`if not rawequal(root, current_root) or not rawequal(top, current_top) or not rawequal(section, current_section) or not rawequal(parent, current_parent) or not configuration_parent_unchanged(parent, fields) then return ${refused} end`,
			finish
		];
		const tokens = scriptTokens(native, '.lua'),
			depths = tokenDepths(tokens);
		let previous = -1;
		for (const statement of chronology) {
			const wanted = scriptTokens(statement, '.lua');
			const at = tokens.findIndex(
				(_, index) =>
					index > previous &&
					depths[index] === 0 &&
					wanted.every(
						(token, offset) =>
							tokens[index + offset]?.kind === token.kind &&
							tokens[index + offset]?.value === token.value
					)
			);
			assert(at >= 0, 'actual source/child/recheck/parent chronology');
			previous = at;
		}
		for (const statement of chronology) {
			assert(
				hasStatement(native, statement),
				file + ': actual Configuration source/choice/finished-child owner ' + statement
			);
			assert(
				!hasStatement('if false then\n' + native + '\nend', statement),
				'conditional data is not the native owner'
			);
			assert(!hasStatement(JSON.stringify(statement), statement), 'quoted native route refused');
			assert(!hasStatement('-- ' + statement, statement), 'commented route refused');
			if (statement.includes('ManifestMenu.')) {
				const changed = native.replace(
					statement,
					statement.replace('ManifestMenu.', 'Foreign.ManifestMenu.')
				);
				assert(!hasStatement(changed, statement), 'foreign renderer cannot own Configuration');
			}
		}
		for (const [name, statements] of [
			[
				'configuration_source',
				[
					'local root = renderer.get_root()',
					'local top, children = rawget(root, "top_level"), rawget(root, "configuration_menu")',
					'if not configuration_dense(top, true) or not configuration_dense(children, true) then return nil end',
					'local fields = {}',
					'return root, top, children, parent, fields'
				]
			],
			[
				'configuration_dense',
				[
					'if type(value) ~= "table" or getmetatable(value) ~= nil then return false end',
					'return count == maximum'
				]
			],
			['configuration_parent_unchanged', ['return true']]
		]) {
			const definition =
				name === 'configuration_source'
					? 'local function configuration_source(renderer, platform)'
					: name === 'configuration_dense'
						? 'local function configuration_dense(value, records)'
						: 'local function configuration_parent_unchanged(parent, fields)';
			const actual = ownerBody(source, definition);
			assert.throws(
				() => ownerBody('if false then\n' + source + '\nend', definition),
				/physical native Configuration owner/
			);
			for (const statement of statements)
				assert(hasStatement(actual, statement), 'actual raw structural helper ' + statement);
			assert.throws(
				() => ownerBody(source.replace(definition, '-- ' + definition), definition),
				/physical native Configuration owner/
			);
			assert.throws(
				() => ownerBody(source + '\n' + definition + '\nend\n', definition),
				/physical native Configuration owner/
			);
		}
		const withdrawn =
			source.replace(finish, 'return nil') +
			'\nlocal function unused_configuration_owner()\n' +
			finish +
			'\nend\n';
		assert(
			!hasStatement(
				ownerBody(
					driver === 'hs'
						? ownerBody(withdrawn, 'function M.generate(ctx, menu_mods, actions)')
						: withdrawn,
					signature
				),
				finish
			),
			'unused function cannot lend parent publication'
		);
		const physicalSignature =
			driver === 'hs'
				? source.match(/^\s*\["configuration"\]\s*=\s*function\(\)/m)[0].trimStart()
				: signature;
		assert.throws(
			() =>
				ownerBody(
					driver === 'hs'
						? ownerBody(
								source.replace(physicalSignature, '-- ' + physicalSignature),
								'function M.generate(ctx, menu_mods, actions)'
							)
						: source.replace(physicalSignature, '-- ' + physicalSignature),
					signature
				),
			/physical native Configuration owner/
		);
	}
	console.log(
		'[OK] Configuration: unique typed parent, actual structural admission and retained full-command native routes.'
	);
})();
// Metrics preserves the native lifecycle and completed children before canonical parent projection.
(function checkDeclaredMetricsParents() {
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const fs = require('node:fs');
	const path = require('node:path');
	const base = path.resolve(__dirname, '../..', 'static/ergopti_plus');
	const menu = JSON.parse(
		fs.readFileSync(path.join(base, '_shared/modules/menu/menu_manifest.json'), 'utf8')
	);
	assert.deepEqual(
		menu.top_level.filter((row) => row.id === 'metrics'),
		[
			{
				type: 'group',
				id: 'metrics',
				i18n: 'menu.metrics.title',
				rows: [],
				checked_when: ['keylogger_enabled'],
				greyed_when_paused: true
			}
		]
	);
	const hand = JSON.parse(
		fs.readFileSync(path.join(base, '_shared/tests/corpus/menus/metrics_parent.json'), 'utf8')
	);
	for (const code of ['en', 'fr']) {
		const locale = JSON.parse(
			fs.readFileSync(path.join(base, '_shared/data/locales', code + '.json'), 'utf8')
		);
		assert.equal(hand[code], locale['menu.metrics.title']);
	}
	function tokenDepths(tokens) {
		let depth = 0,
			awaitingDo = 0;
		return tokens.map((token, index) => {
			const before = depth;
			if (
				token.kind !== 'identifier' ||
				(['.', ':'].includes(tokens[index - 1]?.value) &&
					!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
			)
				return before;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
			return before;
		});
	}
	function ownerBody(source, signature) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(signature, '.lua');
		const sourceDepths = tokenDepths(tokens);
		const bodies = [];
		for (let start = 0; start < tokens.length; start++) {
			if (sourceDepths[start] !== 0) continue;
			if (
				source
					.slice(source.lastIndexOf('\n', tokens[start].start - 1) + 1, tokens[start].start)
					.trim()
			)
				continue;
			if (
				!wanted.every(
					(token, offset) =>
						tokens[start + offset]?.kind === token.kind &&
						tokens[start + offset]?.value === token.value
				)
			)
				continue;
			// String identity is the physical simple Lua spelling, not an undecoded alias.
			if (
				!wanted.every(
					(token, offset) =>
						token.kind !== 'string' ||
						source.slice(tokens[start + offset].start, tokens[start + offset].end) ===
							signature.slice(token.start, token.end)
				)
			)
				continue;
			const blocks = ['function'];
			let awaitingDo = 0;
			for (let index = start + wanted.length; index < tokens.length; index++) {
				const token = tokens[index];
				if (
					token.kind !== 'identifier' ||
					(['.', ':'].includes(tokens[index - 1]?.value) &&
						!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
				)
					continue;
				if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
					blocks.push(token.value);
					if (['for', 'while'].includes(token.value)) awaitingDo++;
				} else if (token.value === 'do') {
					if (awaitingDo) awaitingDo--;
					else blocks.push('do');
				} else if (token.value === 'end' || token.value === 'until') {
					if (token.value === 'until' && blocks.at(-1) !== 'repeat')
						throw new Error('invalid actual Lua owner');
					blocks.pop();
					if (!blocks.length) {
						bodies.push(source.slice(tokens[start + wanted.length - 1].end, token.start));
						break;
					}
				}
			}
		}
		assert.equal(bodies.length, 1, 'one complete physical native Metrics owner');
		return bodies[0];
	}
	function hasStatement(source, statement, requiredDepth = 0) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(statement, '.lua');
		let depth = 0,
			awaitingDo = 0;
		const depths = tokens.map((token, index) => {
			const before = depth;
			if (
				token.kind !== 'identifier' ||
				(['.', ':'].includes(tokens[index - 1]?.value) &&
					!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
			)
				return before;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
			return before;
		});
		return tokens.some(
			(first, index) =>
				depths[index] === requiredDepth &&
				!['.', ':', 'function'].includes(tokens[index - 1]?.value) &&
				wanted.every((token, offset) => {
					const actual = tokens[index + offset];
					return (
						actual?.kind === token.kind &&
						actual.value === token.value &&
						(token.kind !== 'string' ||
							source.slice(actual.start, actual.end) === statement.slice(token.start, token.end))
					);
				})
		);
	}
	for (const [driver, file, signature] of [
		['hs', 'macos/ui/menu/menu_metrics.lua', 'function M.build(ctx)'],
		['linux', 'linux/ui/menu/menu_builder.lua', 'local function _build_metrics(ctx)']
	]) {
		const source = fs.readFileSync(path.join(base, file), 'utf8');
		const native = ownerBody(source, signature);
		const checked =
			driver === 'hs' ? 'STATE_GETTERS' : '{ keylogger_enabled = function() return on end }';
		const child = driver === 'hs' ? 'menu' : 'items';
		const finish = `local projected = ManifestMenu.group_row("top_level", "metrics", ${child}, ${checked})`;
		const chronology = [
			`local root, top, section, parent, fields = metrics_source(ManifestMenu, "${driver}")`,
			driver === 'hs'
				? 'local menu = ManifestMenu.build("metrics_menu", "Metrics", dyn_handlers, nil, render_ctx, list_providers)'
				: 'local items = _manifest_metrics_rows(ctx, k)',
			driver === 'hs'
				? 'if root == nil or not metrics_dense(menu, true) then return nil end'
				: 'local on = type(k.is_enabled) == "function" and k.is_enabled() == true',
			`local current_root, current_top, current_section, current_parent = metrics_source(ManifestMenu, "${driver}")`,
			'if not rawequal(root, current_root) or not rawequal(top, current_top) or not rawequal(section, current_section) or not rawequal(parent, current_parent) or not metrics_parent_unchanged(parent, fields) then return nil end',
			finish,
			`current_root, current_top, current_section, current_parent = metrics_source(ManifestMenu, "${driver}")`,
			'if not rawequal(root, current_root) or not rawequal(top, current_top) or not rawequal(section, current_section) or not rawequal(parent, current_parent) or not metrics_parent_unchanged(parent, fields) then return nil end',
			'return projected'
		];
		const tokens = scriptTokens(native, '.lua'),
			depths = tokenDepths(tokens);
		let previous = -1;
		for (const statement of chronology) {
			assert(hasStatement(native, statement), 'actual native Metrics route ' + statement);
			const wanted = scriptTokens(statement, '.lua');
			const at = tokens.findIndex(
				(_, index) =>
					index > previous &&
					depths[index] === 0 &&
					wanted.every(
						(token, offset) =>
							tokens[index + offset]?.kind === token.kind &&
							tokens[index + offset]?.value === token.value
					)
			);
			assert(at > previous, 'actual lifecycle/child/final parent chronology');
			previous = at;
			assert(!hasStatement(JSON.stringify(statement), statement), 'quoted owner refused');
			assert(!hasStatement('-- ' + statement, statement), 'comment owner refused');
			if (statement.includes('ManifestMenu.'))
				assert(
					!hasStatement(statement.replace('ManifestMenu.', 'Foreign.ManifestMenu.'), statement),
					'foreign renderer refused'
				);
		}
		if (driver === 'hs') {
			const firstPhase = chronology[1];
			const before = native.slice(0, native.indexOf(firstPhase));
			assert(
				!hasStatement(before, 'if root == nil then return nil end'),
				'source capture must not bypass WPM cleanup'
			);
			const lifecycle = ownerBody(
				native,
				'local function sync_wpm_visibility(state_key, label, module, ...)'
			);
			assert(
				hasStatement(lifecycle, 'if state[state_key] and not paused then'),
				'unchanged shared WPM pause gate'
			);
			assert(
				hasStatement(
					native,
					'sync_wpm_visibility("keylogger_menubar_wpm", "WPM menubar", WpmMenubar)',
					1
				)
			);
			assert(
				hasStatement(
					native,
					'sync_wpm_visibility("keylogger_float_wpm", "WPM widget", WpmWidget, state.keylogger_float_graph)',
					1
				)
			);
		} else {
			let absentPrevious = -1;
			for (const statement of [
				'local status_rows = ManifestMenu and ManifestMenu.template_rows("linux_metrics_absent_rows", {}, {}, {})',
				'local items = ManifestMenu.render_rows(status_rows, "linux_metrics_absent_rows")',
				'local projected = ManifestMenu.group_row("top_level", "metrics", items, { keylogger_enabled = function() return nil end })',
				'current_root, current_top, current_section, current_parent = metrics_source(ManifestMenu, "linux")',
				'if not rawequal(root, current_root) or not rawequal(top, current_top) or not rawequal(section, current_section) or not rawequal(parent, current_parent) or not metrics_parent_unchanged(parent, fields) then return nil end',
				'return projected'
			]) {
				assert(
					hasStatement(native, statement, 1),
					'actual absent status materializes once before parent ' + statement
				);
				const wanted = scriptTokens(statement, '.lua');
				const at = tokens.findIndex(
					(_, index) =>
						index > absentPrevious &&
						depths[index] === 1 &&
						wanted.every(
							(token, offset) =>
								tokens[index + offset]?.kind === token.kind &&
								tokens[index + offset]?.value === token.value
						)
				);
				assert(
					at > absentPrevious,
					'absent parent source fence follows all actual GroupRow callbacks'
				);
				absentPrevious = at;
			}
		}
		for (const [name, signature, statements] of [
			[
				'metrics_source',
				'local function metrics_source(renderer, platform)',
				[
					'local ok, root = pcall(renderer.get_root)',
					'if not ok then return nil end',
					'local top, children = rawget(root, "top_level"), rawget(root, "metrics_menu")',
					'if not metrics_dense(top, true) or not metrics_dense(children, true) then return nil end',
					'return root, top, children, parent, fields'
				]
			],
			[
				'metrics_dense',
				'local function metrics_dense(value, records)',
				[
					'if type(value) ~= "table" or getmetatable(value) ~= nil then return false end',
					'return count == maximum'
				]
			],
			[
				'metrics_parent_unchanged',
				'local function metrics_parent_unchanged(parent, fields)',
				['return true']
			]
		]) {
			const body = ownerBody(source, signature);
			for (const statement of statements)
				assert(hasStatement(body, statement), 'actual raw structural helper ' + name);
			assert.throws(
				() => ownerBody('if false then\n' + source + '\nend', signature),
				/physical native Metrics owner/
			);
			assert.throws(
				() => ownerBody(source.replace(signature, '-- ' + signature), signature),
				/physical native Metrics owner/
			);
			assert.throws(
				() => ownerBody(source + '\n' + signature + '\nend\n', signature),
				/physical native Metrics owner/
			);
		}
		const withdrawn =
			source.replace(finish, 'return nil') +
			'\nlocal function unused_metrics_owner()\n' +
			finish +
			'\nend\n';
		assert(
			!hasStatement(ownerBody(withdrawn, signature), finish),
			'unused function cannot lend parent projection'
		);
	}
	console.log(
		'[OK] Metrics: lifecycle-preserving structural source fences, genuine completed children and singleton checked ABI.'
	);
})();

// Linux About consumes the genuine top-level owner and preserves its completed native child.
(function checkLinuxDeclaredAboutParent() {
	const assert = require('node:assert/strict');
	const { scriptTokens } = require('../lib/script-source.cjs');
	const fs = require('node:fs');
	const path = require('node:path');
	const base = path.resolve(__dirname, '../..', 'static/ergopti_plus');
	const menu = JSON.parse(
		fs.readFileSync(path.join(base, '_shared/modules/menu/menu_manifest.json'), 'utf8')
	);
	const hand = JSON.parse(
		fs.readFileSync(path.join(base, '_shared/tests/corpus/menus/linux_about_parent.json'), 'utf8')
	);
	assert.deepEqual(
		menu.top_level.filter((row) => row.id === 'about'),
		[{ type: 'group', id: 'about', i18n: 'menu.about.title', rows: [] }]
	);
	assert.deepEqual(hand.prior_top_level_record, { id: 'about' });
	function requireAboutMetadata(rows) {
		assert.deepEqual(
			rows,
			hand.about_child_declarations,
			'all child identities and metadata include the intended startup command guard'
		);
	}
	requireAboutMetadata(menu.about_menu);
	for (const patch of [
		{ disabled_when: undefined },
		{ disabled_when: ['start_at_login_enabled'] },
		{ disabled_reason_key: undefined },
		{ disabled_reason_key: 'menu.about.source_run_reason' }
	]) {
		const rows = structuredClone(menu.about_menu);
		Object.assign(
			rows.find((row) => row.id === 'start_at_login'),
			patch
		);
		assert.throws(
			() => requireAboutMetadata(rows),
			{ code: 'ERR_ASSERTION' },
			'absent or wrong startup availability/reason must refuse the genuine metadata oracle'
		);
	}
	assert.equal(
		Object.keys(hand.locales).length,
		21,
		'all independently frozen caption sources execute'
	);
	for (const [code, prior] of Object.entries(hand.locales)) {
		const labels = JSON.parse(
			fs.readFileSync(path.join(base, '_shared/data/locales', code + '.json'), 'utf8')
		);
		assert.equal(labels['menu.about.title'], prior.about_parent);
		assert.equal(labels['menu.about.changelog'], prior.changelog);
		assert.equal(labels['menu.about.open_releases_page'], prior.releases_page);
		assert.equal(labels['menu.global.start_at_login'], prior.startup);
		assert.equal(labels['menu.global.uninstall'], prior.uninstall);
	}
	function tokenDepths(tokens) {
		let depth = 0,
			awaitingDo = 0;
		return tokens.map((token, index) => {
			const before = depth;
			if (
				token.kind !== 'identifier' ||
				(['.', ':'].includes(tokens[index - 1]?.value) &&
					!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
			)
				return before;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
			return before;
		});
	}
	function ownerBody(source, signature) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(signature, '.lua');
		const sourceDepths = tokenDepths(tokens);
		const bodies = [];
		for (let start = 0; start < tokens.length; start++) {
			if (sourceDepths[start] !== 0) continue;
			if (
				source
					.slice(source.lastIndexOf('\n', tokens[start].start - 1) + 1, tokens[start].start)
					.trim()
			)
				continue;
			if (
				!wanted.every(
					(token, offset) =>
						tokens[start + offset]?.kind === token.kind &&
						tokens[start + offset]?.value === token.value
				)
			)
				continue;
			// String identity is the physical simple Lua spelling, not an undecoded alias.
			if (
				!wanted.every(
					(token, offset) =>
						token.kind !== 'string' ||
						source.slice(tokens[start + offset].start, tokens[start + offset].end) ===
							signature.slice(token.start, token.end)
				)
			)
				continue;
			const blocks = ['function'];
			let awaitingDo = 0;
			for (let index = start + wanted.length; index < tokens.length; index++) {
				const token = tokens[index];
				if (
					token.kind !== 'identifier' ||
					(['.', ':'].includes(tokens[index - 1]?.value) &&
						!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
				)
					continue;
				if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
					blocks.push(token.value);
					if (['for', 'while'].includes(token.value)) awaitingDo++;
				} else if (token.value === 'do') {
					if (awaitingDo) awaitingDo--;
					else blocks.push('do');
				} else if (token.value === 'end' || token.value === 'until') {
					if (token.value === 'until' && blocks.at(-1) !== 'repeat')
						throw new Error('invalid actual Lua owner');
					blocks.pop();
					if (!blocks.length) {
						bodies.push(source.slice(tokens[start + wanted.length - 1].end, token.start));
						break;
					}
				}
			}
		}
		assert.equal(bodies.length, 1, 'one complete physical native About owner');
		return bodies[0];
	}
	function hasStatement(source, statement, requiredDepth = 0) {
		const tokens = scriptTokens(source, '.lua');
		const wanted = scriptTokens(statement, '.lua');
		let depth = 0,
			awaitingDo = 0;
		const depths = tokens.map((token, index) => {
			const before = depth;
			if (
				token.kind !== 'identifier' ||
				(['.', ':'].includes(tokens[index - 1]?.value) &&
					!(tokens[index - 1]?.value === ':' && tokens[index - 2]?.value === ':'))
			)
				return before;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				depth++;
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else depth++;
			} else if (['end', 'until'].includes(token.value)) depth--;
			return before;
		});
		return tokens.some(
			(first, index) =>
				depths[index] === requiredDepth &&
				!['.', ':', 'function'].includes(tokens[index - 1]?.value) &&
				wanted.every((token, offset) => {
					const actual = tokens[index + offset];
					return (
						actual?.kind === token.kind &&
						actual.value === token.value &&
						(token.kind !== 'string' ||
							source.slice(actual.start, actual.end) === statement.slice(token.start, token.end))
					);
				})
		);
	}

	function admits(source) {
		try {
			const native = ownerBody(source, 'local function _build_about(ctx)');
			const publicOwner = ownerBody(source, 'function M.build(ctx)');
			const chronology = [
				'local root, top, section, parent, fields = about_source(ManifestMenu, "linux")',
				'if root == nil then return nil end',
				'local rows = ManifestMenu and ManifestMenu.build("about_menu", "About", nil, nil, render_ctx, { ["about_updates"] = function() return _about_update_rows(ctx) end, }) or {}',
				'if not about_dense(rows, true) then return nil end',
				'local current_root, current_top, current_section, current_parent = about_source(ManifestMenu, "linux")',
				'if not rawequal(root, current_root) or not rawequal(top, current_top) or not rawequal(section, current_section) or not rawequal(parent, current_parent) or not about_parent_unchanged(parent, fields) then return nil end',
				'return ManifestMenu.group_row("top_level", "about", rows, render_ctx.state_getters)'
			];
			if (!chronology.every((statement) => hasStatement(native, statement))) return false;
			const nativeTokens = scriptTokens(native, '.lua'),
				depths = tokenDepths(nativeTokens);
			let previous = -1;
			for (const statement of chronology) {
				const wanted = scriptTokens(statement, '.lua');
				const at = nativeTokens.findIndex(
					(_, index) =>
						index > previous &&
						depths[index] === 0 &&
						wanted.every(
							(token, offset) =>
								nativeTokens[index + offset]?.kind === token.kind &&
								nativeTokens[index + offset]?.value === token.value
						)
				);
				if (at < 0) return false;
				previous = at;
			}
			const guard = ownerBody(source, 'local function about_source(renderer, platform)');
			if (
				!hasStatement(
					guard,
					'local top, children = rawget(root, "top_level"), rawget(root, "about_menu")'
				)
			)
				return false;
			if (
				!hasStatement(
					guard,
					'if not about_dense(top, true) or not about_dense(children, true) or #children == 0 then return nil end'
				)
			)
				return false;
			if (
				!hasStatement(publicOwner, 'return ManifestMenu.render_rows(rows, "top_level")') &&
				!require('../lib/menu-native-llm-parent-binding.cjs').declaredLinuxTopLevelPublication(
					source
				)
			)
				return false;
			const tokens = scriptTokens(publicOwner, '.lua');
			const binding = scriptTokens('["about"] = _build_about', '.lua');
			return tokens.some((_, index) =>
				binding.every(
					(token, offset) =>
						tokens[index + offset]?.kind === token.kind &&
						tokens[index + offset]?.value === token.value
				)
			);
		} catch {
			return false;
		}
	}
	const source = fs.readFileSync(path.join(base, 'linux/ui/menu/menu_builder.lua'), 'utf8');
	assert.equal(
		admits(source),
		true,
		'the actual registered public native About route consumes its true canonical parent'
	);
	for (let [before, after, reason] of [
		[
			'return ManifestMenu.group_row("top_level", "about", rows, render_ctx.state_getters)',
			'return Foreign.group_row("top_level", "about", rows, render_ctx.state_getters)',
			'foreign renderer'
		],
		[
			'return ManifestMenu.group_row("top_level", "about", rows, render_ctx.state_getters)',
			'return ManifestMenu.group_row("top_level", "debug", rows, render_ctx.state_getters)',
			'wrong actual parent'
		],
		[
			'return ManifestMenu.group_row("top_level", "about", rows, render_ctx.state_getters)',
			'return ManifestMenu.group_row("about_menu", "about", rows, render_ctx.state_getters)',
			'wrong catalogue owner'
		],
		[
			'return ManifestMenu.group_row("top_level", "about", rows, render_ctx.state_getters)',
			'return ManifestMenu.group_row("top_level", "about", {}, render_ctx.state_getters)',
			'disconnected finished child'
		],
		[
			'local root, top, section, parent, fields = about_source(ManifestMenu, "linux")',
			'local root, top, section, parent, fields = about_source(Foreign, "linux")',
			'foreign source admission'
		],
		[
			'["about"]           = _build_about,',
			'["about"]           = _build_debug,',
			'missing actual public producer'
		],
		[
			'or not about_parent_unchanged(parent, fields) then return nil end',
			'or false then return nil end',
			'missing actual source identity refusal'
		],
		[
			'return ManifestMenu.render_rows(rows, "top_level")',
			'return rows',
			'missing actual native rendering boundary'
		]
	]) {
		// Preserve the original case oracle while moving its live subject to the actual receiver.
		if (
			reason === 'missing actual native rendering boundary' &&
			source.includes('local rendered = separator_render(rows, "top_level")')
		) {
			before = 'local rendered = separator_render(rows, "top_level")';
			after = 'local rendered = rows';
		}
		assert.equal(source.split(before).length - 1, 1, reason + ': exact source preimage');
		assert.equal(admits(source.replace(before, after)), false, reason);
		assert.notEqual(
			source.replace(before, after),
			source,
			reason + ': genuine source actually changes'
		);
		assert.equal(admits(source), true, reason + ': unchanged genuine inverse');
	}
	const rootProof =
		require('../lib/menu-native-llm-parent-binding.cjs').declaredLinuxTopLevelPublication;
	assert.equal(
		rootProof(source),
		true,
		'the actual captured Linux root has its retained source and renderer'
	);
	for (const [before, after, reason] of [
		[
			'local separator_render = type(ManifestMenu) == "table" and rawget(ManifestMenu, "render_rows")',
			'local separator_render = Foreign.render_rows',
			'foreign captured root renderer'
		],
		[
			'local separator_factory = type(ManifestMenu) == "table" and rawget(ManifestMenu, "top_level_separator_receiver")',
			'local separator_factory = Foreign.receiver',
			'foreign captured source receiver'
		],
		['getmetatable(ManifestMenu) == nil', 'true', 'withdrawn genuine facade metatable refusal'],
		[
			'local declared = ManifestMenu.get_array("top_level")',
			'local declared = {}',
			'withdrawn current canonical root array'
		],
		[
			'or type(declared) ~= "table" or not rawequal(declared, source_rows) then',
			'or type(declared) ~= "table" then',
			'withdrawn exact receiver source identity'
		],
		[
			'local rendered = separator_render(rows, "top_level")',
			'local rendered = separator_render({}, "top_level")',
			'completed native children discarded'
		],
		['return rendered', 'return rows', 'actual captured native result discarded'],
		[
			'function M.build(ctx)',
			'function M.build(ctx)\n local separator_render = Foreign.render_rows',
			'public receiving function shadows captured native renderer'
		]
	]) {
		assert.equal(source.split(before).length - 1, 1, reason + ': unique actual source coordinate');
		const candidate = source.replace(before, after);
		assert.notEqual(candidate, source, reason + ': actual source changes');
		assert.equal(rootProof(candidate), false, reason + ': genuine root projection refuses');
		assert.equal(admits(candidate), false, reason + ': About publication refuses');
		assert.equal(rootProof(source), true, reason + ': original current root remains admitted');
		assert.equal(admits(source), true, reason + ': original About route remains admitted');
	}
	assert.equal(admits(JSON.stringify(source)), false, 'quoted native source is data');
	assert.equal(admits('--[=[\n' + source + '\n]=]'), false, 'comment-only native source is data');
	assert.equal(admits(''), false, 'missing actual native owner');
	assert.equal(admits(source), true, 'genuine source remains admitted after negative controls');
})();
