// tools/test/test-model-browser-host-actions.cjs

/**
 * ==============================================================================
 * MODULE: Model Browser Host Actions
 * DESCRIPTION:
 * Every action the shared model selector page can post must have a handler on
 * every host: a message nobody answers is a dead button with no error anywhere.
 * The gate reads the actions from the page source and from the tools each host
 * puts in its payload, then finds the branch that answers each one on macOS,
 * Linux and Windows. A host that does not offer an action states why here.
 *
 * ROOT CAUSE ENCODED:
 * The maintainer reported dead install buttons on 2026-11-02. On Windows the
 * click went through the backend selection, which does not install; a static
 * "the key exists" check stayed green. This gate covers the wiring: the
 * behaviour of each click is proved by each driver's own tests.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SP = path.resolve(__dirname, '../../static/ergopti_plus');
const read = (relative) => fs.readFileSync(path.join(SP, relative), 'utf8');

const SOURCES = {
	page: read('_shared/ui/model_browser/script.js'),
	macBridge: read('macos/ai/ui/model_browser/init.lua'),
	macPage: read('macos/ai/ui/menu/models/selector_page.lua'),
	linuxBridge: read('linux/ai/ui/model_browser/bridge.lua'),
	linuxRows: read('linux/ai/ui/menu/backend_rows.lua'),
	windows: read('windows/ai/ui/model_browser/init.ahk')
};

/** The distinct first captures of a pattern. */
const captures = (text, pattern) => [...new Set([...text.matchAll(pattern)].map((m) => m[1]))];

