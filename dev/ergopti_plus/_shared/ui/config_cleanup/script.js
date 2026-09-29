// _shared/ui/config_cleanup/script.js

/**
 * MODULE: Configuration Cleanup Page
 * DESCRIPTION:
 * Shows every obsolete setting in a bounded scroll region. The host owns the
 * scan and deletion targets; the page sends only an action and a session token.
 */
(function () {
	'use strict';
	var post = makeHostBridge('config_cleanup_bridge');
	var state = null;
	var busy = false;
	var el = function (id) {
		return document.getElementById(id);
	};

	/** Formats the existing numbered locale placeholders without interpreting values. */
	function t(key) {
		var args = Array.prototype.slice.call(arguments, 1);
		var value = (window._i18n_strings || {})[key];
		return typeof value === 'string'
			? value.replace(/\{(\d+)\}/g, function (_, index) {
					return String(args[Number(index) - 1]);
				})
			: key;
	}

	/** Renders host state without parsing configuration text as HTML. */
	function render() {
		el('btn-clean').disabled = busy || !state || state.status !== 'ready' || !state.keys.length;
		el('btn-refresh').disabled = busy || !state;
		el('count').textContent = state
			? t('config_cleanup.count', state.keys.length)
			: t('common.loading');
		if (!state) return;
		el('path').textContent = state.path;
		el('keys').textContent = '';
		state.keys.forEach(function (entry) {
			var row = document.createElement('li');
			var key = document.createElement('span');
			key.className = 'setting-key';
			key.textContent = '[' + entry.section + '] ' + entry.key;
			var value = document.createElement('span');
			value.className = 'setting-value';
			value.textContent = entry.value;
			row.appendChild(key);
			row.appendChild(value);
			el('keys').appendChild(row);
		});
		var status = '';
		if (state.status === 'empty') status = t('dialog.unused_keys.none', state.path);
		if (state.status === 'changed') status = t('config_cleanup.changed');
		if (state.status === 'removed')
			status = t('dialog.unused_keys.done', state.removed, state.backup);
		if (state.status === 'failed') status = t('dialog.unused_keys.failed', t(state.reason_key));
		el('status').textContent = status;
		el('status').className = state.status;
	}

	/** Accepts only a complete response for this page's current host session. */
	window.receiveConfigCleanup = function (message) {
		if (!message || typeof message.session !== 'string' || !Array.isArray(message.keys)) return;
		if (state && message.session !== state.session) return;
		state = message;
		busy = false;
		render();
	};
	window.__hostBridgeResponse = function (bridge, base64, payload) {
		if (bridge === 'config_cleanup_bridge')
			window.receiveConfigCleanup(decodeHostBridgeResponse(base64, payload));
	};
	['refresh', 'clean', 'close'].forEach(function (action) {
		el('btn-' + action).addEventListener('click', function () {
			if (el('btn-' + action).disabled) return;
			if (action !== 'close') {
				busy = true;
				render();
			}
			post({ action: action, session: state ? state.session : '' });
		});
	});
	var apply = window.i18n_apply;
	window.i18n_apply = function (strings) {
		if (typeof apply === 'function') apply(strings);
		render();
	};
	render();
	post('ready');
})();
