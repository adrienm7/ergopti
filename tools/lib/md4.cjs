// tools/lib/md4.cjs

'use strict';

// MD4 is required for the zsync and NTLM wire formats; it is not a security hash.
function md4(message) {
	const rotate = (value, bits) => ((value << bits) | (value >>> (32 - bits))) >>> 0;
	const padded = Buffer.alloc(((message.length + 8) >>> 6) * 64 + 64);
	message.copy(padded);
	padded[message.length] = 0x80;
	padded.writeUInt32LE((message.length * 8) >>> 0, padded.length - 8);
	padded.writeUInt32LE(Math.floor((message.length * 8) / 2 ** 32), padded.length - 4);
	let [a, b, c, d] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476];
	for (let offset = 0; offset < padded.length; offset += 64) {
		const word = (index) => padded.readUInt32LE(offset + index * 4);
		const [startA, startB, startC, startD] = [a, b, c, d];
		const step = (mix, extra, index, bits) => {
			const next = rotate((a + mix(b, c, d) + word(index) + extra) >>> 0, bits);
			[a, b, c, d] = [d, next, b, c];
		};
		const round1 = (x, y, z) => (x & y) | (~x & z);
		const round2 = (x, y, z) => (x & y) | (x & z) | (y & z);
		const round3 = (x, y, z) => x ^ y ^ z;
		for (let i = 0; i < 16; i++) step(round1, 0, i, [3, 7, 11, 19][i % 4]);
		for (let i = 0; i < 16; i++)
			step(round2, 0x5a827999, (i % 4) * 4 + (i >> 2), [3, 5, 9, 13][i % 4]);
		const third = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15];
		for (let i = 0; i < 16; i++) step(round3, 0x6ed9eba1, third[i], [3, 9, 11, 15][i % 4]);
		a = (a + startA) >>> 0;
		b = (b + startB) >>> 0;
		c = (c + startC) >>> 0;
		d = (d + startD) >>> 0;
	}
	const digest = Buffer.alloc(16);
	[a, b, c, d].forEach((value, index) => digest.writeUInt32LE(value, index * 4));
	return digest;
}

module.exports = { md4 };
