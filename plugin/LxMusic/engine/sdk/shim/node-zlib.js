// node:zlib replacement (pure JS, pako) — callback form used by musicSdk (kw/util.js inflate).
import pako from './vendor/pako.min.js'

const toU8 = d => (d instanceof Uint8Array ? d : new Uint8Array(d == null ? [] : d))

const wrapCb = fn => (data, opts, cb) => {
	if (typeof opts === 'function') { cb = opts; opts = undefined }
	try {
		const out = fn(toU8(data), opts)
		if (typeof cb === 'function') cb(null, new globalThis.Buffer(out))
		return new globalThis.Buffer(out)
	} catch (e) {
		if (typeof cb === 'function') cb(e instanceof Error ? e : new Error(String(e)))
		else throw e
	}
}

export const inflate = wrapCb((d, o) => pako.inflate(d, o))
export const inflateRaw = wrapCb((d, o) => pako.inflateRaw(d, o))
export const unzip = wrapCb((d, o) => pako.unzip(d, o))
export const gunzip = wrapCb((d, o) => pako.ungzip(d, o))
export const deflate = wrapCb((d, o) => pako.deflate(d, o))
export const deflateRaw = wrapCb((d, o) => pako.deflateRaw(d, o))
export const gzip = wrapCb((d, o) => pako.gzip(d, o))

export const constants = {
	Z_NO_FLUSH: 0, Z_SYNC_FLUSH: 2, Z_FULL_FLUSH: 3, Z_FINISH: 4,
	Z_OK: 0, Z_STREAM_END: 1, Z_DEFAULT_COMPRESSION: -1, Z_NO_COMPRESSION: 0,
	Z_BEST_SPEED: 1, Z_BEST_COMPRESSION: 9, Z_DEFAULT_STRATEGY: 0,
	Z_FILTERED: 1, Z_HUFFMAN_ONLY: 2, Z_RLE: 3, Z_FIXED: 4,
	Z_MIN_WINDOW_BITS: 8, Z_MAX_WINDOW_BITS: 15, Z_DEFAULT_WINDOWBITS: 15,
	Z_MIN_MEM_LEVEL: 1, Z_MAX_MEM_LEVEL: 9, Z_DEFAULT_MEMLEVEL: 8,
}

export default { inflate, inflateRaw, unzip, gunzip, deflate, deflateRaw, gzip, constants }
