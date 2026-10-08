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
// The native import owns the C signature: no fabricated AEDesc layout or ABI cast.
// This asks about the same osascript principal, never starts the target or prompts.
function permissionPreflight() {
	checkpoint('P:BEGIN');
	try {
		ObjC.import('CoreServices');
		var eventClass = $.kAECoreSuite,
			eventID = $.kAEGetData,
			targetType = $.typeApplicationBundleID;
		// Fixed failure-only annotations identify the original unavailable guard;
		// they never change bridge admission or disclose exception/native values.
		if (typeof $.AEDeterminePermissionToAutomateTarget !== 'function') {
			checkpoint('B:API');
			checkpoint('P:UNAVAILABLE');
			return;
		}
		if (
			!$.NSAppleEventDescriptor ||
			typeof $.NSAppleEventDescriptor.descriptorWithBundleIdentifier !== 'function'
		) {
			checkpoint('B:METADATA');
			checkpoint('P:UNAVAILABLE');
			return;
		}
		if (
			[eventClass, eventID, targetType].some(function (value) {
				return (
					typeof value !== 'number' ||
					!isFinite(value) ||
					Math.floor(value) !== value ||
					value < 0 ||
					value > 4294967295
				);
			})
		) {
			checkpoint('B:CONSTANTS');
			checkpoint('P:UNAVAILABLE');
			return;
		}
		var descriptor = $.NSAppleEventDescriptor.descriptorWithBundleIdentifier(
			'com.apple.shortcuts.events'
		);
		if (!descriptor || descriptor.descriptorType !== targetType) {
			checkpoint('B:DESCRIPTOR');
			checkpoint('P:UNAVAILABLE');
			return;
		}
		// aeDesc is the SDK's NS_RETURNS_INNER_POINTER. Keep its native owner live
		// through the call and the post-call read; never copy or reinterpret it.
		var pointer = descriptor.aeDesc;
		if (!pointer) {
			checkpoint('B:POINTER');
			checkpoint('P:UNAVAILABLE');
			return;
		}
		checkpoint('P:CALL_ATTEMPT');
		var code = $.AEDeterminePermissionToAutomateTarget(pointer, eventClass, eventID, false);
		if (
			descriptor.descriptorType !== targetType ||
			typeof code !== 'number' ||
			!isFinite(code) ||
			Math.floor(code) !== code ||
			code < -2147483648 ||
			code > 2147483647
		) {
			checkpoint('P:INVALID');
			return;
		}
		checkpoint('P:RETURN:' + code);
	} catch (error) {
		// No exception detail, permission inference or fallback leaves this boundary.
		checkpoint('P:REFUSED');
	}
}
function run(args) {
	var stage = 1;
	try {
		var app = Application('com.apple.shortcuts.events');
		checkpoint(1);
		if (Array.isArray(args) && args.length === 1 && args[0] === '--permission-preflight')
			permissionPreflight();
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
