// vendored replacement for lx-music-desktop src/renderer/utils/index.ts
// (also serves the `@renderer/utils` alias via directory index resolution)
// 仅保留 musicSdk 实际消费的纯 JS 面；decodeName 以 HTML 实体表近似 DOMParser 语义。
export const decodeName = (str = '') => {
	if (!str) return ''
	return String(str)
		.replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
		.replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(parseInt(d, 10)))
		.replace(/&([a-zA-Z][a-zA-Z0-9]*);/g, (m, name) => {
			const ent = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' }
			return Object.prototype.hasOwnProperty.call(ent, name) ? ent[name] : m
		})
}

export const sizeFormate = (size) => {
	if (!size) return '0 B'
	const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
	const number = Math.floor(Math.log(size) / Math.log(1024))
	return `${(size / Math.pow(1024, Math.floor(number))).toFixed(2)} ${units[number]}`
}

export const formatPlayCount = (num) => {
	if (num > 100000000) return `${Math.trunc(num / 10000000) / 10}亿`
	if (num > 10000) return `${Math.trunc(num / 1000) / 10}万`
	return String(num)
}

const toDateObj = (date) => {
	if (!date) return ''
	switch (typeof date) {
		case 'string':
			if (!date.includes('T')) date = date.split('.')[0].replace(/-/g, '/')
		// eslint-disable-next-line no-fallthrough
		case 'number':
			date = new Date(date)
		// eslint-disable-next-line no-fallthrough
		case 'object':
			break
		default: return ''
	}
	return date
}

const numFix = (n) => n < 10 ? (`0${n}`) : n.toString()

export const dateFormat = (_date, format = 'Y-M-D h:m:s') => {
	const date = toDateObj(_date)
	if (!date) return ''
	return format
		.replace('Y', date.getFullYear().toString())
		.replace('M', numFix(date.getMonth() + 1))
		.replace('D', numFix(date.getDate()))
		.replace('h', numFix(date.getHours()))
		.replace('m', numFix(date.getMinutes()))
		.replace('s', numFix(date.getSeconds()))
}

export const formatPlayTime = (time) => {
	const m = Math.trunc(time / 60)
	const s = Math.trunc(time % 60)
	return m == 0 && s == 0 ? '--/--' : numFix(m) + ':' + numFix(s)
}

export const formatPlayTime2 = (time) => {
	const m = Math.trunc(time / 60)
	const s = Math.trunc(time % 60)
	return numFix(m) + ':' + numFix(s)
}

// desktop 版依赖 window.i18n；消费方（comment 模块）已被裁剪，这里仅留纯格式化兜底
export const dateFormat2 = (time) => dateFormat(time)
