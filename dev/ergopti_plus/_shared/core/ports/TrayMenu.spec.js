// _shared/core/ports/TrayMenu.spec.js

/**
 * ==============================================================================
 * PORT: TrayMenu
 * DESCRIPTION:
 * Contract for the OS-level system tray / menubar icon and menu port. Every
 * driver adapter that manages the application's tray presence MUST satisfy
 * this interface. The port abstracts AHK's Menu class (Windows system tray),
 * Hammerspoon's hs.menubar (macOS status bar) and libayatana-appindicator
 * (Linux StatusNotifierItem) behind a unified surface.
 *
 * FEATURES & RATIONALE:
 * 1. An icon is an image file. setIcon takes an option map whose `image` names
 *    an existing file, and answers whether that file is now drawn. The icon has
 *    two states, running and paused, each drawn from its own logo by the pause
 *    owner of its driver (Windows TrayApplyStateIcon, macOS update_icon, Linux
 *    setPaused); none draws an error or an update icon.
 *
 *    CORRECTED 2026-11-21 (TRAY-04). This port used to declare setIcon(state)
 *    over three states, "active", "paused" and "disabled" (error), that
 *    « adapters MUST accept ». No adapter ever took a state: Windows took
 *    { image, title }, macOS { image, imageData, title }, Linux { icon }. Its
 *    vectors asserted only that setIcon('active') did not throw, which every
 *    adapter satisfied by ignoring the string, so they could never fail.
 * 2. Fail fast on a missing file. A missing or unreadable image is refused with
 *    one logged error and the previous icon stays; the adapter never draws
 *    another image in its place (TRAY-05). The pause owners, which must show
 *    something, draw a warning sign and say in the icon's name that the file is
 *    missing.
 * 3. Declarative menu: callers pass a tree of MenuNode objects; the adapter
 *    renders the platform menu from that tree. Callers do NOT call platform
 *    menu APIs directly.
 * 4. Feature-gate: items can carry a `disabled` flag. Disabled items are shown
 *    greyed out and their fn is never called. This lets domain code gate
 *    features without branching on platform details.
 * 5. Checkbox support: items can carry a `checked` flag for toggle features.
 * ==============================================================================
 */

'use strict';

// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The TrayMenu port contract.
 * @type {object}
 */
const portContract = {
	name: 'TrayMenu',
	version: '2.0.0',

	/**
	 * setIcon(opts) — Draw an image file as the tray icon.
	 *   @param {object} opts  Option map (a Lua table, an AHK Map).
	 *   @param {string} opts.image  Absolute path to an existing image file.
	 *          Adapter-only extras, outside this port: Windows `title` sets the
	 *          tooltip, macOS `title` is text beside the icon and `imageData` a
	 *          prebuilt hs.image.
	 *   @returns {boolean} true when the image is drawn; false when opts is not
	 *          a map, `image` is absent or empty, the file is missing or cannot
	 *          be loaded, or the native call refuses it. A refusal logs one
	 *          error and leaves the previous icon; no other image is drawn.
	 *   @error_behavior "log_and_return" (false).
	 *
	 * setMenu(nodes) — Replace the tray menu with the given node tree.
	 *   @param {Array<MenuNode>} nodes  Flat list of top-level menu items.
	 *          Children are nested via the `children` field of a node.
	 *   @returns {void}
	 *   @error_behavior "log_and_return".
	 *
	 * setTooltip(text) — Set the hover tooltip for the tray icon (if supported).
	 *   @param {string} text  Plain text. May be silently ignored on macOS.
	 *   @returns {void}
	 *   @error_behavior "ignore".
	 *
	 * destroy() — Remove the tray icon and free all resources.
	 *   @returns {void}
	 *   @error_behavior "ignore".
	 */
	methods: {
		setIcon: { arity: 1, required: true },
		setMenu: { arity: 1, required: true },
		setTooltip: { arity: 1, required: true },
		destroy: { arity: 0, required: true }
	}

	/**
	 * MenuNode shape (informative — not validated at runtime):
	 * {
	 *   title:    string,          // Display label (localised)
	 *   disabled: boolean,         // true = greyed out, fn never fires
	 *   checked:  boolean,         // true = checkmark shown next to label
	 *   fn:       Function | null, // Callback when the item is clicked
	 *   menu:     MenuNode[],      // Sub-menu items (absent = leaf item)
	 * }
	 * A separator is a node whose `title` is "-", with no other fields.
	 *
	 * CORRECTED 2026-08-04, and "informative" is exactly how it went wrong.
	 * This block used to describe a node as { id, label, enabled, onClick,
	 * children, separator }. No adapter has ever produced or consumed that shape.
	 * Both Lua drivers build hs.menubar-shaped nodes — the ones above — and the
	 * shared dbusmenu serialiser had invented a THIRD spelling of its own
	 * ({ items, enabled, separator }), which meant the Linux tray silently
	 * dropped every submenu, rendered disabled rows clickable and drew separators
	 * as items labelled "-". Three vocabularies for one tree, none of them
	 * enforced, and the only one written down was the one nobody implemented.
	 *
	 * A spec nobody validates is still the document a new driver is written from,
	 * so it is the one place a wrong shape costs the most. The runtime validator
	 * below checks method arity only; the node shape is held by
	 * linux/tests/unit/meta/test_tray_protocol.lua, which now also pins the
	 * abandoned spellings as dead so a half-revert is visible.
	 */
};

// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a TrayMenu adapter.
 * @param {object} adapter
 * @returns {string[]} Violations. Empty = compliant.
 */
function validateAdapter(adapter) {
	const violations = [];
	if (!adapter || typeof adapter !== 'object') {
		return ['adapter must be a non-null object'];
	}
	for (const [name, spec] of Object.entries(portContract.methods)) {
		if (!spec.required) continue;
		if (typeof adapter[name] !== 'function') {
			violations.push(`missing method: ${name}`);
		} else if (adapter[name].length !== spec.arity) {
			violations.push(`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`);
		}
	}
	return violations;
}

// ==================================================
// ==================================================
// ======= 3/ Compliance Test Vectors =======
// ==================================================
// ==================================================

/**
 * Minimal MenuNode tree fixture for testing.
 */
// `id` is NOT part of the node contract — no adapter reads it. It is the handle
// test-port-vector-traceability.cjs matches against the macOS mirror, so removing
// it silently drops a vector out of that ratchet. Kept, and labelled, because the
// first attempt at this correction did exactly that.
const FIXTURE_MENU = [
	{
		id: 'feature_hotstrings',
		title: 'Hotstrings',
		checked: true,
		fn: null,
		menu: [{ id: 'group_autocorrection', title: 'Autocorrection', checked: true, fn: null }]
	},
	// A separator is a row titled "-". Written out here because the fixture is
	// what a new adapter is tested against, and the previous one used a
	// `separator: true` flag no implementation reads.
	{ id: 'sep_1', title: '-' },
	{
		id: 'reload',
		title: 'Recharger',
		disabled: true,
		fn: null
	}
];

/**
 * Returns test vectors for TrayMenu compliance.
 *
 * The setIcon vectors read what the native layer received, not only that no
 * exception escaped: each mirror replays them by id against its real adapter
 * (macOS test_adapter_contract_vectors_input_and_system.lua, Windows
 * test_adapter_contract_vectors.ahk, Linux test_tray_menu_adapter.lua), and
 * each fails on an adapter that ignores its argument.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: 'set_icon_draws_the_image',
			description: 'setIcon({ image }) with an existing file draws that file and returns true.',
			input: { opts: { image: '<an existing image file>' } },
			assert: { returns: true, native_icon: '<that file>' }
		},
		{
			id: 'set_icon_refuses_a_missing_file',
			description:
				'setIcon({ image }) with a missing file returns false, logs an error naming it, and draws nothing.',
			input: { opts: { image: '<a missing file>' } },
			assert: { returns: false, error_logged: true, native_icon: '<unchanged>' }
		},
		{
			id: 'set_icon_refuses_a_state_name',
			description:
				"setIcon('active'), the state string an earlier version of this port declared, returns false and draws nothing.",
			input: { opts: 'active' },
			assert: { returns: false, native_icon: '<unchanged>' }
		},
		{
			id: 'set_menu_renders_without_exception',
			description: 'setMenu() with a valid node tree does not throw.',
			input: { nodes: FIXTURE_MENU },
			assert: { no_exception: true }
		},
		{
			id: 'set_menu_replaces_previous',
			description: 'Calling setMenu() twice replaces the menu (not appends).',
			steps: [
				{ call: 'setMenu', args: [FIXTURE_MENU] },
				{
					call: 'setMenu',
					args: [[{ id: 'single', title: 'Item', checked: false, fn: null }]]
				},
				{ assert: 'no_exception' }
			]
		},
		{
			id: 'set_tooltip_does_not_throw',
			description: 'setTooltip() with any string does not throw.',
			input: { text: 'Ergopti+ actif' },
			assert: { no_exception: true }
		},
		{
			id: 'destroy_is_safe',
			description: 'destroy() does not throw even if called without a prior setMenu.',
			steps: [{ call: 'destroy' }, { assert: 'no_exception' }]
		},
		{
			id: 'destroy_then_set_icon_is_safe',
			description: 'Calling setIcon() after destroy() does not crash.',
			steps: [
				{ call: 'destroy' },
				{ call: 'setIcon', args: [{ image: '<an existing image file>' }] },
				{ assert: 'no_exception' }
			]
		}
	];
}

module.exports = { portContract, validateAdapter, contractTestVectors, FIXTURE_MENU };
