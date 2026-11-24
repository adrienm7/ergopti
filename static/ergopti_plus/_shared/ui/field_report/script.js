// _shared/ui/field_report/script.js

/**
 * ==============================================================================
 * MODULE: Field Report Window Page
 * DESCRIPTION:
 * The window Débogage's « Lancer le field report (tous les tests) » opens on
 * the three drivers: the steps of the driver's own field run as they go
 * (pending, running, then their verdict), the steps not run here with their
 * reason, then the verdict counts, the folder of the result files and the
 * buttons to open it, copy the report or create a GitHub issue.
 *
 * FEATURES & RATIONALE:
 * 1. One entry point for the host, window.receiveFieldReport(message), with a
 *    typed message: init (the steps, the steps not run, the label of the
 *    open-folder button), step (one step's new state), done (the counts and
 *    the folder) and action (the result of a request). Linux answers the
 *    bridge's requests through window.__hostBridgeResponse, routed here too.
 * 2. Every change of a step is announced in the polite live region, so a
 *    screen reader follows the run without moving the focus.
 * 3. Buttons send action names only: the host acts on the run it holds and
 *    opens only its own results folder; the page never names a path or a URL.
 * 4. Closing the window during the run asks the host to stop it: the host
 *    closes the run as interrupted.
 * ==============================================================================
 */

