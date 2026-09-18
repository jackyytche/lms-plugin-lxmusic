// lx-shim.mjs — 洛雪音乐插件 QuickJS 桥接层
// ============================================================
// 在 bellard quickjs (qjs, 含 std/os 模块) 中复刻 lx-music 自定义源
// 脚本沙箱 (globalThis.lx)，以「每 action 一个进程」模型运行：
//
//   qjs shim.mjs -- <source.js路径> <actionJSON> <infoJSON>
//   stdout: RESULT {"ok":true,"data":...} | RESULT {"ok":false,"error":"..."}
//           (调试信息走 LOG 行，宿主按前缀分流)
//
// HTTP：os.exec 同步调系统 curl（--max-time 兜底超时），响应体/响应头落
// 临时文件后由 std.readFile 读回。脚本经 lx.request 的 callback 收到结果，
// 其内部 Promise 由 qjs 顶层作业循环自动驱动。
// ============================================================

import * as std from 'std';
import * as os from 'os';

const TMP = '/tmp';
const HDR = TMP + '/lx-shim-hdr-' + Date.now() + '.txt';
const BODY = TMP + '/lx-shim-body-' + Date.now() + '.bin';
const REQ = TMP + '/lx-shim-req-' + Date.now() + '.bin';

function log(...a) { print('LOG ' + a.join(' ')); }

// ---------- lx 事件环境 ----------
const handlers = {};
const EVENT_NAMES = Object.freeze({
	request: 'request',
	inited: 'inited',
	updateAlert: 'updateAlert',
});

let initedPayload = null;
const alerts = [];

function on(name, handler) {
	if (typeof handler !== 'function') throw new TypeError('lx.on: handler must be function');
	handlers[name] = handler;
}

function send(name, data) {
	if (name === EVENT_NAMES.inited) {
		initedPayload = data || {};
	} else if (name === EVENT_NAMES.updateAlert) {
		alerts.push(data);
		print('ALERT ' + JSON.stringify(data == null ? {} : data));
	}
}

// ---------- HTTP（同步 curl） ----------
function httpSync(url, options) {
	options = options || {};
	const timeout = Math.min(Math.max(Number(options.timeout) || 15, 1), 60);
	const args = ['curl', '-sS', '-L', '--max-time', String(timeout), '-D', HDR, '-o', BODY];
	if (options.method) args.push('-X', String(options.method).toUpperCase());
	const headers = options.headers || {};
	for (const k of Object.keys(headers)) args.push('-H', k + ': ' + String(headers[k]));
	const method = (options.method || 'GET').toUpperCase();
	if (options.body != null && options.body !== '') {
		std.writeFile(REQ, String(options.body));
		args.push('--data-binary', '@' + REQ);
	} else if (options.form && method !== 'GET') {
		for (const k of Object.keys(options.form)) args.push('--data-urlencode', k + '=' + String(options.form[k]));
	}
	args.push(String(url));

	const t0 = Date.now();
	const status = os.exec(args, { block: true, fileErr: HDR + '.err' });
	const elapsed = Date.now() - t0;

	let body = '';
	try { body = std.readFile(BODY); } catch (e) { body = ''; }
	let rawHdr = '';
	try { rawHdr = std.readFile(HDR); } catch (e) { rawHdr = ''; }

	// 解析 status line（取最后一个，兼容重定向链）
	let code = 0;
	const lines = String(rawHdr).split(/\r?\n/);
	const headerObj = {};
	for (const ln of lines) {
		const m = ln.match(/^HTTP\/[\d.]+\s+(\d+)/);
		if (m) code = Number(m[1]);
		const kv = ln.match(/^([A-Za-z0-9-]+)\s*:\s*(.*)$/);
		if (kv) headerObj[kv[1].toLowerCase()] = kv[2].replace(/\s+\z/, '');
	}
	try { os.remove(HDR); } catch (e) {}
	try { os.remove(BODY); } catch (e) {}
	try { os.remove(REQ); } catch (e) {}
	try { os.remove(HDR + '.err'); } catch (e) {}

	if (typeof status === 'number' && (status & 0x7f) !== 0) {
		throw new Error('curl killed by signal ' + (status & 0x7f));
	}
	const exitCode = typeof status === 'number' ? (status >> 8) : 0;
	if (exitCode === 28) throw new Error('timeout after ' + timeout + 's');
	if (code === 0 && exitCode !== 0) throw new Error('curl exit ' + exitCode + ' (' + elapsed + 'ms)');

	log('http', options.method || 'GET', url, '->', code, '(' + elapsed + 'ms,' + String(body).length + 'B)');
	return { body, code, headers: headerObj };
}

