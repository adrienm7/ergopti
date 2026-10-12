// tools/test/test-js-native-qualification-ownership.cjs
'use strict';

const { loadInventory } = require('./lib/js-feature-inventory.cjs');

/** Records only actual CLI/callsite routing; no control body or child process executes. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');
const FILES = {
	item36: 'tools/test/test-item36-native-qualification.cjs',
	pac: 'tools/test/test-macos-native-pac-qualification.cjs',
	deferral: 'tools/test/test-macos-dev-qualification-deferral.cjs',
	pipeline: 'tools/test/test-ci-pipeline-wiring.cjs',
	runner: 'tools/test/run-js-suite.cjs'
};
function parse(text) {
	return acorn.parse(text, { ecmaVersion: 'latest', sourceType: 'script' });
}
function walk(node, visit, ancestors = []) {
	if (!node || typeof node !== 'object') return;
	visit(node, ancestors);
	for (const [key, value] of Object.entries(node)) {
		if (Array.isArray(value)) value.forEach((child) => walk(child, visit, [...ancestors, node]));
		else if (value && typeof value === 'object' && value.type)
			walk(value, visit, [...ancestors, node]);
	}
}
function mainStatement(ast) {
	const candidates = ast.body.filter(
		(node) =>
			node.type === 'IfStatement' &&
			node.test.type === 'BinaryExpression' &&
			node.test.operator === '===' &&
			node.test.left.type === 'MemberExpression' &&
			node.test.left.object.name === 'require' &&
			node.test.left.property.name === 'main' &&
			node.test.right.name === 'module'
	);
	assert.equal(candidates.length, 1, 'one actual standalone CLI owner');
	return candidates[0];
}
function source(slice, node) {
	return slice.substring(node.start, node.end);
}
function census(sources) {
	let item36 = 0;
	walk(parse(sources.item36), (node, ancestors) => {
		if (node.type !== 'CallExpression' || node.callee.name !== 'check') return;
		if (node.arguments[0].type === 'Literal') item36++;
		else {
			const loop = ancestors.filter((parent) => parent.type === 'ForOfStatement').at(-1);
			assert.equal(
				loop?.right.type,
				'ArrayExpression',
				'each dynamic Item36 label has one exact vector'
			);
			item36 += loop.right.elements.length;
		}
	});
	assert.equal(item36, 65);
	for (const [name, variable, expected] of [
		['pac', 'passed', 82],
		['deferral', 'passed', 79],
		['deferral', 'publicReceiptChecks', 2],
		['deferral', 'numberRowSelectorChecks', 30]
	]) {
		const matches = [];
		walk(parse(sources[name]), (node) => {
			if (
				node.type === 'CallExpression' &&
				node.callee.type === 'MemberExpression' &&
				node.callee.object.name === 'assert' &&
				node.callee.property.name === 'equal' &&
				node.arguments[0]?.name === variable &&
				node.arguments[1]?.value === expected
			)
				matches.push(node);
		});
		assert.equal(matches.length, 1, `${name} original ${variable} census remains exact`);
	}
	return { item36, pac: 82, deferral: 111 };
}
function admitRunBoundary(run) {
	// Recording routing must not invent completion after a return in the real owner.
	function visit(node) {
		if (!node || typeof node !== 'object') return;
		if (
			['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(node.type)
		)
			return;
		assert.notEqual(
			node.type,
			'ReturnStatement',
			'deferral owner must not return before its census'
		);
		for (const value of Object.values(node)) {
			if (Array.isArray(value)) value.forEach(visit);
			else if (value && typeof value === 'object' && value.type) visit(value);
		}
	}
	visit(run.body);
}
function trace(sources, entry) {
	const counts = { item36: 0, pac: 0, deferral: 0, pacHelper: 0 };
	const cache = new Map();
	const modules = Object.fromEntries(Object.keys(FILES).map((name) => [name, { exports: {} }]));
	const main = modules[entry];
	const values = {
		workflow: 'PROJECTED_WORKFLOW',
		rawWorkflow: 'RAW_WORKFLOW',
		admitItem36Selector: () => {},
		admitRawNativePacSelector: () => {},
		ITEM36_FILTER: 'ITEM36_FILTER',
		PAC_FILTER: 'PAC_FILTER',
		// This routing-only sentinel never evaluates the source guard or its native body.
		PAC_STEP_SOURCE: 'RECORDED_PAC_HEADER\n        shell: bash\nRECORDED_PAC_RUN'
	};
	const paths = Object.fromEntries(
		Object.entries(FILES).map(([name, rel]) => ['./' + path.basename(rel), name])
	);
	function evaluate(code, module, extra = {}) {
		const require = (specifier) => {
			assert(Object.hasOwn(paths, specifier), `unknown recording dependency ${specifier}`);
			return load(paths[specifier]);
		};
		require.main = main;
		vm.runInNewContext(
			code,
			{ module, require, ...values, ...extra },
			{ timeout: 100, contextCodeGeneration: { strings: false, wasm: false } }
		);
	}
	function load(name) {
		if (cache.has(name)) return cache.get(name).exports;
		const module = modules[name];
		cache.set(name, module);
		if (name === 'item36' || name === 'pac') {
			module.exports = (context) => {
				const expected =
					name === 'item36'
						? ['workflow', 'admitItem36Selector', 'ITEM36_FILTER']
						: ['workflow', 'admitNativePacSelector', 'PAC_FILTER', 'PAC_STEP_GUARD'];
				assert.deepEqual(Object.keys(context), expected);
				if (name === 'pac')
					assert.equal(
						context.PAC_STEP_GUARD,
						values.PAC_STEP_SOURCE.slice(0, values.PAC_STEP_SOURCE.indexOf('        shell: bash')),
						'PAC context must retain the exact source-derived guard prefix'
					);
				counts[name]++;
				if (name === 'pac') counts.pacHelper++;
			};
			evaluate(source(sources[name], mainStatement(parse(sources[name]))), module);
		} else if (name === 'deferral') {
			const ast = parse(sources.deferral);
			const run = ast.body.find(
				(node) => node.type === 'FunctionDeclaration' && node.id.name === 'run'
			);
			if (run) {
				admitRunBoundary(run);
				const leafBlocks = run.body.body.filter(
					(node) => node.type === 'IfStatement' && node.test.name === 'includeLeafControls'
				);
				assert.equal(leafBlocks.length, 1, 'one explicit leaf delegation block');
				const recordedRun = ({ includeLeafControls = true } = {}) => {
					assert.equal(typeof includeLeafControls, 'boolean');
					counts.deferral++;
					evaluate(source(sources.deferral, leafBlocks[0]), module, {
						includeLeafControls
					});
				};
				const assignment = ast.body.filter(
					(node) =>
						node.type === 'ExpressionStatement' &&
						node.expression.type === 'AssignmentExpression' &&
						node.expression.left.object?.name === 'module' &&
						node.expression.left.property?.name === 'exports'
				);
				assert.equal(assignment.length, 1);
				evaluate(source(sources.deferral, assignment[0]), module, {
					run: recordedRun
				});
				evaluate(source(sources.deferral, mainStatement(ast)), module, {
					run: recordedRun
				});
			} else {
				counts.deferral++;
				const calls = ast.body.filter(
					(node) =>
						node.type === 'ExpressionStatement' &&
						node.expression.callee?.type === 'CallExpression' &&
						node.expression.callee.callee.name === 'require' &&
						[
							'./test-item36-native-qualification.cjs',
							'./test-macos-native-pac-qualification.cjs'
						].includes(node.expression.callee.arguments[0]?.value)
				);
				assert.equal(calls.length, 2, 'both original delegated leaf calls are accounted');
				calls.forEach((node) => evaluate(source(sources.deferral, node), module));
			}
		} else if (name === 'pipeline') {
			const calls = parse(sources.pipeline).body.filter(
				(node) =>
					node.type === 'ExpressionStatement' &&
					source(sources.pipeline, node).includes(
						"require('./test-macos-dev-qualification-deferral.cjs')"
					)
			);
			assert.equal(calls.length, 1, 'pipeline has one narrowly exported source-control owner');
			evaluate(source(sources.pipeline, calls[0]), module);
		} else throw new Error('Unknown entry');
		return module.exports;
	}
	load(entry);
	return counts;
}
function enrolled(sources, full) {
	const entries = [...sources.inventory.checks];
	if (full) {
		walk(parse(sources.runner), (node) => {
			if (node.type !== 'VariableDeclarator' || node.id.name !== 'SLOW_CHECKS') return;
			assert.equal(node.init.type, 'ArrayExpression');
			for (const row of node.init.elements) {
				assert.equal(row.type, 'ObjectExpression');
				const args = row.properties.find((property) => property.key.name === 'args')?.value;
				assert.equal(args?.type, 'ArrayExpression');
				entries.push({
					args: args.elements.map((argument) => {
						assert.equal(argument.type, 'Literal');
						return argument.value;
					})
				});
			}
		});
	}
	const checks = [];
	for (const entry of entries) {
		const name = Object.keys(FILES).find((key) => FILES[key] === entry.args[0]);
		if (!['item36', 'pac', 'pipeline'].includes(name)) continue;
		assert(!entry.platforms, 'mandatory owners must never become platform conditional');
		assert.equal(entry.args.length, 1);
		assert(['node', '$NODE_EXECUTABLE'].includes(entry.cmd));
		checks.push(name);
	}
	assert.deepEqual(
		checks,
		['pac', 'item36', 'pipeline'],
		'all original leaf/pipeline entries remain exactly once'
	);
	return checks;
}
function checkOwnership(sources) {
	const named = census(sources);
	const run = parse(sources.deferral).body.find(
		(node) => node.type === 'FunctionDeclaration' && node.id.name === 'run'
	);
	if (run) {
		const early =
			sources.deferral.slice(0, run.body.start + 1) +
			'\nreturn;\n' +
			sources.deferral.slice(run.body.start + 1);
		assert.throws(
			() => trace({ ...sources, deferral: early }, 'pipeline'),
			/deferral owner must not return before its census/,
			'an early return must not be recorded as completed controls'
		);
	}

	const pacAssignments = [];
	walk(parse(sources.deferral), (node) => {
		if (node.type === 'Property' && node.key.name === 'PAC_STEP_GUARD') pacAssignments.push(node);
	});
	assert.equal(
		pacAssignments.length,
		2,
		'standalone and delegated PAC retain the same guard context'
	);
	for (const property of pacAssignments) {
		const without =
			sources.deferral.slice(0, property.start) +
			'PAC_STEP_GUARD: undefined' +
			sources.deferral.slice(property.end);
		const whole =
			sources.deferral.slice(0, property.start) +
			'PAC_STEP_GUARD: PAC_STEP_SOURCE' +
			sources.deferral.slice(property.end);
		const extra =
			sources.deferral.slice(0, property.start) +
			'FOREIGN_PAC_STEP_GUARD: PAC_STEP_SOURCE' +
			sources.deferral.slice(property.end);
		const entry = property === pacAssignments[0] ? 'deferral' : 'pac';
		for (const changed of [without, whole, extra])
			assert.throws(
				() => trace({ ...sources, deferral: changed }, entry),
				undefined,
				'missing/whole/foreign PAC guard context must fail real routing'
			);
	}

	const summaries = [];
	for (const full of [false, true]) {
		const total = { item36: 0, pac: 0, deferral: 0, pacHelper: 0 };
		for (const entry of enrolled(sources, full)) {
			const row = trace(sources, entry);
			Object.keys(total).forEach((key) => (total[key] += row[key]));
		}
		assert.deepEqual(
			total,
			{ item36: 1, pac: 1, deferral: 1, pacHelper: 1 },
			'full/default control ownership is an exact union'
		);
		summaries.push({
			full,
			calls: total,
			namedControls: named.item36 + named.pac + named.deferral
		});
	}
	assert.deepEqual(trace(sources, 'item36'), {
		item36: 1,
		pac: 0,
		deferral: 0,
		pacHelper: 0
	});
	assert.deepEqual(trace(sources, 'pac'), {
		item36: 0,
		pac: 1,
		deferral: 0,
		pacHelper: 1
	});
	assert.deepEqual(trace(sources, 'deferral'), {
		item36: 1,
		pac: 1,
		deferral: 1,
		pacHelper: 1
	});
	assert.deepEqual(trace(sources, 'pipeline'), {
		item36: 0,
		pac: 0,
		deferral: 1,
		pacHelper: 0
	});
	return summaries;
}
module.exports = { checkOwnership, trace, census, enrolled, FILES };
if (require.main === module) {
	const root = path.resolve(__dirname, '../..');
	const sources = Object.fromEntries(
		Object.entries(FILES).map(([name, rel]) => [
			name,
			fs.readFileSync(path.join(root, rel), 'utf8')
		])
	);
	sources.inventory = loadInventory(root);
	checkOwnership(sources);
	console.log(
		'PASS: native qualification JS owner union and direct CLI routing; all platform/control bodies UNRUN.'
	);
}
