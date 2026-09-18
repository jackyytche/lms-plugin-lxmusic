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
	import('os').then(os => {
		globalThis.__lxOs = os;
		main(std, os);
	}).catch(e => {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'fatal: cannot import os: ' + String((e && e.message) || e) }));
	});
}).catch(e => {
	print('RESULT ' + JSON.stringify({ ok: false, error: 'fatal: cannot import std: ' + String((e && e.message) || e) }));
});

function main(std, os) {
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
		print('LOG on: ' + String(name) + ' fnHead=' + JSON.stringify(String(handler).slice(0, 120)));
		handlers[name] = handler;
	}

	function send(name, data) {
		print('LOG send: ' + String(name) + ' data=' + JSON.stringify(data == null ? null : data).slice(0, 400));
		if (name === EVENT_NAMES.updateAlert) {
			print('ALERT ' + JSON.stringify(data == null ? {} : data));
		}
		if (name === EVENT_NAMES.inited) __inited = true;
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
		const os_ = os;
		const uniq = String(Date.now()) + ((Math.random() * 1e6) | 0);
		const fBody = '/tmp/lx-b-' + uniq, fHdr = '/tmp/lx-h-' + uniq, fErr = '/tmp/lx-e-' + uniq, fIn = '/tmp/lx-i-' + uniq;
		const timeout = Math.min(Math.max(Number(options.timeout) || 15, 1), 60);

		const args = ['curl', '-sS', '-L', '--max-time', String(timeout), '-D', fHdr, '-o', fBody, '--stderr', fErr];
		if (options.method) args.push('-X', String(options.method).toUpperCase());
		const method = String(options.method || 'GET').toUpperCase();
		if (options.headers) {
			for (const k of Object.keys(options.headers)) args.push('-H', k + ': ' + String(options.headers[k]));
		}
		if (options.body != null && options.body !== '') {
			const wf = std.open(fIn, 'wb');
			if (!wf) throw new Error('cannot write request body file');
			wf.write(toUtf8(String(options.body)));
			wf.close();
			args.push('--data-binary', '@' + fIn);
		} else if (options.form && method !== 'GET') {
			const parts = [];
			for (const k of Object.keys(options.form)) parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(options.form[k]));
			args.push('--data-urlencode', parts.join('&'));
		}
		args.push(String(url));

		const t0 = Date.now();
		const wstatus = os_.exec(args, { block: true });
		const elapsed = Date.now() - t0;

		function slurp(p) {
			const f = std.open(p, 'r');
			if (!f) return '';
			let s = '';
			for (;;) {
				const line = f.getline();
				if (line === undefined || line === null) break;
				s += line + '\n';
			}
			f.close();
			return s;
		}
		const rawHdr = slurp(fHdr);
		const body = slurp(fBody).replace(/\n\z/, '');
		for (const p of [fBody, fHdr, fErr, fIn]) {
			try { os_.remove(p); } catch (e) {}
		}

		const sig = typeof wstatus === 'number' ? (wstatus & 0x7f) : 0;
		const exitCode = typeof wstatus === 'number' ? (wstatus >> 8) : 0;
		if (sig !== 0) throw new Error('curl killed by signal ' + sig);
		if (exitCode === 28) throw new Error('timeout after ' + timeout + 's');
		if (exitCode !== 0 && rawHdr === '') throw new Error('curl exit ' + exitCode + ' (' + elapsed + 'ms)');

		// 解析 status line（取最后一个，兼容重定向链）+ headers
		let code = 0;
		const headerObj = {};
		const lines = String(rawHdr).split(/\r?\n/);
		for (const ln of lines) {
			const m = ln.match(/^HTTP\/[\d.]+\s+(\d+)/);
			if (m) code = Number(m[1]);
			const kv = ln.match(/^([A-Za-z0-9-]+)\s*:\s*(.*)$/);
			if (kv) headerObj[kv[1].toLowerCase()] = kv[2].replace(/\s+\z/, '');
		}
		log('http', method, url, '->', code, '(' + elapsed + 'ms,' + body.length + 'B)');
		return { body, code, headers: headerObj };
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
		print('LOG req: ' + String(options.method || 'GET') + ' ' + String(url).slice(0, 140)
			+ (options.body ? ' body=' + String(options.body).length + 'B' : ''));
		try {
			const r = httpSync(url, options);
			print('LOG resp: code=' + r.code + ' len=' + (r.body == null ? -1 : String(r.body).length)
				+ ' head=' + JSON.stringify(String(r.body || '').slice(0, 80)));
			callback(null, r.body, r.code, r.headers);
		} catch (e) {
			const msg = String((e && e.message) || e);
			print('LOG req ERR: ' + msg);
			callback(msg);
		}
	}

	// ---------- MD5（RFC 1321 纯 JS） ----------
	function md5Hex(input) {
		// 字节直入：字符串按 UTF-8 编码；Buffer/Uint8Array 原样逐字节（不做 utf8 解码——
		// 非 UTF-8 序列经解码会替换为 U+FFFD，签名即错）
		const bytes = typeof input === 'string' ? toUtf8(input) : new Uint8Array(input);
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

	// ---------- 定时器 polyfill（bellard qjs 的 std/os 无 setTimeout） ----------
	// 同步近似：登记回调，drain 阶段按登记顺序立即执行（忽略 ms 延迟），
	// 回调之间栈 unwind 时微任务（Promise 链）自动推进——源的异步初始化
	// 靠这个泵跑到 send(inited)。
	const __timers = [];
	let __timerSeq = 1;
	let __inited = false;
	globalThis.setTimeout = function (fn, ms) {
		const args = Array.prototype.slice.call(arguments, 2);
		__timers.push({ fn, args });
		return __timerSeq++;
	};
	globalThis.clearTimeout = function () {};
	globalThis.setInterval = globalThis.setTimeout;
	globalThis.clearInterval = globalThis.clearTimeout;
	globalThis.queueMicrotask = globalThis.queueMicrotask || function (fn) {
		Promise.resolve().then(() => fn());
	};

	// 反复排空定时器队列，直到 inited 或轮数上限（防止源无限轮询）
	function drainUntilInited() {
		let rounds = 0;
		while (!__inited && __timers.length && rounds < 300) {
			const batch = __timers.splice(0, __timers.length);
			for (const t of batch) {
				try { t.fn.apply(null, t.args); }
				catch (e) { print('LOG timer ERR: ' + String((e && e.message) || e)); }
			}
			rounds++;
		}
		print('LOG drain: rounds=' + rounds + ' inited=' + __inited + ' pending=' + __timers.length);
	}

	// ---------- Node 环境近似 polyfill（源脚本按 Node 宿主习惯编写） ----------
	function hexEncode(u8) {
		let s = '';
		for (let i = 0; i < u8.length; i++) s += (u8[i] & 255).toString(16).padStart(2, '0');
		return s;
	}
	function hexDecode(s) {
		const clean = String(s).replace(/[^0-9a-fA-F]/g, '');
		const out = new Uint8Array(clean.length >> 1);
		for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.substr(i * 2, 2), 16);
		return out;
	}
	// 真 Uint8Array 子类：buf[i] 下标、new Uint8Array(buf)、逐字节遍历全部原生可用——
	// 混淆源的签名计算依赖字节级语义，普通对象 polyfill 会产出错误签名。
	class NodeBuf extends Uint8Array {
		constructor(data, enc) {
			if (typeof data === 'string') {
				const u8 = enc === 'base64' ? b64Decode(data)
					: enc === 'hex' ? hexDecode(data)
					: toUtf8(data);
				super(u8);
			}
			else if (typeof data === 'number') super(data);
			else super(data instanceof Uint8Array ? data : new Uint8Array(data || 0));
		}
		toString(enc) {
			return enc === 'base64' ? b64Encode(this)
				: enc === 'hex' ? hexEncode(this)
				: utf8Decode(this);
		}
		slice(a, b) { return new NodeBuf(super.slice(a || 0, b == null ? this.length : b)); }
		subarray(a, b) { return this.slice(a, b); }
		concat(others) {
			const all = [this].concat((others || []).map(x => (x instanceof Uint8Array) ? x : new NodeBuf(x)));
			const total = all.reduce((n, a) => n + a.length, 0);
			const out2 = new Uint8Array(total);
			let off = 0;
			for (const a of all) { out2.set(a, off); off += a.length; }
			return new NodeBuf(out2);
		}
	}
	const NodeBuffer = {
		from: (d, e) => new NodeBuf(d, e),
		alloc: (n) => new NodeBuf(Number(n) || 0),
		concat: (arr) => new NodeBuf(0).concat(arr),
		isBuffer: (x) => x instanceof NodeBuf,
	};
	globalThis.Buffer = NodeBuffer;
	globalThis.TextEncoder = class { encode(s) { return toUtf8(String(s)); } };
	globalThis.TextDecoder = class { decode(u8) { return utf8Decode(u8); } };
	globalThis.process = {
		platform: 'linux',
		version: 'v18.0.0',
		env: {},
		argv: ['qjs'],
		nextTick: (fn) => Promise.resolve().then(() => fn()),
	};
	globalThis.setImmediate = globalThis.setTimeout;
	globalThis.clearImmediate = globalThis.clearTimeout;
	globalThis.console = {
		log: (...a) => print('LOG console.log: ' + a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
		info: (...a) => print('LOG console.info: ' + a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
		warn: (...a) => print('LOG console.warn: ' + a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
		error: (...a) => print('LOG console.error: ' + a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
		debug: (...a) => print('LOG console.debug: ' + a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
	};
	globalThis.require = function (name) {
		print('LOG require called: ' + String(name));
		throw new Error('shim: require("' + String(name) + '") not available');
	};
	globalThis.fetch = function (url, opts) {
		return new Promise((resolve, reject) => {
			try {
				const r = httpSync(String(url), opts || {});
				const body = String(r.body == null ? '' : r.body);
				resolve({
					ok: r.code >= 200 && r.code < 300,
					status: r.code,
					headers: r.headers || {},
					text: () => Promise.resolve(body),
					json: () => Promise.resolve(JSON.parse(body || 'null')),
				});
			}
			catch (e) { reject(e); }
		});
	};

	// ---------- 全局 lx 对象 ----------
	globalThis.lx = {
		EVENT_NAMES: Object.freeze({ request: 'request', inited: 'inited', updateAlert: 'updateAlert' }),
		on,
		send,
		request: lxRequest,
		utils: {
			crypto: {
				md5: (data) => md5Hex(data),
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

	// ---------- 分级执行源脚本（定位真实崩溃点） ----------
	const __globalsBefore = Object.getOwnPropertyNames(globalThis);
	try {
		print('LOG e0 eval smoke: ' + (0, eval)('1+1'));
		(0, eval)('lx.on("request", function h(){}); print("LOG e1 simple-on ok")');
		delete handlers[EVENT_NAMES.request];   // 冒烟占位符不参与后续（避免误判源 handler）
		print('LOG e2 handlers: ' + JSON.stringify(Object.keys(handlers)));
		std.loadScript(sourcePath);
		print('LOG e3 loadScript ok, handlers: ' + JSON.stringify(Object.keys(handlers)));
	} catch (e) {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'source load failed: ' + String((e && e.message) || e) }));
		std.exit(1);
	}

	if (typeof handlers[EVENT_NAMES.request] !== 'function') {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'source did not register request handler' }));
		std.exit(1);
	}

	// 源脚本加载后先驱动其异步初始化（desktop 宿主是常驻进程，inited 之后
	// handler 才可用；qjs 一次性进程必须手动泵定时器/微任务到 inited）
	drainUntilInited();

	// 诊断：全局新增键（真差分）+ handler 函数体头部（识别转发器/占位符）
	try {
		const __added = Object.getOwnPropertyNames(globalThis)
			.filter(k => __globalsBefore.indexOf(k) < 0);
		print('LOG globals added: ' + JSON.stringify(__added));
		const hf = handlers[EVENT_NAMES.request];
		print('LOG fnHead: ' + (hf ? JSON.stringify(String(hf).slice(0, 400)) : '"<none - source never called lx.on>"'));
	}
	catch (e) { print('LOG diag ERR: ' + String((e && e.message) || e)); }

	// ---------- 调用 action ----------
	let info;
	try {
		info = JSON.parse(infoJson);
	} catch (e) {
		info = {};
	}
	const source = info.source || '';
	const infoArg = info.info || info;

	print('LOG h0 calling handler, action=' + action
		+ ' args=' + JSON.stringify({ source, action, info: infoArg }).slice(0, 300));
	let ret;
	try {
		ret = handlers[EVENT_NAMES.request]({ source, action, info: infoArg });
	} catch (e) {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'handler sync throw: ' + String((e && e.message) || e) }));
		std.exit(1);
	}
	const fn = handlers[EVENT_NAMES.request];
	print('LOG h1 ret=' + (ret && ret.then ? 'promise' : typeof ret)
		+ ' fnCtor=' + (fn.constructor && fn.constructor.name) + ' fnParams=' + fn.length
		+ ' thenPresent=' + !!(ret && typeof ret.then === 'function'));

	Promise.resolve(ret).then(r => {
		print('LOG t1 type=' + typeof r);
		print('LOG t2 keys=' + (r ? Object.keys(r).join(',') : 'null'));
		const s = JSON.stringify({ ok: true, data: r == null ? null : r });
		print('LOG t3 stringify len=' + s.length);
		print('RESULT ' + s);
		print('LOG t4 before flush');
		std.out.flush();
		print('LOG t5 flushed, exiting');
		std.exit(0);
	}).catch(e => {
		print('RESULT ' + JSON.stringify({ ok: false, error: String((e && e.message) || e) }));
		std.out.flush();
		std.exit(1);
	});
	print('LOG h3 promise chain armed, entering job loop');
}
