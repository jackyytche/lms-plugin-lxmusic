// test-source.js — shim 冒烟测试用假源脚本（CI 用）
// 验证点：md5 正确性 / lx.request→curl 桥 / Promise 驱动 / RESULT 行协议
lx.on(lx.EVENT_NAMES.request, ({ action, info }) => {
	if (action === 'ping') {
		return Promise.resolve({
			pong: true,
			md5abc: lx.utils.crypto.md5('abc'),
			b64: lx.utils.buffer.bufToString(lx.utils.buffer.from('hello'), 'base64'),
			ver: lx.version,
			env: lx.env,
			name: lx.currentScriptInfo.name,
		});
	}
	if (action === 'http') {
		return new Promise((resolve, reject) => {
			lx.request('https://example.com/', { timeout: 15 }, (err, body, status, headers) => {
				if (err) return reject(new Error('http err: ' + err));
				resolve({ status, len: String(body).length, ct: headers['content-type'] || '' });
			});
		});
	}
	throw new Error('unknown action: ' + action);
});
lx.send(lx.EVENT_NAMES.inited, { sources: ['kw'] });
