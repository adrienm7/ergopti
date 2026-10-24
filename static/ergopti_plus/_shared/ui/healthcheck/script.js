// _shared/ui/healthcheck/script.js

/**
 * ==============================================================================
 * MODULE: Diagnostics Page
 * DESCRIPTION:
 * The diagnostics window of the three drivers: it renders the host's v2
 * snapshot through the shared model (model.js), keeps the preview of what
 * leaves the machine, and asks the host, by message, to copy, save, report,
 * open a folder or a settings page, or collect again. The window's own close
 * button closes it.
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
 * 5. "Also save a redacted copy of today's complete log" is a second opt-in,
 *    unticked at every snapshot. Ticking asks the host to read and redact the
 *    log; the page shows the host's size and preview, and only Save and Report
 *    a bug carry the choice back (Copy never does). The text of the log never
 *    reaches this page, only its first and last redacted lines.
 * ==============================================================================
 */

(function () {
	'use strict';

	var Model = window.ErgoptiDiagnostics;
	var Redact = window.ErgoptiRedact;
	var post = makeHostBridge('healthcheck');

	// The host's configuration (schema, redaction rules and context) and
	// the snapshot on screen; both null until the host's init message
	var state = { config: null, snapshot: null };
	var Checks = window.ErgoptiDiagnosticChecks;
	var checkRun = null;
	var exportSequence = 0;
	var pendingExport = null;
	var sharedText = null;
	var collection = { phase: 'idle' };
	// The opt-in day log: off, preparing, or the host's verdict (ready,
	// too_large, empty, missing, failed)
	var dayLog = { phase: 'off' };
	var lastExportDayLog = false;

	/** Collection controls expose exact host state without accepting a page-supplied path. */
	function renderCollection() {
		var supported = state.config !== null && state.config.capabilities.diagnostic_collection;
		var active =
			isTrue(collection.owner_pending) ||
			(collection.phase !== 'idle' &&
				collection.phase !== 'completed' &&
				collection.phase !== 'failed');
		var button = document.getElementById('btn-collect-windows');
		button.disabled = !supported || active;
		button.title = supported ? '' : t('healthcheck.collection.unavailable');
		document.getElementById('btn-collection-cancel').hidden = !active;
		document.getElementById('btn-collection-guided').hidden = collection.phase !== 'guided';
		document.getElementById('btn-collection-skip').hidden = collection.phase !== 'guided';
		document.getElementById('btn-collection-open').hidden =
			!isTrue(collection.archive_created) && !isTrue(collection.folder_available);
		document.getElementById('collection-progress').textContent = !supported
			? t('healthcheck.collection.unavailable')
			: collection.phase === 'idle'
				? ''
				: collection.phase === 'completed'
					? t('healthcheck.collection.complete')
					: collection.phase === 'failed'
						? t('healthcheck.collection.failed')
						: t(
								'healthcheck.deep_tests.progress',
								collection.completed || 0,
								collection.total || 0
							);
	}

	/** Invalid observations refuse sharing without disabling cleanup or local display. */
	function pageObservations() {
		try {
			return Model.pageCheckObservations(state.snapshot.diagnostic_checks, state.config.schema);
		} catch (_) {
			setStatus(t('healthcheck.probe.error', 'invalid_page_observations'), 'fail');
			return null;
		}
	}

	/** True when the user ticked the day log and the host holds it ready. */
	function dayLogReady() {
		return document.getElementById('chk-day-log').checked && dayLog.phase === 'ready';
	}

	/** Formats a byte count for the day log line. */
	function formatBytes(bytes) {
		if (bytes < 1024) return bytes + ' B';
		if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KiB';
		return (bytes / 1048576).toFixed(1) + ' MiB';
	}

	/** Shows the day log verdict and, when ready, the host's preview of it. */
	function renderDayLog() {
		var status = document.getElementById('day-log-status');
		var preview = document.getElementById('day-log-preview');
		preview.hidden = true;
		switch (dayLog.phase) {
			case 'preparing':
				status.textContent = t('healthcheck.day_log.preparing');
				break;
			case 'ready':
				status.textContent = t(
					'healthcheck.day_log.summary',
					dayLog.lines,
					formatBytes(dayLog.bytes),
					formatBytes(dayLog.cap_bytes),
					dayLog.first_time || '-',
					dayLog.last_time || '-'
				);
				var head = Array.isArray(dayLog.head) ? dayLog.head : [];
				var tail = Array.isArray(dayLog.tail) ? dayLog.tail : [];
				document.getElementById('day-log-preview-text').textContent = head
					.concat(tail.length > 0 ? [t('healthcheck.day_log.omitted')] : [], tail)
					.join('\n');
				preview.hidden = false;
				break;
			case 'too_large':
				status.textContent = t(
					'healthcheck.day_log.too_large',
					formatBytes(dayLog.bytes),
					formatBytes(dayLog.cap_bytes)
				);
				break;
			case 'empty':
			case 'missing':
				status.textContent = t('healthcheck.day_log.' + dayLog.phase);
				break;
			case 'failed':
				status.textContent = t('healthcheck.day_log.failed');
				break;
			default:
				status.textContent = '';
		}
	}

	/** Back to unticked: every new snapshot starts without the day log. */
	function resetDayLog() {
		dayLog = { phase: 'off' };
		document.getElementById('chk-day-log').checked = false;
		renderDayLog();
	}

	function requestExport(action) {
		if (pendingExport) return;
		if (exportSequence >= state.config.schema.report.export_sequence_max)
			throw new Error('The export sequence is exhausted');
		var observations = pageObservations();
		if (!observations) return;
		// Copy never carries the day log: it is a file, saved with the report
		var withDayLog = action !== 'copy' && dayLogReady();
		pendingExport = {
			action: action,
			dayLog: withDayLog,
			sequence: ++exportSequence,
			snapshot: state.snapshot,
			checks: JSON.stringify(observations)
		};
		var message = {
			action: 'export_snapshot',
			export_sequence: exportSequence,
			generated_at: state.snapshot.generated_at,
			snapshot_revision: state.snapshot.export_revision,
			page_checks: observations.results
		};
		if (withDayLog) message.day_log = true;
		post(message);
	}

	/** Host encoders may reorder keys; normalize only the exact closed envelope. */
	function hostPageObservations(value) {
		if (
			!value ||
			typeof value !== 'object' ||
			Array.isArray(value) ||
			value.source !== 'installed_page_reported' ||
			value.qualification !== 'unqualified' ||
			Object.keys(value).sort().join(',') !== 'qualification,results,source'
		)
			return null;
		try {
			return Model.pageCheckObservations(value.results, state.config.schema);
		} catch (_) {
			return null;
		}
	}

	function completeExport(message) {
		var request = pendingExport;
		if (!request || message.export_sequence !== request.sequence) return;
		pendingExport = null;
		var currentChecks = pageObservations();
		var hostChecks = hostPageObservations(
			message.snapshot && message.snapshot.page_check_observations
		);
		if (!currentChecks || !hostChecks) return;
		if (
			!isTrue(message.ok) ||
			!message.snapshot ||
			typeof message.share_text !== 'string' ||
			state.snapshot !== request.snapshot ||
			message.snapshot.driver !== request.snapshot.driver ||
			message.snapshot.generated_at !== request.snapshot.generated_at ||
			message.snapshot.export_revision !== request.snapshot.export_revision ||
			JSON.stringify(currentChecks) !== request.checks ||
			JSON.stringify(hostChecks) !== request.checks
		)
			return;
		// Keep the actual check owner alive; replacing it would abandon pending callbacks.
		var checks = state.snapshot.diagnostic_checks;
		Object.keys(state.snapshot).forEach(function (key) {
			if (
				key !== 'diagnostic_checks' &&
				!Object.prototype.hasOwnProperty.call(message.snapshot, key)
			)
				delete state.snapshot[key];
		});
		Object.assign(state.snapshot, message.snapshot, { diagnostic_checks: checks });
		sharedText = message.share_text;
		render();
		lastExportDayLog = request.dayLog;
		var sent;
		if (request.action === 'copy') sent = { action: 'copy', text: exportText() };
		else if (request.action === 'save')
			sent = { action: 'save', text: exportText(), name: reportName() };
		else sent = { action: 'report', text: exportText(), fields: issueFields() };
		if (request.dayLog) sent.day_log = true;
		post(sent);
	}

	function cancelChecks() {
		if (checkRun) checkRun.cancel();
		checkRun = null;
	}

	function startChecks() {
		cancelChecks();
		var captured = state.snapshot;
		checkRun = Checks.start(
			captured,
			state.config.schema,
			state.config.redaction,
			Redact.apply,
			function (id, result) {
				if (state.snapshot !== captured) return;
				captured.diagnostic_checks[id] = result;
				sharedText = null;
				render();
			},
			function (fn) {
				return window.setTimeout(fn, 0);
			},
			function (id) {
				window.clearTimeout(id);
			}
		);
		captured.diagnostic_checks = checkRun.results;
	}

	function refreshRequest() {
		pendingExport = null;
		post({
			action: 'refresh',
			detailed: document.getElementById('chk-details').checked,
			extensive: document.getElementById('chk-extensive').checked
		});
	}

	function cancelRequestedChecks() {
		cancelChecks();
		Object.keys(state.snapshot.probes || {}).forEach(function (id) {
			if (state.snapshot.probes[id].state === 'pending')
				state.snapshot.probes[id] = { state: 'cancelled', cleanup: 'pending' };
		});
		render();
		post({ action: 'cancel' });
	}

	/** Keeps cleanup cancellation requestable after the business result is terminal. */
	function hasUnsettledCleanup(snapshot) {
		var groups = [snapshot.probes, snapshot.diagnostic_checks];
		(snapshot.retired_probes || []).forEach(function (cohort) {
			if (cohort) groups.push(cohort.probes);
		});
		return groups.some(function (results) {
			return Object.keys(results || {}).some(function (id) {
				var result = results[id];
				return result && result.cleanup !== undefined && result.cleanup !== 'settled';
			});
		});
	}

	function showCheckProgress() {
		var count = Checks.progress(state.snapshot);
		document.getElementById('deep-progress').textContent = isTrue(state.snapshot.extensive)
			? t('healthcheck.deep_tests.progress', count.completed, count.total)
			: '';
		document.getElementById('btn-cancel').disabled =
			count.completed === count.total && !hasUnsettledCleanup(state.snapshot);
		document.getElementById('chk-extensive').checked = isTrue(state.snapshot.extensive);
		document.getElementById('deep-results').textContent = Checks.report(
			state.snapshot,
			state.config.schema,
			t
		);
	}

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
		if (sharedText !== null) return sharedText;
		var observations = pageObservations();
		if (!observations) return '# Export refused\n\ninvalid_page_observations';
		var preview = Object.assign({}, state.snapshot, {
			page_check_observations: observations
		});
		return Model.formatShareable(preview, state.config.schema, t);
	}

	/**
	 * Enables the toolbar once there is something to act on.
	 * @param {boolean} enabled
	 */
	function setToolbarEnabled(enabled) {
		document.querySelectorAll('.toolbar button').forEach(function (button) {
			button.disabled = !enabled;
		});
		document.getElementById('chk-details').disabled = !enabled;
		document.getElementById('chk-day-log').disabled = !enabled;
		document.getElementById('chk-extensive').disabled = !enabled;
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
		showCheckProgress();
		renderCollection();
		renderDayLog();
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
		if (message.action === 'export_snapshot') {
			completeExport(message);
			return;
		}
		if (message.action === 'day_log') {
			// A late answer for a box the user has since unticked is dropped
			if (!document.getElementById('chk-day-log').checked || dayLog.phase !== 'preparing') return;
			dayLog = isTrue(message.ok)
				? Object.assign({ phase: message.state }, message)
				: { phase: 'failed' };
			if (['ready', 'too_large', 'empty', 'missing'].indexOf(dayLog.phase) < 0)
				dayLog = { phase: 'failed' };
			renderDayLog();
			return;
		}
		if (message.action === 'cancel' && message.snapshot && state.snapshot) {
			message.snapshot.diagnostic_checks = state.snapshot.diagnostic_checks;
			state.snapshot = message.snapshot;
			render();
		}
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
				setStatus(
					lastExportDayLog
						? t('healthcheck.day_log.saved')
						: t('healthcheck.status.saved', message.path || ''),
					'ok'
				);
				break;
			case 'report':
				setStatus(
					lastExportDayLog ? t('healthcheck.day_log.saved') : t('notify.report_bug_body'),
					'ok'
				);
				break;
			default:
				setStatus('', 'info');
		}
	}

	/**
	 * The host's only entry point into the page.
	 * @param {object} message { type: "init"|"snapshot"|"probe"|"action", … }
	 */
	window.receiveDiagnostics = function (message) {
		if (!message || typeof message !== 'object') return;
		if (message.type !== 'action' || message.action === 'cancel' || message.action === 'day_log')
			sharedText = null;
		switch (message.type) {
			case 'init':
				// The host states what it can do; the page never infers it from the driver name.
				if (
					!message.config ||
					!message.config.capabilities ||
					typeof message.config.capabilities.diagnostic_collection !== 'boolean'
				)
					throw new Error('health check host must state its diagnostic_collection capability');
				collection = message.collection || { phase: 'idle' };
				state.config = message.config;
				state.snapshot = message.snapshot;
				resetDayLog();
				startChecks();
				render();
				break;
			case 'snapshot':
				if (!state.config) return;
				state.snapshot = message.snapshot;
				resetDayLog();
				startChecks();
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
			case 'collection':
				if (!message.collection || typeof message.collection.phase !== 'string') return;
				collection = message.collection;
				renderCollection();
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
		return Model.fileName(
			Model.reportInfo(Model.shareSnapshot(state.snapshot, state.config.schema))
		);
	}

	/**
	 * The issue form's identity fields, redacted. The host prefills the report
	 * itself: the text this page sends, the one Copy copies.
	 * @returns {object}
	 */
	function issueFields() {
		var fields = Model.issueFields(
			Model.reportInfo(Model.shareSnapshot(state.snapshot, state.config.schema))
		);
		Object.keys(fields).forEach(function (id) {
			fields[id] = Redact.apply(String(fields[id]), state.config.redaction, state.config.context);
		});
		return fields;
	}

	var TOOLBAR = {
		'btn-copy': function () {
			requestExport('copy');
		},
		'btn-save': function () {
			requestExport('save');
		},
		'btn-report': function () {
			requestExport('report');
		},
		'btn-open-logs': function () {
			post({ action: 'open_path', id: 'logs_dir' });
		},
		'btn-cancel': cancelRequestedChecks,
		'btn-refresh': function () {
			setStatus(t('healthcheck.status.loading'), 'info');
			refreshRequest();
		}
	};

	Object.keys(TOOLBAR).forEach(function (id) {
		document.getElementById(id).addEventListener('click', TOOLBAR[id]);
	});
	[
		'collect-windows',
		'collection-cancel',
		'collection-guided',
		'collection-skip',
		'collection-open'
	].forEach(function (id) {
		document.getElementById('btn-' + id).addEventListener('click', function () {
			post({ action: id.replace(/-/g, '_') });
		});
	});

	document.getElementById('chk-extensive').addEventListener('change', function (event) {
		if (!event.target.checked && state.snapshot) {
			cancelChecks();
			state.snapshot.extensive = false;
		}
		refreshRequest();
	});

	document.getElementById('chk-day-log').addEventListener('change', function (event) {
		if (event.target.checked) {
			dayLog = { phase: 'preparing' };
			sharedText = null;
			renderDayLog();
			post({ action: 'day_log', enabled: true });
		} else {
			dayLog = { phase: 'off' };
			sharedText = null;
			renderDayLog();
			post({ action: 'day_log', enabled: false });
		}
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
		refreshRequest();
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
