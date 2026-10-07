// tools/diagnostics/apple_shortcuts_probe/discover.js
// Read-only native API probe. No user name is interpolated; no shortcut is run.
// Shortcuts Events retrieves the full native catalogue. Only output is bounded.
ObjC.import('Foundation');
function checkpoint(number) {
	var data = $.NSString.stringWithString('ASCP:' + number + '\n').dataUsingEncoding(
		$.NSUTF8StringEncoding
	);
	$.NSFileHandle.fileHandleWithStandardError.writeData(data);
}
function run() {
	var stage = 1;
	try {
		var app = Application('com.apple.shortcuts.events');
		checkpoint(1);
		var catalogue = app.shortcuts();
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
			var identifier = shortcut.id(),
				name = shortcut.name(),
				acceptsInput = shortcut.acceptsInput();
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
		var after = app.shortcuts();
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
