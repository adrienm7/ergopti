// tools/diagnostics/apple_shortcuts_probe/discover_diagnostic.js
// Read-only native API probe. No user name is interpolated; no shortcut is run.
// Shortcuts Events retrieves the full native catalogue. Only output is bounded.
ObjC.import('Foundation');
function checkpoint(number) {
	var data = $.NSString.stringWithString('ASCP:' + number + '\n').dataUsingEncoding(
		$.NSUTF8StringEncoding
	);
	$.NSFileHandle.fileHandleWithStandardError.writeData(data);
}

// Per-event observation only. The parent retains the absolute 20-second budget.
var diagnosticDeadline = 0;
var diagnosticStage = 0;
function diagnostic(phase, error) {
	var kind = 'missing',
		available = false,
		number = 0;
	try {
		var value = error == null ? undefined : error.errorNumber;
		kind = value === null ? 'null' : typeof value;
		if (
			kind === 'number' &&
			Number.isInteger(value) &&
			value >= -2147483648 &&
			value <= 2147483647
		) {
			kind = 'integer';
			available = true;
			number = value;
		}
	} catch (_) {
		kind = 'unavailable';
	}
	try {
		var line = JSON.stringify({
			phase: phase,
			stage: diagnosticStage,
			error_type: kind,
			error_available: available,
			error_number: number
		});
		var data = $.NSString.stringWithString('ASCD:' + line + '\n').dataUsingEncoding(
			$.NSUTF8StringEncoding
		);
		$.NSFileHandle.fileHandleWithStandardError.writeData(data);
	} catch (_) {
		// A missing frame is explicit unavailable health in the parent parser.
	}
}
function eventModifiers() {
	var remaining = diagnosticDeadline - $.NSProcessInfo.processInfo.systemUptime;
	if (!Number.isFinite(remaining) || remaining <= 0) throw new Error('diagnostic_deadline');
	// A half-remaining event budget leaves time for the owned supervisor to observe errors.
	return { timeout: remaining / 2 };
}

function run(arguments) {
	var stage = 1;
	try {
		if (!Array.isArray(arguments) || arguments.length !== 1 || !/^[0-9]+$/.test(arguments[0]))
			throw new Error('diagnostic_arguments');
		var remainingMs = Number(arguments[0]);
		if (!Number.isInteger(remainingMs) || remainingMs <= 0 || remainingMs > 20000)
			throw new Error('diagnostic_arguments');
		diagnosticDeadline = $.NSProcessInfo.processInfo.systemUptime + remainingMs / 1000;
		var app = Application('com.apple.shortcuts.events');
		checkpoint(1);
		diagnosticStage = 1;
		diagnostic('get_entered');
		var catalogue = app.shortcuts(eventModifiers());
		diagnostic('get_returned');
		checkpoint(2);
		if (!Array.isArray(catalogue))
			return JSON.stringify({
				version: 1,
				status: 'refused',
				stage: stage,
				reason: 'native_refused'
			});
		var count = catalogue.length;
		var rows = [],
			seen = Object.create(null),
			limit = Math.min(count, 64);
		stage = 2;
		for (var index = 0; index < limit; index++) {
			var shortcut = catalogue[index];
			var identifier = shortcut.id(eventModifiers()),
				name = shortcut.name(eventModifiers()),
				acceptsInput = shortcut.acceptsInput(eventModifiers());
			if (
				typeof identifier !== 'string' ||
				identifier.length < 1 ||
				identifier.length > 256 ||
				typeof name !== 'string' ||
				name.indexOf('\u0000') !== -1 ||
				identifier.indexOf('\u0000') !== -1 ||
				typeof acceptsInput !== 'boolean' ||
				seen[identifier]
			)
				return JSON.stringify({
					version: 1,
					status: 'refused',
					stage: stage,
					reason: 'native_refused'
				});
			stage = 3;
			var data = $.NSString.stringWithString(name).dataUsingEncoding($.NSUTF8StringEncoding);
			if (!data || data.length > 4096)
				return JSON.stringify({
					version: 1,
					status: 'refused',
					stage: stage,
					reason: 'native_refused'
				});
			seen[identifier] = true;
			rows.push({ id: identifier, name: name, accepts_input: acceptsInput });
			stage = 2;
		}
		stage = 4;
		checkpoint(3);
		diagnosticStage = 4;
		diagnostic('get_entered');
		var after = app.shortcuts(eventModifiers());
		diagnostic('get_returned');
		checkpoint(4);
		if (!Array.isArray(after) || after.length !== count)
			return JSON.stringify({
				version: 1,
				status: 'stale',
				stage: stage,
				reason: 'native_refused'
			});
		stage = 5;
		var packet = JSON.stringify({
			version: 1,
			status: 'observed',
			choices: rows,
			truncated: count > 64
		});
		if (
			$.NSString.stringWithString(packet).dataUsingEncoding($.NSUTF8StringEncoding).length > 65536
		)
			return JSON.stringify({
				version: 1,
				status: 'refused',
				stage: stage,
				reason: 'native_refused'
			});
		return packet;
	} catch (error) {
		diagnosticStage = stage;
		diagnostic('get_failed', error);
		// Only an exact native error-code field enters the closed taxonomy.
		var permission = error && error.errorNumber === -1743;
		return JSON.stringify({
			version: 1,
			status: 'refused',
			stage: stage,
			reason: permission ? 'automation_permission_refused' : 'native_refused'
		});
	}
}
