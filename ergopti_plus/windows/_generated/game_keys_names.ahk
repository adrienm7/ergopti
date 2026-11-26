; _generated/game_keys_names.ahk
; AUTO-GENERATED from _shared/layouts/data/game_keys.json and the
; layout.game_keys enum of _shared/settings/data/config_schema/config.schema.json.
; DO NOT EDIT BY HAND — run `npm run codegen:game-keys` to refresh.
#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Game Keys Names
; DESCRIPTION:
; The choices, Ergopti modes, strategies and reason keys of the game keys
; (modules/keymap/keylayout/game_keys.ahk), the names game_keys.lua reads on
; macOS and Linux. A misspelt name fails at the first access.
; ==============================================================================

class GameKeysName {
	class Choice {
		static PHYSICAL := "physical"
		static LETTERS := "letters"
	}
	class Mode {
		static EMULATION := "emulation"
		static INSTALLED := "installed"
		static SYSTEM := "system"
	}
	class Strategy {
		static NATIVE := "native"
		static HELD_BASE_KEY := "held_base_key"
		static SPLIT_EVENT := "split_event"
		static SWITCH_TO_INSTALLED := "switch_to_installed"
		static REWRITE_KEYCODE := "rewrite_keycode"
	}
	class Reason {
		static PHYSICAL_NEEDS_INSTALLED_LAYOUT := "platform_reason.game_keys_physical_needs_installed_layout"
		static LETTERS_NEEDS_BASE_LAYOUT := "platform_reason.game_keys_letters_needs_base_layout"
		static VK_GAMES_FOLLOW_LETTERS := "platform_reason.game_keys_vk_games_follow_letters"
		static HID_GAMES_ARE_PHYSICAL := "platform_reason.game_keys_hid_games_are_physical"
	}
}
