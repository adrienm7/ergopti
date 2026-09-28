// tools/lib/configuration-scopes.cjs

'use strict';

const schema = require('../../static/ergopti_plus/_shared/modules/features/manifest.schema.json');
const parameterShape = schema.$defs.configuration_scope.properties.action_parameters;

/**
 * Derives generated value types before AHK represents false and zero alike.
 * The source values remain authoritative; conflicting explicit types are errors.
 * @param {object} scopes Canonical scope declarations.
 * @returns {object} Detached scope metadata with typed dynamic defaults.
 */
function normalizeScopes(scopes) {
	const normalized = structuredClone(scopes);
	for (const [scope, declaration] of Object.entries(normalized)) {
		const parameters = declaration.action_parameters;
		if (parameters !== undefined && (parameters === null || typeof parameters !== 'object' ||
			parameters.restore !== parameterShape.properties.restore.const || !Array.isArray(parameters.domains) ||
			parameters.domains.length === 0 || new Set(parameters.domains).size !== parameters.domains.length ||
			parameters.domains.some(domain => !parameterShape.properties.domains.items.enum.includes(domain)) ||
			Object.keys(parameters).some(key => !Object.hasOwn(parameterShape.properties, key)))) {
			throw new Error(`Invalid action parameter ownership in scope ${scope}`);
		}
		for (const entry of declaration.dynamic_defaults || []) {
			const kindOf = value => Array.isArray(value) ? 'array' : typeof value;
			const scalar = value => ['boolean', 'string'].includes(typeof value) ||
				(typeof value === 'number' && Number.isFinite(value));
			const kind = kindOf(entry.default);
			if (!['boolean', 'number', 'string', 'array'].includes(kind) || kindOf(entry.recommended) !== kind ||
				(kind === 'array' && (!entry.default.every(scalar) || !entry.recommended.every(scalar))) ||
				(kind === 'number' && (!Number.isFinite(entry.default) || !Number.isFinite(entry.recommended)))) {
				throw new Error(`Invalid dynamic default values in scope ${scope}: ${entry.prefix}`);
			}
			const type = kind === 'number' && Number.isInteger(entry.default) && Number.isInteger(entry.recommended)
				? 'integer' : kind;
			if (entry.type !== undefined && entry.type !== type) {
				throw new Error(`Dynamic default type disagrees with its values in scope ${scope}: ${entry.prefix}`);
			}
			entry.type = type;
		}
	}
	return normalized;
}

module.exports = { normalizeScopes };
