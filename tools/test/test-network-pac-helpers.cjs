// Independent standard PAC vectors; expected results are handwritten.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(
	path.join(__dirname, '../../static/ergopti_plus/_shared/modules/network/pac_helpers.js'),
	'utf8'
);
const clock = Date.parse('2026-01-02T23:30:15Z');
class ControlledDate extends Date {
	constructor(...args) {
		super(...(args.length ? args : [clock]));
		this.frozen = args.length === 0;
	}
	// UTC is Friday January 2; the independent local clock is Saturday January 3.
	getFullYear() {
		return this.frozen ? 2026 : super.getFullYear();
	}
	getMonth() {
		return this.frozen ? 0 : super.getMonth();
	}
	getDate() {
		return this.frozen ? 3 : super.getDate();
	}
	getDay() {
		return this.frozen ? 6 : super.getDay();
	}
	getHours() {
		return this.frozen ? 1 : super.getHours();
	}
	getMinutes() {
		return this.frozen ? 30 : super.getMinutes();
	}
	getSeconds() {
		return this.frozen ? 15 : super.getSeconds();
	}
}
const nativeCalls = [];
const context = vm.createContext({
	Date: ControlledDate,
	__ergoptiDns(host, extended) {
		nativeCalls.push(['dns', host, extended]);
		return host === 'owned.invalid' ? (extended ? '192.0.2.9;2001:db8::9' : '192.0.2.9') : null;
	},
	__ergoptiLocalAddresses(extended) {
		nativeCalls.push(['local', extended]);
		return extended ? '192.0.2.8;2001:db8::8' : '192.0.2.8';
	},
	__ergoptiSortAddresses(addresses) {
		nativeCalls.push(['sort', addresses]);
		return addresses === '2001:db8::9;192.0.2.9' ? '192.0.2.9;2001:db8::9' : null;
	}
});
vm.runInContext(source, context, { timeout: 1000 });
const vectors = [
	['dnsDomainIs("www.example.test", ".example.test")', true],
	['dnsDomainIs("www.example.test", ".ample.test")', false],
	['dnsDomainLevels("www.example.test")', 2],
	['dnsDomainLevels("printer")', 0],
	['isPlainHostName("printer")', true],
	['isPlainHostName("printer.example.test")', false],
	['localHostOrDomainIs("printer", "printer.example.test")', true],
	['localHostOrDomainIs("print", "printer.example.test")', false],
	['localHostOrDomainIs("printer.other.test", "printer.example.test")', false],
	['localHostOrDomainIs("printer.example.test", "printer.example.test")', true],
	['shExpMatch("https://owned.invalid/a?b=1", "https://*.invalid/a?b=*")', true],
	['shExpMatch("a+b", "a+b")', true],
	['shExpMatch("ab", "a+b")', false],
	['shExpMatch("[a]", "[a]")', true],
	['shExpMatch("a", "[a]")', false],
	['shExpMatch("a\\\\b", "a\\\\b")', true],
	['dnsResolve("owned.invalid")', '192.0.2.9'],
	['dnsResolveEx("owned.invalid")', '192.0.2.9;2001:db8::9'],
	['dnsResolve("missing.invalid")', null],
	['isResolvable("owned.invalid")', true],
	['isResolvable("missing.invalid")', false],
	['isResolvableEx("owned.invalid")', true],
	['myIpAddress()', '192.0.2.8'],
	['myIpAddressEx()', '192.0.2.8;2001:db8::8'],
	['sortIpAddressList("2001:db8::9;192.0.2.9")', '192.0.2.9;2001:db8::9'],
	['isInNet("192.0.2.9", "192.0.2.0", "255.255.255.0")', true],
	['isInNet("owned.invalid", "192.0.2.0", "255.255.255.0")', true],
	['isInNet("192.0.3.9", "192.0.2.0", "255.255.255.0")', false],
	['isInNet("missing.invalid", "192.0.2.0", "255.255.255.0")', false],
	['isInNet("256.0.2.9", "192.0.2.0", "255.255.255.0")', false],
	['isInNetEx("192.0.2.9", "192.0.2.0/24")', true],
	['isInNetEx("192.0.3.9", "192.0.2.0/24")', false],
	['isInNetEx("2001:db8::9", "2001:db8::/32")', true],
	['isInNetEx("2001:db9::9", "2001:db8::/32")', false],
	['isInNetEx("2001:db8::9", "2001:db8::8/127")', true],
	['isInNetEx("2001:db8::a", "2001:db8::8/127")', false],
	['isInNetEx("192.0.2.9;2001:db8::9", "2001:db8::/32")', true],
	['isInNetEx("::ffff:192.0.2.9", "::ffff:192.0.2.0/120")', true],
	['isInNetEx("::1", "::/0")', true],
	['isInNetEx("::1", "::1/128")', true],
	['isInNetEx("::2", "::1/128")', false],
	['isInNetEx("192.0.2.9", "::/0")', false],
	['isInNetEx("2001:::9", "::/0")', false],
	['isInNetEx("::1", "::/129")', false],
	['isInNetEx("192.0.2.9", "192.0.2.0/33")', false],
	['isInNetEx("::1", "::/-1")', false],
	['isInNetEx("::1", "::/01")', false],
	['weekdayRange("FRI", "GMT")', true],
	['weekdayRange("SAT", "GMT")', false],
	['weekdayRange("SAT")', true],
	['weekdayRange("FRI")', false],
	['weekdayRange("FRI", "MON")', true],
	['weekdayRange("SUN", "THU")', false],
	['weekdayRange("INVALID")', false],
	['timeRange(23, "GMT")', true],
	['timeRange(1)', true],
	['timeRange(22, 2, "GMT")', true],
	['timeRange(22, 2)', true],
	['timeRange(2, 22)', false],
	['timeRange(23, 30, 23, 30, "GMT")', true],
	['timeRange(23, 31, 1, 29, "GMT")', false],
	['timeRange(23, 30, 15, 23, 30, 15, "GMT")', true],
	['timeRange(23, 30, 16, 23, 30, 17, "GMT")', false],
	['timeRange(24)', false],
	['timeRange(1, 60, 2, 0)', false],
	['timeRange(1, 2, 3)', false],
	['dateRange(2, "GMT")', true],
	['dateRange(3)', true],
	['dateRange(2)', false],
	['dateRange("JAN")', true],
	['dateRange("DEC", "FEB")', true],
	['dateRange("FEB", "DEC")', false],
	['dateRange(2026)', true],
	['dateRange(2025, 2027)', true],
	['dateRange(2027, 2025)', false],
	['dateRange(29, 5)', true],
	['dateRange(4, 28)', false],
	['dateRange(31, "DEC", 4, "JAN")', true],
	['dateRange(4, "JAN", 31, "DEC")', false],
	['dateRange("DEC", 2025, "FEB", 2026)', true],
	['dateRange("DEC", 2026, "FEB", 2025)', false],
	['dateRange(31, "DEC", 2025, 4, "JAN", 2026)', true],
	['dateRange(3, "JAN", 2026, 3, "JAN", 2026)', true],
	['dateRange(3, "JAN", 2026, 3, "JAN", 2026, "GMT")', false],
	['dateRange(31, "FEB", 4, "MAR")', false],
	['dateRange("invalid")', false]
];
assert.ok(vectors.length >= 80, 'the independent corpus must have a meaningful floor');
for (const [expression, expected] of vectors) {
	assert.equal(vm.runInContext(expression, context, { timeout: 1000 }), expected, expression);
}
assert.deepEqual(nativeCalls.slice(0, 3), [
	['dns', 'owned.invalid', false],
	['dns', 'owned.invalid', true],
	['dns', 'missing.invalid', false]
]);
assert.equal(
	vm.runInContext('alert("private credentials")', context, { timeout: 1000 }),
	undefined
);
console.log(
	`PASS ${vectors.length} independent PAC helper vectors; DNS/interface bridges are controlled, not native acceptance.`
);
