// _shared/ui/error_dialog/script.js

/**
 * ==============================================================================
 * MODULE: Error Window Page
 * DESCRIPTION:
 * The window the three drivers open when an error is logged, or at the next
 * launch after a crash: what went wrong, where it is logged, the report that
 * would be shared, and the buttons to report it on GitHub, copy it, open the
 * log it is in, or close the window.
 *
 * FEATURES & RATIONALE:
 * 1. One entry point for the host, window.receiveErrorDialog(message), with a
 *    typed message: init (the error and its report), more (errors logged
 *    since, folded into this window) and action (the result of a request).
 *    macOS and Windows evaluate it; Linux answers the bridge's requests through
 *    window.__hostBridgeResponse, routed to the same place.
 * 2. The host sends every text already redacted, and the details block shows
 *    the exact report the Copy and Report buttons use: the user sees what is
 *    shared before sharing it.
 * 3. Buttons send action names only. The host acts on the error it holds and
 *    opens only the file it logged it in; the page never names a path, a text
 *    or a URL for it to use.
 * 4. The window is non-modal and never takes the keyboard: the host opens it
 *    without focus, since it can appear while the user is typing.
 * ==============================================================================
 */

(function () {
	'use strict';

	var post = makeHostBridge('error_dialog');

	// The host's init message: { kind, module, message, log_path, text, more };
	// null until it arrives
	var state = null;

	/**
	 * True for a boolean true, or the 1 the AutoHotkey JSON writer sends for it.
	 * @param {*} value
	 * @returns {boolean}
	 */
	function isTrue(value) {
		return value === true || value === 1;
	}

	// ==============================
	// ==============================
	// ======= 1/ Translation =======
	// ==============================
	// ==============================

	/**
	 * Translates a key, filling "%s" placeholders in order. An unknown key comes
	 * back as itself, which is visible rather than blank.
	 * @param {string} key
	 * @returns {string}
	 */
	function t(key) {
		var strings = window._i18n_strings || {};
		var value = strings[key];
		if (typeof value !== 'string') return key;
		var args = Array.prototype.slice.call(arguments, 1);
		var index = 0;
		return value.replace(/%s/g, function () {
			return String(args[index++]);
		});
	}

	// ============================
	// ============================
	// ======= 2/ Rendering =======
	// ============================
	// ============================

	/**
	 * Shows a one-line status above the buttons.
	 * @param {string} text
	 * @param {string} kind "ok", "fail" or "info".
	 */
	function setStatus(text, kind) {
		var status = document.getElementById('status');
		status.textContent = text;
		status.className = 'status ' + (kind || 'info');
	}

	/**
	 * Enables the buttons that act on the error once there is one.
	 * @param {boolean} enabled
	 */
	function setButtonsEnabled(enabled) {
		['btn-report', 'btn-copy', 'btn-open-log'].forEach(function (id) {
			document.getElementById(id).disabled = !enabled;
		});
	}

	/** Renders the window from the current state, in the user's language. */
	function render() {
		var heading = document.getElementById('heading');
		if (!state) {
			heading.textContent = t('common.loading');
			setButtonsEnabled(false);
			return;
		}
		var crash = state.kind === 'crash';
		heading.textContent = t(crash ? 'error_dialog.heading_crash' : 'error_dialog.heading');
		document.getElementById('intro').textContent = t(
			crash ? 'error_dialog.intro_crash' : 'error_dialog.intro'
		);
		document.getElementById('module').textContent = state.module;
		document.getElementById('message').textContent = state.message;
		document.getElementById('logged').textContent = t(
			crash ? 'error_dialog.crash_saved_in' : 'error_dialog.logged_in',
			state.log_path
		);
		document.getElementById('btn-open-log').textContent = t(
			crash ? 'error_dialog.open_crash_report' : 'error_dialog.open_log'
		);
		var more = document.getElementById('more');
		var count = Number(state.more) || 0;
		more.hidden = count <= 0;
		more.textContent = count > 0 ? t('error_dialog.more', count) : '';
		document.getElementById('details-text').textContent = state.text;
		document.getElementById('disable-hint').textContent = t(
			'error_dialog.disable_hint',
			t('menu.debug.title'),
			t('menu.debug.show_error_dialog')
		);
		setButtonsEnabled(true);
	}

	// ===============================
	// ===============================
	// ======= 3/ Host Messages ======
	// ===============================
	// ===============================

	/**
	 * Reports the outcome of an action the page asked for.
	 * @param {object} message { action, ok, missing }
	 */
	function onActionResult(message) {
		// A file not created yet is nothing to open rather than a failure
		if (isTrue(message.missing)) {
			setStatus(t('healthcheck.status.missing'), 'info');
			return;
		}
		if (!isTrue(message.ok)) {
			setStatus(t('healthcheck.status.failed'), 'fail');
			return;
		}
		switch (message.action) {
			case 'copy':
				setStatus(t('healthcheck.status.copied'), 'ok');
				break;
			case 'report':
				setStatus(t('notify.report_bug_body'), 'ok');
				break;
			default:
				setStatus('', 'info');
		}
	}

	/**
	 * The host's only entry point into the page.
	 * @param {object} message { type: "init"|"more"|"action", … }
	 */
	window.receiveErrorDialog = function (message) {
		if (!message || typeof message !== 'object') return;
		switch (message.type) {
			case 'init':
				state = message;
				setStatus('', 'info');
				render();
				break;
			case 'more':
				if (!state) return;
				state.more = message.count;
				render();
				break;
			case 'action':
				onActionResult(message);
				break;
		}
	};

	// Linux answers each request through the bridge response hook
	window.__hostBridgeResponse = function (bridge, isBase64, payload) {
		if (bridge !== 'error_dialog') return;
		var message = decodeHostBridgeResponse(isBase64, payload);
		if (message !== null) window.receiveErrorDialog(message);
	};

	// ==============================
	// ==============================
	// ======= 4/ Page Actions ======
	// ==============================
	// ==============================

	var BUTTONS = {
		'btn-report': 'report',
		'btn-copy': 'copy',
		'btn-open-log': 'open_log',
		'btn-close': 'close'
	};

	Object.keys(BUTTONS).forEach(function (id) {
		document.getElementById(id).addEventListener('click', function () {
			post({ action: BUTTONS[id] });
		});
	});

	// The labels arrive with the locale; the window renders again in the
	// user's language whenever they are applied
	var applyStrings = window.i18n_apply;
	window.i18n_apply = function (strings) {
		if (typeof applyStrings === 'function') applyStrings(strings);
		render();
	};

	render();
	post('ready');
})();
