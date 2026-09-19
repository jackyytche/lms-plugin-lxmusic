// node:dns replacement — musicSdk/utils.js getHostIp 仅做异步预取缓存（消费方 api-test 已裁剪）。
// 空实现即可：lookup 以错误回调结束，getHostIp 静默走 console.log(err) 分支。
export function lookup(hostname, options, callback) {
	if (typeof options === 'function') { callback = options; options = {} }
	if (typeof callback === 'function') {
		const err = new Error('node-dns shim: dns disabled')
		setTimeout(() => callback(err), 0)
	}
}

export const resolve = (hostname, callback) => {
	if (typeof callback === 'function') setTimeout(() => callback(new Error('node-dns shim: dns disabled')), 0)
}

export default { lookup, resolve }
