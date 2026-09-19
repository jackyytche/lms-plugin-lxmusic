// vendored replacement for `@renderer/store` (pinia stores in desktop)
// api-source.js 顶层只读 supportQuality 表；apis() 仅在官方源取链（OSS 空壳）路径被调用。
// apiSource 固定 'kw' → getAPI 返回 undefined → apis() 抛 'Api is not found'，与 desktop OSS 版行为一致。
export const apiSource = { value: 'kw' }
export const userApi = { apis: {} }
export const proxy = { enable: false, host: '', port: '', envProxy: null }
