// lx-shim.mjs — 洛雪音乐插件 QuickJS 桥接层
// ============================================================
// 在 bellard quickjs (qjs, 含 std 模块) 中复刻 lx-music 自定义源
// 脚本沙箱 (globalThis.lx)，以「每 action 一个进程」模型运行：
//
//   qjs shim.mjs <source.js路径> <action> <infoJSON>
//   stdout: RESULT {"ok":true,"data":...} | RESULT {"ok":false,"error":"..."}
//           (调试信息走 LOG 行，宿主按前缀分流)
//
// HTTP：std.urlGet（qjs 内置 libcurl 客户端）+ shim 手动跟随 3xx（最多 3 跳，
// 对齐 lx 宿主 needle follow_max:3）。
// 注意：quickjs 无 TextEncoder/TextDecoder/URL，shim 手写等价物。
// 主体在 import('std') 成功后执行；任何顶层错误都以 RESULT 行输出（永不静默）。
// ============================================================

function fatal(msg) {
	print('RESULT ' + JSON.stringify({ ok: false, error: String(msg) }));
	std_exit(1);
}

function std_exit(code) {
	try {
		// std 模块注入后才可用；失败则靠进程自然退出
		if (globalThis.__lxStd) globalThis.__lxStd.exit(code);
	} catch (e) {}
	throw { __lxExit: code };
}

function toUtf8(s) {
	s = String(s);
	const out = [];
	for (let i = 0; i < s.length; i++) {
		let c = s.charCodeAt(i);
		if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
			c = 0x10000 + ((c - 0xd800) << 10) + (s.charCodeAt(++i) - 0xdc00);
		}
		if (c < 0x80) out.push(c);
		else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
		else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
		else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
	}
	return new Uint8Array(out);
}

function utf8Decode(u8) {
	u8 = u8 instanceof Uint8Array ? u8 : new Uint8Array(u8 || []);
	let s = '';
	for (let i = 0; i < u8.length;) {
		const b = u8[i];
		let cp;
		if (b < 0x80) { cp = b; i += 1; }
		else if (b < 0xe0) { cp = ((b & 31) << 6) | (u8[i + 1] & 63); i += 2; }
		else if (b < 0xf0) { cp = ((b & 15) << 12) | ((u8[i + 1] & 63) << 6) | (u8[i + 2] & 63); i += 3; }
		else { cp = ((b & 7) << 18) | ((u8[i + 1] & 63) << 12) | ((u8[i + 2] & 63) << 6) | (u8[i + 3] & 63); i += 4; }
		if (cp >= 0x10000) {
			cp -= 0x10000;
			s += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
		} else s += String.fromCharCode(cp);
	}
	return s;
}

import('std').then(std => {
	globalThis.__lxStd = std;
	main(std);
}).catch(e => {
	print('RESULT ' + JSON.stringify({ ok: false, error: 'fatal: cannot import std: ' + String((e && e.message) || e) }));
});

