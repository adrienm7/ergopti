// _shared/ui/layout_optimizer/optimizer_worker.js

/**
 * ==============================================================================
 * MODULE: Layout Optimizer Worker
 * DESCRIPTION:
 * Runs a share of the optimizer's restarts off the page's thread, so the
 * Studio stays responsive while thousands of layouts are scored. It loads
 * the engine and the optimizer next to it and speaks the runner's protocol:
 * {type: 'start', request} starts, {type: 'stop'} stops; the runner's
 * messages go back to the page as they are.
 * ==============================================================================
 */

/* global LAYOUT_OPTIMIZER_RUNNER */
'use strict';

importScripts(
	'../layout_analysis/_generated/analysis_data.js',
	'../layout_analysis/analysis_engine.js',
	'optimizer_core.js',
	'optimizer_runner.js'
);

let running = null;

self.onmessage = (event) => {
	const message = event.data || {};
	if (message.type === 'start') {
		if (running) throw new Error('layout_optimizer: this worker already runs a search');
		running = LAYOUT_OPTIMIZER_RUNNER.start(message.request, (out) => self.postMessage(out));
	} else if (message.type === 'stop' && running) running.stop();
};
