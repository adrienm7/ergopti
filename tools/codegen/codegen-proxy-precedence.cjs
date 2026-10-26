// tools/codegen/codegen-proxy-precedence.cjs

/**
 * ==============================================================================
 * MODULE: Proxy Precedence Shell Projection
 * DESCRIPTION:
 * POSIX shell scripts read the proxy environment with parameter expansion
 * before any JSON reader exists, so they cannot load proxy_policy.json. This
 * generator patches the two expansions in place from the policy, so the shell
 * copies are generated and the drift guard (`npm run gen:check`) refuses a
 * script that disagrees with the JSON:
 *   - the nested HTTPS precedence  ${https_proxy:-${HTTPS_PROXY:-...}}
 *     from environment_precedence.https (in order);
 *   - the "any relay variable set" inventory  ${HTTPS_PROXY:-}${https_proxy:-}...
 *     from system_lookup_environment_exclusions.
 * Only a line that already spells the pattern is rewritten; a script with no
 * such line is left alone, and a script listed here with none fails loudly.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { REPO_ROOT, sharedRel } = require('../lib/paths.cjs');

const SOURCE = sharedRel('modules', 'network', 'proxy_policy.json');
// network-retry.sh is written by codegen-bootstrap-retry.cjs, which applies project()
// itself (one generator owns each output); check() below still covers it.
const SCRIPTS = ['static/ergopti_plus/macos/adapters/release_stage.sh'];
const OWNED_ELSEWHERE = ['static/ergopti_plus/macos/modules/llm/network-retry.sh'];
const NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

// ${a:-${b:-${c:-}}}: at least one nested level, so the flat inventory never matches.
const NESTED = /\$\{[A-Za-z]+_(?:proxy|PROXY):-(?:\$\{[A-Za-z]+_(?:proxy|PROXY):-)+\}+/g;
// ${A:-}${b:-}... : four or more adjacent empty-default expansions.
const FLAT = /(?:\$\{[A-Za-z]+_(?:proxy|PROXY):-\}){4,}/g;

/** Validates the two lists the projection spells. */
function validate(policy) {
	const lists = [
		policy?.environment_precedence?.https,
		policy?.system_lookup_environment_exclusions
	];
	for (const list of lists) {
		if (!Array.isArray(list) || list.length < 2 || new Set(list).size !== list.length)
			throw new TypeError('Proxy policy lists must be distinct arrays of two names or more.');
		for (const name of list)
			if (typeof name !== 'string' || !NAME.test(name))
				throw new TypeError('Proxy policy variable names must be shell identifiers.');
	}
}

/** Renders ${a:-${b:-...:-}}} for names in order of precedence. */
function nested(names) {
	return names.reduceRight((inner, name) => `\${${name}:-${inner}}`, '');
}

/** Renders ${A:-}${b:-}... for an unordered inventory. */
function flat(names) {
	return names.map((name) => `\${${name}:-}`).join('');
}

/** The variable names an expansion spells, in order. */
const namesIn = (expansion) => [...expansion.matchAll(/\$\{([A-Za-z_]+):-/g)].map((m) => m[1]);

/** Rewrites an expansion only when it is the https precedence / the relay inventory. */
const only = (required, render) => (match) =>
	required.every((name) => namesIn(match).includes(name)) ? render() : match;

/** Returns one script's text with both expansions regenerated from the policy. */
function project(text, policy) {
	validate(policy);
	return text
		.replace(
			NESTED,
			only(['https_proxy', 'HTTPS_PROXY', 'all_proxy'], () =>
				nested(policy.environment_precedence.https)
			)
		)
		.replace(
			FLAT,
			only(['https_proxy', 'HTTPS_PROXY', 'http_proxy', 'HTTP_PROXY'], () =>
				flat(policy.system_lookup_environment_exclusions)
			)
		);
}

/** Writes (or, with check, verifies) every script. Returns the projected texts. */
function generate(root = REPO_ROOT, { check = false } = {}) {
	const policy = JSON.parse(fs.readFileSync(path.join(root, SOURCE), 'utf8'));
	const outputs = {};
	for (const relative of SCRIPTS) {
		const file = path.join(root, relative);
		const current = fs.readFileSync(file, 'utf8');
		if (!NESTED.test(current))
			throw new Error(`${relative} spells no proxy precedence to project.`);
		NESTED.lastIndex = 0;
		const projected = project(current, policy);
		outputs[relative] = projected;
		if (check) {
			if (projected !== current) throw new Error(`${relative} drifted from ${SOURCE}.`);
		} else if (projected !== current) {
			fs.writeFileSync(file, projected);
		}
	}
	return outputs;
}

module.exports = { project, generate, nested, flat, SOURCE, SCRIPTS, OWNED_ELSEWHERE };
if (require.main === module) generate(undefined, { check: process.argv.includes('--check') });
