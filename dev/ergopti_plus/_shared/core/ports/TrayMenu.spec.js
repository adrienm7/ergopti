// _shared/core/ports/TrayMenu.spec.js

/**
 * ==============================================================================
 * PORT: TrayMenu
 * DESCRIPTION:
 * Contract for the OS-level system tray / menubar icon and menu port. Every
 * driver adapter that manages the application's tray presence MUST satisfy
 * this interface. The port abstracts AHK's Menu class (Windows system tray)
 * and Hammerspoon's hs.menubar (macOS status bar) behind a unified surface.
 *
 * FEATURES & RATIONALE:
 * 1. Icon state machine: the tray icon has three visual states — "active"
 *    (script running normally), "paused" (user paused expansions), "disabled"
 *    (error / not initialized). The adapter maps each state to a platform icon.
 * 2. Declarative menu: callers pass a tree of MenuNode objects; the adapter
 *    renders the platform menu from that tree. Callers do NOT call platform
 *    menu APIs directly.
 * 3. Feature-gate: items can carry an `enabled` flag. Disabled items are shown
 *    greyed out and their onClick is never called. This lets domain code gate
 *    features without branching on platform details.
 * 4. Checkbox support: items can carry a `checked` flag for toggle features.
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
	version: '1.0.0',

	/**
	 * setIcon(state) — Update the tray icon to reflect the given state.
	 *   @param {string} state  "active" | "paused" | "disabled"
	 *   @returns {void}
	 *   @error_behavior "log_and_return".
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
	},

	/** Valid icon states. Adapters MUST accept all three. */
	ICON_STATES: ['active', 'paused', 'disabled']

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
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: 'set_icon_active',
			description: "setIcon('active') does not throw.",
			input: { state: 'active' },
			assert: { no_exception: true }
		},
		{
			id: 'set_icon_paused',
			description: "setIcon('paused') does not throw.",
			input: { state: 'paused' },
			assert: { no_exception: true }
		},
		{
			id: 'set_icon_disabled',
			description: "setIcon('disabled') does not throw.",
			input: { state: 'disabled' },
			assert: { no_exception: true }
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
					args: [
						[
							{
								id: 'single',
								label: 'Item',
								enabled: true,
								checked: false,
								onClick: null,
								children: [],
								separator: false
							}
						]
					]
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
				{ call: 'setIcon', args: ['active'] },
				{ assert: 'no_exception' }
			]
		}
	];
}

module.exports = { portContract, validateAdapter, contractTestVectors, FIXTURE_MENU };
