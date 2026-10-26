// tools/lib/menu-parent-source-gate.cjs

/**
 * ==============================================================================
 * MODULE: Menu Parent Source Ownership Gate
 * DESCRIPTION:
 * Owns the assertions on the raw structural admission of the Debug,
 * Configuration, Metrics and About parents. The admission body lives once in
 * _shared/lua/menu/frames/parent_source.lua; each native driver keeps only its
 * root-level import and three delegating ports. The menu gates call this
 * module with their own physical-owner readers, so every mutation they used to
 * apply to a driver-local helper is now applied to the shared module text, and
 * the driver pins stay as strong as the helper bodies they replace.
 *
 * FEATURES & RATIONALE:
 * 1. Shared body ownership. The three shared functions (dense, read_source,
 *    parent_unchanged) must each exist exactly once at the top level, keep
 *    their raw-read statements, and refuse a wrapped, commented or duplicated
 *    definition.
 * 2. Section catalogue. A section's children key and options are one physical
 *    line of the SECTIONS table, pinned per section.
 * 3. Driver pins. The import and each delegating return must be root-level
 *    statements of the driver, and a foreign receiver or a withdrawn return
 *    is refused.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SHARED_PATH = path.resolve(
	__dirname,
	'../..',
	'static/ergopti_plus/_shared/lua/menu/frames/parent_source.lua'
);
const IMPORT = 'local ParentSource = require("menu.frames.parent_source")';

/** The physical SECTIONS line of each section. */
const SECTION_LINES = {
	debug: '\tdebug = { children = "debug_menu" },',
	configuration: '\tconfiguration = { children = "configuration_menu" },',
	metrics: '\tmetrics = { children = "metrics_menu", protect_root = true },',
	about: '\tabout = { children = "about_menu", children_required = true, plain_label = true },'
};

const SHARED_DEFINITIONS = [
	[
		'local function read_source(renderer, platform, section)',
		[
			'if type(root) ~= "table" or getmetatable(root) ~= nil then return nil end',
			'local top, children = rawget(root, "top_level"), rawget(root, spec.children)',
			'if not dense(top, true) or not dense(children, true) then return nil end',
			'if spec.children_required and #children == 0 then return nil end',
			'if spec.plain_label and rawget(parent, "label_prefix") ~= nil then return nil end',
			'local fields = {}',
			'return root, top, children, parent, fields'
		]
	],
	[
		'local function dense(value, records)',
		[
			'if type(value) ~= "table" or getmetatable(value) ~= nil then return false end',
			'return count == maximum'
		]
	],
	['local function parent_unchanged(parent, fields)', ['return true']]
];

/** Statements of read_source that sit one block deep. */
const NESTED_STATEMENTS = [
	'ok, root = pcall(renderer.get_root)',
	'if not ok then return nil end',
	'root = renderer.get_root()'
];

function readShared() {
	return fs.readFileSync(SHARED_PATH, 'utf8');
}

/**
 * Asserts the shared body and one section's pins in a driver source.
 * @param {object} gate Physical readers of the calling gate: ownerBody, hasStatement.
 * @param {string} section Parent id: debug, configuration, metrics or about.
 * @param {string} label Name the gate's ownerBody reports ("Debug", ...).
 * @param {string} source The driver file text.
 * @param {string} prefix The driver's local port prefix (debug, configuration...).
 */
function checkParentSource(gate, section, label, source, prefix) {
	const { ownerBody, hasStatement } = gate;
	const physical = new RegExp('physical native ' + label + ' owner');
	const shared = readShared();
	for (const [definition, statements] of SHARED_DEFINITIONS) {
		const actual = ownerBody(shared, definition);
		for (const statement of statements)
			assert(hasStatement(actual, statement), 'actual shared raw structural helper ' + statement);
		assert.throws(() => ownerBody('if false then\n' + shared + '\nend', definition), physical);
		assert.throws(
			() => ownerBody(shared.replace(definition, '-- ' + definition), definition),
			physical
		);
		assert.throws(() => ownerBody(shared + '\n' + definition + '\nend\n', definition), physical);
		for (const statement of statements) {
			assert(
				!hasStatement(actual.replace(statement, 'return nil'), statement),
				'a withdrawn shared statement is refused ' + statement
			);
		}
	}
	const reader = ownerBody(shared, SHARED_DEFINITIONS[0][0]);
	for (const statement of NESTED_STATEMENTS)
		assert(hasStatement(reader, statement, 1), 'nested shared statement ' + statement);
	assert.equal(
		shared.split('\n').filter((line) => line === SECTION_LINES[section]).length,
		1,
		section + ': one physical SECTIONS line'
	);
	assert.equal(source.split('ParentSource =').length - 1, 1, 'one ParentSource binding');
	assert(hasStatement(source, IMPORT), 'root-level shared import');
	assert(!hasStatement('if false then\n' + source + '\nend', IMPORT), 'conditional import refused');
	assert(!hasStatement(source.replace(IMPORT, '-- ' + IMPORT), IMPORT), 'commented import refused');
	for (const [definition, statement] of [
		[`local function ${prefix}_dense(value, records)`, 'return ParentSource.dense(value, records)'],
		[
			`local function ${prefix}_source(renderer, platform)`,
			`return ParentSource.read(renderer, platform, "${section}")`
		],
		[
			`local function ${prefix}_parent_unchanged(parent, fields)`,
			'return ParentSource.unchanged(parent, fields)'
		]
	]) {
		const actual = ownerBody(source, definition);
		assert(hasStatement(actual, statement), 'delegating port ' + statement);
		assert(!hasStatement(actual.replace(statement, 'return nil'), statement), 'withdrawn port');
		assert(
			!hasStatement(actual.replace('ParentSource.', 'Foreign.ParentSource.'), statement),
			'foreign shared module cannot own the port'
		);
		assert.throws(() => ownerBody('if false then\n' + source + '\nend', definition), physical);
		assert.throws(
			() => ownerBody(source.replace(definition, '-- ' + definition), definition),
			physical
		);
		assert.throws(() => ownerBody(source + '\n' + definition + '\nend\n', definition), physical);
	}
}

module.exports = { checkParentSource, SHARED_PATH, IMPORT };
