// linux/desktop_focus/kwin/contents/code/main.js

/**
 * ==============================================================================
 * MODULE: Ergopti Focus (KWin script)
 * DESCRIPTION:
 * Calls the Ergopti daemon back with the active window's resource class,
 * caption, process and KWin id on every activation and caption change. KWin
 * answers focus questions only to a loaded script, and a script can only call
 * out, so the daemon owns the session-bus name below and this script calls it.
 *
 * FEATURES & RATIONALE:
 * 1. Plasma 6 and 5: windowActivated/activeWindow (6) and
 *    clientActivated/activeClient (5) name the same event.
 * 2. Every argument is a string, so KWin's callDBus marshals the four
 *    arguments as the (ssss) signature the daemon accepts, whatever number type
 *    a process id would otherwise become.
 * 3. The current window is reported when the script loads: the daemon reloads
 *    this script once it owns its name, so a daemon started after KWin knows
 *    the active window before the next activation.
 * ==============================================================================
 */

// Pinned by tests/unit/adapters/compositor_focus/test_compositor_focus_assets.lua
// against adapters/compositor_focus.lua, which owns them.
const BUS_NAME = 'org.ergopti.Focus';
const OBJECT_PATH = '/org/ergopti/Focus';
const INTERFACE = 'org.ergopti.Focus1';

let tracked = null;

function report(window) {
	if (!window) {
		callDBus(BUS_NAME, OBJECT_PATH, INTERFACE, 'Cleared');
		return;
	}
	const pid = Number(window.pid) > 0 ? String(window.pid) : '';
	callDBus(
		BUS_NAME,
		OBJECT_PATH,
		INTERFACE,
		'Activated',
		String(window.resourceClass || ''),
		String(window.caption || ''),
		pid,
		String(window.internalId || '')
	);
}

function onCaptionChanged() {
	report(tracked);
}

function activated(window) {
	if (tracked && tracked.captionChanged) tracked.captionChanged.disconnect(onCaptionChanged);
	tracked = window || null;
	if (tracked && tracked.captionChanged) tracked.captionChanged.connect(onCaptionChanged);
	report(tracked);
}

const activation = workspace.windowActivated || workspace.clientActivated;
activation.connect(activated);
activated(workspace.activeWindow !== undefined ? workspace.activeWindow : workspace.activeClient);
