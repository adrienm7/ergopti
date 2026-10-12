// tools/test/lib/js-feature-results.cjs

/** Verify the complete source-bound union of independently executed feature lots. */
'use strict';

function requireEvidence(condition, message) {
	if (!condition)
		throw new Error(
			`${message}. Re-run the affected feature lot on this source/run, or start a new complete run. Retained success journals require the exact source, run and canonical inventory, with a valid producer attempt no newer than this receiving attempt.`
		);
}

function duration(value) {
	return typeof value === 'number' && Number.isFinite(value) && value >= 0;
}

/** Admit only actual positive attempts; missing or unsafe values cannot grant reuse. */
function attempt(value) {
	requireEvidence(
		typeof value === 'string' && /^[1-9][0-9]*$/.test(value) && Number.isSafeInteger(Number(value)),
		'Invalid actual CI producer or receiving attempt'
	);
	return Number(value);
}

/** Returns counts only after all declared checks completed successfully exactly once. */
function validateFeatureJournals(inventory, journals, context) {
	requireEvidence(
		['linux', 'darwin', 'win32'].includes(context.platform),
		'Invalid execution platform'
	);
	requireEvidence(/^[a-f0-9]{40}$/.test(context.source || ''), 'Invalid CI source identity');
	for (const key of ['run_id', 'run_attempt'])
		requireEvidence(/^[1-9][0-9]*$/.test(context[key] || ''), `Invalid CI ${key}`);
	const receivingAttempt = attempt(context.run_attempt);
	requireEvidence(/^[a-f0-9]{64}$/.test(inventory.digest || ''), 'Invalid inventory digest');
	requireEvidence(
		Array.isArray(inventory.features) && inventory.features.length > 0,
		'Empty feature inventory'
	);
	requireEvidence(
		new Set(inventory.features).size === inventory.features.length,
		'Duplicate inventory feature'
	);
	requireEvidence(
		Array.isArray(journals) && journals.length === inventory.features.length,
		'Missing or extra feature journal'
	);
	const remaining = new Set(inventory.features);
	const expectedChecks = inventory.checks.filter(
		(check) => !check.platforms || check.platforms.includes(context.platform)
	);
	const allIds = new Set();
	const summaries = [];
	for (const rows of journals) {
		requireEvidence(
			Array.isArray(rows) && rows.length >= 4,
			'Empty or interrupted feature journal'
		);
		const header = rows[0];
		requireEvidence(
			header && header.type === 'suite' && header.schema_version === 1 && header.suite === 'js',
			'Invalid feature journal header'
		);
		requireEvidence(
			header.mode === 'feature' && remaining.has(header.feature),
			'Unknown or repeated feature journal'
		);
		const feature = header.feature;
		remaining.delete(feature);
		requireEvidence(header.platform === context.platform, `${feature}: wrong execution platform`);
		requireEvidence(header.inventory_sha256 === inventory.digest, `${feature}: changed inventory`);
		requireEvidence(
			header.ci_source_sha === context.source &&
				header.ci_run_id === context.run_id &&
				attempt(header.ci_run_attempt) <= receivingAttempt,
			`${feature}: wrong source, run or attempt`
		);
		const checks = expectedChecks.filter((check) => check.feature === feature);
		requireEvidence(
			checks.length > 0 && header.planned_count === checks.length,
			`${feature}: incomplete planned inventory`
		);
		requireEvidence(
			rows.length === checks.length * 2 + 2,
			`${feature}: missing, repeated or unfinished results`
		);
		let childDuration = 0;
		for (let index = 0; index < checks.length; index++) {
			const check = checks[index];
			const start = rows[index * 2 + 1];
			const result = rows[index * 2 + 2];
			for (const [record, type] of [
				[start, 'start'],
				[result, 'result']
			]) {
				requireEvidence(
					record &&
						record.type === type &&
						record.ordinal === index + 1 &&
						record.check_id === check.id &&
						record.global_ordinal === check.ordinal &&
						record.name === check.name,
					`${feature}: wrong ${type} identity at ${index + 1}`
				);
			}
			requireEvidence(!allIds.has(check.id), `${feature}: duplicate check ${check.id}`);
			allIds.add(check.id);
			requireEvidence(
				result.reproduce === check.repro,
				`${feature}: changed reproduction command for ${check.id}`
			);
			requireEvidence(
				result.status === 'PASS' &&
					result.exit_code === 0 &&
					result.signal === null &&
					result.error_code === null,
				`${feature}: failed or unexecuted check ${check.id}`
			);
			requireEvidence(duration(result.duration_ms), `${feature}: invalid duration for ${check.id}`);
			childDuration += result.duration_ms;
		}
		const footer = rows.at(-1);
		requireEvidence(
			footer.type === 'complete' &&
				footer.executed_count === checks.length &&
				footer.passed === checks.length &&
				footer.failed === 0,
			`${feature}: incomplete or failed terminal summary`
		);
		requireEvidence(
			duration(footer.child_duration_ms) &&
				Math.abs(footer.child_duration_ms - childDuration) <= 0.001,
			`${feature}: child duration total disagrees`
		);
		requireEvidence(
			duration(footer.duration_ms) && footer.duration_ms + 0.001 >= footer.child_duration_ms,
			`${feature}: invalid suite duration`
		);
		summaries.push({
			feature,
			checks: checks.length,
			duration_ms: footer.duration_ms,
			producer_run_attempt: header.ci_run_attempt
		});
	}
	requireEvidence(
		remaining.size === 0 && allIds.size === expectedChecks.length,
		'Feature union does not cover the inventory'
	);
	return {
		features: summaries.sort((a, b) => a.feature.localeCompare(b.feature)),
		checks: allIds.size,
		inventory_sha256: inventory.digest,
		source: context.source,
		run_id: context.run_id,
		run_attempt: context.run_attempt
	};
}

module.exports = { validateFeatureJournals };
