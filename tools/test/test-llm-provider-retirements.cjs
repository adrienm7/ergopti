// tools/test/test-llm-provider-retirements.cjs

/**
 * ==============================================================================
 * MODULE: Remote Provider Retirement Guard
 * DESCRIPTION:
 * Pins the announced provider retirements against the shared provider data
 * (_shared/ai/data/api_providers.json), so a later edit cannot bring back
 * a retired endpoint or model as a default.
 *
 * FEATURES & RATIONALE:
 * 1. Perplexity ended Sonar chat completions on 2026-09-27: the provider must
 *    stay on the Agent API format, and its default must not be a Sonar id the
 *    Agent API rejects (sonar-pro, sonar-reasoning-pro).
 * 2. Moonshot closed the Kimi K2 series to new accounts on 2026-10-31 and
 *    retires it by the end of December 2026 (kimi-k2.5 and moonshot-v1 ended
 *    on 2026-08-31): no K2 or moonshot-v1 id may be Moonshot's default.
 * 3. DashScope's shared domain (dashscope-intl.aliyuncs.com) is in
 *    maintenance mode from 2026-09-30 with no shutdown date: it may stay the
 *    default only while the optional workspace-dedicated address survives,
 *    because that address is the route once the shared one closes.
 * The dates and sources live in each provider's _source; this file holds only
 * the ids those notices name, which no production file restates.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const CATALOG = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'ai',
	'data',
	'api_providers.json'
);

// Model ids each provider's retirement notice names, as prefixes of the
// lowercased last path segment (the normalization thinking_off.json uses).
const RETIRED_PREFIXES = {
	perplexity: ['sonar-pro', 'sonar-reasoning-pro', 'sonar-deep-research'],
	moonshot: ['kimi-k2', 'moonshot-v1']
};

const failures = [];
const check = (condition, message) => {
	if (!condition) failures.push(message);
};

const catalog = JSON.parse(fs.readFileSync(CATALOG, 'utf8'));
const providers = catalog.providers;
const normalize = (id) => String(id).toLowerCase().split('/').pop();

for (const [pid, prefixes] of Object.entries(RETIRED_PREFIXES)) {
	const provider = providers[pid];
	check(provider !== undefined, `provider ${pid} is gone: update this guard with the retirement`);
	if (!provider) continue;
	const retired = (id) => prefixes.some((prefix) => normalize(id).startsWith(prefix));
	check(
		!retired(provider.default_model),
		`${pid} defaults to the retired model ${provider.default_model}`
	);
}

// Only Perplexity serves Sonar, so a Sonar price row is stale data; Kimi K2
// weights stay on other providers, so their prices are not checked.
for (const id of Object.keys(catalog.model_prices))
	check(
		!RETIRED_PREFIXES.perplexity.some((prefix) => normalize(id).startsWith(prefix)),
		`model_prices still prices the retired Sonar model ${id}`
	);

check(
	providers.perplexity && providers.perplexity.format === 'perplexity_agent',
	'perplexity must stay on the Agent API: Sonar chat completions ended on 2026-09-27'
);

const dashscope = providers.dashscope;
check(dashscope !== undefined, 'provider dashscope is gone: update this guard with the retirement');
if (dashscope) {
	const shared = new URL(dashscope.base_url).hostname === 'dashscope-intl.aliyuncs.com';
	const dedicated =
		dashscope.optional_address && dashscope.optional_address.host_suffix === '.maas.aliyuncs.com';
	check(
		!shared || dedicated,
		'dashscope defaults to the shared domain in maintenance mode without the workspace-dedicated address'
	);
}

if (failures.length > 0) {
	for (const failure of failures) console.error(`\x1b[31m[ERROR] ${failure}\x1b[0m`);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] No retired provider endpoint or model is a default in api_providers.json.\x1b[0m'
);
