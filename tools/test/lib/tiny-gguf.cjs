// tools/test/lib/tiny-gguf.cjs

/**
 * ==============================================================================
 * MODULE: Tiny GGUF Model
 * DESCRIPTION:
 * Writes a real, loadable GGUF v3 "llama" model of a few kilobytes: one layer, an
 * eight-wide embedding, a byte-level vocabulary and fixed pseudo-random weights.
 *
 * FEATURES & RATIONALE:
 * 1. It is generated, so the test downloads no model: the real daemon's whole path
 *    (manifest, layer, digest check, runner, inference) runs on bytes this file
 *    made. Its answers are noise; that they arrive is the point.
 * 2. The weights come from a hash stream of a fixed seed, so the same bytes and
 *    the same digest come out on every machine.
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');

const GGUF_VERSION = 3;
const ALIGNMENT = 32;
const TYPE = Object.freeze({ UINT32: 4, INT32: 5, FLOAT32: 6, STRING: 8, ARRAY: 9 });
const GGML_F32 = 0;
const TOKEN_NORMAL = 1;
const TOKEN_UNKNOWN = 2;
const TOKEN_CONTROL = 3;
const TOKEN_BYTE = 6;
const EMBEDDING = 8;
const HEADS = 2;
const FEED_FORWARD = 16;
const CONTEXT = 64;

const u32 = (value) => {
	const bytes = Buffer.alloc(4);
	bytes.writeUInt32LE(value);
	return bytes;
};
const u64 = (value) => {
	const bytes = Buffer.alloc(8);
	bytes.writeBigUInt64LE(BigInt(value));
	return bytes;
};
const i32 = (value) => {
	const bytes = Buffer.alloc(4);
	bytes.writeInt32LE(value);
	return bytes;
};
const f32 = (value) => {
	const bytes = Buffer.alloc(4);
	bytes.writeFloatLE(value);
	return bytes;
};
const text = (value) => {
	const bytes = Buffer.from(value, 'utf8');
	return Buffer.concat([u64(bytes.length), bytes]);
};

/** One metadata entry: key, type tag, value bytes. */
const entry = (key, type, value) => Buffer.concat([text(key), u32(type), value]);
const uintEntry = (key, value) => entry(key, TYPE.UINT32, u32(value));
const stringEntry = (key, value) => entry(key, TYPE.STRING, text(value));
const floatEntry = (key, value) => entry(key, TYPE.FLOAT32, f32(value));
const arrayEntry = (key, itemType, items) =>
	entry(key, TYPE.ARRAY, Buffer.concat([u32(itemType), u64(items.length), ...items]));

/** Pads a length to the file alignment. */
const aligned = (length) => Math.ceil(length / ALIGNMENT) * ALIGNMENT;

/** A fixed stream of floats in [-0.5, 0.5). */
function weights(name, count) {
	const values = Buffer.alloc(count * 4);
	for (let index = 0; index < count; index++) {
		const digest = crypto.createHash('sha256').update(`${name}:${index}`).digest();
		values.writeFloatLE(digest.readUInt16LE(0) / 65536 - 0.5, index * 4);
	}
	return values;
}

/** A tensor of ones, what a fresh layer norm holds. */
function ones(count) {
	const values = Buffer.alloc(count * 4);
	for (let index = 0; index < count; index++) values.writeFloatLE(1, index * 4);
	return values;
}

/**
 * Builds the model.
 * @param {string} [name] Its name: another name is another digest, so another blob
 *     the daemon has not stored yet.
 * @returns {Buffer} The GGUF file.
 */
function buildTinyGguf(name = 'ergopti-tiny') {
	const tokens = ['<unk>', '<s>', '</s>'];
	const types = [TOKEN_UNKNOWN, TOKEN_CONTROL, TOKEN_CONTROL];
	for (let byte = 0; byte < 256; byte++) {
		tokens.push(`<0x${byte.toString(16).toUpperCase().padStart(2, '0')}>`);
		types.push(TOKEN_BYTE);
	}
	for (const word of ['▁the', '▁a', '▁ok']) {
		tokens.push(word);
		types.push(TOKEN_NORMAL);
	}
	const vocabulary = tokens.length;
	const metadata = [
		stringEntry('general.architecture', 'llama'),
		stringEntry('general.name', name),
		uintEntry('llama.context_length', CONTEXT),
		uintEntry('llama.embedding_length', EMBEDDING),
		uintEntry('llama.block_count', 1),
		uintEntry('llama.feed_forward_length', FEED_FORWARD),
		uintEntry('llama.attention.head_count', HEADS),
		uintEntry('llama.rope.dimension_count', EMBEDDING / HEADS),
		uintEntry('llama.vocab_size', vocabulary),
		floatEntry('llama.attention.layer_norm_rms_epsilon', 1e-5),
		stringEntry('tokenizer.ggml.model', 'llama'),
		arrayEntry('tokenizer.ggml.tokens', TYPE.STRING, tokens.map(text)),
		arrayEntry(
			'tokenizer.ggml.scores',
			TYPE.FLOAT32,
			tokens.map(() => f32(0))
		),
		arrayEntry('tokenizer.ggml.token_type', TYPE.INT32, types.map(i32)),
		uintEntry('tokenizer.ggml.bos_token_id', 1),
		uintEntry('tokenizer.ggml.eos_token_id', 2),
		uintEntry('tokenizer.ggml.unknown_token_id', 0)
	];

	const tensors = [
		['token_embd.weight', [EMBEDDING, vocabulary]],
		['blk.0.attn_norm.weight', [EMBEDDING], 'ones'],
		['blk.0.attn_q.weight', [EMBEDDING, EMBEDDING]],
		['blk.0.attn_k.weight', [EMBEDDING, EMBEDDING]],
		['blk.0.attn_v.weight', [EMBEDDING, EMBEDDING]],
		['blk.0.attn_output.weight', [EMBEDDING, EMBEDDING]],
		['blk.0.ffn_norm.weight', [EMBEDDING], 'ones'],
		['blk.0.ffn_gate.weight', [EMBEDDING, FEED_FORWARD]],
		['blk.0.ffn_down.weight', [FEED_FORWARD, EMBEDDING]],
		['blk.0.ffn_up.weight', [EMBEDDING, FEED_FORWARD]],
		['output_norm.weight', [EMBEDDING], 'ones'],
		['output.weight', [EMBEDDING, vocabulary]]
	];
	const infos = [];
	const payloads = [];
	let offset = 0;
	for (const [name, dimensions, fill] of tensors) {
		const count = dimensions.reduce((left, right) => left * right, 1);
		infos.push(
			Buffer.concat([
				text(name),
				u32(dimensions.length),
				...dimensions.map(u64),
				u32(GGML_F32),
				u64(offset)
			])
		);
		const data = fill === 'ones' ? ones(count) : weights(name, count);
		const padded = Buffer.alloc(aligned(data.length));
		data.copy(padded);
		payloads.push(padded);
		offset += padded.length;
	}

	const header = Buffer.concat([
		Buffer.from('GGUF', 'latin1'),
		u32(GGUF_VERSION),
		u64(tensors.length),
		u64(metadata.length),
		...metadata,
		...infos
	]);
	return Buffer.concat([header, Buffer.alloc(aligned(header.length) - header.length), ...payloads]);
}

module.exports = { buildTinyGguf };
