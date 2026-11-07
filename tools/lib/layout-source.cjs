// tools/lib/layout-source.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Loader
 * DESCRIPTION:
 * Loads the browser's source model with the existing composer reader and TOML
 * codec. The CLI and tests use the same contract a shared editor can load.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const codec = require('smol-toml');
const { shared } = require('./paths.cjs');

/** Load the pure source model in the same classic-script order as a page. */
function loadLayoutSource() {
	const context = vm.createContext({});
	for (const file of ['composer_model.js', 'source_model.js']) {
		const filename = path.join(shared('ui', 'layout_composer'), file);
		vm.runInContext(fs.readFileSync(filename, 'utf8'), context, { filename });
	}
	const model = vm.runInContext('LayoutSource', context);
	return {
		...model,
		read: (text) => model.read(text, codec),
		write: (source) => model.write(source, codec)
	};
}

module.exports = { loadLayoutSource };