(function () {
	'use strict';

	var post = makeHostBridge('field_report');

	// The verdicts of the shared protocol and the two states before them
	var STATES = [
		'pending',
		'running',
		'pass',
		'fail',
		'timeout',
		'skip',
		'needs_person',
		'needs_typing'
	];

	// The host's init message and the run's progress; null until it arrives
	var run = null;

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

	// The live region's line as a key and its arguments: a host may send a step
	// before the locale lands, and the line is said again in its language.
	var statusLine = null;

	/**
	 * Shows and announces one line in the live region.
	 * @param {string} key Locale key of the line ("" for none).
	 * @param {Array} args Its placeholders, filled at render time.
	 * @param {string} kind "ok", "fail" or "info".
	 */
	function setStatus(key, args, kind) {
		statusLine = { key: key, args: args, kind: kind || 'info' };
		renderStatus();
	}

	/** Draws the live region's line in the current strings. */
	function renderStatus() {
		var status = document.getElementById('status');
		var args = statusLine
			? statusLine.args.map(function (arg) {
					return typeof arg === 'function' ? arg() : arg;
				})
			: [];
		status.textContent =
			statusLine && statusLine.key ? t.apply(null, [statusLine.key].concat(args)) : '';
		status.className = 'status ' + (statusLine ? statusLine.kind : 'info');
	}

	// The label key of each state, and of each reason a step is not run for
	var STATE_KEYS = {
		pending: 'field_report.state.pending',
		running: 'field_report.state.running',
		pass: 'field_report.state.pass',
		fail: 'field_report.state.fail',
		timeout: 'field_report.state.timeout',
		skip: 'field_report.state.skip',
		needs_person: 'field_report.state.needs_person',
		needs_typing: 'field_report.state.needs_typing'
	};
	var REASON_KEYS = {
		needs_collector: 'field_check.all.reason.needs_collector',
		needs_person: 'field_check.all.reason.needs_person'
	};

	/**
	 * The label of a state, in the user's language.
	 * @param {string} state
	 * @returns {string}
	 */
	function stateLabel(state) {
		return t(STATE_KEYS[state]);
	}

	/**
	 * One line of the step list: its name and its state, read as one phrase.
	 * @param {string} name
	 * @param {string} state The class of the line (a state, or not_run).
	 * @param {string} label The state's words.
	 */
	function stepLine(name, state, label) {
		var item = document.createElement('li');
		item.className = 'step ' + state;
		item.textContent = name + ' — ' + label;
		document.getElementById('steps').appendChild(item);
	}

	/** Draws the step list from the run. */
	function renderSteps() {
		document.getElementById('steps').textContent = '';
		if (!run) return;
		run.steps.forEach(function (step) {
			stepLine(step.title || step.id, step.state, stateLabel(step.state));
		});
		run.not_run.forEach(function (step) {
			var reason = REASON_KEYS[step.reason];
			stepLine(
				step.id,
				'not_run',
				t('field_report.state.not_run') + (reason ? ' — ' + t(reason) : '')
			);
		});
	}

	/** Draws the summary once the run ended. */
	function renderSummary() {
		var summary = document.getElementById('summary');
		if (!run || !run.done) {
			summary.hidden = true;
			return;
		}
		summary.hidden = false;
		var done = run.done;
		var verdict = isTrue(done.interrupted)
			? 'field_check.all.interrupted'
			: isTrue(done.passed)
				? 'field_check.all.verdict_pass'
				: 'field_check.all.verdict_fail';
		document.getElementById('verdict').textContent = t(verdict);
		var counts = document.getElementById('counts');
		counts.textContent = '';
		STATES.slice(2).forEach(function (state) {
			var count = Number((done.counts || {})[state]) || 0;
			if (count <= 0) return;
			var item = document.createElement('li');
			item.className = 'count ' + state;
			// The locale's own label-value join (common.label_value, {1} and {2})
			item.textContent = t('common.label_value')
				.replace('{1}', stateLabel(state))
				.replace('{2}', String(count));
			counts.appendChild(item);
		});
		document.getElementById('folder').textContent = t('field_report.folder', done.folder);
	}

	/** Renders the window from the run, in the user's language. */
	function render() {
		document.getElementById('heading').textContent = t(
			run && run.done ? 'field_report.heading_done' : 'field_report.heading'
		);
		renderSteps();
		renderSummary();
		var finished = Boolean(run && run.done);
		document.getElementById('btn-cancel').hidden = finished;
		renderStatus();
		document.getElementById('btn-open').textContent = run ? t(run.open_key) : '';
		['btn-open', 'btn-copy', 'btn-issue'].forEach(function (id) {
			document.getElementById(id).disabled = !finished;
		});
	}

	// ===============================
	// ===============================
	// ======= 3/ Host Messages ======
	// ===============================
	// ===============================

	/**
	 * Moves one step to its new state and announces it.
	 * @param {object} message { id, state }
	 */
	function onStep(message) {
		if (!run || STATES.indexOf(message.state) < 0) return;
		var index = -1;
		run.steps.forEach(function (step, position) {
			if (step.id === message.id) index = position;
		});
		if (index < 0) return;
		var step = run.steps[index];
		step.state = message.state;
		render();
		setStatus(
			'field_report.announce',
			[
				index + 1,
				run.steps.length,
				step.title || step.id,
				function () {
					return stateLabel(step.state);
				}
			],
			step.state === 'fail' || step.state === 'timeout' ? 'fail' : 'info'
		);
	}

	/**
	 * Reports the outcome of an action the page asked for.
	 * @param {object} message { action, ok }
	 */
	function onActionResult(message) {
		if (!isTrue(message.ok)) {
			setStatus('field_report.action_failed', [], 'fail');
			return;
		}
		var key = { copy: 'field_check.copied', issue: 'field_report.issue_opened' }[message.action];
		setStatus(key || '', [], key ? 'ok' : 'info');
	}

	/**
	 * The host's only entry point into the page.
	 * @param {object} message { type: "init"|"step"|"done"|"action", … }
	 */
	window.receiveFieldReport = function (message) {
		if (!message || typeof message !== 'object') return;
		switch (message.type) {
			case 'init':
				run = {
					steps: (message.steps || []).map(function (step) {
						return { id: step.id, title: step.title, state: 'pending' };
					}),
					not_run: message.not_run || [],
					open_key: message.open_key,
					done: null
				};
				statusLine = null;
				render();
				break;
			case 'step':
				onStep(message);
				break;
			case 'done':
				if (!run) return;
				run.done = message;
				render();
				setStatus(
					isTrue(message.interrupted)
						? 'field_check.all.interrupted'
						: isTrue(message.passed)
							? 'field_check.all.verdict_pass'
							: 'field_check.all.verdict_fail',
					[],
					isTrue(message.passed) ? 'ok' : 'fail'
				);
				break;
			case 'action':
				onActionResult(message);
				break;
		}
	};

	// Linux answers each request through the bridge response hook
	window.__hostBridgeResponse = function (bridge, isBase64, payload) {
		if (bridge !== 'field_report') return;
		var message = decodeHostBridgeResponse(isBase64, payload);
		if (message !== null) window.receiveFieldReport(message);
	};

	// ==============================
	// ==============================
	// ======= 4/ Page Actions ======
	// ==============================
	// ==============================

	var BUTTONS = {
		'btn-cancel': 'cancel',
		'btn-open': 'open_folder',
		'btn-copy': 'copy',
		'btn-issue': 'issue',
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
