// tools/test/test-macos-python-system-compat.cjs
/**
 * The macOS helpers run under the first native python3 of the Mac, which is
 * Apple's Python 3.9 of the developer tools when nothing newer is installed.
 * Path.stat(follow_symlinks=...) needs Python 3.10: under 3.9 it raised
 * TypeError, the owned Ollama metadata hint refused, and an installed runtime
 * was reported as not installed (field run 2026-10-30 17:19). Every macOS and
 * shared helper must parse as Python 3.9 and call os.stat for a no-follow stat.
 */
'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../..');
const SCAN = String.raw`
import ast, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
roots = [root / "static/ergopti_plus/macos", root / "static/ergopti_plus/_shared/python"]
problems, count = [], 0
for base in roots:
    for path in sorted(base.rglob("*.py")):
        if "tests" in path.relative_to(root).parts:
            continue
        count += 1
        text = path.read_text(encoding="utf-8")
        try:
            ast.parse(text, feature_version=(3, 9))
        except SyntaxError as error:
            problems.append("%s: not Python 3.9 syntax (%s)" % (path.relative_to(root), error.msg))
        for number, line in enumerate(text.splitlines(), 1):
            if re.search(r"(?<!os)\.stat\(follow_symlinks=", line):
                problems.append("%s:%d: Path.stat(follow_symlinks=) needs Python 3.10; use os.stat" % (path.relative_to(root), number))
print("\n".join(problems) if problems else "OK %d" % count)
sys.exit(1 if problems else 0)
`;
const result = spawnSync('python3', ['-I', '-c', SCAN, ROOT], { encoding: 'utf8' });
assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
const scanned = Number(result.stdout.trim().split(' ')[1]);
assert(scanned >= 20, `the scan must see the macOS helpers, saw ${scanned}`);
console.log(`[OK] ${scanned} macOS and shared Python helper(s) run on the system Python 3.9.`);
