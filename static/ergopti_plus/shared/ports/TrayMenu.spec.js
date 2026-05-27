// static/ergopti_plus/shared/ports/TrayMenu.spec.js

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

"use strict";




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
	name: "TrayMenu",
	version: "1.0.0",

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
		setIcon:    { arity: 1, required: true },
		setMenu:    { arity: 1, required: true },
		setTooltip: { arity: 1, required: true },
		destroy:    { arity: 0, required: true },
	},

	/** Valid icon states. Adapters MUST accept all three. */
	ICON_STATES: ["active", "paused", "disabled"],

	/**
	 * MenuNode shape (informative — not validated at runtime):
	 * {
	 *   id:       string,          // Unique stable identifier for this item
	 *   label:    string,          // Display label (localised)
	 *   enabled:  boolean,         // false = greyed out, onClick never fires
	 *   checked:  boolean,         // true = checkmark shown next to label
	 *   onClick:  Function | null, // Callback when item is clicked
	 *   children: MenuNode[],      // Sub-menu items (empty = leaf item)
	 *   separator:boolean,         // true = render as a separator line (ignores other fields)
	 * }
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
	if (!adapter || typeof adapter !== "object") {
		return ["adapter must be a non-null object"];
	}
	for (const [name, spec] of Object.entries(portContract.methods)) {
		if (!spec.required) continue;
		if (typeof adapter[name] !== "function") {
			violations.push(`missing method: ${name}`);
		} else if (adapter[name].length !== spec.arity) {
			violations.push(
				`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`
			);
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
const FIXTURE_MENU = [
	{
		id: "feature_hotstrings", label: "Hotstrings",
		enabled: true, checked: true, onClick: null, children: [],
		separator: false,
	},
	{ separator: true, id: "sep_1", label: "", enabled: true, checked: false, onClick: null, children: [] },
	{
		id: "reload", label: "Recharger",
		enabled: true, checked: false, onClick: null, children: [],
		separator: false,
	},
];

/**
 * Returns test vectors for TrayMenu compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "set_icon_active",
			description: "setIcon('active') does not throw.",
			input: { state: "active" },
			assert: { no_exception: true },
		},
		{
			id: "set_icon_paused",
			description: "setIcon('paused') does not throw.",
			input: { state: "paused" },
			assert: { no_exception: true },
		},
		{
			id: "set_icon_disabled",
			description: "setIcon('disabled') does not throw.",
			input: { state: "disabled" },
			assert: { no_exception: true },
		},
		{
			id: "set_menu_renders_without_exception",
			description: "setMenu() with a valid node tree does not throw.",
			input: { nodes: FIXTURE_MENU },
			assert: { no_exception: true },
		},
		{
			id: "set_menu_replaces_previous",
			description: "Calling setMenu() twice replaces the menu (not appends).",
			steps: [
				{ call: "setMenu", args: [FIXTURE_MENU] },
				{ call: "setMenu", args: [[{ id: "single", label: "Item", enabled: true, checked: false, onClick: null, children: [], separator: false }]] },
				{ assert: "no_exception" },
			],
		},
		{
			id: "set_tooltip_does_not_throw",
			description: "setTooltip() with any string does not throw.",
			input: { text: "Ergopti+ actif" },
			assert: { no_exception: true },
		},
		{
			id: "destroy_is_safe",
			description: "destroy() does not throw even if called without a prior setMenu.",
			steps: [
				{ call: "destroy" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "destroy_then_set_icon_is_safe",
			description: "Calling setIcon() after destroy() does not crash.",
			steps: [
				{ call: "destroy" },
				{ call: "setIcon", args: ["active"] },
				{ assert: "no_exception" },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors, FIXTURE_MENU };
