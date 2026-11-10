// linux/desktop_focus/gnome/extension.js

/**
 * ==============================================================================
 * MODULE: Ergopti Focus (GNOME Shell extension)
 * DESCRIPTION:
 * Reports the focused window's WM class, title, process and Mutter id to the
 * Ergopti daemon, which owns the session-bus name below. GNOME admits its own
 * Introspect interface to allow-listed senders only and removed Shell.Eval, so
 * code running inside the Shell is the only place that can answer.
 *
 * FEATURES & RATIONALE:
 * 1. Pushed, never polled: the daemon asks four times a second, and a D-Bus
 *    round trip per poll would cost the Shell a wakeup each time. The Shell
 *    calls the daemon on focus, title and class changes only.
 * 2. Unicast to the current owner: the call goes to the unique name that owns
 *    org.ergopti.Focus when it appeared, not to a broadcast signal, so no
 *    other session client is told the titles. (AT-SPI already exposes window
 *    titles to every same-user client; this adds no wider audience.)
 * 3. The daemon starting after the Shell still gets the current window: the
 *    name's appearance triggers one report.
 * 4. The daemon checks that the caller owns org.gnome.Shell; this extension
 *    exports nothing and answers nothing.
 * ==============================================================================
 */

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

// Pinned by tests/unit/adapters/compositor_focus/test_compositor_focus_assets.lua
// against adapters/compositor_focus.lua, which owns them.
const BUS_NAME = 'org.ergopti.Focus';
const OBJECT_PATH = '/org/ergopti/Focus';
const INTERFACE = 'org.ergopti.Focus1';
const CALL_TIMEOUT_MS = 1000;

export default class ErgoptiFocusExtension extends Extension {
	enable() {
		this._owner = null;
		this._window = null;
		this._windowSignals = [];
		this._focusSignal = global.display.connect('notify::focus-window', () => this._track());
		this._watch = Gio.bus_watch_name_on_connection(
			Gio.DBus.session,
			BUS_NAME,
			Gio.BusNameWatcherFlags.NONE,
			(_connection, _name, owner) => {
				this._owner = owner;
				this._report();
			},
			() => {
				this._owner = null;
			}
		);
		this._track();
	}

	disable() {
		if (this._watch) Gio.bus_unwatch_name(this._watch);
		this._watch = 0;
		if (this._focusSignal) global.display.disconnect(this._focusSignal);
		this._focusSignal = 0;
		this._untrackWindow();
		// The daemon must not keep the last window as current once nothing reports.
		this._send('Cleared', null);
		this._owner = null;
	}

	_untrackWindow() {
		for (const id of this._windowSignals) this._window.disconnect(id);
		this._windowSignals = [];
		this._window = null;
	}

	_track() {
		if (this._window) this._untrackWindow();
		const window = global.display.focus_window;
		if (window) {
			this._window = window;
			this._windowSignals = [
				window.connect('notify::title', () => this._report()),
				window.connect('notify::wm-class', () => this._report())
			];
		}
		this._report();
	}

	_report() {
		const window = this._window;
		if (!window) {
			this._send('Cleared', null);
			return;
		}
		const pid = window.get_pid();
		this._send(
			'Activated',
			new GLib.Variant('(ssss)', [
				window.get_wm_class() ?? '',
				window.get_title() ?? '',
				pid > 0 ? String(pid) : '',
				String(window.get_id())
			])
		);
	}

	_send(method, parameters) {
		if (!this._owner) return;
		Gio.DBus.session.call(
			this._owner,
			OBJECT_PATH,
			INTERFACE,
			method,
			parameters,
			null,
			Gio.DBusCallFlags.NO_AUTO_START,
			CALL_TIMEOUT_MS,
			null,
			(connection, result) => {
				try {
					connection.call_finish(result);
				} catch (error) {
					// A daemon stopping mid-call is ordinary; it re-reads on its next start.
					console.debug(`Ergopti focus: ${method} not delivered (${error.message})`);
				}
			}
		);
	}
}
