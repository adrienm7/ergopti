// tools/test/test-key-legend.cjs

/**
 * ==============================================================================
 * MODULE: Key Legend Formatter Gate
 * DESCRIPTION:
 * src/lib/keyboard/keyLegend.js is the one legend formatter of the site's
 * keyboards, the layout editor and the Comparer; its classic-script copy
 * (_shared/ui/_generated/key_legend.js) is what the app pages load.
 *
 * WHAT IS CHECKED:
 * 1. The generated copy is the codegen's output for the current source.
 * 2. A dead key reads as its bare accent: a combining mark on a dotted circle
 *    (the site's data), a lone combining mark or a spacing terminator gives
 *    the spacing accent; a dead key that is not an accent keeps its character.
 * 3. A character a key types keeps its stand-ins (∅, ␣, control pictures, a
 *    combining mark on its dotted circle).
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const Codegen = require('../codegen/codegen-key-legend-js.cjs');

// 1/ The generated copy is current.
const generated = fs.readFileSync(Codegen.OUT_PATH, 'utf8');
assert.equal(
	generated,
	Codegen.buildSource(),
	'key_legend.js is stale: npm run codegen:key-legend:js'
);

// The page's KEY_LEGEND, as the app windows load it.
const context = vm.createContext({});
vm.runInContext(`${generated}\nthis.KEY_LEGEND = KEY_LEGEND;`, context);
const { deadKeyText, visibleText, DEAD_KEY_CLASS } = context.KEY_LEGEND;

// 2/ Dead keys.
assert.equal(DEAD_KEY_CLASS, 'key-legend-dead');
assert.equal(deadKeyText('◌̂'), '^', 'the site data spelling of the circumflex');
assert.equal(deadKeyText('◌̈'), '¨', 'the site data spelling of the diaeresis');
assert.equal(deadKeyText('́'), '´', 'a lone combining acute');
assert.equal(deadKeyText('^'), '^', 'a spacing terminator stays');
assert.equal(deadKeyText('µ'), 'µ', 'a dead key that is not an accent keeps its character');
assert.equal(deadKeyText(''), '', 'no terminator');
assert.ok(!deadKeyText('◌̃').includes('◌'), 'never a dotted circle');

// 3/ Characters.
assert.equal(visibleText(''), '∅');
assert.equal(visibleText(' '), '␣');
assert.equal(visibleText('\t'), '␉');
assert.equal(visibleText('́'), '◌́', 'a typed combining mark keeps its carrier');
assert.equal(visibleText('é'), 'é');

console.log('[OK] key legend formatter (generated copy current, dead keys, characters)');
