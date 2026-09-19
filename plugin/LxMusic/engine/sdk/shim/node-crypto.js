// node:crypto / crypto replacement (pure JS) for the vendored musicSdk bundle.
// 覆盖面 = musicSdk 实际消费集（见 docs/js-helper-architecture.md §2.2/§5.3）：
//   createHash('md5'|'sha1')  ← musicSdk/utils.js toMD5、wy eapi、tx zzcSign
//   createCipheriv/createDecipheriv aes-128-cbc|ecb ← wy weapi/eapi/linuxapi、kw wbdCrypto
//   publicEncrypt(RSA_NO_PADDING) ← wy weapi（1024-bit，入参左补零到 128 字节）
//   randomBytes ← wy weapi secretKey
import aesjs from './vendor/aes-js.js'
import md5Lib from './vendor/js-md5.js'
import sha1Lib from './vendor/js-sha1.js'

export const constants = { RSA_NO_PADDING: 3, RSA_PKCS1_PADDING: 1 }

const hashLibs = { md5: md5Lib, sha1: sha1Lib }

const toBytes = d => {
	if (d instanceof Uint8Array) return d
	if (typeof d === 'string') return new TextEncoder().encode(d)
	return new Uint8Array(d == null ? [] : d)
}

export function createHash(alg) {
	const lib = hashLibs[String(alg).toLowerCase().replace(/-/g, '')]
	if (!lib) throw new Error('node-crypto shim: hash not supported: ' + alg)
	const chunks = []
	return {
		update(data) {
			chunks.push(toBytes(data))
			return this
		},
		digest(enc) {
			const total = chunks.reduce((n, c) => n + c.length, 0)
			const all = new Uint8Array(total)
			let off = 0
			for (const c of chunks) { all.set(c, off); off += c.length }
			const hex = lib.hex(all.length ? all.buffer : new ArrayBuffer(0))
			if (enc === 'hex' || enc == null) return enc == null ? globalThis.Buffer.from(hex, 'hex') : hex
			if (enc === 'base64') {
				return globalThis.Buffer.from(hex, 'hex').toString('base64')
			}
			throw new Error('node-crypto shim: digest encoding not supported: ' + enc)
		},
	}
}

const parseMode = mode => {
	const m = /^aes-(128|192|256)-(cbc|ecb)$/i.exec(String(mode))
	if (!m) throw new Error('node-crypto shim: cipher mode not supported: ' + mode)
	return { bits: Number(m[1]), op: m[2].toLowerCase() }
}

const pkcs7Pad = bytes => {
	const padLen = 16 - (bytes.length % 16)
	const out = new Uint8Array(bytes.length + padLen)
	out.set(bytes)
	out.fill(padLen, bytes.length)
	return out
}

const pkcs7Unpad = bytes => {
	if (bytes.length === 0 || bytes.length % 16 !== 0) throw new Error('node-crypto shim: bad ciphertext length')
	const n = bytes[bytes.length - 1]
	if (n < 1 || n > 16) throw new Error('node-crypto shim: bad padding')
	for (let i = bytes.length - n; i < bytes.length; i++) {
		if (bytes[i] !== n) throw new Error('node-crypto shim: bad padding bytes')
	}
	return bytes.subarray(0, bytes.length - n)
}

const makeCipher = (mode, key, iv, encrypt) => {
	const { bits, op } = parseMode(mode)
	const keyBytes = toBytes(key)
	if (keyBytes.length !== bits / 8) throw new Error(`node-crypto shim: invalid key length ${keyBytes.length} for ${mode}`)
	const Ctor = op === 'ecb' ? aesjs.ModeOfOperation.ecb : aesjs.ModeOfOperation.cbc
	const cipher = op === 'ecb' ? new Ctor(keyBytes) : new Ctor(keyBytes, toBytes(iv))
	const chunks = []
	let done = false
	const process = () => {
		if (done) return
		done = true
		const total = chunks.reduce((n, c) => n + c.length, 0)
		const all = new Uint8Array(total)
		let off = 0
		for (const c of chunks) { all.set(c, off); off += c.length }
		let out
		if (encrypt) {
			out = op === 'ecb' ? cipher.encrypt(pkcs7Pad(all)) : cipher.encrypt(pkcs7Pad(all))
		} else {
			const dec = cipher.decrypt(all)
			out = pkcs7Unpad(dec)
		}
		return new globalThis.Buffer(out)
	}
	return {
		update(data) {
			chunks.push(toBytes(data))
			return new globalThis.Buffer(0)
		},
		final() {
			return process()
		},
	}
}

