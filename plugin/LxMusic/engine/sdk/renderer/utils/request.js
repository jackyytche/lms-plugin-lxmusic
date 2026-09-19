// vendored replacement for lx-music-desktop src/renderer/utils/request.js
// 契约对齐 needle 实现（httpFetch → {promise, cancelHttp}；promise resolve
// {statusCode, headers, raw, body}，body = raw.toString() 后尽力 JSON.parse）。
// HTTP 实体走宿主桥 globalThis.__lxBinHttp.fetch（同步、字节精确、手动 3 跳跟随）：
//   fetch(url, {method, headers, body:Uint8Array|null, timeout:ms})
//     -> {statusCode, headers, bytes:Uint8Array}   失败 throw Error(.code)
import { requestMsg } from './message'
import { bHh } from './musicSdk/options'

const defaultHeaders = {
	'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
}

const toQueryString = form => Object.keys(form).map(k => `${encodeURIComponent(k)}=${encodeURIComponent(form[k])}`).join('&')

const toBytes = d => {
	if (d instanceof Uint8Array) return d
	if (typeof d === 'string') return new TextEncoder().encode(d)
	return new TextEncoder().encode(JSON.stringify(d))
}

const request = (url, options, callback) => {
	const bin = globalThis.__lxBinHttp
	if (!bin || typeof bin.fetch !== 'function') {
		callback(new Error('__lxBinHttp bridge missing'), null)
		return null
	}
	const headers = Object.assign({}, defaultHeaders, options.headers || {})
	if (headers[bHh] != null) delete headers[bHh] // l2a 同款：bHh 隐藏头不实现（仅影响 kw 官方源取链空壳）
	let bodyBytes = null
	if (options.body != null) {
		headers['Content-Type'] = headers['Content-Type'] || (typeof options.body === 'object' && !(options.body instanceof Uint8Array) ? 'application/json' : 'text/plain')
		bodyBytes = toBytes(options.body)
	} else if (options.form != null) {
		headers['Content-Type'] = headers['Content-Type'] || 'application/x-www-form-urlencoded'
		bodyBytes = toBytes(typeof options.form === 'string' ? options.form : toQueryString(options.form))
	}
	try {
		const r = bin.fetch(String(url), {
			method: options.method || 'get',
			headers,
			body: bodyBytes,
			timeout: options.timeout || 15000,
		})
		const raw = new globalThis.Buffer(r.bytes == null ? [] : r.bytes)
		let body
		try {
			body = raw.toString()
			body = JSON.parse(body)
		} catch (_) {
			body = raw.toString()
		}
		const resp = { statusCode: r.statusCode, headers: r.headers || {}, raw, body }
		callback(null, resp, body)
	} catch (e) {
		callback(e instanceof Error ? e : new Error(String((e && e.message) || e)), null)
	}
	return null
}

export const cancelHttp = () => {} // 同步 fetch 不可中断，形状兼容即可

export const httpFetch = (url, options = { method: 'get' }) => {
	const obj = {
		isCancelled: false,
		cancelHttp: () => {
			obj.isCancelled = true
			obj.promise = obj.cancelHttp = null
		},
	}
	obj.promise = new Promise((resolve, reject) => {
		request(url, options, (err, resp) => {
			if (err) {
				let e = err instanceof Error ? err : new Error(String((err && err.message) || err))
				const code = e.code || ''
				if (code === 'ETIMEDOUT' || code === 'ESOCKETTIMEDOUT' || /timeout/i.test(e.message || '')) {
					e = new Error(requestMsg.timeout)
				} else if (code === 'ENOTFOUND' || code === 'ECONNREFUSED' || code === 'ECONNRESET') {
					e = new Error(requestMsg.notConnectNetwork)
				}
				return reject(e)
			}
			resolve(resp)
		})
	})
	return obj
}
