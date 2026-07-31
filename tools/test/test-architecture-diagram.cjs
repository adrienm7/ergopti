// tools/test/test-architecture-diagram.cjs

/**
 * ==============================================================================
 * MODULE: Architecture Diagram Generator Regression Test
 * DESCRIPTION:
 * Guards tools/codegen/gen-architecture-diagram.cjs against the silent
 * path-drift class of bug. After the static/drivers -> static/ergopti_plus reorg
 * the generator's hardcoded paths (and a ROOT that resolved to tools/ instead of
 * the repo root) pointed at nothing, so it regenerated an EMPTY diagram while
 * still exiting 0. CI never noticed because nothing exercised the output.
 *
 * This test asserts (a) the generator resolves the real ports/domain/adapter
 * directories with a sane non-zero count, and (b) the committed
 * static/ergopti_plus/docs/architecture.md is in sync with what the generator
 * would emit. The committed file's only volatile part is the timestamp in the
 * wrapper header; the Mermaid body is deterministic, so comparing the body is
 * stable across days.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const gen = require('../codegen/gen-architecture-diagram.cjs');

let pass = 0;
let fail = 0;

function check(name, condition, detail) {
	if (condition) {
		pass += 1;
		console.log(`  ✓ ${name}`);
	} else {
		fail += 1;
		console.log(`  ✗ ${name}${detail ? ' — ' + detail : ''}`);
	}
}

const ports = gen.readSpecNames(gen.PORTS_DIR);
const domain = gen.readSpecNames(gen.DOMAIN_DIR);
const driverData = gen.collectDriverData();

// (a) The reorg-drift regression: a stale path resolves to 0 entries.
check('generator resolves the ports/ spec dir (>=18, not 0)', ports.length >= 18, `found ${ports.length} at ${gen.PORTS_DIR}`);
check('generator resolves the domain/ spec dir (>=4)', domain.length >= 4, `found ${domain.length} at ${gen.DOMAIN_DIR}`);

// (a2) Every driver, not two of them. The diagram used to hardcode windows and
// macos, so linux/adapters/ — a full set of them — appeared nowhere in a
// document titled "the three-layer hexagonal architecture".
check('generator discovers all three drivers', gen.DRIVERS.length >= 3, `found ${gen.DRIVERS.map((d) => d.name).join(', ')}`);
for (const { driver, adapters } of driverData) {
	check(`generator resolves ${driver.name}/adapters (>=18)`, adapters.length >= 18, `found ${adapters.length} at ${driver.dir}`);
}

// (b) Staleness: the committed diagram body must match the freshly built one.
const mermaid = gen.buildDiagram(ports, domain, driverData);
const committed = fs.existsSync(gen.OUT_FILE) ? fs.readFileSync(gen.OUT_FILE, 'utf8') : '';
check(
	'committed architecture.md is in sync with the generator',
	committed.includes(mermaid),
	'architecture.md is stale — run: npm run gen:diagram'
);

// Every port spec must appear as a node in the rendered diagram.
const missing = ports.filter((p) => !mermaid.includes(`["${p}"]`));
check('every port spec appears as a diagram node', missing.length === 0, `missing: ${missing.join(', ')}`);

// And every driver must have its own subgraph. Naming the driver in the diagram
// text is the check that would have failed on the original two-driver version.
const noSubgraph = gen.DRIVERS.filter((d) => !mermaid.includes(`${d.name}/adapters/`));
check('every driver has an adapters subgraph', noSubgraph.length === 0, `missing: ${noSubgraph.map((d) => d.name).join(', ')}`);

console.log(`\nTotal: ${pass + fail} — ${pass} passed, ${fail} failed.`);
process.exit(fail > 0 ? 1 : 0);
