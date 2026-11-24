// _shared/ui/healthcheck/model.js

/**
 * ==============================================================================
 * MODULE: Diagnostics Page Model (Shared)
 * DESCRIPTION:
 * Turns a version 2 diagnostics snapshot into what the diagnostics window
 * shows and what leaves the machine: the structured HTML of the page, the
 * problems of its summary, the Markdown report (copied, saved and prefilled
 * into a GitHub issue) and the other fields of that issue form. Pure: no DOM
 * and no host; the page script (script.js) owns both, so the three drivers
 * render and export through this one formatter.
 *
 * FEATURES & RATIONALE:
 * 1. The schema (_shared/diagnostics/data/schema.json) decides the order of
 *    the sections, which fields exist on which driver, how each value is
 *    formatted and which ones are opt-in. Adding a field is a schema edit, a
 *    collector and two locale keys; nothing here names a field except the
 *    summary's problems and the report identity.
 * 2. A field filled by an asynchronous probe reads as "checking…" until the
 *    probe answers, and states its timeout or failure instead of a blank row.
 * 3. Opt-in values (open applications, device names) are dropped before
 *    anything is rendered or exported when the user has not ticked "Include
 *    details", even if a host sent them.
 * 4. The Markdown report carries the same sections as the page, then the
 *    snapshot itself as a fenced JSON block, so both a person and a tool can
 *    read it. Code fences outgrow every backtick run of their content.
 * 5. The page sends the issue form's identity fields only: the host fills the
 *    form's report field with the exported report itself, the one text the
 *    Copy button copies too.
 * ==============================================================================
 */

