// video/src/lib/data.ts
//
// Typed access to src/_generated/driver-data.json, which scripts/prepare.mjs
// measures from the driver sources before every studio run or render.

import data from '../_generated/driver-data.json';
import timeline from '../data/timeline.json';

export type HotstringDemo = { output: string; category: string; color: string };

export const FACTS = data.facts;
export const TOOLTIP = data.tooltip;
export const WEBVIEWS: Array<{ id: string; width: number; height: number }> = data.webviews;
export const TAP_HOLDS: Array<{ id: string; key: string; tap: string; hold: string }> =
	data.tapHolds;
export const WINDOWS_ACTIONS: Array<{ id: string; label: string }> = data.windowsActions;
/** Tap-hold keys that exist on Windows, macOS and Linux. */
export const TAP_HOLD_KEYS: Array<{ id: string; name: string }> = data.tapHoldCatalog;
/** Example tap actions and holds, as the tap-hold picker names them. */
export const TAP_HOLD_OPTIONS: { taps: string[]; holds: string[] } = data.tapHoldOptions;

/** The wrap-selection feature's label and its symbol groups. */
export const WRAP_SYMBOLS: {
	label: string;
	groups: Array<{ label: string; pairs: Array<{ left: string; right: string }> }>;
} = data.wrapSymbols;
export type MenuRow = {
	id: string;
	label?: string;
	/** label is null for rows the driver fills at run time. */
	children?: Array<{ type: string; label: string | null }>;
};
/** The tray menu's top level and first-level children, in English. */
export const MENU: MenuRow[] = data.menu;
/** The site's best-of abbreviations, longest output per key first. */
export const BEST_OF: Array<{ trigger: string; output: string; color: string; ratio: number }> =
	data.bestOf;
/** Recommended navigation layer: physical key code, action, label. */
export const NAV_LAYER: Array<{ code: string; action: string; label: string }> = data.navLayer;
export type ShortcutSlot = {
	action: string;
	label: string;
	windows: string;
	macos: { keys: string; label: string } | null;
};
/** Recommended Win + letter slots, with what the same letter does on macOS. */
export const SHORTCUTS: ShortcutSlot[] = data.shortcuts;

/**
 * A recommended shortcut slot by action id.
 * @param action - Action id in actions.toml.
 */
export function shortcut(action: string): ShortcutSlot {
	const slot = SHORTCUTS.find((s) => s.action === action);
	if (!slot) throw new Error(`No recommended shortcut runs "${action}"`);
	return slot;
}

/** Drops the picker's "[configurable]" note from a label. */
export const bareLabel = (label: string): string => label.replace(/\s*\[[^\]]+\]$/, '');

export const TIMELINE = timeline;
/** Scenes the film plays: "film": false keeps a scene (and its GIF) out of the cut. */
export const FILM_SCENES = timeline.scenes.filter((scene) => scene.film !== false);

/**
 * English label of a Windows action, from the driver's locale.
 * @param id - Action id in actions.toml.
 */
export function actionLabel(id: string): string {
	const action = WINDOWS_ACTIONS.find((a) => a.id === id);
	if (!action) throw new Error(`Action "${id}" is not available on Windows`);
	// "[configurable]" tells the picker the action takes a parameter; on
	// screen it is noise.
	return bareLabel(action.label);
}
export const FPS = timeline.fps;

/**
 * The real output of a hotstring trigger declared in demo-script.json.
 * @param trigger - Trigger exactly as the driver files spell it.
 */
export function hotstring(trigger: string): HotstringDemo {
	const entry = (data.hotstrings as Record<string, HotstringDemo>)[trigger];
	if (!entry) throw new Error(`Trigger "${trigger}" is not in src/data/demo-script.json`);
	return entry;
}

/**
 * Native window size of a driver webview, from apps.manifest.json.
 * @param id - Folder name under _shared/ui/.
 */
export function webviewSize(id: string): { width: number; height: number } {
	const view = WEBVIEWS.find((w) => w.id === id);
	if (!view) throw new Error(`Unknown driver window "${id}"`);
	return view;
}

/** Thousands separator for on-screen figures. */
export const fmt = (n: number): string => n.toLocaleString('en-US');
