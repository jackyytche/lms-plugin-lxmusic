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

async function main(std, os) {
	// stdout/stderr 被 Helper 重定向到文件 ⇒ glibc 全缓冲 ⇒ 子进程被 timeout KILL 时
	// 缓冲里的 LOG/RESULT 全部丢失（现象：父进程只看到 "no RESULT line" 且日志区空白）。
	// 这里把 print 包一层、每条都 flush：诊断现场就不再"无痕"。
	try {
		const __rawPrint = globalThis.print;
		globalThis.print = function () {
			try { __rawPrint.apply(null, arguments); } catch (e) {}
			try { std.out.flush(); } catch (e) {}
		};
	} catch (e) {}

	function log(...a) { print('LOG ' + a.join(' ')); }

	// 读全文本文件（bellard std 无 readFile：open + getline 循环；getline 不含换行，需补回）
	// 注意：页面 textarea 提交会把换行规范成 CRLF，installSource 落盘后 current.js 是 CRLF 行尾，
	// 而源的完整性签名基于原版 LF 内容——读入时必须统一回 LF，否则 rawScript hash 必错（403）。
	function readTextFile(path) {
		const f = std.open(path, 'r');
		if (!f) throw new Error('cannot open ' + path);
		let s = '';
		for (;;) {
			const line = f.getline();
			if (line === undefined || line === null) break;
			s += line.replace(/\r$/, '') + '\n';
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

	// lx.on / lx.send 必须返回 **Promise**（权威实现：desktop-preload.js:243-272 里
	// send/on 都 return new Promise / Promise.resolve）。返回 undefined 时，源里的
	// `lx.on('request', h).then(...)`、`await lx.send('inited', ...).then(...)` 会直接
	// 抛 "not a function"——实测就是 ikun/huibq/huanyin/juhe 一类源的失败原因。
	function on(name, handler) {
		if (typeof handler !== 'function') return Promise.reject(new TypeError('lx.on: handler must be function'));
		if (name !== EVENT_NAMES.request) return Promise.reject(new Error('The event is not supported: ' + name));
		print('LOG on: ' + String(name) + ' fnHead=' + JSON.stringify(String(handler).slice(0, 120)));
		handlers[name] = handler;
		return Promise.resolve();
	}

	function send(name, data) {
		print('LOG send: ' + String(name) + ' data=' + JSON.stringify(data == null ? null : data).slice(0, 400));
		if (name === EVENT_NAMES.updateAlert) {
			print('ALERT ' + JSON.stringify(data == null ? {} : data));
			return Promise.resolve();
		}
		if (name === EVENT_NAMES.inited) {
			__inited = true;
			// 0.11.58：**把源的能力表带出去**（PC 端 `preload.js:146-167` 正是用它生成 userApi.apis /
			// qualityList 并做请求裁剪）。从前只置 __inited=true、data 直接丢弃 ⇒ 宿主只能按
			// 「所有已启用源 × 所有档位」盲打：慢源上每次取链都白跑好几轮，还会把上游错误
			// 放大成超时/熔断（用户报的"解析慢"、worker 雪崩的结构性原因）。
			try {
				const d = (data && typeof data === 'object') ? data : {};
				__caps = {
					status: String(d.status || 'success'),
					sources: (d.sources && typeof d.sources === 'object') ? d.sources : {},
				};
				print('CAPS ' + JSON.stringify(__caps));
			} catch (e) {
				print('LOG caps capture failed: ' + String((e && e.message) || e));
			}
			return Promise.resolve();
		}
		return Promise.reject(new Error('The event is not supported: ' + name));
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

		// 0.11.66：**加 `--compressed`** —— 让 curl 主动声明并透明解压 gzip/deflate。
		// 起因：静态扫描 178 个候选源发现有源依赖 `lx.utils.zlib.inflate`，而我们没有实现它；
		// 绝大多数场景只是"上游把 JSON 压了"，curl 自己就能解开，不需要源去 inflate。
		const args = ['curl', '-sS', '-L', '--compressed', '--max-time', String(timeout), '-D', fHdr, '-o', fBody, '--stderr', fErr];
		if (options.method) args.push('-X', String(options.method).toUpperCase());
		const method = String(options.method || 'GET').toUpperCase();
		if (options.headers) {
			for (const k of Object.keys(options.headers)) args.push('-H', k + ': ' + String(options.headers[k]));
		}
		if (options.body != null && options.body !== '') {
			const wf = std.open(fIn, 'wb');
			if (!wf) throw new Error('cannot write request body file');
			const u8 = toUtf8(String(options.body));
			wf.write(u8.buffer, u8.byteOffset, u8.byteLength);   // write 只收 ArrayBuffer
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

		// qjs（bellard）block exec 返回的是**纯退出码**，不是 wait status（HANDOFF §5.1 实测）。
		// 早先按 wait status 解析（sig = status & 0x7f）把 curl 的 exit 35（SSL 连接错误）
		// 误报成 "killed by signal 35"，还让 `exit 28 = 超时` 的专用分支变成死代码。
		// 兼容：>255 的值只可能来自"原始 wait status"形态（node sim stub 旧约定）。
		const raw = typeof wstatus === 'number' ? wstatus : 0;
		const sig = raw > 255 ? (raw & 0x7f) : 0;
		const exitCode = raw > 255 ? (raw >> 8) : raw;
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
		print('LOG req hdrs=' + JSON.stringify(options.headers || {}) + ' ' + 'LOG req: ' + String(options.method || 'GET') + ' ' + String(url).slice(0, 140)
			+ (options.body ? ' body=' + String(options.body).length + 'B' : ''));
		try {
			const r = httpSync(url, options);
			print('LOG resp: code=' + r.code + ' len=' + (r.body == null ? -1 : String(r.body).length)
				+ ' head=' + JSON.stringify(String(r.body || '').slice(0, 80)));
			// 对齐 desktop preload 的 callback 形状（源按它解析）：
			//   第二参 = { statusCode, statusMessage, headers, bytes, raw(Buffer), body(尽量 JSON 解析) }
			//   第三参 = JSON 解析后的 body（不是 status 数字！）
			const rawBytes = toUtf8(String(r.body == null ? '' : r.body));
			let parsed = r.body;
			try { parsed = JSON.parse(parsed); } catch (e) {}
			callback(null, {
				statusCode: r.code,
				statusMessage: '',
				headers: r.headers,
				bytes: rawBytes.length,
				raw: new NodeBuf(rawBytes),
				body: parsed,
			}, parsed);
		} catch (e) {
			const msg = String((e && e.message) || e);
			print('LOG req ERR: ' + msg);
			callback(msg);
		}
		// 权威实现返回"取消函数"（desktop-preload.js:238-241）；源可能保存它并调用，
		// 返回 undefined 会 "not a function"。我们的 HTTP 是同步 curl，取消是空操作。
		return function cancelRequest() { print('LOG req: cancel (noop)'); };
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
	// 0.11.58：源在 `lx.send('inited', {sources:{…}})` 里声明的能力表（平台 → 可用档位）。
	// `send()` 里采集、以一行 `CAPS {json}` 打给宿主；serve 模式的 READY 行也带上它。
	let __caps = null;
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

	// 反复让出执行栈直到 inited 或轮数上限（防止源无限轮询）。
	// 关键：qjs 顶层同步代码中 promise 微任务不执行——必须 await 让栈退回引擎，
	// rconfig 回调之后的 then 链（注册 handler + send(inited)）才有机会跑。
	async function drainUntilInited() {
		let rounds = 0;
		// 上限从 200 提到 1500：混淆大源（如六音 333 KB）初始化更慢；同时每 200 轮打点，
		// 配合下面的 print 强制 flush，被 Helper 超时 KILL 时也能留下"卡在第几轮"的证据。
		while (!__inited && rounds < 1500) {
			rounds++;
			const batch = __timers.splice(0, __timers.length);
			for (const t of batch) {
				try { t.fn.apply(null, t.args); }
				catch (e) { print('LOG timer ERR: ' + String((e && e.message) || e)); }
			}
			if (rounds % 200 === 0) print('LOG drain progress: rounds=' + rounds + ' pending=' + __timers.length);
			await null;
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
	// Buffer 必须可 new（vendor musicSdk 的 request/crypto/zlib 与 js-md5/js-sha1
	// 都有 `new Buffer(x)` 调用；node harness 里真 Buffer 是构造函数所以曾漏测）。
	// 类继承 NodeBuf 获得实例方法；静态方法挂类上（不用 static 字段语法，兼容旧 qjs）。
	class NodeBuffer extends NodeBuf { }
	NodeBuffer.from = (d, e) => new NodeBuf(d, e);
	NodeBuffer.alloc = (n) => new NodeBuf(Number(n) || 0);
	NodeBuffer.concat = (arr) => new NodeBuf(0).concat(arr);
	NodeBuffer.isBuffer = (x) => x instanceof NodeBuf;
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
	// console 必须"全套"：源里一句 console.group / console.table 缺失就会 TypeError，
	// 整个源当场废掉（M0.9 实测：ikun 第 121 行只调了 console.group 就挂了）。
	// 全部落到 LOG 行（缩进体现 group 层级），不认识的方法一律给个空实现。
	globalThis.console = (() => {
		const fmt = (a) => a.map(x => typeof x === 'string' ? x
			: (x === undefined ? 'undefined' : (() => { try { return JSON.stringify(x); } catch (e) { return String(x); } })())).join(' ');
		let depth = 0;
		const out = (tag) => (...a) => print('LOG console.' + tag + ': ' + '  '.repeat(depth) + fmt(a));
		const c = {
			log: out('log'), info: out('info'), warn: out('warn'), error: out('error'), debug: out('debug'),
			trace: out('trace'), dir: out('dir'), table: out('table'), assert: () => {},
			group: (...a) => { out('group')(...a); depth++; },
			groupCollapsed: (...a) => { out('group')(...a); depth++; },
			groupEnd: () => { depth = Math.max(0, depth - 1); },
			time: () => {}, timeEnd: () => {}, timeLog: () => {},
			count: () => {}, countReset: () => {}, clear: () => {},
		};
		return c;
	})();
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
				// 0.11.66：**说明是引擎的限制**，而不是让源看起来"自己坏了"。
				// 静态扫描 178 个候选源：aesEncrypt 13 个、rsaEncrypt 7 个、randomBytes 7 个（已支持）、
				// zlib.inflate/deflate 需要看源（curl 侧已加 --compressed，能挡住绝大多数 gzip 场景）。
				aesEncrypt: () => { throw new Error('ENGINE_UNSUPPORTED: lx.utils.crypto.aesEncrypt'); },
				rsaEncrypt: () => { throw new Error('ENGINE_UNSUPPORTED: lx.utils.crypto.rsaEncrypt'); },
				randomBytes,
			},
			buffer: {
				from: (data, enc) => (enc === 'base64' ? b64Decode(data) : toUtf8(data)),
				bufToString: (buf, enc) => (enc === 'hex'
					? Array.from(buf instanceof Uint8Array ? buf : new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('')
					: (enc === 'base64' ? b64Encode(buf) : utf8Decode(buf))),
			},
			zlib: {
				inflate: () => { throw new Error('ENGINE_UNSUPPORTED: lx.utils.zlib.inflate'); },
				deflate: () => { throw new Error('ENGINE_UNSUPPORTED: lx.utils.zlib.deflate'); },
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
		print('RESULT ' + JSON.stringify({ ok: false, error: 'usage: qjs shim.mjs <source.js|sdk.bundle.js> <action> <infoJSON> (args=' + JSON.stringify(rawArgs) + ')' }));
		std.exit(1);
	}
	const [sourcePath, action, infoJson] = args;

	// probe 的实体实现（单次进程与探测 worker 共用）：返回结果对象，不打印不退出
	// M0.10：从"只发 HEAD"升级为"取前 2KB 实体 + 嗅探音频魔数"。
	// 起因（现场）：长青音源的直链 http://yinyue.haitangw.net/kw/kw.php?... 对 HEAD 回 200，
	// 但真去 GET 时既不出声也不报错——LMS 队列显示 mode=play 而位置永远停在 0 秒（"选了 flac 却没声"）。
	// 只校验状态码/Content-Type 挡不住这种"HEAD 说好、GET 是空壳/错误页"的直链。
	function probeOnce(payload) {
		const url = String(payload.url || '');
		if (!/^https?:\/\//i.test(url)) return { ok: false, error: 'probe: bad url' };
		const tmo = Math.max(3, Math.min(20, Number(payload.timeout) || 8));
		const base = ((os.getenv && os.getenv('LX_TMP')) || '/tmp') + '/lxp_' + Date.now() + '_' + Math.floor(Math.random() * 1e6);
		const hdrF = base + '.hdr';
		const bodyF = base + '.bin';
		const run = (extra) => {
			// 必须 -L 跟随重定向：真实播放链路会跟随（binHttp 也是手动跟 3 跳），
			// 不跟随就会把 301/302 误判成不可播（0.8.5 现场：长青音源的直链是 301，被误杀）
			const a = ['curl', '-sS', '-L', '--compressed', '--max-redirs', '3', '--max-time', String(tmo),
				'-A', 'Mozilla/5.0', '-D', hdrF, '-o', bodyF, '--max-filesize', '400000'];
			for (const x of extra) a.push(x);
			a.push(url);
			try { os.exec(a, { block: true }); } catch (e) {}
			let text = '';
			try {
				const f = std.open(hdrF, 'r');
				if (f) { for (;;) { const l = f.getline(); if (l == null) break; text += l + '\n'; } f.close(); }
			} catch (e) {}
			try { os.remove(hdrF); } catch (e) {}
			return text;
		};
		const readBody = (max) => {
			const bytes = [];
			try {
				const f = std.open(bodyF, 'r');
				if (f) {
					for (;;) {
						const b = f.getByte();
						if (b < 0) break;
						bytes.push(b);
						if (bytes.length >= max) break;
					}
					f.close();
				}
			} catch (e) {}
			return bytes;
		};
		// 先 Range GET 取实体头（服务器不支持 Range 会给 200 + 全量；--max-filesize 让 curl 早停）
		let bytes = [];
		let text = run(['-r', '0-2047']);
		let method = 'RANGE';
		let m = text.match(/^HTTP\/[\d.]+\s+(\d{3})/m);
		if (!m || Number(m[1]) >= 400) {
			bytes = [];
			text = run(['-I']);
			method = 'HEAD';
			m = text.match(/^HTTP\/[\d.]+\s+(\d{3})/m);
		}
		else {
			bytes = readBody(2048);
		}
		try { os.remove(bodyF); } catch (e) {}
		// -L 会保留中间跳的响应头块：只看最后一个块（否则会读到 301 而不是最终 200）
		const blocks = text.split(/\r?\n\r?\n/).filter(b => /^HTTP\//m.test(b));
		const final = blocks.length ? blocks[blocks.length - 1] : text;
		const hdr = (name) => {
			const r = final.match(new RegExp('^' + name + '\\s*:\\s*(.*)$', 'mi'));
			return r ? r[1].trim() : '';
		};
		m = final.match(/^HTTP\/[\d.]+\s+(\d{3})/m);
		const status = m ? Number(m[1]) : 0;
		// ---- 音频魔数嗅探（取到的前 2KB 里认头）----
		const hx = (i) => (bytes[i] || 0).toString(16).padStart(2, '0');
		let magic = '';
		const tag = (s) => bytes.slice(0, s.length).map(c => String.fromCharCode(c)).join('') === s;
		if (tag('ID3')) magic = 'mp3';
		else if (tag('fLaC')) magic = 'flac';
		else if (tag('OggS')) magic = 'ogg';
		else if (tag('RIFF')) magic = 'wav';
		else if (tag('MAC ')) magic = 'ape';
		else if (bytes.length > 11 && String.fromCharCode.apply(null, bytes.slice(4, 8)) === 'ftyp') magic = 'm4a';
		else if (bytes.length > 1 && bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0) magic = 'mp3';
		else if (bytes.length > 3 && bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3) magic = 'mkv';
		// 0.11.52：FLAC 的 **位深**（STREAMINFO 里的 bits-per-sample）——用来把"档位标签"
		// 从"请求的档位"改成"真实拿到的档位"（用户报：明明 128kbps 也显示 24bit FLAC）。
		// 布局：'fLaC'(4) + 元数据块头(4) + STREAMINFO：min/max blocksize(4) min/max framesize(6)
		// ⇒ 第 12/13 字节起是 20bit 采样率 + 3bit 声道 + 5bit (位深-1)。
		let bits = 0;
		if (magic === 'flac' && bytes.length > 21) {
			bits = (((bytes[20] & 0x01) << 4) | ((bytes[21] & 0xf0) >> 4)) + 1;
			if (bits < 4 || bits > 32) bits = 0;      // 不可信就丢掉
		}
		const head = bytes.slice(0, 32).map(c => (c >= 32 && c < 127) ? String.fromCharCode(c) : '.').join('');
		const looksHtml = /^\s*(<!doctype|<html|<\?xml|\{|\[)/i.test(head);
		// 总长度优先取 Content-Range 里的总量（`bytes 0-2047/34600000`）：范围响应的
		// Content-Length 只是这一片，用它算码率只会得到 ~0kbps（2026-09-21 修）
		const crTotal = (() => {
			const r = (hdr('content-range') || '').match(/\/\s*(\d+)\s*$/);
			return r ? Number(r[1]) : 0;
		})();
		// 0.11.51：**把重定向链跟到底，求出最终 URL**。
		// 现场（2026-09-22 深夜，最小复现）：念心给的 `http://mcp.nianxinxz.com/share/ceshi/tx.php?…`
		// 会 302 两次（→ https 同域 → car-lv.kuwo.cn/…）；LMS 让**我们的 handler**去开这条流时，
		// 走到第二步就挂住、30 秒零日志被达菲看门狗判 crashed（本地库/直链/源直链直接播放都稳）。
		// 已用对照实验判定：直链源（全豆要 wy → m801.music.126.net，无 302）不崩。
		// 办法：探测时本来就用 `curl -L` 跟了跳，这里把 3xx 块里的 Location 依次套上去得到最终 URL，
		// 交给上层当"直链"发布 ⇒ LMS 拿到的永远是不带跳转的地址，等价于已证安全的那条路径。
		const eff = (() => {
			let cur = url, changed = 0;
			for (const b of blocks) {
				const sm = b.match(/^HTTP\/[\d.]+\s+(\d{3})/m);
				if (!sm) continue;
				const code = Number(sm[1]);
				if (code < 300 || code >= 400) continue;
				const lm = b.match(/^location\s*:\s*(.+)$/mi);
				if (!lm) continue;
				const loc = lm[1].trim();
				if (/^https?:\/\//i.test(loc)) {
					cur = loc;
				} else if (loc.startsWith('//')) {
					cur = ((cur.match(/^https?:/i) || ['http:'])[0]) + loc;
				} else {
					const mm = cur.match(/^(https?:\/\/[^\/]+)(.*)$/i);
					if (!mm) continue;
					cur = mm[1] + (loc.startsWith('/') ? loc : mm[2].replace(/[^\/]*$/, '') + loc);
				}
				changed = 1;
			}
			return changed ? cur : '';
		})();
		const out = {
			status, method,
			type: hdr('content-type'),
			length: crTotal || Number(hdr('content-length')) || 0,
			range: hdr('content-range'),
			acceptRanges: hdr('accept-ranges'),
			bytes: bytes.length,
			magic,
			bits,
			head: head,
			url_effective: eff,
		};
		const typeAudio = /^(?:audio\/|video\/|application\/(?:octet-stream|x-|ogg|flac|mp4))/i.test(out.type || '');
		const bad = status < 200 || status >= 300
			|| (bytes.length && (looksHtml || magic === 'mkv' && false));
		// 判定：状态码 OK + （认得出音频魔数 或 至少不是 HTML/空壳且声明的类型像音频）
		const ok = !bad && (!!magic || (bytes.length > 0 && !looksHtml && typeAudio));
		print('LOG probe ' + JSON.stringify(out) + ' ok=' + (ok ? 1 : 0));
		const why = !ok ? ((status >= 200 && status < 300)
			? ('not playable: ' + (looksHtml ? 'HTML body' : (bytes.length ? ('bytes=' + bytes.length + ' magic=<none>') : 'empty body')))
			: (status ? 'HTTP ' + status : 'no response')) : undefined;
		return { ok, data: out, error: why };
	}


	// ---------- probe 模式：直链可播性探测（M0.6"取链后校验"）----------
	// qjs shim.mjs <任意存在的文件> probe {"url":"...","timeout":8}
	//   → RESULT { ok, data:{ status, method, type, length, range, acceptRanges } }
	// 先 HEAD；CDN 不允许 HEAD（403/405）时退 Range 0-0（只传 1 字节）。
	// 目的：把 403/HTML 错误页挡在播放器之外——那是"选了 flac 却无声"的常见成因。
	if (action === 'probe') {
		let payload = {};
		try { payload = JSON.parse(infoJson || '{}') || {} } catch (e) {}
		if (payload && payload.info && typeof payload.info === 'object') payload = payload.info;
		const r = probeOnce(payload);
		print('RESULT ' + JSON.stringify(r));
		std.out.flush();
		std.exit(r.ok ? 0 : 1);
	}

	// ---------- 探测 worker（M0.10）：argv[1] = '-' ⇒ 不加载任何订阅源 ----------
	// 校验探测（每次取链一条 HEAD）原本要现起一个 qjs 进程（~0.3s 里绝大部分是进程+脚本解析）。
	// 单独一个"不加载源"的常驻进程服务 probe：与取链 worker 分开，长探测不会卡住取链。
	if (action === 'serve' && sourcePath === '-') {
		print('READY ' + JSON.stringify({ name: 'probe', version: '' }));
		std.out.flush();
		for (;;) {
			const line = std.in.getline();
			if (line === null || line === undefined) break;
			const t = String(line).trim();
			if (!t) continue;
			let req;
			try { req = JSON.parse(t); }
			catch (e) { print('RESULT 0 ' + JSON.stringify({ ok: false, error: 'bad request json' })); continue; }
			const id = req.id != null ? req.id : 0;
			const t0 = Date.now();
			let r;
			try { r = probeOnce(req.info || {}); } catch (e) { r = { ok: false, error: String((e && e.message) || e) }; }
			r.ms = Date.now() - t0;
			print('RESULT ' + id + ' ' + JSON.stringify(r));
		}
		print('LOG probe worker: stdin closed, exiting');
		std.exit(0);
	}

	// ---------- SDK 模式（vendored musicSdk，无需订阅源） ----------
	// qjs shim.mjs <sdk.bundle.js> <search|boards|boardlist|songlist|songlistdetail|songlistbytag|songlistsorts|songlisttags> <payloadJSON>
	//   search    payload = { query, source?, page?, limit? }
	//             source 缺省 = searchMusic 跨源聚合（返回按源分组的数组）
	//   boards    payload = { source }                       -> getBoards()
	//   boardlist payload = { source, bangid|id, page? }     -> getList(bangid, page)
	//     注：kg/tx/wy/mg 的 getList 吃 bangid；kw 榜单上游 wbd 签名已失效（搜索不受影响）
	const SDK_ACTIONS = { search: 1, boards: 1, boardlist: 1, songlist: 1, songlistdetail: 1, songlistbytag: 1, songlistsorts: 1, songlisttags: 1 };
	// 0.11.43：这个分支同时服务「fork 单次」与「常驻 worker」两种形态。
	// 动机：设备是 i386（Atom 级），每个请求 fork 一个 qjs 再解析 ~700KB bundle ≈ 0.5s；
	// 而歌单下钻一次要问好几层（平台/排序/分类/列表/曲目），这笔固定开销被放大数倍。
	// 常驻后 bundle 只解析一次（Helper 侧用 source=$SDK 起一个 worker，argv[1] 就是它）。
	const isSdkWorker = (action === 'serve') && /sdk\.bundle\.js$/.test(String(sourcePath || ''));
	if (SDK_ACTIONS[action] || isSdkWorker) {
		let payload = {};
		try { payload = JSON.parse(infoJson || '{}') || {} } catch (e) {}
		if (payload && payload.info && typeof payload.info === 'object') payload = payload.info;
		print('LOG sdk mode=' + action + ' payload=' + JSON.stringify(payload).slice(0, 200));
		// navigator polyfill：kg infSign 模块加载期读 navigator.userAgent（KGBrowser 检测）。
		// node harness（node24 自带 navigator）是已验证基线，值贴 node 避免走进未测分支。
		if (typeof globalThis.navigator === 'undefined') {
			globalThis.navigator = { userAgent: 'Node.js/24', platform: 'linux', language: 'zh-CN' };
		}
		// ---- __lxBinHttp：sdk bundle 的 HTTP 实体（字节精确，curl 落临时文件）----
		// fetch(url, {method, headers, body:Uint8Array|null, timeout:ms})
		//   -> {statusCode, headers, bytes:Uint8Array}；失败 throw Error(.code)
		const bridgeTmpBase = (os.getenv && os.getenv('LX_TMP') || '/tmp') + '/lxh_' + Date.now() + '_' + Math.floor(Math.random() * 1e6);
		function curlHeaderName(line, name) {
			const m = line.match(new RegExp('^' + name + '\\s*:\\s*(.*)$', 'i'));
			return m ? m[1].trim() : null;
		}
		function readBinFile(path) {
			const f = std.open(path, 'rb');
			if (!f) throw new Error('binHttp: cannot open ' + path);
			const chunks = [];
			const buf = new Uint8Array(65536);
			for (;;) {
				const n = f.read(buf.buffer, 0, buf.length);
				if (n <= 0) break;
				chunks.push(buf.slice(0, n));
				if (n < buf.length) break;
			}
			f.close();
			let total = 0;
			for (const c of chunks) total += c.length;
			const out = new Uint8Array(total);
			let off = 0;
			for (const c of chunks) { out.set(c, off); off += c.length; }
			return out;
		}
		function writeBinFile(path, bytes) {
			const f = std.open(path, 'wb');
			if (!f) throw new Error('binHttp: cannot write ' + path);
			// bellard FILE.write 只收 ArrayBuffer(offset,length)，不收字符串！
			f.write(bytes.buffer, bytes.byteOffset, bytes.length);
			f.close();
		}
		function bytesToLatin1(b) {
			let s = '';
			for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
			return s;
		}
		// ---- 平台级失败短路（0.11.82）----
		// 现场（2026-09-24 设备实测）：mg 的搜索 API `jadeite.migu.cn` 不可达
		//   （本机 TLS 握手超时、设备侧 `curl exit=28` after 3002ms），而 SDK 的 mg 搜索
		//   **会重试 3 次**（`musicSdk/mg/utils/index.js:9-26`，`retryNum > 2` 才抛），
		//   每次都要吃满下面那个 3s 硬帽 ⇒ **每次歌单/歌曲搜索白等 3×3=9s**（实测首屏 4.5~12.4s 波动全由它造成，
		//   同期 kg 316ms / tx 702ms / wy 333ms）。
		// 这里按**精确主机名**记"连续失败"：达到阈值就开闸，其后 60s 内该主机的请求**直接失败、不再起 curl**。
		// ⚠️ 必须用精确主机名，**不能用 `migu.cn` 后缀**：mg 的音频 CDN（`freetyst.nf.migu.cn`，实测 200/0.09s）
		//    与图床（`d.musicapp.migu.cn`，200/0.13s）都是好的，用后缀会把它们一起短路（那才会真的"点了没声"）。
		// 安全阀：3 次失败才开闸（一次完整请求的 3 次重试刚好够触发）、失败计数超过 90s 就重新计、
		// 闸只关 60s ⇒ 最坏情况下一个"刚连续失败 3 次"的主机被快速失败 1 分钟，其余一切照旧。
		const HOST_BREAK = new Map();          // host -> { n, last, until }
		const HOST_BREAK_LIMIT = 3;            // 连续失败阈值
		const HOST_BREAK_WINDOW = 90 * 1000;   // 失败计数窗口
		const HOST_BREAK_MS = 60 * 1000;       // 闸时长
		const HOST_BREAK_ON = !(os.getenv && String(os.getenv('LX_HOST_BREAKER')) === '0');

		function curlOnce(url, opts, outBin, outHdr, inBody) {
			const t0 = Date.now();
			const outErr = outHdr + '.err';
			// 桥级超时钳制（单位：秒！opts.timeout 是 ms）：UI 等不了 15s 级拖尾；
			// migu.cn 设备网络实测 ~325B/s 龟速（0.3.4 现场测量），单独 3s 快速失败
			// 上限由设置页下发（Helper 传 LX_BRIDGE_TIMEOUT），默认 7s
			const envCap = (os.getenv && Number(os.getenv('LX_BRIDGE_TIMEOUT'))) || 7;
			const baseCap = envCap >= 2 && envCap <= 30 ? envCap : 7;
			const mHost = String(url).match(/^https?:\/\/([^\/]+)/i);
			const capSec = (mHost && /migu\.cn/i.test(mHost[1])) ? Math.min(3, baseCap) : baseCap;
			const tmo = Math.min(capSec, Math.max(2, Math.ceil((opts.timeout || 15000) / 1000)));
			const hostKey = (mHost && mHost[1]) ? mHost[1].toLowerCase() : '';
			if (HOST_BREAK_ON && hostKey) {
				const bs = HOST_BREAK.get(hostKey);
				if (bs && bs.until > Date.now()) {
					print('LOG binHttp host-breaker skip ' + hostKey
						+ ' (open ' + Math.ceil((bs.until - Date.now()) / 1000) + 's left)');
					throw errCode('binHttp host breaker open: ' + hostKey, 'ETIMEDOUT');
				}
			}
			const args = ['curl', '-sS', '--compressed', '--max-time', String(tmo),
				'-o', outBin, '-D', outHdr, '--path-as-is', '--stderr', outErr];
			const hdrs = opts.headers || {};
			for (const k of Object.keys(hdrs)) {
				if (hdrs[k] == null) continue;
				args.push('-H', k + ': ' + String(hdrs[k]));
			}
			const method = String(opts.method || 'get').toLowerCase();
			if (method !== 'get' && method !== 'head') args.push('-X', method.toUpperCase());
			if (opts.body && opts.body.length) {
				writeBinFile(inBody, opts.body);
				args.push('--data-binary', '@' + inBody);
			}
			args.push(url);
			const r = os.exec(args, { block: true });
			// 设备 bellard qjs：block exec 返回纯数字退出码（quickjs-libc.c "exec -> exitcode"）；
			// 兼容对象形态（node sim stub 旧约定）
			const code = typeof r === 'number' ? r : (r ? ((r.exit_code != null) ? r.exit_code : 1) : 1);
			if (HOST_BREAK_ON && hostKey) {
				if (code === 0) {
					HOST_BREAK.delete(hostKey);            // 通了就清零
				}
				else {
					const now = Date.now();
					const bs = HOST_BREAK.get(hostKey) || { n: 0, last: 0, until: 0 };
					bs.n = (now - (bs.last || 0) > HOST_BREAK_WINDOW) ? 1 : (bs.n + 1);
					bs.last = now;
					if (bs.n >= HOST_BREAK_LIMIT) {
						bs.until = now + HOST_BREAK_MS;
						bs.n = 0;
						print('LOG binHttp host-breaker OPEN ' + hostKey + ' for ' + (HOST_BREAK_MS / 1000) + 's');
					}
					HOST_BREAK.set(hostKey, bs);
				}
			}
			if (code !== 0) {
				let errText = '';
				try { const ef = std.open(outErr, 'r'); if (ef) { for (;;) { const l = ef.getline(); if (l == null) break; errText += l + '\n'; } ef.close(); } } catch (e) {}
				print('LOG binHttp curl exit=' + code + ' url=' + String(url).slice(0, 80) + ' stderr=' + errText.slice(0, 200));
				print('LOG binHttp args=' + JSON.stringify(args).slice(0, 400));
			}
			if (code === 28) throw errCode('binHttp timeout', 'ETIMEDOUT');
			if (code === 6 || code === 7) throw errCode('binHttp connect failed', 'ENOTFOUND');
			if (code !== 0) throw errCode('binHttp curl exit ' + code, 'ECONNRESET');
			const hf = std.open(outHdr, 'r');
			const headerLines = [];
			if (hf) {
				for (;;) {
					const line = hf.getline();
					if (line === undefined || line === null) break;
					headerLines.push(line.replace(/\r$/, ''));
				}
				hf.close();
			}
			let statusCode = 0;
			for (const line of headerLines) {
				const m = line.match(/^HTTP\/[\d.]+\s+(\d{3})/);
				if (m) statusCode = Number(m[1]);
			}
			const headers = {};
			for (const line of headerLines) {
				const c = line.indexOf(':');
				if (c > 0) headers[line.slice(0, c).trim().toLowerCase()] = line.slice(c + 1).trim();
			}
			const bytes = readBinFile(outBin);
			// 带耗时：设备是 i386，要分清"慢在上游"还是"慢在本机解析"
			print('LOG binHttp ' + statusCode + ' ' + bytes.length + 'B ' + (Date.now() - t0) + 'ms '
				+ String(url).slice(0, 70));
			return { statusCode, headers, bytes };
		}
		function errCode(msg, code) {
			const e = new Error(msg);
			e.code = code;
			return e;
		}
		globalThis.__lxBinHttp = {
			fetch(url, opts) {
				const outBin = bridgeTmpBase + '.bin';
				const outHdr = bridgeTmpBase + '.hdr';
				const inBody = bridgeTmpBase + '.in';
				try {
					let cur = String(url);
					for (let hop = 0; hop < 3; hop++) {
						const r = curlOnce(cur, opts || {}, outBin, outHdr, inBody);
						if (r.statusCode >= 300 && r.statusCode < 400 && r.headers['location']) {
							const loc = r.headers['location'];
							const origin = (cur.match(/^https?:\/\/[^/]+/i) || ['']);
							cur = /^https?:\/\//i.test(loc) ? loc : (loc.charAt(0) === '/' ? origin[0] + loc : cur.slice(0, cur.lastIndexOf('/') + 1) + loc);
							continue;
						}
						return r;
					}
					throw errCode('too many redirects (>3)', 'ETOOMANYREDIRECTS');
				}
				finally {
					try { os.remove(outBin); } catch (e) {}
					try { os.remove(outHdr); } catch (e) {}
					try { os.remove(outHdr + '.err'); } catch (e) {}
					try { os.remove(inBody); } catch (e) {}
				}
			},
		};
		try {
			std.loadScript(sourcePath);
		} catch (e) {
			print('RESULT ' + JSON.stringify({ ok: false, error: 'sdk bundle load failed: ' + String((e && e.message) || e) }));
			std.exit(1);
		}
		const sdk = globalThis.__LXSDK;
		if (!sdk) {
			print('RESULT ' + JSON.stringify({ ok: false, error: 'sdk bundle did not expose __LXSDK' }));
			std.exit(1);
		}
		// ---- kg 歌单详情「快路径」（0.11.46）----
		// 起因：用户问"榜单加载挺快，歌单能参考它吗"。答案是能——榜单走的是一次精简 JSON
		// （leaderboard.getList，100 首/页），而 kg 的歌单详情在 SDK 里是**两步重活**：
		//   ① 抓 371KB 的 special/single HTML 再正则抠 JSON  ② 再打一次 574KB 的音频信息接口
		// 设备是 i386（Atom 级）：本机 qjs 只需 ~0.27s 的解析，在设备上要 2~3s。
		// mobilecdn 的 special/song 是同一份数据的**精简 JSON**（可 pagesize 分页，
		// 字段足够还原 SDK 的曲目对象形状），实测 42KB/0.14s（100 首）。
		// 任何一步失败都**回落到 SDK 原路径**，行为不变。
		function __sizeFmt(size) {
			if (!size) return '0 B';
			const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
			const n = Math.floor(Math.log(size) / Math.log(1024));
			return (size / Math.pow(1024, Math.floor(n))).toFixed(2) + ' ' + units[n];
		}
		function __fmtTime(secs) {
			const m = Math.trunc(secs / 60), s2 = Math.trunc(secs % 60);
			const p = (x) => (x < 10 ? '0' + x : String(x));
			return (m == 0 && s2 == 0) ? '--/--' : p(m) + ':' + p(s2);
		}
		async function kgLeanDetail(rawId, page) {
			const id = String(rawId).replace(/^id_/, '').replace(/.*special\/single\//, '');
			if (!/^\d+$/.test(id)) throw new Error('lean: not a numeric special id');
			const pagesize = 100;
			const base = 'http://mobilecdn.kugou.com/api/v3/special';
			const get = async (u) => {
				const r = await globalThis.__lxBinHttp.fetch(u, { timeout: 15000 });
				if (r.statusCode !== 200) throw new Error('lean http ' + r.statusCode);
				// ⚠️ 必须 utf8Decode：latin1 拿字节会让中文名整片乱码（0.11.46 本地 A/B 现场）
				return JSON.parse(utf8Decode(r.bytes));
			};
			const body = await get(base + '/song?specialid=' + id + '&page=' + page
				+ '&pagesize=' + pagesize + '&version=9108');
			if (!body || body.status !== 1 || !body.data) throw new Error('lean: bad song body');
			const raw = body.data.info || [];
			const list = raw.map((it) => {
				const types = [], _types = {};
				if (it.filesize) { const s = __sizeFmt(it.filesize); types.push({ type: '128k', size: s, hash: it.hash }); _types['128k'] = { size: s, hash: it.hash }; }
				if (it['320filesize']) { const s = __sizeFmt(it['320filesize']); types.push({ type: '320k', size: s, hash: it['320hash'] }); _types['320k'] = { size: s, hash: it['320hash'] }; }
				if (it['sqfilesize']) { const s = __sizeFmt(it['sqfilesize']); types.push({ type: 'flac', size: s, hash: it.sqhash }); _types.flac = { size: s, hash: it.sqhash }; }
				const fn = String(it.filename || '');
				const dash = fn.indexOf(' - ');
				const singer = dash > 0 ? fn.slice(0, dash) : '';
				const name = dash > 0 ? fn.slice(dash + 3) : fn;
				let secs = Number(it.duration) || 0;
				if (secs > 10000) secs = Math.round(secs / 1000);   // 兼容秒/毫秒两种口径
				return {
					singer, name, albumName: '',
					// id 统一成字符串：SDK 路径给的就是字符串，订阅源里按字符串处理
					albumId: String(it.album_id != null ? it.album_id : ''),
					songmid: String(it.audio_id != null ? it.audio_id : ''),
					albumAudioId: String(it.album_audio_id != null ? it.album_audio_id : ''),
					source: 'kg', interval: __fmtTime(secs), img: null, lrc: null,
					hash: it.hash, types, _types, typeUrl: {},
				};
			});
			const total = Number(body.data.total) || list.length;
			let meta = {};
			try {
				const mi = await get(base + '/info?specialid=' + id + '&version=9108');
				meta = (mi && mi.data) || {};
			} catch (e) { /* 封面/名字拿不到不影响曲目 */ }
			return {
				list, page, limit: pagesize, total, source: 'kg',
				info: {
					name: meta.specialname || '', author: meta.nickname || '',
					img: meta.imgurl ? String(meta.imgurl).replace('{size}', '240') : '',
					count: total,
				},
			};
		}

		// 0.11.43：参数化（从前闭包吃外层的 action/payload，常驻 worker 一进程要服务多个请求）
		const runSdk = async (act, argPayload) => {
			const action = act;
			const payload = argPayload || {};
			if (action === 'search') {
				const q = String(payload.query || payload.name || '');
				const page = Number(payload.page) || 1;
				const limit = Number(payload.limit) || 30;
				if (!q) throw new Error('search: query required');
				const src = payload.source || payload.src;
				if (src) {
					const mod = sdk[src] && sdk[src].musicSearch;
					if (!mod) throw new Error('sdk: no musicSearch for source ' + src);
					return await mod.search(q, page, limit);
				}
				return await sdk.searchMusic({ name: q, limit });
			}
			if (action === 'songlist') {
				// 歌单搜索：跨源聚合（kw/kg/tx/wy/mg 各自 songList.search）
				// 0.11.78：每平台默认条数 8 → 20，并把 page 透传（调用方现在会按窗口要第 N 页）。
				// 起因见 Plugin.pm 的注释：与 PC 版实测对照后，插件从"只看每源 8 条第 1 页"
				// 改成 PC 口径（每平台 20 条 + 原生翻页）。
				const q = String(payload.query || payload.name || '');
				if (!q) throw new Error('songlist: query required');
				const page = Number(payload.page) || 1;
				const perSrc = Number(payload.limit) || 20;
				// 0.11.78：支持**只要某一个平台**（`payload.source`）。
				// 插件的虚拟列表是"平台优先拼接"，一次窗口往往只用到 1~2 个平台；
				// 没有这个过滤，取 kg 的第 3 页会把 tx/wy/mg/kw 的第 3 页一起打一遍（4/5 是白打）。
				const only = payload.source || payload.src || '';
				const SL_SOURCES = only ? [String(only)] : ['kg', 'tx', 'wy', 'mg', 'kw'];
				const tasks = SL_SOURCES.map(s => {
					const sl = sdk[s] && sdk[s].songList;
					if (!sl || !sl.search) return Promise.resolve(null);
					return sl.search(q, page, perSrc).then(r => {
						if (!r || !r.list || !r.list.length) return null;
						return { source: s, page, list: r.list.slice(0, perSrc), total: r.total };
					}).catch(() => null);
				});
				const groups = (await Promise.all(tasks)).filter(g => g);
				return groups;
			}
			if (action === 'songlistsorts') {
				// 该平台的排序 tab（PC 端 SortTab 的数据源）：songList.sortList 是客户端硬编码的静态数组
				const src = payload.source || payload.src;
				const sl = sdk[src] && sdk[src].songList;
				if (!sl) throw new Error('songlistsorts: no songList for source ' + src);
				const sorts = (sl.sortList || []).map(s => ({ id: String(s.id), name: String(s.name || s.id) }));
				return { source: src, sorts };
			}
			if (action === 'songlisttags') {
				// 该平台的分类标签（PC 端 TagList 的数据源）：getTags() 运行时打平台 API
				// 返回形状各平台一致：{ tags: [{name, list:[{id,name}]}], hotTag: [{id,name}] }
				// ⚠️ id 形状不同源不同（kw "<id>-<digest>" / kg,tx,mg 数字 / **wy 是中文分类名**），原样透传
				const src = payload.source || payload.src;
				const sl = sdk[src] && sdk[src].songList;
				if (!sl || !sl.getTags) throw new Error('songlisttags: no getTags for source ' + src);
				const t = (await sl.getTags()) || {};
				const normGroup = g => ({
					name: String((g && g.name) || ''),
					list: (((g && g.list) || []).map(i => ({ id: String(i.id), name: String(i.name || '') }))),
				});
				const hot = (((t.hotTag) || []).map(i => ({ id: String(i.id), name: String(i.name || '') })));
				return { source: src, tags: ((t.tags) || []).map(normGroup), hotTag: hot };
			}
			if (action === 'songlistbytag') {
				// 某平台某排序某分类的歌单列表：sortId 取自该平台 sortList，tagId 取自 getTags()
				// （''=全部）。0.11.36 起 sortId/tagId 都由调用方显式给，不再有插件自造的档位映射。
				const src = payload.source || payload.src;
				const sl = sdk[src] && sdk[src].songList;
				if (!sl || !sl.getList) throw new Error('songlistbytag: no songList for source ' + src);
				const sortId = payload.sortId != null ? payload.sortId : '';
				const tagId = payload.tagId != null ? payload.tagId : '';
				return await sl.getList(sortId, tagId, Number(payload.page) || 1);
			}
			if (action === 'songlistdetail') {
				// 歌单详情：统一 getListDetail(id, page)，tx 内部自带 getListDetail2 兜底
				const src = payload.source || payload.src;
				const sl = sdk[src] && sdk[src].songList;
				if (!sl || !sl.getListDetail) throw new Error('songlistdetail: no songList for source ' + src);
				const id = String(payload.id != null ? payload.id : (payload.listid || ''));
				if (!id) throw new Error('songlistdetail: id required');
				const page = Number(payload.page) || 1;
				// kg 快路径（0.11.46）：见 kgLeanDetail 注释；`lean:0` 可强制走 SDK 做 A/B
				if (src === 'kg' && payload.lean !== 0 && payload.lean !== false) {
					try {
						return await kgLeanDetail(id, page);
					}
					catch (e) {
						print('LOG kg lean failed, fallback to sdk: ' + String((e && e.message) || e));
					}
				}
				return await sl.getListDetail(id, page);
			}
			const mod = sdk[payload.source] && sdk[payload.source].leaderboard;
			if (!mod) throw new Error('sdk: no leaderboard for source ' + payload.source);
			if (action === 'boards') return await mod.getBoards();
			const bangid = String(payload.bangid != null && payload.bangid !== '' ? payload.bangid : (payload.id || ''));
			if (!bangid) throw new Error('boardlist: bangid required');
			return await mod.getList(bangid, Number(payload.page) || 1);
		};
		// ---- 常驻 worker 形态：bundle 已加载，按行协议服务（READY / RESULT <id> {json} / LOG）----
		if (isSdkWorker) {
			print('READY ' + JSON.stringify({ name: 'sdk', version: '' }));
			std.out.flush();
			for (;;) {
				const line = std.in.getline();
				if (line === null || line === undefined) break;      // stdin 关闭 → 退出
				const t = String(line).trim();
				if (!t) continue;
				let req;
				try { req = JSON.parse(t); }
				catch (e) { print('RESULT 0 ' + JSON.stringify({ ok: false, error: 'bad request json' })); continue; }
				const rid = req.id != null ? req.id : 0;
				const t0w = Date.now();
				try {
					const r = await runSdk(req.action || '', req.info || {});
					print('RESULT ' + rid + ' ' + JSON.stringify({ ok: true, data: r == null ? null : r, ms: Date.now() - t0w }));
				}
				catch (e) {
					const o = JSON.parse(fmtErr(e));
					o.ms = Date.now() - t0w;
					print('RESULT ' + rid + ' ' + JSON.stringify(o));
				}
				std.out.flush();
			}
			print('LOG sdk worker: stdin closed, exiting');
			std.exit(0);
		}

		runSdk(action, payload).then(r => {
			const s = JSON.stringify({ ok: true, data: r == null ? null : r });
			print('LOG sdk stringify len=' + s.length);
			print('RESULT ' + s);
			std.out.flush();
			std.exit(0);
		}).catch(e => {
			print('RESULT ' + JSON.stringify({ ok: false, error: String((e && e.message) || e) }));
			std.out.flush();
			std.exit(1);
		});
		print('LOG sdk chain armed');
		return;   // 主流程结束，qjs 排空微任务后 .then 打 RESULT
	}

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
		rawScript: sourceCode,
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
		try { print('LOG srcmd5=' + md5Hex(sourceCode) + ' len=' + sourceCode.length); } catch (e) {}
	print('LOG e3 loadScript ok, handlers: ' + JSON.stringify(Object.keys(handlers)));
	} catch (e) {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'source load failed: ' + String((e && e.message) || e) }));
		std.exit(1);
	}

	// 源脚本加载后先驱动其异步初始化（desktop 宿主是常驻进程，inited 之后
	// handler 才可用；qjs 一次性进程必须手动泵定时器/微任务到 inited）
	// 注意：rconfig 200 的回调在 promise 微任务里注册 handler——必须先 drain
	// 再判 handler；drain 内部用 await 让出栈，否则微任务在 qjs 顶层不执行。
	await drainUntilInited();

	if (typeof handlers[EVENT_NAMES.request] !== 'function') {
		print('RESULT ' + JSON.stringify({ ok: false, error: 'source did not register request handler' }));
		std.exit(1);
	}

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
	// ---------- 请求执行器（单次 fork 与常驻 worker 共用）----------
	async function callHandler(act, argInfo, srcName) {
		const h = handlers[EVENT_NAMES.request];
		if (typeof h !== 'function') throw new Error('source did not register request handler');
		print('LOG h0 calling handler, action=' + act
			+ ' args=' + JSON.stringify({ source: srcName || '', action: act, info: argInfo }).slice(0, 300));
		let done = false, val, err;
		try {
			const ret = h({ source: srcName || '', action: act, info: argInfo });
			print('LOG h1 ret=' + (ret && ret.then ? 'promise' : typeof ret) + ' fnParams=' + h.length);
			Promise.resolve(ret).then(x => { val = x; done = true; }, e => { err = e; done = true; });
		} catch (e) {
			// 同步抛：把源自己的堆栈带出来（"not a function" 只有栈能定位到源的第几行）
			const stk = String((e && e.stack) || '').replace(/\s+/g, ' ').slice(0, 500);
			print('LOG handler throw stack: ' + stk);
			const ne = new Error('handler sync throw: ' + String((e && e.message) || e));
			ne.lxStack = stk;
			throw ne;
		}
		// 看门狗：promise 不 settle 时显式报错（不能让宿主静默退出）
		let wd = 0;
		while (!done && wd < 3000) {
			wd++;
			const batch = __timers.splice(0, __timers.length);
			for (const t of batch) {
				try { t.fn.apply(null, t.args); }
				catch (e) { print('LOG timer ERR: ' + String((e && e.message) || e)); }
			}
			if (wd % 200 === 0) print('LOG watchdog: rounds=' + wd + ' pendingTimers=' + __timers.length);
			await null;
		}
		if (!done) {
			throw new Error('source handler promise never settled (watchdog ' + wd + ' rounds, pendingTimers='
				+ __timers.length + '; source awaits something that never resolves)');
		}
		if (err) throw err;
		print('LOG t1 type=' + typeof val + ' keys=' + (val && typeof val === 'object' ? Object.keys(val).join(',') : '-'));
		return val;
	}

	function fmtErr(e) {
		const o = { ok: false, error: String((e && e.message) || e) };
		const stk = (e && e.lxStack) || String((e && e.stack) || '').replace(/\s+/g, ' ').slice(0, 400);
		if (stk) o.stack = stk;
		return JSON.stringify(o);
	}

	// ---------- 常驻 worker（M0.10）：源脚本加载 + 初始化只付一次，之后按行协议处理请求 ----------
	// stdin 一行 = {"id":N,"action":"musicUrl","source":"kw","info":{...}}
	// stdout 一行 = READY {...} | RESULT <id> {json} | LOG ...
	if (action === 'serve') {
		const info0 = globalThis.lx.currentScriptInfo || {};
		// 0.11.58：READY 带上源声明的能力表（此时 `drainUntilInited()` 已跑完 ⇒ __caps 就绪）
		print('READY ' + JSON.stringify({ name: info0.name || '', version: info0.version || '', caps: __caps }));
		std.out.flush();
		for (;;) {
			const line = std.in.getline();
			if (line === null || line === undefined) break;      // stdin 关闭 → 退出
			const t = String(line).trim();
			if (!t) continue;
			let req;
			try { req = JSON.parse(t); }
			catch (e) { print('RESULT 0 ' + JSON.stringify({ ok: false, error: 'bad request json' })); continue; }
			const id = req.id != null ? req.id : 0;
			const act = req.action || 'musicUrl';
			const t0 = Date.now();
			try {
				const r = await callHandler(act, req.info || {}, req.source || '');
				print('RESULT ' + id + ' ' + JSON.stringify({ ok: true, data: r == null ? null : r, ms: Date.now() - t0 }));
			}
			catch (e) {
				const o = JSON.parse(fmtErr(e));
				o.ms = Date.now() - t0;
				print('RESULT ' + id + ' ' + JSON.stringify(o));
			}
		}
		print('LOG serve: stdin closed, exiting');
		std.exit(0);
	}

	// ---------- 单次模式（fork 每请求一进程）：与 serve 等价的执行流程，跑完即退 ----------
	try {
		const r = await callHandler(action, infoArg, source);
		print('RESULT ' + JSON.stringify({ ok: true, data: r == null ? null : r }));
	}
	catch (e) {
		print('RESULT ' + fmtErr(e));
	}
	std.out.flush();
	std.exit(0);
}
