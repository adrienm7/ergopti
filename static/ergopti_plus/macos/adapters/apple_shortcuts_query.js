// adapters/apple_shortcuts_query.js
// Structured read-only ScriptingBridge role. Never fetch app.shortcuts() as an
// entire native catalogue; request count and at most 64 individual specifiers.
ObjC.import('Foundation');
ObjC.import('ScriptingBridge');

function run(argv) {
	var operation = argv[0],
		nonce = Number(argv[1]);
	function refuse(reason) {
		return JSON.stringify({
			version: 1,
			operation: operation,
			nonce: nonce,
			status: 'refused',
			reason: reason
		});
	}
	function id(value) {
		return (
			typeof value === 'string' &&
			/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
		);
	}
	function row(shortcut) {
		var identifier = ObjC.unwrap(shortcut.id),
			name = ObjC.unwrap(shortcut.name),
			accepts = ObjC.unwrap(shortcut.acceptsInput);
		if (
			!id(identifier) ||
			typeof name !== 'string' ||
			name.indexOf('\u0000') !== -1 ||
			typeof accepts !== 'boolean'
		)
			throw new Error('invalid_row');
		var data = $.NSString.stringWithString(name).dataUsingEncoding($.NSUTF8StringEncoding);
		if (!data || data.length > 4096) throw new Error('invalid_row');
		return { id: identifier, name: name, accepts_input: accepts };
	}
	if (
		!Number.isSafeInteger(nonce) ||
		nonce < 1 ||
		String(nonce) !== argv[1] ||
		(operation !== 'discover' && operation !== 'revalidate') ||
		argv.length !== (operation === 'discover' ? 2 : 3) ||
		(operation === 'revalidate' && !id(argv[2]))
	)
		return refuse('native_refused');
	try {
		var app = $.SBApplication.applicationWithBundleIdentifier('com.apple.shortcuts.events');
		if (!app) return refuse('native_refused');
		function checked() {
			// ScriptingBridge can return an empty value and record NSError instead
			// of throwing. Empty inventory is never a permission-refusal fallback.
			var nativeError = app.lastError;
			if (nativeError) {
				var failure = new Error('native_refused');
				if (Number(nativeError.code) === -1743) failure.errorNumber = -1743;
				throw failure;
			}
		}
		var catalogue = app.shortcuts,
			rows = [],
			seen = Object.create(null),
			truncated = false;
		checked();
		if (operation === 'discover') {
			var count = Number(catalogue.count);
			checked();
			if (!Number.isSafeInteger(count) || count < 0) return refuse('native_refused');
			if (count > 256) return refuse('catalogue_limit');
			for (var index = 0; index < Math.min(count, 64); index++) {
				var value = row(catalogue.objectAtIndex(index));
				checked();
				if (seen[value.id]) return refuse('native_refused');
				seen[value.id] = true;
				rows.push(value);
			}
			var afterCount = Number(app.shortcuts.count);
			checked();
			if (afterCount !== count) return refuse('native_refused');
			truncated = count > 64;
		} else {
			var chosen = row(catalogue.objectWithID(argv[2]));
			checked();
			if (chosen.id !== argv[2]) return refuse('missing');
			var after = row(app.shortcuts.objectWithID(argv[2]));
			checked();
			if (JSON.stringify(chosen) !== JSON.stringify(after)) return refuse('native_refused');
			rows.push(chosen);
		}
		var packet = JSON.stringify({
			version: 1,
			operation: operation,
			nonce: nonce,
			status: 'observed',
			rows: rows,
			truncated: truncated
		});
		if (
			$.NSString.stringWithString(packet).dataUsingEncoding($.NSUTF8StringEncoding).length > 65536
		)
			return refuse('native_refused');
		return packet;
	} catch (error) {
		return refuse(
			error && error.errorNumber === -1743 ? 'automation_permission_refused' : 'native_refused'
		);
	}
}