/** The actions the page can post: its literals and its row-action names. */
function pageActions(page) {
	return [
		...new Set([
			...captures(page, /\baction: '([a-z_]+)'/g),
			...captures(page, /postRowAction\('([a-z_]+)'/g)
		])
	].sort();
}

/**
 * The actions each host answers, and the tools it offers with their handlers.
 * @returns {object} { host: { actions, tools: [{ id, handled }] } }
 */
function hosts(s) {
	const macListed = captures(s.macBridge, /\b([a-z_]+) = true/g);
	const macAnswered = new Set([
		...captures(s.macPage, /\baction == "([a-z_]+)"/g),
		...captures(s.macBridge, /body\.action == "([a-z_]+)"/g)
	]);
	const macHandled = new Set([
		...captures(s.macPage, /\bid == "([a-z_]+)"/g),
		...captures(s.macPage, /body\.id == "([a-z_]+)"/g)
	]);
	// Linux keeps each tool's closure beside its id (strip()): one without `run` is dead.
	const linuxTools = [...s.linuxRows.matchAll(/\{ id = "([a-z_]+)", text = [^\n]*\n?[^\n]*/g)].map(
		(m) => ({ id: m[1], handled: m[0].includes('run = ') })
	);
	const windowsTools = captures(s.windows, /_LLM_MBW_Tool\(Tools, "[a-z]+", "([a-z_]+)"/g);
	return {
		macos: {
			// A listed action is dispatched to the owner, which must answer it.
			actions: [...macAnswered].filter((a) => macListed.includes(a) || a === 'open_url'),
			tools: [
				...captures(s.macPage, /\{ id = "([a-z_]+)"/g),
				...captures(s.macPage, /actions = \{ \{ id = "([a-z_]+)"/g),
				'install'
			].map((id) => ({ id, handled: macHandled.has(id) }))
		},
		linux: {
			actions: captures(s.linuxBridge, /payload\.action == "([a-z_]+)"/g),
			tools: [
				...linuxTools,
				{ id: 'install', handled: s.linuxBridge.includes('payload.id == "install"') }
			]
		},
		windows: {
			actions: captures(s.windows, /\bAction == "([a-z_]+)"/g).concat(
				captures(s.windows, /\bAction != "([a-z_]+)"/g)
			),
			tools: [
				...windowsTools.map((id) => ({ id, handled: true })),
				{ id: 'install', handled: s.windows.includes('Tools["ollama`ninstall"] := (*) =>') }
			]
		}
	};
}

// A host that never draws the control of an action; `absent` must stay out of its
// source, so the exception ends the day the host starts sending that control.
const NOT_OFFERED = {
	windows: {
		add_provider: {
			why: 'Windows adds an API through its own "add_api" tool: its payload sends no provider list',
			absent: ',providers:'
		}
	}
};

/** Every action or tool of the page without a handler, as readable lines. */
function deadActions(s) {
	const wanted = pageActions(s.page);
	const lines = [];
	for (const [host, { actions, tools }] of Object.entries(hosts(s))) {
		for (const action of wanted) {
			const exception = (NOT_OFFERED[host] || {})[action];
			if (exception && !s[host].includes(exception.absent)) continue;
			if (!actions.includes(action)) lines.push(`${host}: page action "${action}" has no handler`);
		}
		for (const tool of tools) {
			if (!tool.handled) lines.push(`${host}: tool "${tool.id}" has no handler`);
		}
	}
	return lines;
}

const actions = pageActions(SOURCES.page);
assert.ok(actions.length >= 10, `the page's actions were read: ${actions.join(', ')}`);
for (const known of ['group_action', 'select_model', 'open_url', 'add_provider']) {
	assert.ok(actions.includes(known), `${known} is one of the page's actions`);
}
assert.deepEqual(deadActions(SOURCES), [], 'every page action has a handler on every host');

// The install buttons post the group action "install" on every host.
assert.ok(
	SOURCES.page.includes("postModelAction({ action: 'group_action', backend: b.id, id: 'install' })")
);
assert.ok(SOURCES.macPage.includes('if id == "install" then return install_runtime(ctx, backend'));
assert.ok(SOURCES.macBridge.includes('group_action = true'), 'macOS dispatches group actions');

// The gate can fail: a page action nobody answers, and a removed handler.
const orphan = {
	...SOURCES,
	page: `${SOURCES.page}\npostModelAction({ action: 'ghost_action' });`
};
assert.equal(
	deadActions(orphan).filter((line) => line.includes('ghost_action')).length,
	3,
	'an unanswered action fails on all three hosts'
);
const noInstall = {
	...SOURCES,
	macPage: SOURCES.macPage.replace('if id == "install" then', 'if id == "installed" then')
};
assert.ok(
	deadActions(noInstall).includes('macos: tool "install" has no handler'),
	'a removed macOS install handler fails'
);
const noWindows = {
	...SOURCES,
	windows: SOURCES.windows.replace('Tools["ollama`ninstall"] := (*) =>', '; removed')
};
assert.ok(
	deadActions(noWindows).includes('windows: tool "install" has no handler'),
	'a removed Windows install handler fails'
);
const noLinux = {
	...SOURCES,
	linuxBridge: SOURCES.linuxBridge.replace('payload.action == "add_provider"', 'false')
};
assert.ok(
	deadActions(noLinux).includes('linux: page action "add_provider" has no handler'),
	'a removed Linux action fails'
);

const lateProviders = { ...SOURCES, windows: `${SOURCES.windows}\n; ,providers:[` };
assert.ok(
	deadActions(lateProviders).includes('windows: page action "add_provider" has no handler'),
	'a Windows provider list without its handler fails'
);
const noLinuxRun = {
	...SOURCES,
	linuxRows: SOURCES.linuxRows.replace(
		'{ id = "other_model", text = tr("model_browser.api_other_model"), run = function()',
		'{ id = "other_model", text = tr("model_browser.api_other_model") }, function()'
	)
};
assert.ok(
	deadActions(noLinuxRun).includes('linux: tool "other_model" has no handler'),
	'a Linux tool without its closure fails'
);

console.log(`[OK] model browser: ${actions.length} page action(s) answered on all three hosts.`);