export function createCipheriv(mode, key, iv) {
	return makeCipher(mode, key, iv, true)
}

export function createDecipheriv(mode, key, iv) {
	return makeCipher(mode, key, iv, false)
}

// ---- RSA（仅 RSA_NO_PADDING，1024-bit） ----
const b64Decode = s => {
	const clean = String(s).replace(/[^A-Za-z0-9+/=]/g, '')
	const out = []
	for (let i = 0; i < clean.length; i += 4) {
		const CH = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
		const e = [CH.indexOf(clean[i]), CH.indexOf(clean[i + 1]), CH.indexOf(clean[i + 2]), CH.indexOf(clean[i + 3])]
		out.push((e[0] << 2) | (e[1] >> 4))
		if (clean[i + 2] !== '=' && e[2] >= 0) out.push(((e[1] & 15) << 4) | (e[2] >> 2))
		if (clean[i + 3] !== '=' && e[3] >= 0) out.push(((e[2] & 3) << 6) | e[3])
	}
	return new Uint8Array(out)
}

const readTlv = (der, pos) => {
	const tag = der[pos]
	let len = der[pos + 1]
	let hdr = 2
	if (len & 0x80) {
		const n = len & 0x7f
		len = 0
		for (let i = 0; i < n; i++) len = len * 256 + der[pos + 2 + i]
		hdr = 2 + n
	}
	return { tag, start: pos + hdr, end: pos + hdr + len, next: pos + hdr + len }
}

const parseSpki = pem => {
	const b64 = String(pem).replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
	const der = b64Decode(b64)
	const seq = readTlv(der, 0) // SEQUENCE
	let p = seq.start
	const algId = readTlv(der, p) // SEQUENCE AlgorithmIdentifier — skip
	p = algId.next
	const bitstr = readTlv(der, p) // BIT STRING
	const inner = der[bitstr.start] === 0 ? bitstr.start + 1 : bitstr.start // skip unused-bits byte
	const keySeq = readTlv(der, inner) // SEQUENCE
	let q = keySeq.start
	const intN = readTlv(der, q)
	let nBytes = der.subarray(intN.start, intN.end)
	if (nBytes[0] === 0) nBytes = nBytes.subarray(1)
	const intE = readTlv(der, intN.next)
	let eBytes = der.subarray(intE.start, intE.end)
	if (eBytes[0] === 0) eBytes = eBytes.subarray(1)
	const bytesToBig = arr => {
		let v = 0n
		for (const b of arr) v = (v << 8n) | BigInt(b)
		return v
	}
	return { n: bytesToBig(nBytes), e: bytesToBig(eBytes), size: nBytes.length }
}

const modPow = (base, exp, mod) => {
	let result = 1n
	let b = base % mod
	let e = exp
	while (e > 0n) {
		if (e & 1n) result = (result * b) % mod
		b = (b * b) % mod
		e >>= 1n
	}
	return result
}

export function publicEncrypt({ key, padding }, buf) {
	if (padding !== constants.RSA_NO_PADDING) throw new Error('node-crypto shim: only RSA_NO_PADDING is supported')
	const { n, e, size } = parseSpki(key)
	const m = toBytes(buf)
	if (m.length > size) throw new Error('node-crypto shim: message too long')
	let v = 0n
	for (const b of m) v = (v << 8n) | BigInt(b)
	const c = modPow(v, e, n)
	const out = new Uint8Array(size)
	let tmp = c
	for (let i = size - 1; i >= 0; i--) {
		out[i] = Number(tmp & 0xffn)
		tmp >>= 8n
	}
	return new globalThis.Buffer(out)
}

export function randomBytes(n) {
	const u = new Uint8Array(Number(n) || 0)
	for (let i = 0; i < u.length; i++) u[i] = (Math.random() * 256) | 0
	return new globalThis.Buffer(u)
}

export default { constants, createHash, createCipheriv, createDecipheriv, publicEncrypt, randomBytes }
