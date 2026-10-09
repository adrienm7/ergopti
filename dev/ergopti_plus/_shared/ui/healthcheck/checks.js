// _shared/ui/healthcheck/checks.js

/**
 * Bounded controls of the installed diagnostic model and synthetic redaction.
 * Driver, installation and reload suites retain explicit NOT_RUN outcomes.
 */
(function (global) {
	'use strict';

	function applies(definition, driver) {
		return !definition.platforms || definition.platforms.indexOf(driver) >= 0;
	}

	function schemaFields(snapshot, schema) {
		var declared = Object.create(null);
		(schema.sections || []).forEach(function (section) {
			if (!applies(section, snapshot.driver) || section.kind === 'summary') return;
			declared[section.id] = section;
		});
		if (
			!Object.keys(declared).every(function (id) {
				return (
					snapshot.sections && snapshot.sections[id] && typeof snapshot.sections[id] === 'object'
				);
			})
		)
			return false;
		return Object.keys(snapshot.sections || {}).every(function (id) {
			var definition = declared[id];
			if (!definition) return false;
			if (!definition.fields) return true;
			var fields = Object.create(null);
			definition.fields.forEach(function (field) {
				fields[field.id] = true;
			});
			return Object.keys(snapshot.sections[id]).every(function (field) {
				return fields[field];
			});
		});
	}

	function probeInventory(snapshot, schema) {
		var probes = snapshot.probes || {};
		var ids = Object.keys(schema.probes || {}).filter(function (id) {
			return applies(schema.probes[id], snapshot.driver);
		});
		return (
			Object.keys(probes).length === ids.length &&
			ids.every(function (id) {
				return (
					probes[id] &&
					[
						'pending',
						'ok',
						'error',
						'timeout',
						'disabled',
						'unsupported',
						'not_run',
						'cancelled'
					].indexOf(probes[id].state) >= 0
				);
			})
		);
	}

	function redactionCheck(snapshot, schema, rules, redact) {
		var vector = schema.diagnostic_checks.redaction_vector;
		return (
			typeof redact === 'function' &&
			redact(vector.input, rules, vector.context) === vector.expected
		);
	}

	var checks = Object.assign(Object.create(null), {
		schema_fields: schemaFields,
		probe_inventory: probeInventory,
		redaction: redactionCheck
	});

	/** Runs bounded diagnostic-model controls; never invokes a driver or CI command. */
	function start(snapshot, schema, rules, redact, publish, schedule, unschedule) {
		var selected = snapshot.extensive === true || snapshot.extensive === 1;
		var specs = schema.diagnostic_checks.items;
		var results = Object.create(null);
		var position = 0;
		var timer = null;
		var cancelled = false;
		specs.forEach(function (spec) {
			results[spec.id] = {
				state: selected && checks[spec.id] ? 'pending' : 'not_run',
				reason: checks[spec.id] ? 'opt_in_required' : spec.reason,
				scope: spec.scope
			};
		});
		function step() {
			timer = null;
			if (cancelled) return;
			while (position < specs.length && !checks[specs[position].id]) position += 1;
			if (position >= specs.length) return;
			var spec = specs[position++];
			var started = Date.now();
			var result = { state: 'error', scope: spec.scope };
			try {
				result.state = checks[spec.id](snapshot, schema, rules, redact) ? 'ok' : 'error';
			} catch (_) {
				result.reason = 'invalid_diagnostic_model';
			}
			result.ms = Math.max(0, Date.now() - started);
			results[spec.id] = result;
			publish(spec.id, result);
			if (!cancelled && position < specs.length) timer = schedule(step);
		}
		if (selected) timer = schedule(step);
		return {
			results: results,
			cancel: function () {
				if (cancelled) return false;
				cancelled = true;
				if (timer !== null) unschedule(timer);
				Object.keys(results).forEach(function (id) {
					if (results[id].state === 'pending') {
						results[id] = { state: 'cancelled', scope: results[id].scope };
						publish(id, results[id]);
					}
				});
				return true;
			}
		};
	}

	function report(snapshot, schema, t) {
		var results = snapshot.diagnostic_checks || {};
		var lines = ['## ' + t('healthcheck.deep_tests.title'), ''];
		(schema.diagnostic_checks.items || []).forEach(function (spec) {
			var result = results[spec.id] || {
				state: 'not_run',
				reason: 'opt_in_required',
				scope: spec.scope
			};
			var state =
				result.state === 'ok'
					? 'PASS'
					: result.state === 'error'
						? 'FAIL'
						: String(result.state || 'unknown').toUpperCase();
			var reason =
				result.reason && result.state === 'not_run'
					? ' — ' + t('healthcheck.deep_tests.reason.' + result.reason)
					: '';
			lines.push(
				'- ' + t(spec.label) + ' (' + spec.id + ', ' + spec.scope + '): ' + state + reason
			);
		});
		function appendProbes(probes, scope) {
			Object.keys(probes || {}).forEach(function (id) {
				var result = probes[id] || { state: 'error' };
				lines.push(
					'- ' +
						id +
						' (' +
						scope +
						'): ' +
						String(result.state || 'unknown').toUpperCase() +
						(typeof result.ms === 'number' ? ', ' + result.ms + ' ms' : '') +
						(Number.isSafeInteger(result.native_status) &&
						result.native_status >= -2147483648 &&
						result.native_status <= 2147483647
							? ', native_status=' + result.native_status
							: '') +
						(Number.isSafeInteger(result.runtime_pid) && result.runtime_pid > 0
							? ', runtime_pid=' + result.runtime_pid
							: '') +
						(typeof result.sender_context === 'string' && /^[a-z_]+$/.test(result.sender_context)
							? ', sender_context=' + result.sender_context
							: '') +
						(typeof result.qualification_scope === 'string' &&
						/^[a-z_]+$/.test(result.qualification_scope)
							? ', qualification_scope=' + result.qualification_scope
							: '') +
						(typeof result.detail === 'string' && /^[a-z_]+$/.test(result.detail)
							? ', detail=' + result.detail
							: '') +
						', cleanup=' +
						(['pending', 'settled', 'unknown'].indexOf(result.cleanup) >= 0
							? result.cleanup
							: 'unknown') +
						(result.cleanup === 'pending' ? ' — ' + t('healthcheck.probe.cleanup_pending') : '')
				);
			});
		}
		appendProbes(snapshot.probes, 'host-probe');
		(snapshot.retired_probes || []).forEach(function (retired) {
			appendProbes(retired.probes, 'retired-host-probe');
		});
		return lines.join('\n') + '\n';
	}

	function progress(snapshot) {
		var results = Object.assign({}, snapshot.probes || {}, snapshot.diagnostic_checks || {});
		var ids = Object.keys(results).filter(function (id) {
			return results[id] && results[id].state !== 'not_run' && results[id].state !== 'unsupported';
		});
		return {
			total: ids.length,
			completed: ids.filter(function (id) {
				return results[id].state !== 'pending';
			}).length
		};
	}

	if (!global.ErgoptiDiagnostics || typeof global.ErgoptiDiagnostics.formatMarkdown !== 'function')
		throw new Error('Diagnostic checks require the actual report model');
	var formatSnapshot = global.ErgoptiDiagnostics.formatMarkdown;
	global.ErgoptiDiagnostics.formatMarkdown = function (snapshot, schema, t) {
		return formatSnapshot(snapshot, schema, t) + '\n' + report(snapshot, schema, t);
	};
	global.ErgoptiDiagnosticChecks = { start: start, report: report, progress: progress };
})(window);
