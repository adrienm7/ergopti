// _shared/ui/healthcheck/script.js

/**
 * ==============================================================================
 * MODULE: Diagnostics Page
 * DESCRIPTION:
 * The diagnostics window of the three drivers: it renders the host's v2
 * snapshot through the shared model (model.js), keeps the preview of what
 * leaves the machine, and asks the host, by message, to copy, save, report,
 * open a folder or a settings page, collect again or close.
 *
 * FEATURES & RATIONALE:
 * 1. One entry point for the host, window.receiveDiagnostics(message), with a
 *    typed message: init (config and first snapshot), snapshot (after a
 *    refresh), probe (an asynchronous probe answered) and action (the result
 *    of a request). macOS and Windows evaluate it; Linux answers the bridge's
 *    requests through window.__hostBridgeResponse, routed to the same place.
 * 2. The page builds the exported text once, redacts it with the shared rules
 *    the host handed over, and shows that exact text in the preview: the user
 *    sees what is copied, saved and sent.
 * 3. Buttons send action names and ids only. The host validates every message
 *    against its allowlist and opens nothing it did not collect itself.
 * 4. "Include details" asks the host to collect the opt-in facts; unticking it
 *    drops them from the page at once, before any export.
 * ==============================================================================
 */

(function () {
	'use strict';

	var Model = window.ErgoptiDiagnostics;
	var Redact = window.ErgoptiRedact;
	var post = makeHostBridge('healthcheck');

	// The host's configuration (schema, redaction rules and context, mode) and
	// the snapshot on screen; both null until the host's init message
	var state = { config: null, snapshot: null };

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

	// ================================
	// ================================
	// ======= 2/ Rendering ===========
	// ================================
	// ================================

	/**
	 * The redacted Markdown report of the snapshot on screen.
	 * @returns {string}
	 */
	function exportText() {
		var markdown = Model.formatMarkdown(state.snapshot, state.config.schema, t);
		return Redact.apply(markdown, state.config.redaction, state.config.context);
	}

	/**
	 * Enables the toolbar once there is something to act on.
	 * @param {boolean} enabled
	 */
	function setToolbarEnabled(enabled) {
		document.querySelectorAll('.toolbar button').forEach(function (button) {
			if (button.id !== 'btn-close') button.disabled = !enabled;
		});
		document.getElementById('chk-details').disabled = !enabled;
	}

	/**
	 * Shows a one-line status under the toolbar.
	 * @param {string} text
	 * @param {string} kind "ok", "fail" or "info".
	 */
	function setStatus(text, kind) {
		var status = document.getElementById('status');
		status.textContent = text;
		status.className = 'status ' + (kind || 'info');
	}

	/** Renders the page and the preview from the current state. */
	function render() {
		var content = document.getElementById('content');
		if (!state.snapshot || !state.config) {
			content.innerHTML =
				'<p class="loading">' + escapeHtml(t('healthcheck.status.loading')) + '</p>';
			setToolbarEnabled(false);
			return;
		}
		content.innerHTML = Model.renderHtml(state.snapshot, state.config.schema, t);
		document.getElementById('preview-text').textContent = exportText();
		document.getElementById('chk-details').checked = isTrue(state.snapshot.detailed);
		setToolbarEnabled(true);
	}

	// ===============================
	// ===============================
	// ======= 3/ Host Messages ======
	// ===============================
	// ===============================

	/**
	 * Merges the sections a probe filled into the snapshot on screen.
	 * @param {object} sections { <section id>: { <field id>: value } }
	 */
	function mergeSections(sections) {
		Object.keys(sections || {}).forEach(function (id) {
			var target = state.snapshot.sections[id];
			if (!target || typeof target !== 'object' || Array.isArray(target)) {
				target = {};
				state.snapshot.sections[id] = target;
			}
			var values = sections[id] || {};
			Object.keys(values).forEach(function (key) {
				target[key] = values[key];
			});
		});
	}

	/**
	 * Reports the outcome of an action the page asked for.
	 * @param {object} message { action, ok, path, missing }
	 */
	function onActionResult(message) {
		// A file not created yet, such as today's errors file before the day's
		// first warning, is nothing to open rather than a failure
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
			case 'save':
				setStatus(t('healthcheck.status.saved', message.path || ''), 'ok');
				break;
			case 'report':
				setStatus(t('notify.report_bug_body'), 'ok');
				break;
			default:
				setStatus('', 'info');
		}
	}

	/** In report mode, the user starts from the preview and the report button. */
	function applyMode() {
		if (state.config.mode !== 'report') return;
		document.getElementById('preview').open = true;
		setStatus(t('healthcheck.status.report_mode'), 'info');
		document.getElementById('btn-report').focus();
	}

	/**
	 * The host's only entry point into the page.
	 * @param {object} message { type: "init"|"snapshot"|"probe"|"action", … }
	 */
	window.receiveDiagnostics = function (message) {
		if (!message || typeof message !== 'object') return;
		switch (message.type) {
			case 'init':
				state.config = message.config;
				state.snapshot = message.snapshot;
				render();
				applyMode();
				break;
			case 'snapshot':
				if (!state.config) return;
				state.snapshot = message.snapshot;
				setStatus('', 'info');
				render();
				break;
			case 'probe':
				if (!state.snapshot) return;
				state.snapshot.probes = state.snapshot.probes || {};
				state.snapshot.probes[message.id] = message.result;
				mergeSections(message.sections);
				render();
				break;
			case 'action':
				onActionResult(message);
				break;
		}
	};

	// Linux answers each request through the bridge response hook
	window.__hostBridgeResponse = function (bridge, isBase64, payload) {
		if (bridge !== 'healthcheck') return;
		var message = decodeHostBridgeResponse(isBase64, payload);
		if (message !== null) window.receiveDiagnostics(message);
	};

	// ==============================
	// ==============================
	// ======= 4/ Page Actions ======
	// ==============================
	// ==============================

	/**
	 * The saved report's file name.
	 * @returns {string}
	 */
	function reportName() {
		return Model.fileName(Model.reportInfo(state.snapshot));
	}

	/**
	 * The issue form's identity fields, redacted. The host prefills the report
	 * itself: the text this page sends, the one Copy copies.
	 * @returns {object}
	 */
	function issueFields() {
		var fields = Model.issueFields(Model.reportInfo(state.snapshot));
		Object.keys(fields).forEach(function (id) {
			fields[id] = Redact.apply(String(fields[id]), state.config.redaction, state.config.context);
		});
		return fields;
	}

	var TOOLBAR = {
		'btn-copy': function () {
			post({ action: 'copy', text: exportText() });
		},
		'btn-save': function () {
			post({ action: 'save', text: exportText(), name: reportName() });
		},
		'btn-report': function () {
			post({ action: 'report', text: exportText(), fields: issueFields() });
		},
		'btn-open-logs': function () {
			post({ action: 'open_path', id: 'logs_dir' });
		},
		'btn-refresh': function () {
			setStatus(t('healthcheck.status.loading'), 'info');
			post({ action: 'refresh', detailed: document.getElementById('chk-details').checked });
		},
		'btn-close': function () {
			post({ action: 'close' });
		}
	};

	Object.keys(TOOLBAR).forEach(function (id) {
		document.getElementById(id).addEventListener('click', TOOLBAR[id]);
	});

	document.getElementById('chk-details').addEventListener('change', function (event) {
		var detailed = event.target.checked;
		if (!detailed && state.snapshot) {
			// Dropped from the page at once: nothing opt-in may reach an export
			// the user makes before the host answers
			state.snapshot = Model.withoutOptIn(state.snapshot, state.config.schema);
			render();
		}
		setStatus(t('healthcheck.status.loading'), 'info');
		post({ action: 'refresh', detailed: detailed });
	});

	// Row buttons (Open, Open settings) carry an action and an id, nothing else
	document.getElementById('content').addEventListener('click', function (event) {
		var button = event.target.closest('button[data-action]');
		if (!button) return;
		post({ action: button.getAttribute('data-action'), id: button.getAttribute('data-id') });
	});

	// The labels arrive with the locale; the page renders again in the user's
	// language whenever they are applied
	var applyStrings = window.i18n_apply;
	window.i18n_apply = function (strings) {
		if (typeof applyStrings === 'function') applyStrings(strings);
		render();
	};

	render();
	post('ready');
})();