// lx.request(url, options, callback, timeout) — callback(err, resp, status, headers)
function lxRequest(url, options, callback, timeout) {
	if (typeof options === 'function') { callback = options; options = {}; }
	if (typeof callback !== 'function') throw new TypeError('lx.request: callback required');
	options = options || {};
	if (timeout) options.timeout = timeout;
	try {
		const r = httpSync(url, options);
		callback(null, r.body, r.code, r.headers);
	} catch (e) {
		callback(String((e && e.message) || e));
	}
}

// ---------- utils（按需渐进补齐） ----------
function md5hex(str) { return md5Bytes(toUtf8(String(str)), 'hex'); }

// 紧凑 MD5（RFC 1321，纯 JS）
function md5Bytes(bytes, out) {
	const S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
		5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
		4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
		6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
	const K = new Int32Array(64);
	for (let i = 0; i < 64; i++) K[i] = (Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296)) | 0;
	let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
	const len = bytes.length;
	const withPad = new Uint8Array((((len + 8) >> 6) + 1) * 64);
	withPad.set(bytes);
	withPad[len] = 0x80;
	const bitLen = len * 8;
	const dv = new DataView(withPad.buffer);
	dv.setUint32(withPad.length - 8, bitLen >>> 0, true);
	dv.setUint32(withPad.length - 4, Math.floor(bitLen / 4294967296), true);
	const rl = (x, c) => ((x << c) | (x >>> (32 - c))) >>> 0;
	for (let off = 0; off < withPad.length; off += 64) {
		const M = new Int32Array(16);
		for (let i = 0; i < 16; i++) M[i] = dv.getInt32(off + i * 4, true);
		let A = a0, B = b0, C = c0, D = d0;
		for (let i = 0; i < 64; i++) {
			let F, g;
			if (i < 16) { F = (B & C) | (~B & D); g = i; }
			else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
			else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
			else { F = C ^ (B | ~D); g = (7 * i) % 16; }
			F = (F + A + K[i] + M[g]) | 0;
			A = D; D = C; C = B;
			B = (B + rl(F, S[i])) | 0;
		}
		a0 = (a0 + A) | 0; b0 = (b0 + B) | 0; c0 = (c0 + C) | 0; d0 = (d0 + D) | 0;
	}
	const out8 = new Uint8Array(16);
	new DataView(out8.buffer).setInt32(0, a0, true);
	new DataView(out8.buffer).setInt32(4, b0, true);
	new DataView(out8.buffer).setInt32(8, c0, true);
	new DataView(out8.buffer).setInt32(12, d0, true);
	return bytesToB64(out8, out);
}

function toUtf8(s) { return new TextEncoder().encode(s); }
function bytesToB64(u8, how) {
	let s = '';
	if (how === 'hex') { for (const b of u8) s += b.toString(16).padStart(2, '0'); return s; }
	// base64
	const CH = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
	for (let i = 0; i < u8.length; i += 3) {
		const b0 = u8[i], b1 = u8[i + 1], b2 = u8[i + 2];
		s += CH[b0 >> 2] + CH[((b0 & 3) << 4) | ((b1 || 0) >> 4)];
		s += isNaN(b1) ? '=' : CH[((b1 & 15) << 2) | ((b2 || 0) >> 6)];
		s += isNaN(b2) ? '=' : CH[b2 & 63];
	}
	return s;
}

function randomBytes(n) {
	const u = new Uint8Array(n);
	// quickjs 无 crypto 随机；Math.random 种子 + Date 混合足够签名用途
	for (let i = 0; i < n; i++) u[i] = (Math.random() * 256) | 0;
	return u;
}

