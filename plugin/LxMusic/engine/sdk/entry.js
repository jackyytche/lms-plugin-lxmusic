// sdk bundle entry — esbuild --format=iife
// 产出挂载 globalThis.__LXSDK（= desktop musicSdk/index.js default export）。
// 宿主需先注入：globalThis.Buffer、TextEncoder、console、setTimeout，以及
// globalThis.__lxBinHttp.fetch(url, {method, headers, body, timeout}) 同步字节 HTTP。
import musicSdk from './renderer/utils/musicSdk/index.js'

globalThis.__LXSDK = musicSdk
