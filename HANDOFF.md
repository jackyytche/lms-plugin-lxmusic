# HANDOFF — lx-music Daphile 插件开发快照

## 当前状态（2026-09-18）

**v0.1.0-alpha2 已发布（alpha1 的 Run-test 转圈 = 达菲主循环不驱动 AnyEvent，已换 Slim::Utils::Timers 轮询修复）** —— M0.1 设备验证的全部软件侧工作就绪。

- Release: https://github.com/jackyytche/lms-plugin-lxmusic/releases/tag/v0.1.0-alpha1
  - `LxMusic.zip`（1,134,864 B, SHA1 `a77f4c4163e6c6d77725d64fdaa2b3e6856d945f`）
  - `repo.xml`（锚定本版 tag URL，勿用 /releases/latest —— 被引擎 release 占住）
- CI：run 22 全绿（Helper 回归 + 全模块 perl -c 语法检查）
- LAN 通道：`dist/`（repo.xml + LxMusic.zip）+ 开发机 8765 http.server

## alpha1 内容

- `lxm://m/<b64url(musicInfo)>?s=<src>&t=<quality>&n=<name>` 协议（ProtocolHandler.pm）：
  播放时经 Helper→qjs→订阅源取真实直链，canTranscodeSeek=1（达菲 seek 修正），
  内存元数据缓存（标题/音质如实显示）。
- Web 页 `plugins/LxMusic/index.html`：订阅导入（粘贴/URL，服务器端 curl 拉取）、
  状态显示、songmid 取链测试（异步回调重渲染）。
- 菜单（XMLBrowser）：播放测试（输入 kw 数字歌曲 ID → lxm:// 音频项）+ 源状态行。
- prefs：sourceContent/sourceName/quality(320k)；重启自动恢复源到 tmpfs。
- Helper.pm 增 `currentSourcePath`/`sourceInfo`；installSource 额外写 `sources/current.js`。

## M0.1 设备验证步骤（用户操作）

1. （推荐 LAN 通道）达菲 Web → 设置 → 插件 → 第三方仓库：
   添加 `http://192.168.2.68:8765/repo.xml` → 安装「LX Music / 洛雪音乐」。
   （GitHub 通道：`.../releases/download/v0.1.0-alpha1/repo.xml`，达菲根路径机制未在 release URL 上实证。）
2. 浏览器开 `http://<daphile>:9000/plugins/LxMusic/index.html`：
   - 导入订阅源：粘贴 `refs/samples/lx-music-source-v6-fixed.js` 全文（或其 LAN URL）
   - 播放测试输入 `228908`（酷我《晴天》周杰伦，已实测存在的 ID）→ 期望显示真实直链
3. 菜单（音乐服务 → 洛雪音乐）→ 播放测试 → 输入 `228908` → 点击播放 → 听声。
4. 顺带观察：server.log 里 shim 报错若出现 `curl: not found` → M0.1b 需要 busybox 回退。

## 本轮关键勘误（重要，长期有效）

1. **perl -c 语义**：`-c` 不执行目标文件任何代码；但 `use X`（BEGIN-require）会
   **编译并执行 X 的顶层**。因此「-c 主文件」绿灯 ≠ 依赖方视角绿灯：
   ProtocolHandler 顶层的 `registerHandler` 只在 Plugin.pm 的 use 链上触发。
   诊断时必须 `use` 链视角跑全量。
2. **非 ASCII 源码风险**：EM DASH（U+2014）等混入 strict 源码曾致无输出编译死。
   alpha1 起 Plugin.pm 全 ASCII 化（无 use utf8、heredoc 全拆数组拼接、日志文案 ASCII）；
   中文界面文案走 UTF-8 字节串（页面 charset=utf-8 正确）。
3. **CI 诊断通道优先级**：jobs API 的 step 粒度红绿（最稳）> artifact 上传
   （会限流）> runs 日志下载（本会话期间持续 404）。诊断步必须独立成 step。
4. **stub 完备性**：`main::WEBUI/INFOLOG` 等 main 包常量需在 Log stub 里定义；
   `use base` 链、`Slim::Player::ProtocolHandlers` 均需显式加载。
5. **切片器教训**：代码切片诊断会丢 `my` 词法声明（%METADATA 教训）——
   切片必须携带被切组依赖的全部词法声明。
6. **本地 MSYS perl 可用**（danger-full-access 后 signal pipe 问题消失）：
   `C:\Users\jacky\AppData\Local\hermes\git\usr\bin\perl.exe` +
   `-I t_local`（t_local/JSON/XS.pm 纯 perl JSON 替身，CI 不受影响）。
   本地秒级复现 CI 编译问题，不再依赖远端轮询。
7. **kuwo 搜索 API**：`http://search.kuwo.cn/r.s?...` 返回单引号 JSON + GBK，
   用 `ast.literal_eval` 直解；`MUSICRID` 去 `MUSIC_` 前缀即 songmid。

## 下一步

- **M0.1**（用户）：按上述步骤装 alpha1 → 导入 v6 源 → 228908 取链/播放。
  失败看 server.log 的 LXMusic 行 + Web 测试页的错误/日志区。
- **M0.2**：musicSdk vendor 进 shim（聚合搜索 kw/kg/mg/tx/wy + 榜单）→
  菜单接入搜索/分类浏览（共识批次2①②）。
- **M0.3**：歌单搜索/整单播放；**M0.4**：文件上传。
- shim crypto（aes/rsa/zlib）按 v6 源运行时缺什么补什么。
- **Token 安全**：M0.1 验证通过后可撤销本 PAT（CI 重发需用户重建并更新
  本地环境变量）。
