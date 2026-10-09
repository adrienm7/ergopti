// _shared/modules/network/pac_helpers.js
// Shared standard PAC helpers. Native bridges own DNS and interface discovery.
// This ES5 source is embedded by the native worker builder without modification.
(function (root) {
	'use strict';
	var days = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];
	var months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
	function integer(value, minimum, maximum) {
		return (
			typeof value === 'number' &&
			isFinite(value) &&
			Math.floor(value) === value &&
			value >= minimum &&
			value <= maximum
		);
	}
	function cyclic(value, first, last) {
		return first <= last ? value >= first && value <= last : value >= first || value <= last;
	}
	function calendar(args) {
		var values = Array.prototype.slice.call(args);
		var utc = values.length > 0 && values[values.length - 1] === 'GMT';
		if (utc) values.pop();
		var now = new Date();
		return {
			values: values,
			year: utc ? now.getUTCFullYear() : now.getFullYear(),
			month: utc ? now.getUTCMonth() : now.getMonth(),
			day: utc ? now.getUTCDate() : now.getDate(),
			weekday: utc ? now.getUTCDay() : now.getDay(),
			hour: utc ? now.getUTCHours() : now.getHours(),
			minute: utc ? now.getUTCMinutes() : now.getMinutes(),
			second: utc ? now.getUTCSeconds() : now.getSeconds()
		};
	}
	function ipv4(value) {
		if (
			typeof value !== 'string' ||
			!/^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$/.test(value)
		)
			return null;
		var bytes = value.split('.');
		for (var i = 0; i < bytes.length; i++) {
			bytes[i] = Number(bytes[i]);
			if (bytes[i] > 255) return null;
		}
		return bytes;
	}
	function ip(value) {
		var v4 = ipv4(value);
		if (v4) return v4;
		if (typeof value !== 'string' || value.indexOf(':') < 0 || !/^[0-9a-fA-F:.]+$/.test(value))
			return null;
		if (value.indexOf('.') >= 0) {
			var tail = value.substring(value.lastIndexOf(':') + 1);
			var embedded = ipv4(tail);
			if (!embedded) return null;
			value =
				value.substring(0, value.lastIndexOf(':') + 1) +
				(embedded[0] * 256 + embedded[1]).toString(16) +
				':' +
				(embedded[2] * 256 + embedded[3]).toString(16);
		}
		var compressed = value.split('::');
		if (compressed.length > 2) return null;
		var left = compressed[0] ? compressed[0].split(':') : [];
		var right = compressed.length === 2 && compressed[1] ? compressed[1].split(':') : [];
		if (
			(compressed.length === 1 && left.length !== 8) ||
			(compressed.length === 2 && left.length + right.length >= 8)
		)
			return null;
		var words = left.slice();
		if (compressed.length === 2) while (words.length + right.length < 8) words.push('0');
		words = words.concat(right);
		var result = [];
		for (var w = 0; w < words.length; w++) {
			if (!/^[0-9a-fA-F]{1,4}$/.test(words[w])) return null;
			var word = parseInt(words[w], 16);
			result.push(word >> 8, word & 255);
		}
		return result;
	}
	root.dnsDomainIs = function (host, domain) {
		return (
			typeof host === 'string' &&
			typeof domain === 'string' &&
			host.length >= domain.length &&
			host.substring(host.length - domain.length) === domain
		);
	};
	root.dnsDomainLevels = function (host) {
		return host.split('.').length - 1;
	};
	root.isPlainHostName = function (host) {
		return host.indexOf('.') === -1;
	};
	root.localHostOrDomainIs = function (host, hostdom) {
		return (
			host === hostdom ||
			(root.isPlainHostName(host) && hostdom.substring(0, host.length + 1) === host + '.')
		);
	};
	root.shExpMatch = function (value, pattern) {
		var escaped = pattern
			.replace(/[\\^$+.()|\[\]{}]/g, '\\$&')
			.replace(/\*/g, '.*')
			.replace(/\?/g, '.');
		return new RegExp('^' + escaped + '$').test(value);
	};
	root.dnsResolve = function (host) {
		return root.__ergoptiDns(host, false);
	};
	root.dnsResolveEx = function (host) {
		return root.__ergoptiDns(host, true);
	};
	root.myIpAddress = function () {
		return root.__ergoptiLocalAddresses(false);
	};
	root.myIpAddressEx = function () {
		return root.__ergoptiLocalAddresses(true);
	};
	root.sortIpAddressList = function (addresses) {
		return root.__ergoptiSortAddresses(addresses);
	};
	root.isResolvable = function (host) {
		return root.dnsResolve(host) !== null;
	};
	root.isResolvableEx = function (host) {
		return root.dnsResolveEx(host) !== null;
	};
	root.isInNet = function (host, pattern, mask) {
		var address = ipv4(host) || ipv4(root.dnsResolve(host));
		var network = ipv4(pattern),
			bits = ipv4(mask);
		if (!address || !network || !bits) return false;
		for (var i = 0; i < 4; i++) if ((address[i] & bits[i]) !== (network[i] & bits[i])) return false;
		return true;
	};
	root.isInNetEx = function (address, prefix) {
		if (typeof prefix !== 'string') return false;
		var parts = prefix.split('/');
		if (parts.length !== 2 || !/^(?:0|[1-9][0-9]*)$/.test(parts[1])) return false;
		var network = ip(parts[0]),
			bits = Number(parts[1]);
		if (!network || !integer(bits, 0, network.length * 8) || typeof address !== 'string')
			return false;
		var addresses = address.split(';');
		for (var a = 0; a < addresses.length; a++) {
			var candidate = ip(addresses[a]);
			if (!candidate || candidate.length !== network.length) continue;
			var remaining = bits,
				same = true;
			for (var b = 0; b < network.length && remaining > 0; b++) {
				var mask = remaining >= 8 ? 255 : (255 << (8 - remaining)) & 255;
				if ((candidate[b] & mask) !== (network[b] & mask)) {
					same = false;
					break;
				}
				remaining -= 8;
			}
			if (same) return true;
		}
		return false;
	};
	root.weekdayRange = function () {
		var now = calendar(arguments),
			args = now.values;
		if (args.length < 1 || args.length > 2) return false;
		var first = days.indexOf(args[0]),
			last = days.indexOf(args.length === 1 ? args[0] : args[1]);
		return first >= 0 && last >= 0 && cyclic(now.weekday, first, last);
	};
	root.timeRange = function () {
		var now = calendar(arguments),
			args = now.values;
		if (args.length !== 1 && args.length !== 2 && args.length !== 4 && args.length !== 6)
			return false;
		if (args.length <= 2) {
			if (!integer(args[0], 0, 23) || !integer(args[args.length - 1], 0, 23)) return false;
			return cyclic(now.hour, args[0], args[args.length - 1]);
		}
		var half = args.length / 2;
		for (var i = 0; i < args.length; i++)
			if (!integer(args[i], 0, i % half === 0 ? 23 : 59)) return false;
		var first = args[0] * 3600 + args[1] * 60 + (half === 3 ? args[2] : 0);
		var last = args[half] * 3600 + args[half + 1] * 60 + (half === 3 ? args[5] : 59);
		return cyclic(now.hour * 3600 + now.minute * 60 + now.second, first, last);
	};
	root.dateRange = function () {
		var now = calendar(arguments),
			args = now.values;
		if (args.length === 1 || args.length === 2) {
			var first = args[0],
				last = args[args.length - 1];
			if (typeof first === 'string' && typeof last === 'string') {
				first = months.indexOf(first);
				last = months.indexOf(last);
				return first >= 0 && last >= 0 && cyclic(now.month, first, last);
			}
			if (integer(first, 1, 31) && integer(last, 1, 31)) return cyclic(now.day, first, last);
			return (
				integer(first, 32, 2147483647) &&
				integer(last, 32, 2147483647) &&
				first <= now.year &&
				now.year <= last
			);
		}
		if (args.length !== 4 && args.length !== 6) return false;
		var half = args.length / 2;
		function endpoint(offset) {
			var day = 1,
				month,
				year = now.year;
			if (half === 2 && typeof args[offset] === 'string') {
				month = months.indexOf(args[offset]);
				year = args[offset + 1];
				if (month < 0 || !integer(year, 32, 2147483647)) return null;
				return year * 12 + month;
			}
			day = args[offset];
			month = months.indexOf(args[offset + 1]);
			if (half === 3) year = args[offset + 2];
			if (!integer(day, 1, 31) || month < 0 || !integer(year, 32, 2147483647)) return null;
			var check = new Date(0);
			check.setUTCFullYear(year, month, day);
			check.setUTCHours(0, 0, 0, 0);
			if (
				check.getUTCFullYear() !== year ||
				check.getUTCMonth() !== month ||
				check.getUTCDate() !== day
			)
				return null;
			return half === 3 ? year * 372 + month * 31 + day : month * 31 + day;
		}
		var first = endpoint(0),
			last = endpoint(half);
		if (first === null || last === null) return false;
		var value =
			half === 2 && typeof args[0] === 'string'
				? now.year * 12 + now.month
				: (half === 3 ? now.year * 372 : 0) + now.month * 31 + now.day;
		return half === 3 || typeof args[0] === 'string'
			? first <= value && value <= last
			: cyclic(value, first, last);
	};
	// PAC alert is deliberately silent: script text can contain credentials.
	root.alert = function () {};
})(this);