(function (global) {
	'use strict';

	// ===============================
	// ===============================
	// ======= 1/ Schema Views =======
	// ===============================
	// ===============================

	/**
	 * True when a schema entry applies to the driver.
	 * @param {{platforms?: string[]}} entry
	 * @param {string} driver
	 * @returns {boolean}
	 */
	function appliesTo(entry, driver) {
		return !Array.isArray(entry.platforms) || entry.platforms.indexOf(driver) >= 0;
	}

	/**
	 * The sections of the schema that apply to a driver, with only its fields.
	 * @param {object} schema
	 * @param {string} driver
	 * @returns {object[]}
	 */
	function sectionsFor(schema, driver) {
		if (!schema || !Array.isArray(schema.sections))
			throw new Error('diagnostics: the schema has no sections');
		return schema.sections
			.filter(function (section) {
				return appliesTo(section, driver);
			})
			.map(function (section) {
				var view = {};
				Object.keys(section).forEach(function (key) {
					view[key] = section[key];
				});
				view.kind = section.kind || 'fields';
				view.fields = (section.fields || []).filter(function (field) {
					return appliesTo(field, driver);
				});
				return view;
			});
	}

	/**
	 * The probe that fills a field on a driver, or null.
	 * @param {object} field
	 * @param {string} driver
	 * @returns {string|null}
	 */
	function probeFor(field, driver) {
		if (typeof field.probe === 'string') return field.probe;
		if (field.probe && typeof field.probe === 'object') return field.probe[driver] || null;
		return null;
	}

	// ==========================
	// ==========================
	// ======= 2/ Values ========
	// ==========================
	// ==========================

	/**
	 * True for a boolean true, or the 1 the AutoHotkey JSON writer sends for it.
	 * @param {*} value
	 * @returns {boolean}
	 */
	function isTrue(value) {
		return value === true || value === 1;
	}

	/**
	 * True when a value carries nothing to show.
	 * @param {*} value
	 * @returns {boolean}
	 */
	function isAbsent(value) {
		return value === undefined || value === null || value === '';
	}

	/**
	 * Formats a duration in seconds as "2h 04m 37s", "3m 05s" or "45s", the
	 * format of the shared Lua snapshot module.
	 * @param {number} seconds
	 * @returns {string}
	 */
	function formatSeconds(seconds) {
		var sec = Math.floor(Number(seconds) || 0);
		var h = Math.floor(sec / 3600);
		var m = Math.floor((sec % 3600) / 60);
		var s = sec % 60;
		var pad = function (n) {
			return (n < 10 ? '0' : '') + n;
		};
		if (h > 0) return h + 'h ' + pad(m) + 'm ' + pad(s) + 's';
		if (m > 0) return m + 'm ' + pad(s) + 's';
		return s + 's';
	}

	/**
	 * Formats a byte count in GB with one decimal, or in MB below one GB.
	 * @param {number} bytes
	 * @returns {string}
	 */
	function formatBytes(bytes) {
		var n = Number(bytes);
		if (n >= 1073741824) return (n / 1073741824).toFixed(1) + ' GB';
		return Math.round(n / 1048576) + ' MB';
	}

	/**
	 * The text of a field value, or null when there is none.
	 * @param {object} field Schema field.
	 * @param {*} value Raw value from the snapshot.
	 * @param {function(string, ...*): string} t Translator.
	 * @returns {string|null}
	 */
	function formatValue(field, value, t) {
		if (isAbsent(value)) return null;
		switch (field.type) {
			case 'bool':
				return t(isTrue(value) ? 'healthcheck.value.yes' : 'healthcheck.value.no');
			case 'bytes':
				return typeof value === 'number' ? formatBytes(value) : String(value);
			case 'seconds':
				return formatSeconds(value);
			case 'ms':
				return Math.round(Number(value)) + ' ms';
			case 'percent':
				return Math.round(Number(value) * 10) / 10 + '%';
			case 'list':
				if (!Array.isArray(value)) return String(value);
				return value.length > 0 ? value.map(String).join(', ') : t('healthcheck.value.none');
			case 'log':
				if (!Array.isArray(value)) return String(value);
				return value.length > 0 ? value.map(String).join('\n') : null;
			case 'enum':
				return t(field.enum_key + value);
			default:
				return String(value);
		}
	}

	/**
	 * The text of an asynchronous probe that has not produced a value.
	 * @param {object|undefined} result { state, ms, detail }
	 * @param {function(string, ...*): string} t
	 * @returns {{text: string, state: string}}
	 */
	function probeState(result, t) {
		var state = result && result.state ? result.state : 'pending';
		switch (state) {
			case 'pending':
				return { text: t('healthcheck.probe.pending'), state: 'pending' };
			case 'timeout':
				return {
					text: t('healthcheck.probe.timeout', Math.round(Number(result.ms) || 0)),
					state: 'fail'
				};
			case 'error':
				return { text: t('healthcheck.probe.error', String(result.detail || '')), state: 'fail' };
			case 'not_run':
				return {
					text: t(
						'healthcheck.probe.not_run',
						t('healthcheck.deep_tests.reason.' + (result.reason || 'opt_in_required'))
					),
					state: 'muted'
				};
			case 'cancelled':
				return { text: t('healthcheck.probe.cancelled'), state: 'muted' };
			case 'disabled':
				return { text: t('healthcheck.probe.disabled'), state: 'muted' };
			case 'unsupported':
				return { text: t('healthcheck.probe.unsupported'), state: 'muted' };
			default:
				return { text: t('healthcheck.value.unknown'), state: 'muted' };
		}
	}

	/**
	 * What one field of a section shows.
	 * @param {object} field Schema field.
	 * @param {object} data The section's values.
	 * @param {object} snapshot
	 * @param {function(string, ...*): string} t
	 * @returns {{text: string, state: string}}
	 */
	function fieldDisplay(field, data, snapshot, t) {
		var probeId = probeFor(field, snapshot.driver);
		var result = probeId && snapshot.probes ? snapshot.probes[probeId] : undefined;
		var text = formatValue(field, data[field.id], t);
		if (text !== null) {
			var state = 'value';
			if (result && result.state === 'ok' && field.show_ms && typeof result.ms === 'number') {
				text += ' (' + Math.round(result.ms) + ' ms)';
				state = 'ok';
			} else if (result && (result.state === 'error' || result.state === 'timeout')) {
				state = 'fail';
			}
			return { text: text, state: state };
		}
		if (probeId && (!result || result.state !== 'ok')) return probeState(result, t);
		return { text: t('healthcheck.value.unknown'), state: 'muted' };
	}

	// ==========================
	// ==========================
	// ======= 3/ Opt-In ========
	// ==========================
	// ==========================

	/**
	 * A copy of the snapshot without the opt-in fields and columns.
	 * @param {object} snapshot
	 * @param {object} schema
	 * @returns {object}
	 */
	function withoutOptIn(snapshot, schema) {
		var copy = JSON.parse(JSON.stringify(snapshot));
		copy.detailed = false;
		schema.sections.forEach(function (section) {
			var data = copy.sections && copy.sections[section.id];
			if (!data || typeof data !== 'object') return;
			(section.fields || []).forEach(function (field) {
				if (field.opt_in) delete data[field.id];
			});
			if (Array.isArray(section.opt_in_columns) && Array.isArray(data.items)) {
				data.items.forEach(function (item) {
					section.opt_in_columns.forEach(function (column) {
						delete item[column];
					});
				});
			}
		});
		return copy;
	}

	// ============================
	// ============================
	// ======= 4/ Problems ========
	// ============================
	// ============================

	/**
	 * The section values of a snapshot, never undefined.
	 * @param {object} snapshot
	 * @param {string} id
	 * @returns {object}
	 */
	function sectionData(snapshot, id) {
		var data = snapshot.sections && snapshot.sections[id];
		return data && typeof data === 'object' ? data : {};
	}

	/** Classifies recorded coverage independently of completion counts. */
	function diagnosticCoverage(snapshot, schema) {
		if (!schema.diagnostic_checks) return null;
		if (!isTrue(snapshot.extensive)) return 'healthcheck.summary.quick';
		function unconfirmed(result) {
			return result.cleanup !== undefined && result.cleanup !== 'settled';
		}
		var complete = schema.diagnostic_checks.items
			.filter(function (spec) {
				return !spec.reason;
			})
			.every(function (spec) {
				var result = (snapshot.diagnostic_checks || {})[spec.id];
				return result && result.state === 'ok' && !unconfirmed(result);
			});
		Object.keys(schema.probes || {}).forEach(function (id) {
			if (!appliesTo(schema.probes[id], snapshot.driver)) return;
			var result = (snapshot.probes || {})[id];
			if (!result || (result.state !== 'ok' && result.state !== 'disabled') || unconfirmed(result))
				complete = false;
		});
		(snapshot.retired_probes || []).forEach(function (cohort) {
			Object.keys(cohort.probes || {}).forEach(function (id) {
				var result = cohort.probes[id];
				if (
					!result ||
					unconfirmed(result) ||
					(result.state !== 'ok' && result.state !== 'disabled')
				)
					complete = false;
			});
		});
		return complete ? 'healthcheck.summary.observed' : 'healthcheck.summary.incomplete';
	}

	/** Adds failed recorded diagnostics; cancellation and NOT_RUN remain neutral. */
	function diagnosticProblems(snapshot, schema) {
		var list = [];
		function failed(result) {
			return result && (result.state === 'error' || result.state === 'timeout');
		}
		(schema.diagnostic_checks ? schema.diagnostic_checks.items : []).forEach(function (spec) {
			if (failed((snapshot.diagnostic_checks || {})[spec.id]))
				list.push({
					key: 'healthcheck.problem.diagnostic_check',
					args: [{ key: spec.label }],
					action: null
				});
		});
		function probes(results, retired) {
			Object.keys(schema.probes || {}).forEach(function (id) {
				if (!appliesTo(schema.probes[id], snapshot.driver) || !failed((results || {})[id])) return;
				// The original summary already names these two current network failures.
				if (
					!retired &&
					(id === 'github_api' ||
						(id === 'ai_health' && isTrue(sectionData(snapshot, 'ai').ai_enabled)))
				)
					return;
				list.push({
					key: 'healthcheck.problem.diagnostic_check',
					args: [schema.probes[id].label ? { key: schema.probes[id].label } : id],
					action: null
				});
			});
		}
		probes(snapshot.probes, false);
		(snapshot.retired_probes || []).forEach(function (cohort) {
			probes(cohort.probes, true);
		});
		return list;
	}

	/**
	 * The problems the summary lists, each with the action that fixes it when
	 * one exists. A problem is a locale key and its arguments; an argument
	 * written { key } is itself translated.
	 * @param {object} snapshot
	 * @param {object} schema
	 * @returns {Array<{key: string, args: Array, action: (null|{name: string, id: string})}>}
	 */
	function problems(snapshot, schema) {
		var list = [];
		var permissions = (schema.permissions && schema.permissions[snapshot.driver]) || {};
		var probes = snapshot.probes || {};
		var failed = function (id) {
			return probes[id] && (probes[id].state === 'error' || probes[id].state === 'timeout');
		};
		if (isTrue(sectionData(snapshot, 'input').paused)) {
			list.push({ key: 'healthcheck.problem.paused', args: [], action: null });
		}
		(sectionData(snapshot, 'permissions').items || []).forEach(function (item) {
			// `unavailable`: granted in principle but not working (the macOS remap
			// guardian), which leaves the feature inert just like a missing grant
			if (item.state !== 'missing' && item.state !== 'unavailable') return;
			list.push({
				key:
					item.state === 'missing'
						? 'healthcheck.problem.permission'
						: 'healthcheck.problem.unavailable',
				args: [{ key: 'healthcheck.permission.' + item.id }],
				action:
					permissions[item.id] && permissions[item.id].settings
						? { name: 'open_settings', id: item.id }
						: null
			});
		});
		if (failed('github_api'))
			list.push({ key: 'healthcheck.problem.network', args: [], action: null });
		if (isTrue(sectionData(snapshot, 'ai').ai_enabled) && failed('ai_health')) {
			list.push({ key: 'healthcheck.problem.ai', args: [], action: null });
		}
		var errors = Number(sectionData(snapshot, 'issues').err_count) || 0;
		if (errors > 0) {
			list.push({
				key: 'healthcheck.problem.errors',
				args: [errors],
				action: { name: 'open_path', id: 'errors_today' }
			});
		}
		var failedModules = sectionData(snapshot, 'developer').modules_failed;
		if (Array.isArray(failedModules) && failedModules.length > 0) {
			list.push({ key: 'healthcheck.problem.modules', args: [failedModules.length], action: null });
		}
		if (
			sectionData(snapshot, 'input').keymap_resolved === false ||
			sectionData(snapshot, 'input').keymap_resolved === 0
		) {
			list.push({ key: 'healthcheck.problem.keymap', args: [], action: null });
		}
		return list.concat(diagnosticProblems(snapshot, schema));
	}

	/**
	 * The text of one problem.
	 * @param {{key: string, args: Array}} problem
	 * @param {function(string, ...*): string} t
	 * @returns {string}
	 */
	function problemText(problem, t) {
		var args = problem.args.map(function (arg) {
			return arg && typeof arg === 'object' && arg.key ? t(arg.key) : arg;
		});
		return t.apply(null, [problem.key].concat(args));
	}

	// ===========================
	// ===========================
	// ======= 5/ The Page =======
	// ===========================
	// ===========================

	/**
	 * A button the page script dispatches to the host, by action and id only.
	 * @param {string} action
	 * @param {string} id
	 * @param {string} label
	 * @returns {string}
	 */
	function actionButton(action, id, label) {
		return (
			'<button type="button" class="row-action" data-action="' +
			escapeHtml(action) +
			'" data-id="' +
			escapeHtml(id) +
			'">' +
			escapeHtml(label) +
			'</button>'
		);
	}

	/**
	 * The label of an item column.
	 * @param {string} sectionId
	 * @param {string} column
	 * @param {function(string, ...*): string} t
	 * @returns {string}
	 */
	function columnLabel(sectionId, column, t) {
		return t('healthcheck.column.' + sectionId + '.' + column);
	}

	/**
	 * The text of one item cell.
	 * @param {object} section
	 * @param {object} schema
	 * @param {string} column
	 * @param {*} value
	 * @param {function(string, ...*): string} t
	 * @returns {string}
	 */
	function itemText(section, schema, column, value, t) {
		if (isAbsent(value)) return '';
		if (section.id === 'features' && column === 'id') {
			var key = schema.feature_labels && schema.feature_labels[value];
			return key ? t(key) : String(value);
		}
		if (section.id === 'features' && column === 'enabled') {
			return t(isTrue(value) ? 'healthcheck.value.on' : 'healthcheck.value.off');
		}
		if (section.id === 'permissions' && column === 'id')
			return t('healthcheck.permission.' + value);
		if (section.id === 'permissions' && column === 'state') return t('healthcheck.state.' + value);
		if (section.id === 'configuration_files' && column === 'id')
			return t('healthcheck.config_file.' + value);
		if (section.id === 'configuration_files' && column === 'state')
			return t('healthcheck.config_state.' + value);
		if (section.id === 'configuration' && column === 'type')
			return t('healthcheck.setting_type.' + value);
		if (section.id === 'peripherals' && column === 'bus') return t('healthcheck.bus.' + value);
		if (section.id === 'peripherals' && column === 'kind') return t('healthcheck.device.' + value);
		// The host sends the manifest's reason key: the report is in the reader's language
		if (section.id === 'unavailable' && column === 'reason') return t(value);
		return String(value);
	}

	/**
	 * The CSS state of an item row.
	 * @param {object} section
	 * @param {object} item
	 * @returns {string}
	 */
	function itemState(section, item) {
		if (section.id === 'permissions') {
			if (item.state === 'granted') return 'ok';
			if (item.state === 'missing' || item.state === 'unavailable') return 'fail';
			return 'muted';
		}
		if (section.id === 'features') return isTrue(item.enabled) ? 'ok' : 'muted';
		if (section.id === 'configuration_files') {
			if (item.state === 'ok') return 'ok';
			return item.state === 'missing' ? 'muted' : 'fail';
		}
		return 'value';
	}

	/**
	 * Orders feature labels in the reader's language, leaving the host snapshot
	 * untouched. Decorative prefixes must not decide alphabetical position.
	 * @param {object} section
	 * @param {object} data
	 * @param {object} schema
	 * @param {function(string, ...*): string} t
	 * @returns {object[]}
	 */
	function sectionItems(section, data, schema, t) {
		var items = Array.isArray(data.items) ? data.items : [];
		if (section.id !== 'features') return items;
		var labelled = items.map(function (item) {
			return {
				item: item,
				label: itemText(section, schema, 'id', item.id, t).replace(/^[^\p{L}\p{N}]+/u, '')
			};
		});
		labelled.sort(function (left, right) {
			return (
				left.label.localeCompare(right.label, global._i18n_locale, { sensitivity: 'base' }) ||
				String(left.item.id).localeCompare(String(right.item.id))
			);
		});
		return labelled.map(function (entry) {
			return entry.item;
		});
	}

	/**
	 * What an items section that a probe completes says while that probe has
	 * not answered with the whole list, or null.
	 * @param {object} section
	 * @param {object} snapshot
	 * @param {function(string, ...*): string} t
	 * @returns {{text: string, state: string}|null}
	 */
	function itemsProbeNote(section, snapshot, t) {
		var probeId = probeFor(section, snapshot.driver);
		if (!probeId) return null;
		var result = snapshot.probes ? snapshot.probes[probeId] : undefined;
		return result && result.state === 'ok' ? null : probeState(result, t);
	}

	/**
	 * The HTML of an items section.
	 * @param {object} section
	 * @param {object} data
	 * @param {object} snapshot
	 * @param {object} schema
	 * @param {function(string, ...*): string} t
	 * @returns {string}
	 */
	function renderItems(section, data, snapshot, schema, t) {
		var items = sectionItems(section, data, schema, t);
		var note = itemsProbeNote(section, snapshot, t);
		var noteHtml = note ? '<p class="' + note.state + '">' + escapeHtml(note.text) + '</p>' : '';
		if (items.length === 0) {
			return (
				(note ? '' : '<p class="empty">' + escapeHtml(t('healthcheck.value.none')) + '</p>') +
				noteHtml
			);
		}
		var permissions = (schema.permissions && schema.permissions[snapshot.driver]) || {};
		var columns = section.columns.filter(function (column) {
			return snapshot.detailed || (section.opt_in_columns || []).indexOf(column) < 0;
		});
		var html = '<table class="items"><thead><tr>';
		columns.forEach(function (column) {
			html += '<th scope="col">' + escapeHtml(columnLabel(section.id, column, t)) + '</th>';
		});
		html += '</tr></thead><tbody>';
		items.forEach(function (item) {
			html += '<tr class="' + itemState(section, item) + '">';
			columns.forEach(function (column, index) {
				var cell = escapeHtml(itemText(section, schema, column, item[column], t));
				if (section.id === 'permissions' && index === columns.length - 1) {
					// `not_used`: the feature needing it is switched off, so there is
					// nothing to grant (the macOS remap guardian while Ergopti does not
					// use Karabiner)
					if (
						item.state !== 'granted' &&
						item.state !== 'not_used' &&
						permissions[item.id] &&
						permissions[item.id].settings
					) {
						cell +=
							' ' + actionButton('open_settings', item.id, t('healthcheck.action.open_settings'));
					}
					if (item.state === 'missing' && permissions[item.id] && permissions[item.id].fix) {
						cell +=
							'<p class="fix">' + escapeHtml(t('healthcheck.permission_fix.' + item.id)) + '</p>';
					}
				}
				html += '<td>' + cell + '</td>';
			});
			html += '</tr>';
		});
		return html + '</tbody></table>' + noteHtml;
	}

	/**
	 * The HTML of a fields section: a table of the short values, then an H3
	 * and a block for each log value.
	 * @param {object} section
	 * @param {object} data
	 * @param {object} snapshot
	 * @param {function(string, ...*): string} t
	 * @returns {string}
	 */
	function renderFields(section, data, snapshot, t) {
		var rows = '';
		var blocks = '';
		section.fields.forEach(function (field) {
			if (field.opt_in && !snapshot.detailed) return;
			var label = t('healthcheck.field.' + field.id);
			var shown = fieldDisplay(field, data, snapshot, t);
			if (field.type === 'log') {
				if (shown.state === 'muted') return;
				blocks += '<h3>' + escapeHtml(label) + '</h3><pre>' + escapeHtml(shown.text) + '</pre>';
				return;
			}
			// The cell carries the value's state, which its text also says.
			var cell = escapeHtml(shown.text);
			if (field.type === 'path' && shown.state === 'value')
				cell += ' ' + actionButton('open_path', field.id, t('healthcheck.action.open'));
			rows +=
				'<tr><th scope="row">' +
				escapeHtml(label) +
				'</th><td class="' +
				shown.state +
				'">' +
				cell +
				'</td></tr>';
		});
		return (rows ? '<table class="fields">' + rows + '</table>' : '') + blocks;
	}

	/**
	 * The HTML of the summary: every problem, with its fix when one exists.
	 * @param {object} snapshot
	 * @param {object} schema
	 * @param {function(string, ...*): string} t
	 * @returns {string}
	 */
	function renderSummary(snapshot, schema, t) {
		var list = problems(snapshot, schema);
		var coverage = diagnosticCoverage(snapshot, schema);
		var scope = coverage
			? '<p class="muted">' + escapeHtml(t('healthcheck.summary.scope')) + '</p>'
			: '';
		if (list.length === 0)
			return (
				'<p class="' +
				(!coverage || coverage === 'healthcheck.summary.observed' ? 'ok' : 'muted') +
				'">' +
				escapeHtml(t(coverage || 'healthcheck.problem.none')) +
				'</p>' +
				scope
			);
		var html = '<ul class="problems">';
		list.forEach(function (problem) {
			html += '<li class="fail">' + escapeHtml(problemText(problem, t));
			if (problem.action && problem.action.name === 'open_settings') {
				html +=
					' ' +
					actionButton('open_settings', problem.action.id, t('healthcheck.action.open_settings'));
			} else if (problem.action && problem.action.name === 'open_path') {
				html += ' ' + actionButton('open_path', problem.action.id, t('healthcheck.action.open'));
			}
			html += '</li>';
		});
		return html + '</ul>' + scope;
	}

	/**
	 * The page's HTML, one H2 section per schema section.
	 * @param {object} snapshot
	 * @param {object} schema
	 * @param {function(string, ...*): string} t
	 * @returns {string}
	 */
	function renderHtml(snapshot, schema, t) {
		var shown = snapshot.detailed ? snapshot : withoutOptIn(snapshot, schema);
		var html = '';
		sectionsFor(schema, shown.driver).forEach(function (section) {
			var title = escapeHtml(t('healthcheck.section.' + section.id));
			var body;
			if (section.kind === 'summary') body = renderSummary(shown, schema, t);
			else if (section.kind === 'items')
				body = renderItems(section, sectionData(shown, section.id), shown, schema, t);
			else body = renderFields(section, sectionData(shown, section.id), shown, t);
			if (section.collapsed) {
				html +=
					'<details class="section" id="section-' +
					section.id +
					'"><summary><h2>' +
					title +
					'</h2></summary>' +
					body +
					'</details>';
			} else {
				html +=
					'<section class="section" id="section-' +
					section.id +
					'"><h2>' +
					title +
					'</h2>' +
					body +
					'</section>';
			}
		});
		return html;
	}

	// ==============================
	// ==============================
	// ======= 6/ The Report ========
	// ==============================
	// ==============================

	/**
	 * A code fence longer than every backtick run in the text, so the report can
	 * never close its own block.
	 * @param {string} text
	 * @returns {string}
	 */
	function fenceFor(text) {
		var longest = 0;
		(text.match(/`+/g) || []).forEach(function (run) {
			if (run.length > longest) longest = run.length;
		});
		return new Array(Math.max(3, longest + 1) + 1).join('`');
	}

	/**
	 * Escapes a Markdown table cell.
	 * @param {*} value
	 * @returns {string}
	 */
	function cell(value) {
		return String(isAbsent(value) ? '' : value)
			.replace(/\\/g, '\\\\')
			.replace(/[\r\n]+/g, ' ')
			.replace(/\|/g, '\\|');
	}

	/**
	 * The Markdown of one section.
	 * @param {object} section
	 * @param {object} snapshot
	 * @param {object} schema
	 * @param {function(string, ...*): string} t
	 * @returns {string[]}
	 */
	function markdownSection(section, snapshot, schema, t) {
		var lines = ['## ' + t('healthcheck.section.' + section.id), ''];
		var data = sectionData(snapshot, section.id);
		if (section.kind === 'summary') {
			var list = problems(snapshot, schema);
			var coverage = diagnosticCoverage(snapshot, schema);
			if (coverage) lines.push(t('healthcheck.summary.scope'));
			if (list.length === 0) lines.push(t(coverage || 'healthcheck.problem.none'));
			list.forEach(function (problem) {
				lines.push('- ' + problemText(problem, t));
			});
			lines.push('');
			return lines;
		}
		if (section.kind === 'items') {
			var items = sectionItems(section, data, schema, t);
			var note = itemsProbeNote(section, snapshot, t);
			if (items.length === 0) {
				lines.push(note ? note.text : t('healthcheck.value.none'), '');
				return lines;
			}
			var columns = section.columns.filter(function (column) {
				return snapshot.detailed || (section.opt_in_columns || []).indexOf(column) < 0;
			});
			lines.push(
				'| ' +
					columns
						.map(function (column) {
							return cell(columnLabel(section.id, column, t));
						})
						.join(' | ') +
					' |'
			);
			lines.push(
				'|' +
					columns
						.map(function () {
							return ' --- |';
						})
						.join('')
			);
			items.forEach(function (item) {
				lines.push(
					'| ' +
						columns
							.map(function (column) {
								return cell(itemText(section, schema, column, item[column], t));
							})
							.join(' | ') +
						' |'
				);
			});
			lines.push('');
			if (note) lines.push(note.text, '');
			return lines;
		}
		var rows = [];
		var blocks = [];
		section.fields.forEach(function (field) {
			if (field.opt_in && !snapshot.detailed) return;
			var label = t('healthcheck.field.' + field.id);
			var shown = fieldDisplay(field, data, snapshot, t);
			if (field.type === 'log') {
				if (shown.state === 'muted') return;
				var fence = fenceFor(shown.text);
				blocks.push(
					'<details><summary>' + escapeHtml(label) + '</summary>',
					'',
					fence + 'text',
					shown.text,
					fence,
					'',
					'</details>',
					''
				);
				return;
			}
			rows.push('| ' + cell(label) + ' | ' + cell(shown.text) + ' |');
		});
		if (rows.length > 0) lines.push('| | |', '| --- | --- |');
		return lines.concat(rows, rows.length > 0 ? [''] : [], blocks);
	}

	/**
	 * The full report: an identity table, every section, then the snapshot as
	 * a fenced JSON block. Nothing here redacts: the page script redacts the
	 * finished text, the single place that decides what leaves the machine.
	 * @param {object} snapshot
	 * @param {object} schema
	 * @param {function(string, ...*): string} t
	 * @returns {string}
	 */
	function formatMarkdown(snapshot, schema, t) {
		var shown = snapshot.detailed ? snapshot : withoutOptIn(snapshot, schema);
		var info = reportInfo(shown);
		var lines = [
			'# ErgoptiPlus — ' + t('menu.debug.healthcheck'),
			'',
			'| | |',
			'| --- | --- |',
			'| ' + cell(t('healthcheck.export.version')) + ' | ' + cell(info.version) + ' |',
			'| ' + cell(t('healthcheck.export.commit')) + ' | ' + cell(info.commit) + ' |',
			'| ' + cell(t('healthcheck.export.system')) + ' | ' + cell(info.os) + ' |',
			'| ' + cell(t('healthcheck.export.driver')) + ' | ' + cell(info.driver) + ' |',
			'| ' + cell(t('healthcheck.export.generated')) + ' | ' + cell(info.generated_utc) + ' |',
			'| ' + cell(t('healthcheck.export.schema')) + ' | ' + cell(shown.schema_version) + ' |',
			'| ' +
				cell(t('healthcheck.export.details')) +
				' | ' +
				cell(t(shown.detailed ? 'healthcheck.value.yes' : 'healthcheck.value.no')) +
				' |',
			''
		];
		sectionsFor(schema, shown.driver).forEach(function (section) {
			var body = markdownSection(section, shown, schema, t);
			if (section.collapsed) {
				lines.push(
					'<details><summary>' + escapeHtml(t('healthcheck.section.' + section.id)) + '</summary>',
					''
				);
				lines = lines.concat(body.slice(2), ['</details>', '']);
			} else {
				lines = lines.concat(body);
			}
		});
		var json = JSON.stringify(shown, null, 2);
		var fence = fenceFor(json);
		lines.push(
			'<details><summary>' + escapeHtml(t('healthcheck.export.json')) + '</summary>',
			'',
			fence + 'json',
			json,
			fence,
			'',
			'</details>',
			''
		);
		return lines.join('\n');
	}

	// ====================================
	// ====================================
	// ======= 7/ Issue And File ==========
	// ====================================
	// ====================================

	/**
	 * The report's identity: what the issue form and the file name are built from.
	 * @param {object} snapshot
	 * @returns {object} { driver, version, commit, os, generated_utc, file_stamp }
	 */
	function reportInfo(snapshot) {
		var versions = sectionData(snapshot, 'versions');
		var system = sectionData(snapshot, 'system');
		var generated = String(snapshot.generated_at || '');
		return {
			driver: String(snapshot.driver || 'unknown'),
			version: String(isAbsent(versions.ergopti_version) ? 'unknown' : versions.ergopti_version),
			commit: String(isAbsent(versions.commit) ? '' : versions.commit),
			os: String(isAbsent(system.os) ? 'unknown' : system.os),
			generated_utc: generated,
			file_stamp: generated.replace(/[-:]/g, '').replace(/\.\d+/, '')
		};
	}

	/**
	 * The saved report's name: driver, version and UTC time, file-name safe.
	 * @param {object} info { driver, version, file_stamp }
	 * @returns {string}
	 */
	function fileName(info) {
		var safe = function (value) {
			// One "_" per code point: a non-ASCII character is one character
			return Array.from(String(value))
				.map(function (ch) {
					return ch.charCodeAt(0) > 127 ? '_' : ch;
				})
				.join('')
				.replace(/[^A-Za-z0-9._-]/g, '_');
		};
		return (
			'ergopti-diagnostics-' +
			safe(info.driver) +
			'-' +
			safe(info.version) +
			'-' +
			safe(info.file_stamp) +
			'.md'
		);
	}

	/**
	 * The identity fields prefilled into the bug form. The host adds the report
	 * itself as the form's report field and builds the URL.
	 * @param {object} info From reportInfo().
	 * @returns {object}
	 */
	function issueFields(info) {
		return { version: info.version, os: info.os, driver: info.driver };
	}

	/**
	 * One configuration row {setting, type, value}. A value outside the grammar of
	 * its type drops the whole row: an enum is a bare identifier, a text or a list
	 * only a count, so a path or a sentence matches none of them.
	 * @param {*} value
	 * @returns {object|undefined}
	 */
	function projectSettingRow(value) {
		if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
		var setting = value.setting,
			kind = value.type,
			text = value.value;
		if (
			typeof setting !== 'string' ||
			setting.length > 96 ||
			!/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$/.test(setting) ||
			typeof text !== 'string'
		)
			return undefined;
		var fits;
		if (kind === 'boolean') fits = text === 'true' || text === 'false';
		else if (kind === 'number')
			fits =
				text.length <= 24 && /^-?\d[\d.]*e?[+-]?\d*$/i.test(text) && Number.isFinite(Number(text));
		else if (kind === 'enum') fits = /^[A-Za-z0-9_+-]{1,40}$/.test(text);
		else if (kind === 'text' || kind === 'list') fits = /^\d{1,6}$/.test(text);
		else fits = false;
		return fits ? { setting: setting, type: kind, value: text } : undefined;
	}

	/** Projects only typed fields declared by the canonical sharing policy. */
	function projectShare(value, rule) {
		if (
			[
				'object',
				'array',
				'enum',
				'boolean',
				'number',
				'integer',
				'version',
				'hash',
				'utc',
				'commit',
				'runtime',
				'platform_name',
				'setting_row'
			].indexOf(rule.kind) < 0
		)
			throw new Error('Unknown diagnostic sharing rule');
		if (rule.kind === 'object') {
			if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
			var result = {};
			Object.keys(rule.fields).forEach(function (key) {
				if (
					!Object.prototype.hasOwnProperty.call(value, key) &&
					rule.fields[key].default === undefined
				)
					return;
				var item = projectShare(value[key], rule.fields[key]);
				if (item !== undefined) result[key] = item;
			});
			return result;
		}
		if (rule.kind === 'array') {
			if (!Array.isArray(value)) return [];
			var items = [];
			for (var entry of value) {
				if (rule.max_items !== undefined && items.length >= rule.max_items) break;
				var kept = projectShare(entry, rule.item);
				if (kept !== undefined) items.push(kept);
			}
			return items;
		}
		if (rule.kind === 'setting_row') return projectSettingRow(value);
		if (rule.kind === 'enum')
			return typeof value === 'string' && rule.values.indexOf(value) >= 0 ? value : rule.default;
		if (rule.kind === 'boolean') {
			if (value === true || value === 1) return true;
			if (value === false || value === 0) return false;
			return undefined;
		}
		if (rule.kind === 'number' || rule.kind === 'integer')
			return typeof value === 'number' &&
				Number.isFinite(value) &&
				Math.abs(value) <= Number.MAX_SAFE_INTEGER &&
				(rule.minimum === undefined || value >= rule.minimum) &&
				(rule.maximum === undefined || value <= rule.maximum) &&
				(rule.kind !== 'integer' || Number.isSafeInteger(value))
				? value
				: undefined;
		if (typeof value !== 'string') return undefined;
		if (rule.kind === 'commit') {
			var binding = /^([a-fA-F0-9]{7,64})(?: \((?:build|git)\))?$/.exec(value);
			return binding ? binding[1] : undefined;
		}
		if (rule.kind === 'runtime') {
			for (var prefix of rule.prefixes)
				for (var suffix of rule.suffixes) {
					if (!value.startsWith(prefix) || !value.endsWith(suffix)) continue;
					var end = suffix ? value.length - suffix.length : value.length;
					var version = projectShare(value.slice(prefix.length, end), { kind: 'version' });
					if (version !== undefined) return version;
				}
			return undefined;
		}
		if (rule.kind === 'version')
			return /^\d+(?:\.\d+){1,3}(?:-dev\.\d+|-beta\d+)?$/.test(value) ? value : undefined;
		// An operating system or desktop name from the host: one of the rule's known
		// families, then a closed set of name characters. A path, an address, a
		// sentence or a name that is not listed never matches.
		if (rule.kind === 'platform_name') {
			if (value.length > 64) return undefined;
			for (var family of rule.families) {
				var rest = value.slice(family.length);
				if (
					value.slice(0, family.length).toLowerCase() === family.toLowerCase() &&
					/^[A-Za-z0-9 .+/:(),!-]*$/.test(rest) &&
					!/^[A-Za-z]/.test(rest)
				)
					return value;
			}
			return undefined;
		}
		if (rule.kind === 'hash') return /^[a-fA-F0-9]{7,64}$/.test(value) ? value : undefined;
		if (rule.kind === 'utc')
			return /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z$/.test(value) ? value : undefined;
		throw new Error('Unknown diagnostic sharing rule');
	}

	/** Closed log facts contain no raw message, path, generation token or inferred cause. */
	function recentErrorFacts(entries, source, schema) {
		var observed = Array.isArray(entries),
			events = [],
			count = 0,
			specs = schema.recent_error_facts;
		(observed ? entries : []).forEach(function (entry, index) {
			count += 1;
			var first = typeof entry === 'string' ? entry.split(/[\r\n]/, 1)[0] : '';
			var start = first.indexOf(specs.owner_prefix);
			var marker =
				start < 0 ? -1 : first.indexOf(specs.failure_marker, start + specs.owner_prefix.length);
			var reason = marker < 0 ? '' : first.slice(marker + specs.failure_marker.length);
			for (var rule of specs.rules) {
				var event,
					candidate = reason;
				if (rule.message_prefix) {
					var position = first.indexOf(rule.message_prefix);
					candidate = position < 0 ? '' : first.slice(position);
					if (rule.number_marker) {
						var numberAt = candidate.indexOf(rule.number_marker, rule.message_prefix.length);
						candidate = numberAt < 0 ? '' : candidate.slice(numberAt);
					}
				}
				if (rule.literal && candidate === rule.literal)
					event = { entry_index: index + 1, code: rule.code };
				else if (rule.prefix && candidate.startsWith(rule.prefix)) {
					var value = candidate.slice(rule.prefix.length);
					if (rule.suffix) {
						var finish = value.indexOf(rule.suffix);
						value = finish < 0 ? '' : value.slice(0, finish);
					}
					if (/^-?\d+$/.test(value)) {
						var number = projectShare(Number(value), {
							kind: 'integer',
							minimum: rule.minimum,
							maximum: rule.maximum
						});
						if (number !== undefined && String(number) === value) {
							event = { entry_index: index + 1, code: rule.code };
							event[rule.field] = number;
						}
					}
				}
				if (event) {
					events.push(event);
					break;
				}
			}
		});
		return {
			observed: observed,
			source: ['errors_file', 'ring'].indexOf(source) >= 0 ? source : 'unavailable',
			qualification: 'log_observation_only',
			examined_entries: count,
			excluded_entries: count - events.length,
			events: events
		};
	}

	/** Technical sharing never exports free text, local details or page-only model verdicts. */
	function shareSnapshot(snapshot, schema) {
		if (
			!schema.share_policy ||
			schema.share_policy.version !== 1 ||
			!snapshot ||
			['windows', 'macos', 'linux'].indexOf(snapshot.driver) < 0
		)
			throw new Error('Diagnostic sharing policy or identity unavailable');
		var safe = projectShare(snapshot, schema.share_policy.projection);
		var issues = snapshot.sections && snapshot.sections.issues;
		if (issues && typeof issues === 'object' && !Array.isArray(issues))
			safe.sections.issues.recent_error_facts = recentErrorFacts(
				issues.recent,
				issues.recent_source,
				schema
			);
		return safe;
	}

	/** Rebuilds closed installed-page records; they never qualify driver suites. */
	function pageCheckObservations(results, schema) {
		if (!results || typeof results !== 'object' || Array.isArray(results))
			throw new Error('Invalid page check records');
		var accepted = {},
			expected = {};
		schema.diagnostic_checks.items.forEach(function (spec) {
			expected[spec.id] = true;
			var row = results[spec.id];
			if (
				!row ||
				typeof row !== 'object' ||
				Array.isArray(row) ||
				row.scope !== spec.scope ||
				Object.keys(row).some(function (key) {
					return ['state', 'scope', 'reason', 'ms'].indexOf(key) < 0;
				})
			)
				throw new Error('Invalid page check record');
			var rule =
				schema.share_policy.projection.fields.page_check_observations.fields.results.fields[
					spec.id
				];
			var clean = projectShare(row, rule);
			if (
				clean.state === undefined ||
				clean.state !== row.state ||
				clean.scope !== row.scope ||
				clean.reason !== row.reason ||
				clean.ms !== row.ms
			)
				throw new Error('Invalid page check value');
			if (
				spec.reason
					? row.state !== 'not_run' || row.reason !== spec.reason || row.ms !== undefined
					: row.state === 'ok' || row.state === 'error'
						? row.ms === undefined ||
							(row.reason !== undefined && row.reason !== 'invalid_diagnostic_model')
						: row.ms !== undefined ||
							(row.state === 'cancelled'
								? row.reason !== undefined
								: row.reason !== 'opt_in_required')
			)
				throw new Error('Invalid page check outcome');
			accepted[spec.id] = clean;
		});
		if (
			Object.keys(results).some(function (id) {
				return !expected[id];
			})
		)
			throw new Error('Unknown page check');
		return { source: 'installed_page_reported', qualification: 'unqualified', results: accepted };
	}

	// The operating-system name each driver is shown as in the report's Driver line
	var SHARE_OS_NAMES = { macos: 'macOS', windows: 'Windows', linux: 'Linux' };
	// The probe facts the compact report shows after the state; the hashes and
	// deep-test provenance stay in the JSON block of the complete report
	var SHARE_PROBE_FACTS = ['detail', 'cleanup', 'native_status', 'ms'];
	var SHARE_PAGE_CHECK_FACTS = ['reason', 'ms'];
	var SHARE_FENCE = '```';

	/**
	 * A number as the three ports print it: an integer bare, else at most two
	 * decimals.
	 * @param {number} value
	 * @returns {string}
	 */
	function shareNumber(value) {
		if (value === Math.floor(value)) return String(value);
		return value.toFixed(2).replace(/0+$/, '').replace(/\.$/, '');
	}

	/**
	 * A section field's scalar by its schema type: units for sizes and
	 * durations, yes or no for a boolean.
	 * @param {*} value
	 * @param {string|undefined} kind
	 * @param {function(string): string} label
	 * @returns {string}
	 */
	function shareFieldText(value, kind, label) {
		if (typeof value === 'boolean' || kind === 'bool')
			return label(value ? 'healthcheck.value.yes' : 'healthcheck.value.no');
		if (typeof value !== 'number') return String(value);
		if (kind === 'bytes') return Math.floor(value / 1048576 + 0.5) + ' MB';
		if (kind === 'percent') return shareNumber(value) + ' %';
		if (kind === 'seconds') return shareNumber(value) + ' s';
		if (kind === 'ms') return shareNumber(value) + ' ms';
		return shareNumber(value);
	}

	/**
	 * The `key=value` facts of a record in the given key order.
	 * @param {object} record
	 * @param {string[]} keys
	 * @returns {string} '' or ' (k=v, k=v)'.
	 */
	function shareFacts(record, keys) {
		var parts = [];
		keys.forEach(function (key) {
			var value = record[key];
			if (value === undefined || value === null) return;
			parts.push(key + '=' + (typeof value === 'number' ? shareNumber(value) : String(value)));
		});
		return parts.length ? ' (' + parts.join(', ') + ')' : '';
	}

	/**
	 * Formats only detached approved leaves as readable English lines, grouped
	 * in the order of share_policy.report_order, most useful first: when the
	 * issue link cuts the report, the least useful part goes. Port of
	 * share.lua's readable(); all three replay report_vectors.json byte for byte.
	 * @param {object} safe The projected snapshot.
	 * @param {object} schema
	 * @param {function(string): string} label English label lookup.
	 * @returns {string}
	 */
	function shareReadable(safe, schema, label) {
		var sections = safe.sections || {};
		var specs = {};
		schema.sections.forEach(function (section) {
			specs[section.id] = section;
		});
		var out = [];
		function group(title, lines, fenced) {
			if (!lines.length) return;
			out.push('## ' + title);
			if (fenced) out.push(SHARE_FENCE);
			out.push.apply(out, lines);
			if (fenced) out.push(SHARE_FENCE);
			out.push('');
		}
		function fieldLines(id) {
			var lines = [];
			var data = sections[id];
			if (!data || typeof data !== 'object') return lines;
			(specs[id].fields || []).forEach(function (field) {
				var value = data[field.id];
				if (value === undefined || value === null || typeof value === 'object') return;
				lines.push(
					label('healthcheck.field.' + field.id) + ': ' + shareFieldText(value, field.type, label)
				);
			});
			return lines;
		}
		var render = {
			issues: function () {
				var lines = fieldLines('issues');
				var recent = sections.issues && sections.issues.recent_error_facts;
				if (recent && recent.examined_entries !== undefined) {
					// An unread source is no count: "0" would say the log held no error
					lines.push(
						label('healthcheck.export.recent_errors_read') +
							': ' +
							(recent.observed
								? shareNumber(recent.examined_entries) +
									' (' +
									label('healthcheck.recent_source.' + recent.source) +
									')'
								: label('healthcheck.value.unknown'))
					);
					(recent.events || []).forEach(function (event) {
						var keys = Object.keys(event)
							.sort()
							.filter(function (key) {
								return key !== 'code' && key !== 'entry_index';
							});
						lines.push(
							label('healthcheck.export.recognised_error') +
								': ' +
								event.code +
								shareFacts(event, keys)
						);
					});
				}
				// The maintainer's ask of 2026-11-24: a report without DEBUG lines says how to get them
				if (sections.developer && sections.developer.detailed_log === false)
					lines.push(label('healthcheck.export.detailed_log_off'));
				group(label('healthcheck.section.issues'), lines);
			},
			checks: function () {
				var lines = [];
				var probes = safe.probes || {};
				Object.keys(probes)
					.sort()
					.forEach(function (id) {
						var probe = probes[id];
						var shown = SHARE_PROBE_FACTS.filter(function (key) {
							return !(key === 'cleanup' && probe.cleanup === 'settled');
						});
						lines.push(id + ': ' + String(probe.state) + shareFacts(probe, shown));
					});
				var pages = (safe.page_check_observations && safe.page_check_observations.results) || {};
				Object.keys(pages)
					.sort()
					.forEach(function (id) {
						lines.push(
							'page.' +
								id +
								': ' +
								String(pages[id].state) +
								shareFacts(pages[id], SHARE_PAGE_CHECK_FACTS)
						);
					});
				if (Array.isArray(safe.retired_probes) && safe.retired_probes.length)
					lines.push('retired_runs: ' + safe.retired_probes.length);
				group(label('healthcheck.export.checks'), lines, true);
			},
			permissions: function () {
				var items = (sections.permissions && sections.permissions.items) || [];
				group(
					label('healthcheck.section.permissions'),
					items.map(function (item) {
						return label('healthcheck.permission.' + item.id) + ': ' + String(item.state);
					})
				);
			},
			configuration_files: function () {
				var items = (sections.configuration_files && sections.configuration_files.items) || [];
				group(
					label('healthcheck.section.configuration_files'),
					items.map(function (item) {
						return (
							label('healthcheck.config_file.' + item.id) +
							': ' +
							label('healthcheck.config_state.' + item.state)
						);
					})
				);
			},
			report: function () {
				var lines = [
					label('healthcheck.export.driver') + ': ' + (SHARE_OS_NAMES[safe.driver] || safe.driver)
				];
				if (safe.generated_at !== undefined)
					lines.push(label('healthcheck.export.generated') + ': ' + safe.generated_at);
				if (safe.schema_version !== undefined)
					lines.push(label('healthcheck.export.schema') + ': ' + shareNumber(safe.schema_version));
				if (safe.detailed !== undefined)
					lines.push(
						label('healthcheck.export.details') +
							': ' +
							shareFieldText(safe.detailed, 'bool', label)
					);
				if (safe.extensive !== undefined)
					lines.push(
						label('healthcheck.export.extensive') +
							': ' +
							shareFieldText(safe.extensive, 'bool', label)
					);
				var log = safe.day_log_attachment;
				if (log && log.included !== undefined)
					lines.push(
						label('healthcheck.export.day_log') +
							': ' +
							shareFieldText(log.included, 'bool', label) +
							shareFacts(log, ['bytes', 'lines'])
					);
				group(label('healthcheck.export.report'), lines);
			},
			configuration: function () {
				var title = label('healthcheck.export.changed_settings');
				// Until the configuration probe answers, an empty list would claim
				// no setting was changed
				var probe = safe.probes && safe.probes.configuration;
				if (probe && probe.state !== 'ok') {
					group(title, [label('healthcheck.value.unknown')]);
					return;
				}
				var items = (sections.configuration && sections.configuration.items) || [];
				var lines = items.map(function (item) {
					var value = item.value;
					if (item.type === 'text') value += ' ' + label('healthcheck.export.characters');
					else if (item.type === 'list') value += ' ' + label('healthcheck.export.items');
					return item.setting + ' = ' + value;
				});
				if (!lines.length) group(title, [label('healthcheck.value.none')]);
				else group(title, lines, true);
			}
		};
		schema.share_policy.report_order.forEach(function (id) {
			if (render[id]) return render[id]();
			if (!specs[id]) throw new Error('report_order names an unknown section: ' + id);
			group(label('healthcheck.section.' + id), fieldLines(id));
		});
		return out.join('\n');
	}

	/** The local preview uses the same closed projection as the host's output. */
	function formatShareable(snapshot, schema, t) {
		var safe = shareSnapshot(snapshot, schema);
		// Export translation never consults or changes the active page locale.
		t = function (key) {
			var value = schema.export_strings && schema.export_strings[key];
			if (typeof value !== 'string' || !value)
				throw new Error('English export label unavailable: ' + key);
			return value;
		};
		return (
			'# ErgoptiPlus diagnostics\n\n' +
			t(schema.share_policy.notice_key) +
			'\n\n' +
			shareReadable(safe, schema, t) +
			'\n```json\n' +
			JSON.stringify(safe) +
			'\n```\n'
		);
	}

	global.ErgoptiDiagnostics = {
		shareSnapshot: shareSnapshot,
		pageCheckObservations: pageCheckObservations,
		formatShareable: formatShareable,
		sectionsFor: sectionsFor,
		probeFor: probeFor,
		formatValue: formatValue,
		fieldDisplay: fieldDisplay,
		withoutOptIn: withoutOptIn,
		problems: problems,
		renderHtml: renderHtml,
		formatMarkdown: formatMarkdown,
		reportInfo: reportInfo,
		fileName: fileName,
		issueFields: issueFields
	};
})(window);