// ---------- 全局 lx 对象 ----------
globalThis.lx = {
	EVENT_NAMES,
	on,
	send,
	request: lxRequest,
	utils: {
		crypto: {
			md5: (data, out) => (typeof data === 'string' ? md5hex(data) : md5Bytes(data, out)),
			aesEncrypt: (data, mode, key, iv) => { throw new Error('shim: aesEncrypt not implemented yet'); },
			rsaEncrypt: (data, key) => { throw new Error('shim: rsaEncrypt not implemented yet'); },
			randomBytes2: null,
			randomBytes,
		},
		buffer: {
			from: (data, enc) => (enc === 'base64' ? b64ToBytes(String(data)) : toUtf8(String(data))),
			bufToString: (buf, enc) => (enc === 'hex'
				? Array.from(buf).map(b => b.toString(16).padStart(2, '0')).join('')
				: new TextDecoder().decode(buf)),
		},
		zlib: {
			inflate: (buf) => { throw new Error('shim: zlib.inflate not implemented yet'); },
			deflate: (buf) => { throw new Error('shim: zlib.deflate not implemented yet'); },
		},
	},
	currentScriptInfo: null,
	version: '2.0.0',
	env: 'desktop',
};

function b64ToBytes(s) {
	const CH = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
	const clean = String(s).replace(/[^A-Za-z0-9+/=]/g, '');
	const out = [];
	for (let i = 0; i < clean.length; i += 4) {
		const e = [CH.indexOf(clean[i]), CH.indexOf(clean[i + 1]), CH.indexOf(clean[i + 2]), CH.indexOf(clean[i + 3])];
		out.push((e[0] << 2) | (e[1] >> 4));
		if (e[2] >= 0 && clean[i + 2] !== '=') out.push(((e[1] & 15) << 4) | (e[2] >> 2));
		if (e[3] >= 0 && clean[i + 3] !== '=') out.push(((e[2] & 3) << 6) | e[3]);
	}
	return new Uint8Array(out);
}

// ---------- 解析参数 ----------
// 兼容 scriptArgs 首元素为脚本名或直接为参数两种形态
const rawArgs = Array.from(scriptArgs || []);
let ai = 0;
if (rawArgs[0] && /\.mjs$/.test(rawArgs[0])) ai = 1;
const args = rawArgs.slice(ai);
if (args.length < 3) {
	print('RESULT ' + JSON.stringify({ ok: false, error: 'usage: qjs shim.mjs <source.js> <actionJson> <infoJson>' }));
	std.exit(1);
}
const [sourcePath, actionJson, infoJson] = args;

// ---------- 加载并运行源脚本 ----------
let sourceCode;
try {
	sourceCode = std.readFile(sourcePath);
} catch (e) {
	print('RESULT ' + JSON.stringify({ ok: false, error: 'cannot read source: ' + e }));
	std.exit(1);
}

// 解析脚本头注释元数据（@name/@version/@author/@homepage/@description）
const meta = {};
const metaRe = /@(\w+)\s+([^\r\n*]+)/g;
const head = String(sourceCode).slice(0, 2048);
let m;
while ((m = metaRe.exec(head))) meta[m[1]] = m[2].trim();

globalThis.lx.currentScriptInfo = {
	name: meta.name || '',
	version: meta.version || '',
	author: meta.author || '',
	homepage: meta.homepage || '',
	description: meta.description || '',
	filename: sourcePath,
	log: log,
};

try {
	// 全局 eval 执行源脚本（sloppy script）
	(0, eval)(sourceCode);
} catch (e) {
	print('RESULT ' + JSON.stringify({ ok: false, error: 'source load failed: ' + String((e && e.message) || e) }));
	std.exit(1);
}

if (typeof handlers[EVENT_NAMES.request] !== 'function') {
	print('RESULT ' + JSON.stringify({ ok: false, error: 'source did not register request handler' }));
	std.exit(1);
}

// ---------- 调用 action ----------
const action = actionJson;
const info = JSON.parse(infoJson);

const ret = handlers[EVENT_NAMES.request]({ source: info.source || '', action, info: info.info || info });
Promise.resolve(ret).then(r => {
	print('RESULT ' + JSON.stringify({ ok: true, data: r == null ? null : r }));
	std.out.flush();
	std.exit(0);
}).catch(e => {
	print('RESULT ' + JSON.stringify({ ok: false, error: String((e && e.message) || e) }));
	std.out.flush();
	std.exit(1);
});
