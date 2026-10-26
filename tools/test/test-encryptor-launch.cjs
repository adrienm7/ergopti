// tools/test/test-encryptor-launch.cjs

/**
 * ==============================================================================
 * MODULE: Encryptor Startup Receipt
 * DESCRIPTION:
 * Runs the actual Python launcher and icon decision over physical bundle files.
 * Explicit native-boundary traps observe helper and execv calls without running
 * zsh, osascript or a macOS application. No native GUI qualification is claimed.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const root = path.resolve(__dirname, '../..');
const launcher = path.join(
	root,
	'static/ergopti_plus/macos/apps/Encryptor.app/Contents/MacOS/encryptor'
);
const harness = String.raw`
import builtins
import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
from unittest.mock import patch

source = Path(sys.argv[1])
receipts = []
for mode in ("missing_icon", "stale_icon", "fresh_icon", "missing_svg", "missing_helper", "missing_droplet", "helper_refused"):
    with tempfile.TemporaryDirectory(prefix="ergopti-encryptor-") as temporary:
        macos = Path(temporary) / "Encryptor ' literal.app" / "Contents" / "MacOS"
        resources = macos.parent / "Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        launch = macos / "encryptor"
        shutil.copyfile(source, launch)
        svg, icns, helper = (resources / name for name in ("AppIcon.svg", "AppIcon.icns", "make_icon.sh"))
        droplet = macos / "droplet_bin"
        if mode != "missing_svg":
            svg.write_text("<svg/>\n", encoding="utf-8")
            os.utime(svg, (200, 200))
        if mode != "missing_helper":
            helper.write_text("#!/bin/zsh\nexit 0\n", encoding="utf-8")
        if mode not in ("missing_icon", "missing_droplet", "helper_refused"):
            icns.write_bytes(b"physical-icon-fixture")
            os.utime(icns, (100, 100) if mode == "stale_icon" else (300, 300))
        if mode != "missing_droplet":
            droplet.write_bytes(b"physical-droplet-boundary-fixture")
        loader = importlib.machinery.SourceFileLoader("encryptor_fixture", str(launch))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        subject = importlib.util.module_from_spec(spec)
        loader.exec_module(subject)
        children, replacements, log_attempts = [], [], []
        native_open = builtins.open
        arguments = [str(launch), "literal ' $ file.txt", "--argument", "Unicode-\u00e9.txt"]
        def open_boundary(file, *args, **kwargs):
            if os.fspath(file) == "/tmp/encryptor.log":
                log_attempts.append(os.fspath(file))
                raise PermissionError(errno.EACCES, "explicit fixed log refusal", os.fspath(file))
            return native_open(file, *args, **kwargs)
        def run_boundary(argv, *args, **kwargs):
            children.append({"argv": list(argv), "capture_output": kwargs.get("capture_output")})
            return types.SimpleNamespace(returncode=1 if mode == "helper_refused" else 0, stdout=b"", stderr=b"")
        def exec_boundary(executable, argv):
            replacements.append({"executable": executable, "argv": list(argv)})
        diagnostic = io.StringIO()
        error, status = None, None
        with patch.object(builtins, "open", open_boundary), patch.object(subprocess, "run", run_boundary), patch.object(os, "execv", exec_boundary), patch.object(sys, "argv", arguments), contextlib.redirect_stderr(diagnostic):
            try:
                subject.main()
            except SystemExit as stopped:
                status = stopped.code
            except Exception as failure:
                error = {"type": type(failure).__name__, "errno": getattr(failure, "errno", None)}
        receipts.append({"mode": mode, "error": error, "status": status, "children": children, "replacements": replacements, "log_attempts": log_attempts, "stderr": diagnostic.getvalue(), "resources": str(resources), "droplet": str(droplet), "arguments": arguments[1:]})
print(json.dumps(receipts))
`;

const result = spawnSync(pythonExecutable(), ['-c', harness, launcher], {
	cwd: root,
	encoding: 'utf8',
	maxBuffer: 1024 * 1024
});
assert.ifError(result.error);
assert.equal(result.signal, null, result.stderr);
assert.equal(result.status, 0, result.stderr);
const receipts = JSON.parse(result.stdout);
assert.equal(receipts.length, 7, 'every physical bundle scenario must execute');
let failed = 0;
for (const receipt of receipts) {
	try {
		assert.equal(receipt.error, null, 'startup cannot depend on the fixed diagnostic sink');
		assert.deepEqual(receipt.log_attempts, [], 'no fixed temporary log is acquired');
		const needsBuild = ['missing_icon', 'stale_icon', 'missing_droplet', 'helper_refused'].includes(
			receipt.mode
		);
		const helper = path.join(receipt.resources, 'make_icon.sh');
		const iconChildren = receipt.children.filter((child) => child.argv[0] === 'zsh');
		assert.deepEqual(
			iconChildren,
			needsBuild ? [{ argv: ['zsh', helper], capture_output: true }] : [],
			'only missing or stale available icons invoke the existing helper'
		);
		assert.equal(
			receipt.stderr,
			needsBuild
				? `[Encryptor] regenerating icon from ${path.join(receipt.resources, 'AppIcon.svg')}\n`
				: '',
			'the existing English status reaches inherited stderr only when a build is requested'
		);
		if (receipt.mode === 'missing_droplet') {
			assert.equal(receipt.status, 1, 'missing droplet remains a startup refusal');
			assert.deepEqual(receipt.replacements, []);
			assert.equal(receipt.children.length, 2);
			assert.equal(receipt.children[1].argv[0], 'osascript');
			assert.equal(receipt.children[1].capture_output, true);
			assert.ok(receipt.children[1].argv[2].includes(receipt.droplet));
		} else {
			assert.equal(receipt.status, null);
			assert.deepEqual(receipt.replacements, [
				{ executable: receipt.droplet, argv: [receipt.droplet, ...receipt.arguments] }
			]);
			assert.equal(receipt.children.length, needsBuild ? 1 : 0);
		}
		console.log(`ok Encryptor ${receipt.mode} preserves helper and execv receipts`);
	} catch (error) {
		failed += 1;
		console.error(`FAIL Encryptor ${receipt.mode}: ${error.message}\n${JSON.stringify(receipt)}`);
	}
}
assert.equal(failed, 0, 'Encryptor launcher scenarios failed');
