// _shared/ui/update_check/script.js

/**
 * ==============================================================================
 * MODULE: Update Check Page
 * DESCRIPTION:
 * The centered window the three drivers open for a manual "Check for updates":
 * which channel is being checked, then the answer (up to date, a new release,
 * no release on the channel yet, or why the check failed), with one line for
 * every other channel that published a newer release than the installed build.
 *
 * FEATURES & RATIONALE:
 * 1. One entry point for the host, window.receiveUpdateCheck(message), with a
 *    typed message: state (the check's phase and answer) and action (the
 *    result of a request). macOS and Windows evaluate it; Linux answers the
 *    bridge's requests through window.__hostBridgeResponse, routed to the same
 *    place.
 * 2. The host sends ids, versions and locale keys only; every sentence is
 *    composed here in the menu language, with the channel's name read from the
 *    shared registry, so the "checking" text follows the language like the rest.
 * 3. Buttons send action names only, plus the channel id of a switch line the
 *    host listed. The host installs, opens and reports what it holds; the page
 *    never names a URL, a path or a release for it to use.
 * 4. Nothing installs from the page by itself: Update is a button the user
 *    clicks, shown only for a release the host offered.
 * ==============================================================================
 */

(function () {
	'use strict';

	var post = makeHostBridge('update_check_bridge');
	var channels = createUpdateChannels(window.UPDATE_CHANNEL_REGISTRY);

	// The phases the host reports, and which of them offer an install
	var STATES = { checking: true, up_to_date: true, available: true, no_release: true, error: true };

	// The host's last state message; null until it arrives
	var state = null;

	/**
	 * True for a boolean true, or the 1 the AutoHotkey JSON writer sends for it.
	 * @param {*} value
	 * @returns {boolean}
	 */
	function isTrue(value) {
		return value === true || value === 1;
	}

	/**
	 * A string field of a host message, or "" when it is absent.
	 * @param {*} value
	 * @returns {string}
	 */
	function text(value) {
		return typeof value === 'string' ? value : '';
	}

	// ==============================
	// ==============================
	// ======= 1/ Translation =======
	// ==============================
	// ==============================

	/**
	 * Translates a key, filling named "{name}" placeholders. An unknown key comes
	 * back as itself, which is visible rather than blank.
	 * @param {string} key
	 * @param {Object<string, string>} [values]
	 * @returns {string}
	 */
	function t(key, values) {
		var strings = window._i18n_strings || {};
		var template = strings[key];
		if (typeof template !== 'string') return key;
		return template.replace(/\{([a-z_]+)\}/g, function (whole, name) {
			return values && Object.prototype.hasOwnProperty.call(values, name)
				? String(values[name])
				: whole;
		});
	}

	/**
	 * The translated name of a registry channel; an id the registry does not
	 * know stays visible as itself.
	 * @param {string} id
	 * @returns {string}
	 */
	function channelName(id) {
		var channel = channels.channel(id);
		return channel ? t(channel.labelKey) : String(id);
	}

	// ============================
	// ============================
	// ======= 2/ Rendering =======
	// ============================
	// ============================

	/**
	 * Shows a one-line status under the answer.
	 * @param {string} message
	 * @param {string} kind "ok", "fail" or "info".
	 */
	function setStatus(message, kind) {
		var status = document.getElementById('status');
		status.textContent = message;
		status.className = 'status ' + (kind || 'info');
	}

	/**
	 * Shows or hides one element.
	 * @param {string} id
	 * @param {boolean} visible
	 */
	function show(id, visible) {
		document.getElementById(id).hidden = !visible;
	}

	/**
	 * Lists the other channels the host found newer releases on, each with its
	 * switch button.
	 * @param {Array<{channel: string, tag: string}>} others
	 */
	function renderOthers(others) {
		var list = document.getElementById('others');
		while (list.firstChild) list.removeChild(list.firstChild);
		var entries = Array.isArray(others) ? others : [];
		entries.forEach(function (entry) {
			if (!entry || typeof entry.channel !== 'string' || typeof entry.tag !== 'string') return;
			var item = document.createElement('li');
			var line = document.createElement('span');
			line.textContent = t('update_check.also_available', {
				channel: channelName(entry.channel),
				tag: entry.tag
			});
			var button = document.createElement('button');
			button.type = 'button';
			button.className = 'link';
			button.textContent = t('update_check.switch_channel');
			button.addEventListener('click', function () {
				post({ action: 'switch_channel', channel: entry.channel });
			});
			item.appendChild(line);
			item.appendChild(button);
			list.appendChild(item);
		});
		list.hidden = list.childNodes.length === 0;
	}

	/** Renders the window from the current state, in the menu language. */
	function render() {
		document.getElementById('btn-close').textContent = t('common.close');
		document.getElementById('btn-update').textContent = t('update_check.update');
		document.getElementById('btn-whats-new').textContent = t('update_check.whats_new');
		document.getElementById('btn-report').textContent = t('healthcheck.toolbar.report');
		document.getElementById('btn-open-log').textContent = t('update_check.open_log');
		var line1 = document.getElementById('line1');
		var line2 = document.getElementById('line2');
		var phase = state ? state.state : 'loading';
		var channel = state ? channelName(text(state.channel)) : '';
		var current = state ? text(state.current) : '';
		var latest = state ? text(state.latest) : '';
		document.body.className = 'state-' + phase;

		show('spinner', phase === 'loading' || phase === 'checking');
		show('btn-update', phase === 'available');
		show('btn-whats-new', phase === 'available');
		show('btn-report', phase === 'error');
		show('btn-open-log', phase === 'error' && text(state.log_path) !== '');
		show('logged', phase === 'error' && text(state.log_path) !== '');
		line2.textContent = '';

		switch (phase) {
			case 'loading':
				line1.textContent = t('common.loading');
				break;
			case 'checking':
				line1.textContent = t('update_check.checking', { channel: channel });
				break;
			case 'up_to_date':
				line1.textContent = current;
				line2.textContent = t('update_check.is_latest', { channel: channel });
				break;
			case 'available':
				line1.textContent = latest;
				line2.textContent = t('update_check.available', { current: current, channel: channel });
				break;
			case 'no_release':
				line1.textContent = current;
				line2.textContent = t('updater.no_release_on_channel', { channel: channel });
				break;
			case 'error':
				line1.textContent = t('update_check.error_heading');
				line2.textContent = t(text(state.reason_key), {
					channel: channel,
					tag: latest,
					current: current
				});
				document.getElementById('logged').textContent = t('update_check.logged_in', {
					path: text(state.log_path)
				});
				break;
		}
		var listsOthers = phase === 'up_to_date' || phase === 'available' || phase === 'no_release';
		renderOthers(listsOthers ? state.others : []);
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
		if (isTrue(message.missing)) {
			setStatus(t('healthcheck.status.missing'), 'info');
			return;
		}
		if (!isTrue(message.ok)) {
			setStatus(t('healthcheck.status.failed'), 'fail');
			return;
		}
		setStatus(message.action === 'report' ? t('notify.report_bug_body') : '', 'ok');
	}

	/**
	 * The host's only entry point into the page.
	 * @param {object} message { type: "state"|"action", … }
	 */
	window.receiveUpdateCheck = function (message) {
		if (!message || typeof message !== 'object') return;
		if (message.type === 'state') {
			if (!STATES[message.state]) {
				console.error('[update_check] unknown state:', message.state);
				return;
			}
			state = message;
			setStatus('', 'info');
			render();
		} else if (message.type === 'action') {
			onActionResult(message);
		}
	};

	// Linux answers each request through the bridge response hook
	window.__hostBridgeResponse = function (bridge, isBase64, payload) {
		if (bridge !== 'update_check_bridge') return;
		var message = decodeHostBridgeResponse(isBase64, payload);
		if (message !== null) window.receiveUpdateCheck(message);
	};

	// ==============================
	// ==============================
	// ======= 4/ Page Actions ======
	// ==============================
	// ==============================

	var BUTTONS = {
		'btn-update': 'update',
		'btn-whats-new': 'whats_new',
		'btn-report': 'report',
		'btn-open-log': 'open_log',
		'btn-close': 'close'
	};

	Object.keys(BUTTONS).forEach(function (id) {
		document.getElementById(id).addEventListener('click', function () {
			post({ action: BUTTONS[id] });
		});
	});

	// The labels arrive with the locale; the window renders again in the menu
	// language whenever they are applied
	var applyStrings = window.i18n_apply;
	window.i18n_apply = function (strings) {
		if (typeof applyStrings === 'function') applyStrings(strings);
		render();
	};

	render();
	post('ready');
})();
