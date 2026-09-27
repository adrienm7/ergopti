// tools/test/test-linux-package-setup.cjs

/**
 * ==============================================================================
 * MODULE: Linux Package Permission Setup Regression
 * DESCRIPTION:
 * Executes the privileged setup helper with isolated filesystem roots and
 * stubbed system commands. Only local graphical users may receive input access.
 * ==============================================================================
 */

'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const sourcePath = path.join(ROOT, 'static/ergopti_plus/linux/install/setup_permissions.sh');
assert.ok(fs.existsSync(sourcePath), 'native packages need an automatic permission setup owner');
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-package-setup-'));
const bashPath = (value) => value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`);
try {
	const stubs = path.join(sandbox, 'stubs');
	const callLog = path.join(sandbox, 'calls');
	fs.mkdirSync(stubs);
	const stub = (name, body) => fs.writeFileSync(path.join(stubs, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
	stub('id', 'if [ "$1" = -u ]; then echo 0; else exit 1; fi');
	stub('getent', 'if [ "$1" = passwd ]; then echo "desktop:x:1000:1000::/home/desktop:/bin/bash"; else exit 2; fi');
	stub('loginctl', `case "$1" in
list-sessions) printf '1 1000 desktop seat0 tty2\n2 1001 remote - -\n3 1002 console seat0 tty3\n4 120 gdm seat0 tty1\n5 1003 inactive seat0 tty4\n6 1004 gone seat0 tty5\n' ;;
show-session) case "$2" in
1) printf 'Type=wayland\nRemote=no\nUser=1000\nClass=user\nActive=yes\n' ;;
2) printf 'Type=x11\nRemote=yes\nUser=1001\nClass=user\nActive=yes\n' ;;
3) printf 'Type=tty\nRemote=no\nUser=1002\nClass=user\nActive=yes\n' ;;
4) printf 'Type=wayland\nRemote=no\nUser=120\nClass=greeter\nActive=yes\n' ;;
5) printf 'Type=x11\nRemote=no\nUser=1003\nClass=user\nActive=no\n' ;;
6) exit 1 ;;
*) exit 1 ;; esac ;; esac`);
	for (const name of ['groupadd', 'usermod', 'modprobe', 'udevadm']) {
		stub(name, 'printf "%s %s\\n" "${0##*/}" "$*" >> "$CALL_LOG"');
	}
	const script = path.join(sandbox, 'setup.sh');
	for (const name of ['99-ergopti-uinput.rules', 'ergopti-uinput.conf']) {
		fs.copyFileSync(path.join(path.dirname(sourcePath), name), path.join(sandbox, name));
	}
	fs.writeFileSync(script, fs.readFileSync(sourcePath, 'utf8')
		.replaceAll('/etc/', `${bashPath(sandbox)}/etc/`)
		.replace('[ -S /run/udev/control ]', 'true')
		.replace('set -euo pipefail', 'set -euo pipefail\nexport PATH="$TEST_STUBS:/usr/bin:/bin"'));
	const result = spawnSync(bashExecutable(), [bashPath(script), '--active-sessions'], {
		encoding: 'utf8', timeout: 15000,
		env: { HOME: bashPath(sandbox), PATH: `${bashPath(stubs)}:/usr/bin:/bin`,
			TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) },
	});
	assert.equal(result.status, 0, result.stderr || result.error?.message);
	assert.match(result.stderr, /Session 6 could not be inspected/, 'a logout race is reported and deferred');
	const calls = fs.readFileSync(callLog, 'utf8');
	assert.match(calls, /usermod -aG input,uinput desktop/);
	assert.equal((calls.match(/usermod /g) || []).length, 1, 'only one local graphical account is enrolled');
	assert.doesNotMatch(calls, /usermod.*(?:remote|console)/);
	assert.match(fs.readFileSync(path.join(sandbox, 'etc/udev/rules.d/99-ergopti-uinput.rules'), 'utf8'), /static_node=uinput/);
	assert.match(fs.readFileSync(path.join(sandbox, 'etc/modules-load.d/ergopti-uinput.conf'), 'utf8'), /^uinput$/m);
	assert.match(calls, /modprobe uinput/);
	assert.match(calls, /udevadm control --reload-rules/);
	// Exercise the actual BusyBox branch with only command availability
	// replaced. Group mutations still go through the recorded stubs.
	stub('addgroup', 'printf "addgroup %s\\n" "$*" >> "$CALL_LOG"');
	fs.writeFileSync(script, fs.readFileSync(script, 'utf8')
		.replaceAll('command -v usermod >/dev/null 2>&1', 'false')
		.replaceAll('command -v groupadd >/dev/null 2>&1', 'false'));
	fs.writeFileSync(callLog, '');
	const busybox = spawnSync(bashExecutable(), [bashPath(script), '--user', '1000'], {
		encoding: 'utf8', timeout: 15000,
		env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) },
	});
	assert.equal(busybox.status, 0, busybox.stderr || busybox.error?.message);
	const busyboxCalls = fs.readFileSync(callLog, 'utf8');
	for (const group of ['input', 'uinput']) {
		assert.match(busyboxCalls, new RegExp(`^addgroup -S ${group}$`, 'm'));
		assert.match(busyboxCalls, new RegExp(`^addgroup desktop ${group}$`, 'm'));
	}
	assert.doesNotMatch(busyboxCalls, /usermod|groupadd/);
	const launcher = path.join(sandbox, 'installed/install/launch.sh');
	fs.mkdirSync(path.dirname(launcher), { recursive: true });
	fs.writeFileSync(launcher, fs.readFileSync(path.join(ROOT, 'static/ergopti_plus/linux/install/launch.sh'), 'utf8')
		.replace('set -euo pipefail', 'set -euo pipefail\nexport PATH="$TEST_STUBS:/usr/bin:/bin"'));
	const logCall = 'printf "%s %s\\n" "${0##*/}" "$*" >> "$CALL_LOG"';
	stub('id', `if [ "$1" = -u ]; then echo 1000
