// tools/test/linux-feature-parity.cjs

/**
 * ============================================================================
 * MODULE: Linux Feature Parity Evidence
 * DESCRIPTION:
 * Projects every generated Linux feature claim into explicit implementation
 * and proof dimensions. Missing proof is recorded as unverified, never inferred
 * from a declaration or a source-code reference.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const STATES = new Set(['yes', 'no', 'not_applicable', 'unverified']);
const PROOF_TIERS = new Set(['declaration', 'unit', 'integration', 'os', 'hardware']);
const EVIDENCE_FIELDS = [
	'registered',
	'production_caller',
	'persisted',
	'applied',
	'hardware_proven',
	'proof_tier',
	'intentional',
	'evidence',
];

function fail(message) {
	throw new Error(message);
}

function parsePlatforms(raw) {
	return (raw.match(/"([^"]+)"/g) || []).map((value) => value.slice(1, -1));
}

function parseLinuxManifest(source) {
	const featureStart = source.indexOf('M.features = {');
	const unavailableStart = source.indexOf('M.unavailable = {');
	if (featureStart < 0 || unavailableStart < featureStart) {
		fail('Linux generated manifest has no features/unavailable boundary');
	}

	const supported = [];
	for (const match of source.slice(featureStart, unavailableStart).matchAll(/path\s*=\s*"([^"]+)"/g)) {
		supported.push({ path: match[1] });
	}

	const unavailable = [];
	const unavailableSource = source.slice(unavailableStart);
	const row = /path\s*=\s*"([^"]+)"[^\n]*reason_key\s*=\s*"([^"]*)"[^\n]*platforms\s*=\s*\{([^}]*)\}/g;
	for (const match of unavailableSource.matchAll(row)) {
		unavailable.push({ path: match[1], reason_key: match[2], platforms: parsePlatforms(match[3]) });
	}
	if (supported.length === 0 || unavailable.length === 0) {
		fail('Linux generated manifest yielded an empty supported or unavailable set');
	}
	return { supported, unavailable };
}

function inferredReason(feature) {
	if (feature.reason_key) return { kind: 'declared_reason', key: feature.reason_key };
	const platforms = [...feature.platforms].sort().join(',');
	if (platforms === 'ahk,hs') return { kind: 'linux_parity_gap', key: '' };
	if (platforms === 'ahk') return { kind: 'windows_specific', key: '' };
	if (platforms === 'hs') return { kind: 'macos_specific', key: '' };
	return { kind: 'platform_restricted', key: '' };
}

function validateSupportedEvidence(featurePath, evidence, rootDirectory) {
	for (const field of EVIDENCE_FIELDS) {
		if (!Object.hasOwn(evidence, field)) fail(`${featurePath} is missing evidence field ${field}`);
	}
	for (const field of ['registered', 'production_caller', 'persisted', 'applied', 'hardware_proven']) {
		if (!STATES.has(evidence[field])) fail(`${featurePath}.${field} has invalid state ${evidence[field]}`);
	}
	if (!PROOF_TIERS.has(evidence.proof_tier)) {
		fail(`${featurePath}.proof_tier has invalid value ${evidence.proof_tier}`);
	}
	if (typeof evidence.intentional !== 'boolean') fail(`${featurePath}.intentional must be boolean`);
	if (!Array.isArray(evidence.evidence)) fail(`${featurePath}.evidence must be an array`);
	const upgraded = evidence.proof_tier !== 'declaration' ||
		['registered', 'production_caller', 'persisted', 'applied', 'hardware_proven']
			.some((field) => evidence[field] === 'yes');
	if (upgraded && evidence.evidence.length === 0) {
		fail(`${featurePath} claims proof without a tracked evidence path`);
	}
	for (const relativePath of evidence.evidence) {
		if (typeof relativePath !== 'string' || relativePath === '') {
			fail(`${featurePath} has an invalid evidence path`);
		}
		if (!fs.existsSync(path.join(rootDirectory, relativePath))) {
			fail(`${featurePath} evidence path does not exist: ${relativePath}`);
		}
	}
}

function buildParityRows({ manifest, evidenceConfig, rootDirectory }) {
	if (evidenceConfig.schema_version !== 1) fail('Linux evidence schema_version must be 1');
	if (typeof evidenceConfig.owner !== 'string' || evidenceConfig.owner === '') {
		fail('Linux evidence owner must be non-empty');
	}
	if (!evidenceConfig.supported_defaults || !evidenceConfig.overrides) {
		fail('Linux evidence must define supported_defaults and overrides');
	}

	const parsed = parseLinuxManifest(manifest);
	const paths = new Set();
	const rows = [];
	for (const feature of parsed.supported) {
		if (paths.has(feature.path)) fail(`duplicate Linux feature path ${feature.path}`);
		paths.add(feature.path);
		const override = evidenceConfig.overrides[feature.path] || {};
		const implementation = { ...evidenceConfig.supported_defaults, ...override };
		validateSupportedEvidence(feature.path, implementation, rootDirectory);
		rows.push({
			path: feature.path,
			status: 'claimed_supported',
			owner: evidenceConfig.owner,
			declared: true,
			reason: { kind: 'declared_for_linux', key: '' },
			...implementation,
		});
	}
	for (const feature of parsed.unavailable) {
		if (paths.has(feature.path)) fail(`Linux path is both supported and unavailable: ${feature.path}`);
		paths.add(feature.path);
		const reason = inferredReason(feature);
		rows.push({
			path: feature.path,
			status: 'unavailable',
			owner: evidenceConfig.owner,
			declared: false,
			reason,
			registered: 'no',
			production_caller: 'no',
			persisted: 'no',
			applied: 'no',
			hardware_proven: 'no',
			proof_tier: 'declaration',
			intentional: reason.kind !== 'linux_parity_gap',
			evidence: [],
		});
	}
	for (const featurePath of Object.keys(evidenceConfig.overrides)) {
		if (!paths.has(featurePath)) fail(`Linux evidence override names unknown path ${featurePath}`);
		if (rows.find((row) => row.path === featurePath)?.status !== 'claimed_supported') {
			fail(`Linux evidence override targets unavailable path ${featurePath}`);
		}
	}
	return rows.sort((left, right) => left.path.localeCompare(right.path));
}

function summarize(rows) {
	const count = (predicate) => rows.filter(predicate).length;
	return {
		total: rows.length,
		claimed_supported: count((row) => row.status === 'claimed_supported'),
		unavailable: count((row) => row.status === 'unavailable'),
		parity_gaps: count((row) => row.reason.kind === 'linux_parity_gap'),
		proven_above_declaration: count((row) => row.proof_tier !== 'declaration'),
		unverified_supported: count((row) => row.status === 'claimed_supported' &&
			[row.registered, row.production_caller, row.persisted, row.applied]
				.some((state) => state === 'unverified')),
	};
}

module.exports = { buildParityRows, parseLinuxManifest, summarize };
