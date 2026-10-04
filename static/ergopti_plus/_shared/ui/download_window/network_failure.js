// _shared/ui/download_window/network_failure.js

/**
 * ==============================================================================
 * MODULE: Managed Download Failure Renderer
 * DESCRIPTION:
 * Renders the host's shared cause and available action records. Messages carry
 * only the captured session and action id; native hosts recheck current owners.
 * ==============================================================================
 */

(function () {
	'use strict';

	const post = makeHostBridge('dl_bridge');
	let retained = null;
	let acceptedSession = null;
	let acceptedEpoch = 0;

	function text(key) {
		const value = window._i18n_strings && window._i18n_strings[key];
		return typeof value === 'string' && value.length > 0 ? value : null;
	}

	/** Clears retained failure actions when the host starts or retires a session. */
	window.clearNetworkFailure = function () {
		retained = null;
		const panel = document.getElementById('managed-network-actions');
		if (panel) panel.replaceChildren();
	};

	/**
	 * Shows a translated host report without copying raw URLs, paths or stderr.
	 * Policy stays in managed_network.json and the native shared interpreter.
	 */
	window.showNetworkFailure = function (report, session, epoch) {
		if (
			!Number.isSafeInteger(session) ||
			session <= 0 ||
			!Number.isSafeInteger(epoch) ||
			epoch <= 0 ||
			!report ||
			typeof report.message_key !== 'string' ||
			!Array.isArray(report.actions)
		)
			return false;
		if (typeof bridgeSession !== 'undefined' && bridgeSession !== session) return false;
		if (typeof globalDoneState !== 'undefined' && !globalDoneState) return false;
		if (typeof globalDoneSucceeded !== 'undefined' && globalDoneSucceeded === true) return false;
		if (
			acceptedSession === session &&
			(epoch < acceptedEpoch || (epoch === acceptedEpoch && retained === null))
		)
			return false;
		const message = text(report.message_key);
		const target = document.getElementById('done-msg');
		const controls = document.getElementById('ui-controls');
		if (!message || !target || !controls) return false;
		const seen = new Set();
		const records = [];
		for (const action of report.actions) {
			if (
				!action ||
				typeof action.id !== 'string' ||
				!/^[a-z][a-z_]*$/.test(action.id) ||
				seen.has(action.id) ||
				typeof action.label_key !== 'string'
			)
				return false;
			const label = text(action.label_key);
			if (!label) return false;
			seen.add(action.id);
			records.push({ id: action.id, label_key: action.label_key, label });
		}
		let panel = document.getElementById('managed-network-actions');
		if (!panel) {
			panel = document.createElement('div');
			panel.id = 'managed-network-actions';
			panel.className = 'btn-row';
			controls.appendChild(panel);
		}
		panel.replaceChildren();
		const retry = document.getElementById('btn-retry');
		if (retry) retry.style.display = 'none';
		target.textContent = message;
		for (const action of records) {
			const button = document.createElement('button');
			button.textContent = action.label;
			button.addEventListener('click', function () {
				post({ action: 'failure_action', id: action.id, session, epoch });
			});
			panel.appendChild(button);
		}
		retained = {
			message_key: report.message_key,
			actions: records.map(({ id, label_key }) => ({ id, label_key })),
			session,
			epoch
		};
		acceptedSession = session;
		acceptedEpoch = epoch;
		return true;
	};

	// Locale application must redraw labels, including the host-seeded locales
	// used by inline macOS and Linux WebViews.
	document.addEventListener('i18n:applied', function () {
		if (retained) window.showNetworkFailure(retained, retained.session, retained.epoch);
	});
})();