function main(std) {
	function log(...a) { print('LOG ' + a.join(' ')); }

	// 读全文本文件（bellard std 无 readFile：open + getline 循环；getline 不含换行，需补回）
	function readTextFile(path) {
		const f = std.open(path, 'r');
		if (!f) throw new Error('cannot open ' + path);
		let s = '';
		for (;;) {
			const line = f.getline();
			if (line === undefined || line === null) break;
			s += line + '\n';
		}
		f.close();
		return s;
	}

	// ---------- lx 事件环境 ----------
	const handlers = {};
	const EVENT_NAMES = Object.freeze({
		request: 'request',
		inited: 'inited',
		updateAlert: 'updateAlert',
	});

	function on(name, handler) {
		if (typeof handler !== 'function') throw new TypeError('lx.on: handler must be function');
		handlers[name] = handler;
	}

	function send(name, data) {
		if (name === EVENT_NAMES.updateAlert) {
			print('ALERT ' + JSON.stringify(data == null ? {} : data));
		}
	}

	// ---------- HTTP（std.urlGet + 手动 3xx 跟随） ----------
	function absUrl(base, loc) {
		loc = String(loc);
		if (/^https?:\/\//i.test(loc)) return loc;
		const origin = (base.match(/^https?:\/\/[^\/]+/i) || [''])[0];
		if (loc.charAt(0) === '/') return origin + loc;
		return base.slice(0, base.lastIndexOf('/') + 1) + loc;
	}

	function httpOnce(url, options) {
		const reqOpts = {
			method: String(options.method || 'GET').toUpperCase(),
			timeoutSec: Math.min(Math.max(Number(options.timeout) || 15, 1), 60),
		};
		if (options.headers) {
			reqOpts.headers = {};
			for (const k of Object.keys(options.headers)) reqOpts.headers[k] = String(options.headers[k]);
		}
		if (options.body != null && options.body !== '') {
			reqOpts.content = String(options.body);
		} else if (options.form && reqOpts.method !== 'GET') {
			const parts = [];
			for (const k of Object.keys(options.form)) parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(options.form[k]));
			reqOpts.content = parts.join('&');
			reqOpts.headers = reqOpts.headers || {};
			if (!reqOpts.headers['Content-Type']) reqOpts.headers['Content-Type'] = 'application/x-www-form-urlencoded';
		}
		const t0 = Date.now();
		const r = std.urlGet(url, reqOpts);
		const elapsed = Date.now() - t0;
		const body = typeof r.response === 'string' ? r.response : utf8Decode(new Uint8Array(r.response || []));
		const headerObj = {};
		for (const k of Object.keys(r.headers || {})) headerObj[String(k).toLowerCase()] = String(r.headers[k]);
		log('http', reqOpts.method, url, '->', r.status, '(' + elapsed + 'ms,' + body.length + 'B)');
		return { body, code: r.status, headers: headerObj };
	}

	function httpSync(url, options) {
		let cur = String(url);
		for (let hop = 0; hop < 3; hop++) { // 对齐 lx 宿主 follow_max:3
			const r = httpOnce(cur, options);
			if (r.code >= 300 && r.code < 400 && r.headers['location']) {
				cur = absUrl(cur, r.headers['location']);
				continue;
			}
			return r;
		}
		throw new Error('too many redirects (>3)');
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

	// ---------- MD5（RFC 1321 纯 JS） ----------
	function md5Hex(str) {
		const bytes = toUtf8(String(str));
		const S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
			5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
			4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
			6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21];
		const K = new Int32Array(64);
		for (let i = 0; i < 64; i++) K[i] = (Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296)) | 0;
		let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
		const len = bytes.length;
		const total = (((len + 8) >> 6) + 1) * 64;
		const buf = new Uint8Array(total);
		buf.set(bytes);
		buf[len] = 0x80;
		const dv = new DataView(buf.buffer);
		dv.setUint32(total - 8, (len * 8) >>> 0, true);
		dv.setUint32(total - 4, Math.floor((len * 8) / 4294967296), true);
		const rl = (x, c) => ((x << c) | (x >>> (32 - c))) >>> 0;
		for (let off = 0; off < total; off += 64) {
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
		let hex = '';
		for (const v of [a0, b0, c0, d0]) {
			for (let i = 0; i < 4; i++) hex += ((v >>> (i * 8)) & 255).toString(16).padStart(2, '0');
		}
		return hex;
	}

	const B64CH = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
	function b64Encode(u8) {
		let s = '';
		for (let i = 0; i < u8.length; i += 3) {
			const b0 = u8[i], b1 = u8[i + 1], b2 = u8[i + 2];
			s += B64CH[b0 >> 2] + B64CH[((b0 & 3) << 4) | ((b1 == null ? 0 : b1) >> 4)];
			s += b1 == null ? '=' : B64CH[((b1 & 15) << 2) | ((b2 == null ? 0 : b2) >> 6)];
			s += b2 == null ? '=' : B64CH[b2 & 63];
		}
		return s;
	}
	function b64Decode(s) {
		const clean = String(s).replace(/[^A-Za-z0-9+/=]/g, '');
		const out = [];
		for (let i = 0; i < clean.length; i += 4) {
			const e = [B64CH.indexOf(clean[i]), B64CH.indexOf(clean[i + 1]), B64CH.indexOf(clean[i + 2]), B64CH.indexOf(clean[i + 3])];
			out.push((e[0] << 2) | (e[1] >> 4));
			if (clean[i + 2] !== '=') out.push(((e[1] & 15) << 4) | (e[2] >> 2));
			if (clean[i + 3] !== '=') out.push(((e[2] & 3) << 6) | e[3]);
		}
		return new Uint8Array(out);
	}

	function randomBytes(n) {
		const u = new Uint8Array(n);
		for (let i = 0; i < n; i++) u[i] = (Math.random() * 256) | 0;
		return u;
	}

	// ---------- 全局 lx 对象 ----------
	globalThis.lx = {
		EVENT_NAMES: Object.freeze({ request: 'request', inited: 'inited', updateAlert: 'updateAlert' }),
		on,
		send,
		request: lxRequest,
		utils: {
			crypto: {
				md5: (data) => md5Hex(typeof data === 'string' ? data : utf8Decode(data)),
				aesEncrypt: () => { throw new Error('shim: aesEncrypt not implemented yet'); },
				rsaEncrypt: () => { throw new Error('shim: rsaEncrypt not implemented yet'); },
				randomBytes,
			},
			buffer: {
				from: (data, enc) => (enc === 'base64' ? b64Decode(data) : toUtf8(data)),
				bufToString: (buf, enc) => (enc === 'hex'
					? Array.from(buf instanceof Uint8Array ? buf : new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('')
					: (enc === 'base64' ? b64Encode(buf) : utf8Decode(buf))),
			},
			zlib: {
				inflate: () => { throw new Error('shim: zlib.inflate not implemented yet'); },
				deflate: () => { throw new Error('shim: zlib.deflate not implemented yet'); },
			},
		},
		currentScriptInfo: null,
		version: '2.0.0',
		env: 'desktop',
	};

	// ---------- 解析参数 ----------
	const rawArgs = Array.from(scriptArgs || []);
	let ai = 0;
	if (rawArgs[0] && /\.mjs$/.test(rawArgs[0])) ai = 1;
	const args = rawArgs.slice(ai);
	if (args.length < 3) {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'usage: qjs shim.mjs <source.js> <action> <infoJSON> (args=' + JSON.stringify(rawArgs) + ')' }));
		std.exit(1);
	}
	const [sourcePath, action, infoJson] = args;

	// ---------- 加载源脚本 ----------
	let sourceCode;
	try {
		sourceCode = readTextFile(sourcePath);
	} catch (e) {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'cannot read source: ' + e }));
		std.exit(1);
	}
	print('LOG src len=' + (sourceCode ? sourceCode.length : -1) + ' head=' + JSON.stringify(String(sourceCode || '').slice(0, 120)));

	const meta = {};
	const head = String(sourceCode).slice(0, 2048);
	const metaRe = /@(\w+)\s+([^\r\n*]+)/g;
	let mm;
	while ((mm = metaRe.exec(head))) meta[mm[1]] = mm[2].trim();

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
		// 间接 eval = 全局 sloppy 作用域执行源脚本（new Function 路径在 bellard qjs 上进程级崩溃，弃用）
		(0, eval)(sourceCode);
	} catch (e) {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'source load failed: ' + String((e && e.message) || e) }));
		std.exit(1);
	}

	print('LOG handlers after load: ' + JSON.stringify(Object.keys(handlers)));

	if (typeof handlers[EVENT_NAMES.request] !== 'function') {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'source did not register request handler' }));
		std.exit(1);
	}

	// ---------- 调用 action ----------
	let info;
	try {
		info = JSON.parse(infoJson);
	} catch (e) {
		info = {};
	}
	const source = info.source || '';
	const infoArg = info.info || info;

	const ret = handlers[EVENT_NAMES.request]({ source, action, info: infoArg });
	Promise.resolve(ret).then(r => {
		print('RESULT ' + JSON.stringify({ ok: true, data: r == null ? null : r }));
		std.out.flush();
		std.exit(0);
	}).catch(e => {
		print('RESULT ' + JSON.stringify({ ok: false, error: String((e && e.message) || e) }));
		std.out.flush();
		std.exit(1);
	});
}
