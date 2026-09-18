// test-source.js — shim 冒烟测试用假源脚本（CI 用）
// 验证点：md5 正确性 / urlGet→301 跟随 / Promise 驱动 / RESULT 行协议
lx.on(lx.EVENT_NAMES.request, ({ action, info }) => {
	if (action === 'ping') {
		return Promise.resolve({
			pong: true,
			md5abc: lx.utils.crypto.md5('abc'),
			b64: lx.utils.buffer.bufToString(lx.utils.buffer.from('hello'), 'base64'),
			hex: lx.utils.buffer.bufToString(lx.utils.buffer.from('hi'), 'hex'),
			ver: lx.version,
			env: lx.env,
			name: lx.currentScriptInfo.name,
		});
	}
	if (action === 'http') {
		return new Promise((resolve, reject) => {
			// http→https 301：验证 shim 手动跟随（follow_max 同款语义）
			lx.request('http://github.com/', { timeout: 15 }, (err, body, status, headers) => {
				if (err) return reject(new Error('http err: ' + err));
				resolve({ status, len: String(body).length, ok200: status === 200 });
			});
		});
	}
	throw new Error('unknown action: ' + action);
});
lx.send(lx.EVENT_NAMES.inited, { sources: ['kw'] });