elif [ "$TEST_CASE" = cancel ]; then echo users
elif [ "$TEST_CASE" = stale ] && [ "$#" = 1 ]; then echo "users \${ACQUIRED_GROUPS:-}"
else echo "users input uinput"; fi`);
	stub('systemctl', logCall + '\nexit 0');
	stub('luajit', logCall + '\nexit 0');
	stub('pkexec', logCall + '\nexit 126');
	stub('sg', logCall + '\nexport ACQUIRED_GROUPS="${ACQUIRED_GROUPS:-} $1"\nexec /bin/bash -c "$3"');
	stub('flock', logCall + '\nif [ "$TEST_CASE" = busy ]; then exit 75; fi');
	if (process.platform === 'win32') {
		// NTFS does not implement the POSIX directory mode. Linux runs the real
		// install command; this seam changes only its filesystem mode operation.
		stub('install', '[[ "$1 $2 $3" = "-d -m 700" ]] || exit 64\nmkdir -p -- "$4"');
	}
	for (const [scenario, args, status, expected, forbidden] of [
		['desktop', ['--tray'], 0, /systemctl --user start ergopti-hotstrings.service/, /luajit|pkexec|enable/],
		['service', ['--service', '--tray'], 0, /luajit .*ergopti_hotstrings.lua --tray/, /systemctl|pkexec/],
		['cancel', ['--service', '--tray'], 78, /pkexec .*setup_permissions.sh --user 1000/, /luajit/],
		['busy', ['--service', '--tray'], 0, /flock /, /luajit|pkexec/],
		['help', ['--help'], 0, /luajit .* --help/, /flock|pkexec|systemctl/],
		['stale', ['--service', '--tray', "an argument's value"], 0, /luajit .* --tray an argument's value/, /pkexec|systemctl/],
	]) {
		fs.writeFileSync(callLog, '');
		const launched = spawnSync(bashExecutable(), [bashPath(launcher), ...args], {
			encoding: 'utf8', timeout: 15000,
			env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog), TEST_CASE: scenario },
		});
		assert.equal(launched.status, status, `${scenario}: ${launched.stderr}`);
		const invoked = fs.readFileSync(callLog, 'utf8');
		assert.match(invoked, expected, scenario);
		assert.doesNotMatch(invoked, forbidden, scenario);
		if (scenario === 'stale') {
			assert.equal((invoked.match(/^sg /gm) || []).length, 2, 'both stale groups are acquired');
			assert.equal((invoked.match(/^flock /gm) || []).length, 1, 'credentials refresh precedes the single instance lock');
		}
	}
	const stopScript = path.join(sandbox, 'stop-sessions.sh');
	const runtimeRoot = path.join(sandbox, 'run/user');
	for (const uid of ['1000', '1001']) {
		fs.mkdirSync(path.join(runtimeRoot, uid), { recursive: true });
		fs.writeFileSync(path.join(runtimeRoot, uid, 'bus'), 'isolated bus presence');
	}
	fs.writeFileSync(stopScript, fs.readFileSync(path.join(ROOT, 'static/ergopti_plus/linux/install/stop_sessions.sh'), 'utf8')
		.replaceAll('/run/user/', `${bashPath(runtimeRoot)}/`)
		.replaceAll('[ -S ', '[ -f ')
		.replace('set -euo pipefail', 'set -euo pipefail\nexport PATH="$TEST_STUBS:/usr/bin:/bin"'));
	stub('id', 'echo 0');
	stub('getent', 'echo "user$2:x:$2:$2::/home/user$2:/bin/bash"');
	stub('runuser', 'export SESSION_ACCOUNT="$2"\nwhile [ "$1" != systemctl ]; do shift; done\nexec "$@"');
	stub('systemctl', `printf '%s %s\\n' "$SESSION_ACCOUNT" "$*" >> "$CALL_LOG"
if [ "$2" = show ]; then
if [ "$SESSION_ACCOUNT" = user1000 ]; then echo /usr/lib/systemd/user/ergopti-hotstrings.service
else echo /home/user1001/.config/systemd/user/ergopti-hotstrings.service; fi
fi`);
	fs.writeFileSync(callLog, '');
	const stopped = spawnSync(bashExecutable(), [bashPath(stopScript)], {
		encoding: 'utf8', timeout: 15000,
		env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) },
	});
	assert.equal(stopped.status, 0, stopped.stderr || stopped.error?.message);
	const stopCalls = fs.readFileSync(callLog, 'utf8');
	assert.match(stopCalls, /^user1000 --user disable --now ergopti-hotstrings.service$/m);
	assert.doesNotMatch(stopCalls, /^user1001 .*disable/m, 'package removal preserves a user-owned service override');
	console.log('[OK] Package setup provisions input access only for local graphical users.');
} finally {
	fs.rmSync(sandbox, { recursive: true, force: true });
}
