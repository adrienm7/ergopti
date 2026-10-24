// tools/test/support/host-capabilities.cjs

/**
 * ==============================================================================
 * MODULE: Host Capability Probe For Page Harnesses
 * DESCRIPTION:
 * Page harnesses replace host_bridge.js with transport stubs that record what
 * a page posts. A page also asks host_bridge.js which capabilities its host
 * declared (hostHasCapability); this installs the real function into the
 * harness sandbox and keeps the harness's own stubs.
 *
 * FEATURES & RATIONALE:
 * 1. One probe: the page's capability question runs the production code, so a
 *    harness cannot answer it differently from the real host bridge.
 * 2. Stubs win: every global the sandbox held before keeps its value, so the
 *    recorded makeHostBridge and decodeHostBridgeResponse stay in place.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const HOST_BRIDGE = path.resolve(
	__dirname,
	'..',
	'..',
	'..',
	'static',
	'ergopti_plus',
	'_shared',
	'ui',
	'host_bridge.js'
);

/**
 * Runs the real host_bridge.js in a contextified sandbox, then restores every
 * global the sandbox defined before, so only the functions it lacked remain.
 * @param {object} context A vm context (vm.createContext) whose stubs to keep.
 * @returns {object} The same context.
 */
function installHostCapabilities(context) {
	if (!vm.isContext(context)) throw new Error('installHostCapabilities needs a vm context');
	const kept = {};
	for (const name of Object.keys(context)) kept[name] = context[name];
	vm.runInContext(fs.readFileSync(HOST_BRIDGE, 'utf8'), context, { filename: 'host_bridge.js' });
	Object.assign(context, kept);
	if (typeof context.hostHasCapability !== 'function')
		throw new Error('host_bridge.js no longer defines hostHasCapability');
	return context;
}

module.exports = { installHostCapabilities };
