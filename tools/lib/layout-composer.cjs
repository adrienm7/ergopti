// tools/lib/layout-composer.cjs

/**
 * ==============================================================================
 * MODULE: Layout Composer Loader
 * DESCRIPTION:
 * Loads the shared layout composer model (_shared/ui/layout_composer) in a vm
 * context, as the classic script a page loads, together with the registry
 * layouts read as composer sources. The corpus generator and the gates that
 * compose layouts share it, so they cannot read the model or the registry
 * differently.
 *
 * FEATURES & RATIONALE:
 * 1. One loader: the model is evaluated exactly as the page evaluates it.
 * 2. Every registry layout and both reference layouts are sources, read with
 *    the keycode convention their index entry declares.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { REPO_ROOT, shared } = require('./paths.cjs');

const REGISTRY_DIR = path.join(REPO_ROOT, 'static', 'layouts', 'registry');

/**
 * Loads the model, the generated key data and every source.
 * @returns {{Composer: object, REFERENCE: object, TABLE: object, SOURCES: object,
 *   INDEX: object, registryText: Function}}
 */
function loadComposer() {
	const sandbox = {};
	vm.createContext(sandbox);
	for (const file of [
		shared('ui', 'layout_composer', '_generated', 'composer_data.js'),
		shared('ui', 'layout_composer', 'reference_layouts.js'),
		shared('ui', 'layout_composer', 'composer_model.js')
	])
		vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	const Composer = vm.runInContext('LayoutComposer', sandbox);
	const REFERENCE = vm.runInContext('LAYOUT_COMPOSER_REFERENCE', sandbox);
	const TABLE = vm.runInContext('LAYOUT_COMPOSER_DATA', sandbox);
	const INDEX = JSON.parse(fs.readFileSync(path.join(REGISTRY_DIR, 'index.json'), 'utf8'));
	const registryText = (id) => {
		const entry = INDEX.layouts.find((candidate) => candidate.id === id);
		return fs.readFileSync(path.join(REGISTRY_DIR, entry.file), 'utf8');
	};
	const SOURCES = {};
	for (const entry of INDEX.layouts)
		SOURCES[entry.id] = Composer.parseSource(
			entry.id,
			registryText(entry.id),
			entry.keycode_convention,
			TABLE
		);
	for (const id of Object.keys(REFERENCE))
		SOURCES[id] = Composer.referenceSource(id, REFERENCE[id]);
	return { Composer, REFERENCE, TABLE, SOURCES, INDEX, registryText };
}

module.exports = { loadComposer, REGISTRY_DIR };
