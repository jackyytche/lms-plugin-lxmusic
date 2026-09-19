# HANDOFF — lx-music Daphile 插件（洛雪音乐）

> **下个 session 恢复方式**：直接说「继续 lx-music 插件，先读 HANDOFF.md」。
> **权威事实源**：本文档 + 磁盘（`plugin/` 源码、`repo/` 发布仓、`dist/` 打包产物、`refs/` 参考克隆、`tmp/` 工具）。
> **一句话现状**（2026-09-20 深夜）：设备运行 **0.8.3**（稳定可用）。M0.1~M0.6 已完工验收；**M0.7 两项新功能已上线**：① 多平台**聚合搜索 + 相似度重排**（PC 的归一化编辑距离算法，实测排序严格单调不增）② 播放失败**由插件立即跳下一曲**开关（`autoSkipOnError`，文案已注明 LMS 自身也会跳）。设备只保留 1 个可用源（qdy 源实测取链是死链 410，已按用户决定删除）。
> ⚠️ 本轮出过一次**自伤事故**（0.8.0 编译失败仍打包上机 → LMS 加载失败并把插件从已安装列表摘掉 → 全部页面 404），已用 `tmp/repair_install.py` 完整恢复，并立了 `tmp/precheck.ps1` 打包门禁（详见 §5.7）。**代码仍未发 GitHub（远端只有 v0.5.9）**：要发版就 GH 基址 pack → release **v0.8.2**（需用户 PAT）。

---

## 一、共识备忘（定稿需求，勿再讨论）

- **纯插件方案**（不做旁车服务/混合路线）：Perl 插件跑在达菲内部，靠 vendored qjs 执行洛雪订阅源与内置 musicSdk。
- **功能范围**：导入订阅源（粘贴/URL/文件）、音质选择、**平台×榜单浏览**、**搜索（歌曲/歌单）**、**歌单整单播放**、收藏（待做）。
- **不做**：歌词 / 下载 / 登录。
- **跨源 fallback 严格匹配**（宁缺毋滥）、静默降级；默认音质 **320k**。
- 显示名 **「洛雪音乐」**；发布仓库 **`jackyytche/lms-plugin-lxmusic`**；设备侧插件名 **LxMusic**（tag `lxmusic`）。
- 达菲订阅源优先走 **LAN 通道** `http://192.168.2.68:8765/repo.xml`（8765 指向 `dist/`，pack 即生效）。

---

## 二、当前进度（里程碑总览）

| 里程碑 | 状态 | 版本 | 验收证据 |
|---|---|---|---|
| **M0.1** 最小可播放（订阅源取链→播放） | ✅ | 0.2.8 | Run test OK ~2.1s 返回酷我直链；**HiBy FC4 出声（用户确认）** |
| **M0.2** vendor musicSdk：聚合搜索 + 四源榜单 + XMLBrowser 菜单 | ✅ | 0.3.7 | 用户实测：**搜索出结果 110 条 / 榜单曲目 / 点选播放出声**；聚合 5.8s |
| **M0.3** 歌单搜索 + 详情 + 整单播放 | ✅ | 0.4.4 | CLI/设备实测：搜索歌单 3.8s/40 个 → 详情 184 曲 → **整单入队 100 首、mode=play、歌名全中文** |
| **M0.4** 体验对齐桌面版（封面/视图/分页/提速/封面兜底） | ✅ | 0.5.9 | 用户实测：**网格/列表切换 ✓、kw 封面 ✓、mg 封面 ✓、速度可接受**；kg 封面经代理修复（设备侧 200/image-jpeg） |
| **M0.5** 设置页 | ✅ | **0.6.4** | 入口：设置 → 插件 的 LX Music 行有 **Settings** 链接（`<optionsURL>`）+ 设置下拉有条目 `label="LX Music"` 且 `selected`；页面 100% ASCII 实体渲染（非 ASCII 字节 0、乱码 0，8 个分区标签齐全）；诊断块 = 版本 / 引擎 ok（qjs+shim+sdk 就绪）/ 日志级别 / 源路径 / 源 64094 B；保存验证：quality 320k↔flac（工具页同步读到）、bridgeTimeout 9 / concurrency 3 / TTL 300 落盘后复原、boardsWy 关闭后菜单 count 8→7 且只剩 kg/tx/mg、coverProxy 关闭后列表 image 由 `/plugins/LxMusic/cover?u=` 变 `imge.kugou.com` 直链、导入(URL+粘贴)/清除/重启恢复 + 取直链 OK 2.2s |

**设备现状**：达菲 192.168.2.111 运行 **0.7.2**（页面 `/plugins/LxMusic/index.html` 显示的版本号＝运行中代码版本，由 `Helper::pluginVersion` 直读 install.xml，是唯一可靠判据）。

| **M0.6** 多源/音质 | ✅ | **0.7.2** | 设备实测：老单源自动迁移进注册表（独家音源 64094 B）；URL 导入成功 + 同内容去重 + 目录导入逐个判重；行内启用/上移下移/删除均持久；取链 `OK (2.4s) [独家音源] 320k ~320kbps verified`（音质裁剪 + HEAD 校验 + **实测码率**）；无源时页面红字提示且取链报明确错误（不再静默无声）。设置页 100% ASCII 实体、`selectFile/selectFolder` 文件选择器字段就位 |

---

## 三、架构与文件地图

**运行链路**（全部设备端实证）：
```
XMLBrowser 菜单 / 网页  →  Plugin.pm（feed handlers / webHandler）
   →  Helper.pm  fork + exec:  /tmp/LXMusic/qjs  /tmp/LXMusic/shim.mjs  <source.js|sdk.bundle.js>  <action>  <payloadJSON>
        →  shim.mjs：qjs 环境 polyfill（lx 宿主 API / Buffer / navigator / node-crypto…）
                     ├─ 源分支：加载洛雪订阅源 → 签名握手 → lx.on('request') → musicUrl 取直链
                     └─ sdk 分支：加载 vendored musicSdk bundle → search / boards / boardlist / songlist / songlistdetail
        →  HTTP：shim 用 os.exec 调系统 curl（字节精确、follow 3 跳、可调超时）
        →  stdout 单行 `RESULT {json}` + `LOG ...` 行
   →  Helper._parse（类方法！）→ cb({ok,data,error,logs,alerts})
   →  ProtocolHandler.pm：lxm:// → 解析缓存 → 真实直链 → 交 Slim::Player::Protocols::HTTP 播放
```

**关键文件**：
| 路径 | 作用 |
|---|---|
| `plugin/LxMusic/Plugin.pm` | 插件主体：OPMLBased 菜单、feed handlers、webHandler（工具页/搜索/试听/封面代理/m3u）、prefs 初始化 |
| `plugin/LxMusic/Helper.pm` | qjs 子进程编排：init 拷贝引擎、request/fork/轮询/解析、**并发闸**、sourceInfo |
| `plugin/LxMusic/ProtocolHandler.pm` | `lxm://` 协议：解析缓存、预取、封面发布、播放收尾与客户端刷新信号 |
| `plugin/LxMusic/Settings.pm` | **M0.5 新增**：`Slim::Web::Settings` 子类（设置页 handler + 订阅源导入/清除 + 诊断信息） |
| `plugin/LxMusic/HTML/EN/plugins/LxMusic/settings/basic.html` | **M0.5 新增**：设置页模板（header/footer + setting WRAPPER） |
| `plugin/LxMusic/engine/shim.mjs` | qjs 宿主 shim（源分支 + sdk 分支 + curl 桥） |
| `plugin/LxMusic/engine/sdk/sdk.bundle.js` | vendored musicSdk 打包产物（kw/kg/tx/wy/mg；bd/xm 已裁） |
| `plugin/LxMusic/engine/sdk/renderer/…` | vendor 源码树（仅开发用，pack.py 排除不上机） |
| `plugin/LxMusic/pack.py` | 打包：zip（qjs 0755）+ SHA1 + `repo.xml`；**zip 名带版本号** |
| `plugin/t/**` | 本地 perl -c 存根（Slim::Plugin::OPMLBased、Web::Settings、Net::SimpleAsyncHTTP、Player::Playlist…） |
| `tmp/shim-sim/` | **shim 层模拟器**：node loader hook 把 qjs `std`/`os` 映射为 fs/spawnSync，直接跑 shim 的 sdk 分支 |
| `repo/` | 发布用 git 仓（GitHub `lms-plugin-lxmusic`），内容 = plugin 源码镜像 |
| `dist/` | `LxMusic-<ver>.zip` + `repo.xml`（pack.py 产物，LAN 直接服务） |
| `refs/lx-music-desktop/` | 落雪 PC 端全量源码（**getPic/封面逻辑的权威参考**） |
| `slimserver/` | LMS 源码稀疏克隆（API/契约对照） |

---

## 四、版本史（为什么长这样）

| 版本 | 关键点 |
|---|---|
| 0.1.x | 骨架；AnyEvent→Timers/dup2；版本号去掉 `-alpha`（破坏升级比较器）；诊断探针 |
| 0.2.0~0.2.6 | Buffer 重写为真 Uint8Array 子类；`rawScript`+`env/version` 契约；**CRLF 双侧规范化**（rconfig 403→200）；drain 泵 |
| 0.2.7 / 0.2.8 | `lx.request` 回调形状对齐 desktop preload；**`_parse` 类方法调用修复**（RESULT 从第一天起从未被解析） |
| 0.3.0~0.3.2 | vendor musicSdk 落地；**基类改 OPMLBased**（此前菜单从未注册）；curl 诊断 |
| **0.3.3** | **qjs 语义双雷修复**（见 §五.1）——聚合搜索首次出结果 |
| 0.3.4~0.3.7 | 超时钳制（15s→7s；migu 3s）；单位 bug 修复；聚合 5.8s |
| 0.4.0~0.4.5 | 歌单搜索/详情/整单入队；并发闸；m3u 截断；编码修复（`_u()`/`parseUrl`） |
| 0.5.0~0.5.2 | 队列元数据发布、分页、解析缓存、预取、渲染期预热 |
| 0.5.3~0.5.9 | 封面五源终态（kg albumId 推导、kw 代理、mg jpg 化）；**封面代理端点 + 新增页面注册**；修复 `SimpleAsyncHTTP->request()` 误用 |
| **0.5.9（上一轮设备版）** | 以上全部 + 封面代理修正（kg/kw 走代理、mg 直取） |
| 0.6.0 | M0.5 设置页接线：coverProxy 进 `_coverOf`、boards* 进 `handleFeed`（+ 下钻防御）、`Helper::pluginVersion` 直读 install.xml、`engineStatus`、工具页去掉硬编码版本号 |
| 0.6.1 | 修设置页两处：模板 `params.X`→顶层变量（诊断值原本全空）、模板中文双重编码 → 改纯 ASCII+数字实体（生成器） |
| 0.6.2 | pack.py 固定 zip 时间戳 → TT 编译缓存永不失效（0.6.1 的模板改动根本没生效）；改为打包时刻 |
| **0.6.3** | 订阅源编码两修：URL 下载字节串必须 decode（64094→72249 的二次编码）、导入不得裁剪首尾空白（少 1 字节就改签名）；`_u()` 改 FB_CROAK+回退；日志级别改用 `allCategories()` |
| **0.6.4（上一轮设备版）** | 补设置入口：install.xml `<optionsURL>`（插件行 Settings 链接）+ `strings.txt` 与 token 化 `name`/`description`（设置下拉不再是空白行） |
| 0.7.0 | M0.6 主体：`Sources.pm` 多源注册表 + 设置页重构（在线订阅/本地导入/源列表/音质）+ `Helper::resolveTrack`（音质裁剪·多源聚合·HEAD 校验）+ shim `probe` action + 老单源迁移 |
| 0.7.1 | 工具页两条取链（试听/Play test）也切到 resolveTrack，页面显示 `[源] 档位 ~实测码率 verified` |
| **0.7.2** | 修"混旗标串"双重编码（设置页消息乱码，见 §5.5.34）；install.xml 中文注释被 PowerShell `Set-Content` 写坏后复原（§5.5.36） |
| 0.8.0 | ⚠️ **坏版本，勿用**：Plugin.pm 编译失败（`$src` 未声明）却被打包上机 → LMS 加载失败（详见 §5.7.37） |
| 0.8.1 | 修 0.8.0 的编译错误；新增「播放行为」分区（`autoSkipOnError`）+ 聚合搜索重排；机上被 LMS 摘除后由 `repair_install.py` 恢复 |
| **0.8.2** | 修单源搜索 die（`@{$res->{data}}` 对 hashref 解引用，§5.7.39）；聚合搜索 + 相似度重排实测排序严格单调不增；自动跳曲 + 防连跳风暴上线 |
| **0.8.3（当前设备）** | 按用户决定：跳曲开关文案改清楚（明说"由插件立即跳"、限流不跳、防连跳）；删除死链源 qdy |

---

## 五、开发经验与坑（长期有效，按类归档）

### 5.1 qjs / shim（最容易翻车）
1. **⚠️ qjs 语义双雷（0.3.3 修复，本项目最大坑）**
   - `os.exec(args,{block:true})` 返回**纯数字退出码**，不是 `{exit_code}` 对象（quickjs-libc.c 注释 "exec -> exitcode"）。读 `r.exit_code` 恒 undefined ⇒ 所有成功请求被误判失败 ⇒ 源重试耗尽抛 `try max num` /「无法连接服务器」。
   - `FILE.write` **只接收 ArrayBuffer(offset,length)，不收字符串**（POST body 写字符串直接 `TypeError: ArrayBuffer object expected`）。
   - 教训：**模拟器 stub 必须照抄 C 实现契约**（我最初的 stub 顺手支持了对象/字符串，把两个雷全掩盖）；golden 依据 = bellard quickjs `quickjs-libc.c`。
2. **qjs 顶层不跑 promise 微任务**：必须 `await` 让出栈；`await` 必须在 async 函数内。源脚本要手动 drain 到 `inited`。
3. **count/units 陷阱**：桥里 `opts.timeout` 是**毫秒**，而钳制常量用**秒**。0.3.6 写成 `Math.min(3000, 15)`（毫秒混秒）⇒ 所有请求回到 15s，修复被无声回退。**验尸金标准**：页面日志里 curl stderr 的 `timed out after N milliseconds`。
4. shim 的 Buffer polyfill **必须可 `new`**（vendor 树有 `new Buffer(x)`）；`navigator.userAgent` 在模块加载期就被 kg infSign 读取（qjs 无 navigator ⇒ bundle 加载崩）。
5. `node --check` 对 `.mjs` 按 CJS 解析会误报顶层 await —— 真实 ESM 验证用 `node -e "import('file:///…')"`。

### 5.2 LMS / 达菲（契约层）
6. **主循环不驱动 AnyEvent**：回调永不触发。配方 = 子进程输出落临时文件 + `Slim::Utils::Timers` 轮询 `waitpid(WNOHANG)` + `POSIX::open/dup2` 重定向 fd（`open(STDOUT,…)` 会死在 Log::Trapper 的 tie 上）。
7. **达菲过滤 info 级日志** ⇒ 诊断输出必须 `$log->warn`（或 `$log->error`）。
8. **插件日志分类必须注册**：只 `logger('plugin.lxmusic')` 不注册 ⇒ 调试页不列出、重启后 warn/info 静默丢失。修法：`Slim::Utils::Log->addLogCategory({category=>'plugin.lxmusic', defaultLevel=>'ERROR', description=>'LX Music'})`；开 DEBUG 时必须带 **`persist=1`**（不带则重启即失效）。
9. **插件基类必须 `Slim::Plugin::OPMLBased`**（0.1~0.3.0 误用 Base ⇒ feed/tag/menu 被无视，菜单/CLI 从未注册，是潜伏 bug）。
10. **XMLBrowser 契约**：feed coderef 收 `($client,$cb,\%args,@passthrough_flat)`（位置参数）；下钻靠 `item_id:<层级>`；CLI 搜索=`search:<词>`；**web 表单=`index=<序号>&q=<词>`**（不是 `search=`）。
11. **新增 web 页面必须注册**：`Slim::Web::Pages->addPageFunction('plugins/LxMusic/cover', …)`——漏注册会落到 LMS 默认 404（0.5.6 现场：'代理端点 404'）。
12. **`SimpleAsyncHTTP` 没有 `->request($req)`**：自定义 header 是作为 `get($url, @headers)` 的**额外参数**传给 Net::HTTP::NB::formatRequest（源码 L49-53 注释明示）。用错 ⇒ 页面处理器整体崩溃、端点对任何 URL 都返回连接失败（0.5.8 现场：**改了 kg 却把原本正常的 mg 一起弄坏**）。
13. **LMS 把远程 m3u 当"单条链式流"**：`playlist play <m3u>` 队列里只有 1 条（顺序播但不可见/不可跳）。**整单正确做法 = 插件侧展开**：feed 放 `type=link` 项 → handler 内 `Slim::Control::Request::executeRequest($player,['playlist','clear'|'play'|'add',$url])`（实测 `playlist add` 仅 5-7ms）。
14. **队列/正在播放元数据**：渲染期 `Slim::Music::Info::setRemoteMetadata($url,{title,secs,cover})`（否则队列行只有裸 URL）+ 解析完成 `currentPlaylistUpdateTime(time())` + `notifyFromArray($client,['playlist','newmetadata'])`（否则轮询客户端不刷新面板）。
15. **分页**：handler 读 `$args->{index}/{quantity}`，`page=int(index/50)+1`、`skip=index%50`；避免返回的 rows < 上报 total（会被补空行）。
16. **`Slim::Web::Settings`**：子类 + `require`+`->new()`（`if (main::WEBUI)`）；模板 `HTML/EN/plugins/<Name>/settings/basic.html`；基类会把**声明的每个 pref 都用表单值覆盖**（未勾选的 checkbox ⇒ 置空），所以模板里必须为每个声明的 pref 提供字段。
17. CLI **9090** 是可靠通道（CLI 命令可下钻/查状态）；`/jsonrpc.js` 可用但异步 items 查询会返回空；POST 到 `/` 只会返回皮肤 HTML。

### 5.3 编码 / 中文
18. **`uri_unescape` 返回未打 UTF-8 旗标的字节串**，交给 LMS（`getMetadataFor`/`setRemoteMetadata`）会被按 latin1 再编码 ⇒ 队列/正在播放乱码（`å¨æ°ä¼¦`）。修法：`parseUrl` 里 `Encode::decode('UTF-8', …)`（FB_CROAK，失败保留原值）。
19. **`join(' · ', …)` 混用旗标/未旗标串**会把非 ASCII 分隔符搞坏 ⇒ 分隔符也要过 `_u()`；m3u 是字节流 ⇒ `Encode::encode('UTF-8', …)` 显式落字节。
20. **PowerShell `Set-Content` 会写坏 UTF-8 中文（三次事故，禁令级）**——改文件一律 python bytes replace / write·edit 工具；PS 给 curl.exe 传 JSON 会吃内嵌双引号（body 走 `--data-binary @file`）。

### 5.4 自主升级链（本项目最大工程资产）
21. **LMS 插件下载按 zip 文件名做 digest 校验**：同名 `LxMusic.zip` 连续升级会 `digest does not match` 而**静默不装**（表现为"POST 成功但版本不变"）。**必须版本化文件名** `LxMusic-<ver>.zip`（pack.py 已改）。
22. **仓库缓存 300s TTL**：两次 POST 间隔 <5min 会拿旧仓数据判"无更新" ⇒ 等满 5 分钟再 POST，或用 `--repos=…?v=N` 换新 URL 破缓存。
23. **安装序列**：`diag_plugin_install.py post LxMusic` →（等 TTL）→ `restart`（**有"正在播放则中止"守卫**，需先 stop 播放器）→ **只看 `/plugins/LxMusic/index.html` 的页面版本号**确认。
24. **日志端点延迟可达 10+ 分钟**（`/server.log?zip=1`、mslog、log.txt 都一样）⇒ 别把它当实时通道；实时诊断优先用「插件自己渲染在页面上的 logs 块」与 CLI/JSONRPC 查询。
25. 首次打包/升级的隐形前提：**Helper init 会重建 `/tmp/LXMusic`**；init 曾因 qjs 拷贝失败提前 return 导致 shim 停在旧版（已加固：shim/sdk 先拷、qjs 失败仅降级）。

### 5.5 LMS 设置页 / TT 模板 / 打包（M0.5 现场，7 条全是设备实测踩出来的）
26. **TT 模板里的非 ASCII 会被双重编码**（本页第一乱码源）：`Slim/Web/Template/SkinManager.pm`
    的 `Template->new({...})` **没有 ENCODING** ⇒ 模板文件里的 UTF-8 字面量按 latin-1 当字符读入，
    输出时再 UTF-8 编码 ⇒ 浏览器看到 `å°é¢ä»£ç`（实测 `封面代理`）。
    **做法：本插件设置页模板一律"纯 ASCII + HTML 数字实体"**，由 `tmp/mk_settings_template.py`
    生成（改文案改生成器后重跑）；Perl 侧动态串走 `Settings::_ent()`（非 ASCII 与 `&<>"'` 一起转实体）。
    实体是 ASCII，管道里任何编码环节都改不坏，也不依赖服务器语言（达菲是 EN，照显示中文）。
    *对照*：喜马拉雅设置页全用 `strings.txt` token + `| string`，在 EN 服务器上渲染英文——
    想让设置页显示中文就别走 token 路线。
27. **LMS 设置模板的 stash 是"顶层"**：`$params->{lxVersion}` 在模板里必须写 `[% lxVersion %]`；
    写成 `[% params.lxVersion %]` 会静默变空串（0.6.0 现场：诊断块三个值全是空的，最容易误判成"后端没数据"）。
    只有 `prefs.pref_x` 带前缀（基类专门往 stash 塞了 `prefs` 键）。
28. **页面里有两个 `<form>`**：皮肤顶部的 `setup_chooser`（action=`/setup.html`）与真正的
    `settingsForm`（action=`/plugins/LxMusic/settings/basic.html?playerid=…`）。表单回放脚本必须认
    `name="settingsForm"`。另外 `settings/footer.html` 自带 `<input type="hidden" name="saveSettings" value="1">`，
    所以自定义按钮（`name="lxAction"`）提交时 `saveSettings` 也在，不必自己加；
    但**同名参数出现两次会被 LMS 解析成数组引用**（`lxAction` 重复 ⇒ `eq 'import'` 恒假、静默不导入）。
29. **复选框 pref 的"取消勾选"会在重启后自己弹回**：未勾选 ⇒ 表单不带该字段 ⇒ 基类 `set($pref, undef)`；
    而 `Prefs::Base::init` 把 `undef` 当"未初始化"，下次启动重灌默认值(1)。
    **修法：handler 里在调 SUPER 之前，把表单未出现的布尔 pref 显式填 `0`**（0 是持久值）。
30. **zip 内的固定时间戳会让 TT 编译缓存永久命中**：`Archive::Zip::extractTree`（PluginDownloader）
    解压**保留 zip 内 mtime**，而 TT 按 mtime 判编译缓存（`COMPILE_DIR=<cachedir>/templates`、`STAT_TTL=3600`）。
    pack.py 曾写死 `(2026,9,18)` ⇒ 0.6.1 改了设置页模板，设备仍渲染 0.6.0 的编译结果（**页面逐字节相同**）。
    **pack.py 现在用打包时刻**（`SOURCE_DATE_EPOCH` 可复现）。判据：改 `.html` 没生效时，先比对页面字节数
    与文案代次（旧代次=缓存命中），再怀疑装机。
31. **URL 下载来的订阅源是字节串**：`_fetch`/curl 给的是原始字节，而 `installSource` 用 `:encoding(UTF-8)`
    落盘 ⇒ 必须先 decode 成字符，否则每个非 ASCII 字节被再编码一次（实测：64094 B 的源落盘成 **72249 B**，
    源被改坏 ⇒ 签名握手失败、取不到直链）。已收敛到 `Helper::installSource` 一处（字节串→字符；非法 UTF-8 原样保留）。
32. **导入订阅源绝不能裁剪首尾空白**：lx 源的完整性签名基于原始字节，尾部少一个换行落盘就变
    **64093 B**（0.6.2 现场，`_installSource` 多了一次 `s/^\s+|\s+$//g`）。判形态可以裁剪副本，落盘必须原样。
    另：LMS 9.0 已无 `logLevelForCategory`，取日志级别用 `Slim::Utils::Log->allCategories()->{category}`。
33. **设置入口是两道独立手续，缺一个就是"没入口"**（0.6.3 现场，用户报"settings 的入口没有"）：
    - **插件行的 Settings 链接**来自 `install.xml` 的 **`<optionsURL>`**（`Slim/Utils/ExtensionsManager.pm`
      `settings => $entry->{optionsURL}`）；漏了它 = 设置 → 插件 那一行没有 Settings 可点。
    - **设置下拉/页面标题的可见文字**来自 `Slim::Web::Settings::name()`，而它的契约是**返回 strings.txt 的
      token**（基类把它当键做 `addPageLinks`，皮肤用 `| string` 渲染）。返回显示串会渲染成**空标签**
      （实测 `<option value="LX Music" label="">`，下拉里是一行空白）。修法：`name()` 返回 `PLUGIN_LXMUSIC`
      + 插件根加 `strings.txt`（EN/ZH_CN）；`install.xml` 的 `<name>`/`<description>` 同理必须是 token。
    - 判据/取证：`tmp/probe_settings_entry.py`（下拉条目 + 插件行链接 + selected）、`tmp/probe_chooser_option.py`
      （原始 option 标记）、`tmp/probe_chooser_js.py`（chooser 的 `case "TOKEN" -> url` 跳转表）。
    - 注意：chooser 的 URL 跳转表是**按注册值生成**的，所以漏 token 时导航 case 仍在（`case "LX Music"`），
      症状只表现为"看不见/点不了"——别被"JS 里有 case"误导。

### 5.6 多源 / 音质 / 编码（M0.6 现场，3 条）
34. **"混旗标串"会把中文字面量按字节逐个转义 ⇒ 双重编码乱码**：本插件的 `.pm` 中文字面量是**字节串**，
    而 JSON 解出的值（源名/路径）是**旗标串**；`'已添加在线订阅：' . $rec->{name}` 一拼，整串变旗标串，
    字面量的每个字节被当成一个字符 ⇒ 上层 `_ent`/`encode_entities` 逐字节转义 ⇒ 页面显示 `å·²æ·»å `。
    **修法：拼文案一律走 `_m(@parts)`（先把每个片段 `_chars` 归一，再 join）**，`Settings.pm` 与 `Sources.pm`
    各有一份。同族坑见 §5.3.19（join 分隔符）。判据：消息里出现"部分中文正常、部分乱码"就是它。
35. **prefs 里存 JSON 不要用 `JSON::XS->utf8`**：`utf8` 模式产出的是"含高位字节的字节串"，
    落到 `YAML::XS::Dump`（`Prefs/Namespace.pm:327`）会出二进制/乱码风险。用**字符模式**（非 ASCII 转 `\uXXXX`，
    落盘纯 ASCII，读写往返稳定）。另：`plugin/t_local/JSON/XS.pm` 原来是手写假实现（不转义非 ASCII、
    decode 直接喂 decode_json），会把"存进去读不出来"这类问题在本地测试里静默掩盖——已换成 **JSON::PP 薄封装**。
36. **`Set-Content` 又写坏了一次中文**（install.xml 注释，第四次）：改文件**只用 write/edit 工具**，
    连"只改个版本号"也别用 PowerShell（`-replace | Set-Content` 会按 ANSI 读、UTF8 写）。
    另：改 `.pm` 里中文时若用脚本批量替换，替换后务必 `perl -c` + 跑一次设备页面验收。

### 5.7 打包门禁与"插件被 LMS 摘除"的恢复（M0.7 现场，5 条，含一次自伤事故）
37. **【事故】编译失败仍打包上机 ⇒ LMS 把插件从"已安装"列表摘掉**：0.8.0 的 Plugin.pm 有
    `Global symbol "$src"`（我改搜索时漏了变量作用域），`perl -c` 的失败我没当门禁，pack 照跑。
    装机后 LMS 加载失败（`Slim::bootstrap::tryModuleLoad` 警告 "failed to load"），后果不是"插件不工作"
    而是 **插件从已安装列表消失**：插件页只剩仓库候选（`<input name="LxMusic" class="unsafePlugin">`
    + 空值 `install:LxMusic`），所有插件页面 404，且**此后所有 POST 都装不上也启不了**（因为
    `update:<plugin>` 对"未安装"的插件是空操作）。
    修法：**先立门禁** `powershell -ExecutionPolicy Bypass -File tmp/precheck.ps1`（5 个 .pm 必须
    出现 `syntax OK` + 模板纯 ASCII + shim.mjs 过 node --check），**通过才允许 pack**；
    再用 `tmp/repair_install.py`（见 38）重新安装启用 + 重启即可恢复。
38. **插件设置页表单有重复字段名（`repos` 两条），必须用保序 (name,value) 列表回放**：
    我用 dict 收字段（`d[n]=v`）跑"修复"脚本，把两条 repos 并成一条 ⇒
    `Slim::Web::Settings::Server::Plugins` 按"提交的 repos 集合 = 当前集合"做增删 ⇒ **把 LAN 仓库删了**，
    插件候选直接从页面消失（比事故本身更难查）。正解：照 `tmp/repair_install.py`
    （列表 + 浏览器语义 + `--repos=` 覆盖 + `install:<name>` 标记 + `<name>` 勾选）回放。
39. **单源搜索返回 hashref、跨源返回 arrayref**：`_webSearch` 里 `@{$res->{data}}` 在单源时直接
    die（"Not an ARRAY reference"）⇒ 页面挂到超时（浏览器/urllib 都只看到 hang，没有错误页）。
    正解：`my @groups = length $src ? ($res->{data}) : @{ $res->{data} };`。
40. **解析缓存会污染故障注入测试**：同一 `lxm://` URL 只要曾经解析成功就会命中缓存 ⇒
    故意"注入失败"的测试会得到"能播"的假象。做失败路径测试必须让 URL 唯一（改 `n=` 查询参数即可）。
41. **LMS 本身在"取不到 URL"时就会跳下一曲**：实测把 `autoSkipOnError` 关掉、禁用全部订阅源，
    LMS 照样从 index 0 跳到 1。所以本开关的真实语义是「**立即跳**（不等 LMS 自己的错误流程）
    + **限流(429)时不跳** + **防连跳风暴（60s 内最多 3 次）**」，而不是"是否跳"。
    若用户要"失败即停住不跳"，得另想办法（LMS 的行为不可由插件关闭）。

---

## 六、自主开发闭环（下个 session 直接复用）

1. **改代码** → 本地校验：`perl -I plugin\t_local -I plugin\t -I plugin -c plugin\LxMusic\<Module>.pm`（需要 `plugin/t/**` 存根）；`node --check engine/shim.mjs`；shim 侧行为验证用 `tmp/shim-sim/`。
   **打包前必须**跑门禁：`powershell -ExecutionPolicy Bypass -File tmp\precheck.ps1`（5 个 .pm 都要 `syntax OK` + 模板纯 ASCII + shim 过），**不通过就不许 pack**（0.8.0 事故的教训，§5.7.37）。
2. **打包发布（LAN）**：`$env:LX_REPO_BASE='http://192.168.2.68:8765'; python plugin\LxMusic\pack.py`（产物进 `dist/`，LAN 即时生效）→ 同步 `repo/plugin/**`（本 session 只改 5 个文件，可用 `Copy-Item` 逐个覆盖）→ `git -C repo add -A plugin; git -C repo commit`（**新提交**，别 amend：远端 main 已有 CI 提交，新提交才能快进推送）。
3. **装机**：`python _research/ximalaya-daphile-plugin/m0/diag_plugin_install.py post LxMusic '--repos=http://192.168.2.68:8765/repo.xml?v=<N>'`（**N 每次 +1**，用于破 LMS 300s 仓库缓存；本 session 用到 **v=37**）→ `… restart`（有"正在播放则中止"守卫）→ 轮询页面版本号。
4. **取证**：
   - CLI 9090：`tmp/lx_cli.py "lxmusic items 0 40"`（顶层菜单）、`… "lxmusic items 0 8 item_id:2"`（下钻榜单）、`… "lxmusic items 0 4 item_id:2.0"`（榜单曲目，**输出含 image 字段**，可验证封面代理开关）；`<playerid> status - 1 tags:cgAl`（播放状态）。
   - JSONRPC：`/jsonrpc.js` POST `{"id":1,"method":"slim.request","params":["<playerid>",["playlist","play",["<url>"]]]}`。
   - 页面自证：`?q=`（搜索）、`?type=pl&q=`（歌单搜索）、`?plid=&plsrc=`（歌单详情）、`?track=`（试听解析）、`?u=<b64url>`（封面代理，返回图片字节即设备侧可直连该 CDN）。
   - 日志：设备日志端点（**延迟大**）；插件自身 `LOG …` 行会渲染在搜索/歌单页的 logs 块里。
5. **播放验证**：`playlist clear` → `playlist add <lxm://…>`×N → `playlist jump 0` → `play` → `<playerid> status`；用户听声确认。
6. **设置页 / 编码验收（M0.5 新增工具，都可重复跑）**：
   - `tmp/verify_settings.py` — 设置页体检：非 ASCII 字节数（须 0）、8 个分区标签是否齐全（实体解码后）、乱码计数、诊断块取值、各 pref 控件状态。
   - `tmp/lx_settings_post.py` — **浏览器语义表单回放**（自动带 `pageAntiCSRFToken`，只提交 `settingsForm`）：`show` / `save pref_x=v -pref_y`（`-` = 取消勾选）/ `save lxAction=import sourceContent=<URL>` / `save lxAction=clear` / `save --file-source=<本地源文件>`（粘贴路径，内容随表单提交）。
   - `tmp/check_resolve.py [关键词] [源]` — 网页搜索 → 取第一条 `?track=` → 解析直链，输出 `OK (n.nn s)` + 直链主机名（**验证源字节完好的硬证据**）。
   - `tmp/test_ent.pl` — `Settings::_ent()` 单测（字节串/旗标串都要出纯 ASCII 实体）。
   - `tmp/mk_settings_template.py` — 设置页模板生成器（改文案改这里，生成纯 ASCII 实体模板）。
   - 编码取证脚本：`tmp/probe_mojibake.py`、`tmp/probe_surfaces.py`、`tmp/probe_template_gen.py`（判定"渲染的是哪一代模板"）。
   - 入口取证脚本：`tmp/probe_settings_entry.py`（设置下拉条目 + 插件行 Settings 链接 + selected）、`tmp/probe_chooser_option.py`、`tmp/probe_chooser_js.py`、`tmp/probe_plugin_row_text.py`。
   - M0.6 新增：`tmp/verify_sources_page.py`（源列表/导入字段/音质控件体检）、`tmp/m0_6_acceptance.py`（多源全流程验收：导入/去重/目录/启停/排序/删除/取链）、`tmp/restore_source.py`（把设备源复原成样本源）、`tmp/test_sources.pl`（Sources.pm 单测）、`tmp/probe_url_playable.py`（HEAD/Range 可播性）、`tmp/probe_source_info.py`（源脚本头/平台能力）。
   - M0.7 新增：**`tmp/precheck.ps1`（打包门禁，必用）**、**`tmp/repair_install.py`（插件被 LMS 摘除后的恢复/重装启用）**、`tmp/verify_search_rank.py`（聚合搜索排序单调性复算）、`tmp/test_autoskip.py`（自动跳曲开关 A/B 实测）、`tmp/check_qdy_source.py` / `tmp/probe_qdy_url.py`（订阅源可用性 + 直链真伪）、`tmp/decode_qdy_error.py`（把页面上的实体乱码还原成源的真实报错）、`tmp/delete_source.py "名称子串"`（按名字删源）。
   - `tmp/lx_set_loglevel.py [LEVEL]` — 查看/整表回放设置某个日志类别级别（带 `persist=1`，重启仍生效）。

**播放器**：HiBy FC4 `5a:78:10:59:c7:74`（用户主用，验证目标）；HD-Audio Generic `5a:bf:86:1b:a6:ff`（本机声卡）；小爱音箱 squeezelite `bb:bb:69:a9:cf:23`（**会出声，勿用**）。

---

## 七、下个 session 待办（按序）

1. **发版 v0.8.3（待定，需用户提供 PAT）**——远端 GitHub 目前只有 v0.5.9，本轮 0.6.0~0.8.3 全在本地。
   - 步骤：不设 `LX_REPO_BASE` 跑 `pack.py`（生成 GH 基址 zip + repo.xml）→ `dist/LxMusic-0.8.3.zip` + `repo.xml` 作为 `v0.8.3` release 资产。
   - 推送：`git push https://x-access-token:<token>@github.com/jackyytche/lms-plugin-lxmusic main`（token 只内联，不落盘；本地 main 领先远端，快进即可）。
2. **M0.7 剩余候选**：每源失败冷却（连续点歌不反复撞死源）；**不喜欢歌曲规则**（`歌曲名@艺术家` 三态过滤，
   PC 端最契合服务端的一项）；搜索排序可选增强（PC 算法下"歌手名越短得分越高"⇒ 是否加"完全同名优先 / 优先某源"）；
   `common.sourceNameType` real/alias；繁简转换；歌词三开关；代理；热门搜索；直链缓存上限语义。
3. **M0.8 候选**：常驻 qjs worker（冷解析 ~2.3s → ~0）；kw 榜单（上游签名失效）。
4. **遗留清理**：`repo/plugin/helper-test.log`；`tmp/` 脚本（本轮新增 6 个，建议全留）；`dist/lx-6.js`、`dist/qdy.js`。
6. **发布历史（✅ 2026-09-19）**：GitHub `jackyytche/lms-plugin-lxmusic`
   - main 已推：`a5af529..2b28c48`（`2b28c48` = 0.3.0→0.5.9 + 设置页 WIP 单一提交，含 vendored sdk 树 0.23MB 以便复现）
   - **Release `v0.5.9`**（id `392124985`）：资产 `LxMusic-0.5.9.zip`（1231509 B，SHA1 `c0959eb82a8f5d968c3e51de8e160c9cb4875180`）+ `repo.xml`（GH 基址）

---

## 八、现场状态与凭据

- **设备**：达菲 `192.168.2.111`（LMS 9.0.3 / perl 5.40；Web `:9000`，CGI `:80`）；运行 **0.8.3**。
- **通道**：达菲订阅 = **LAN** `http://192.168.2.68:8765/repo.xml?v=46`（8765 常驻 `python -m http.server` 指向 `dist/`；**进程易失**，掉线就在 `dist/` 重启；`?v=N` 是 LMS 仓库缓存的破除参数，每次装机 +1）。
- **设备侧现状**：订阅源 **1 个**：`独家音源`（在线 `http://192.168.2.68:8765/lx-6.js`，64094 B）——**可用**，取链实测 `flac ~1647kbps verified` / `320k ~320kbps verified`。prefs 默认（quality 320k / bridgeTimeout 7 / helperConcurrency 2 / resolveTtl 600 / coverProxy on / boards 全 on / qualityFallback on / verifyUrl on / autoSkipOnError on）；`plugin.lxmusic` 日志级别 = **ERROR**。
  - 已删除的源：`全豆要[聚合音源]`（`qdy.js`）——它的取链产物是死链：回 `kw-er.kuwo.cn/...F000000bYDlc2XxKLs.flac?bitrate$2000&...`（`=` 被打成 `$` 是它自己的构造问题），HEAD/Range/带 Referer/换 UA 全是 **HTTP 410 Gone**（`tmp/probe_qdy_url.py` 实测）。`dist/qdy.js` 仍留着，将来拿它做多源测试很方便。
- **本机 IP/仓库基址**：`192.168.2.68:8765`（**DHCP 可能变化**，变了要同步 `dist/repo.xml` 的 URL 与 pack.py 的 `LAN_BASE`）。
- **GitHub**：`jackyytche/lms-plugin-lxmusic`；PAT 由用户在需要时提供（**勿写入文件**；撤销提醒见 §七.4）。
- **订阅源样本**：`refs/samples/lx-6.js`（= `lx-music-source-v6-fixed.js` = `lx-latest.js`，64094 B，与 pdone/lx-music-source 官方 `lx/6.js` 逐字节一致；`dist/lx-6.js` 是给设备做 URL 导入测试的 LAN 副本）。
- **本地工具**：python 3.14（`pack.py`、诊断/验收脚本）、node 24（`tmp/shim-sim`）、达菲诊断脚本复用喜马拉雅项目 `_research/ximalaya-daphile-plugin/m0/diag_plugin_install.py`（装机/重启）与 `diag_settings_form.py`（改日志级别等整表回放）。

---

## 九、文档与索引

- `共识定版.md` — 需求定稿（§一为其摘要）
- `docs/lx-music-source-analysis.md` — 订阅源深度分析；`docs/lx-music-custom-source-api.md` — lx 宿主契约
- `docs/js-helper-architecture.md` — Perl+qjs 助手架构设计；`docs/existing-bridges-and-lms-constraints.md` — 桥接方案与约束调研
- `docs/source-api-endpoint-inventory.md` — 各源端点清单
- `plugin/LxMusic/engine/sdk/` — vendor 树与打包产物说明；`tmp/shim-sim/` — shim 模拟器
- **设置页/编码（M0.5 新增）**：`tmp/mk_settings_template.py`（模板生成器，**改文案的入口**）、`tmp/verify_settings.py`（设置页体检）、`tmp/lx_settings_post.py`（表单回放）、`tmp/lx_cli.py`（9090 CLI 客户端）、`tmp/check_resolve.py`（搜索→取直链）、`tmp/probe_*.py`（编码/模板代次取证）；踩坑细节见 §五.5
- `refs/lx-music-desktop/`（PC 端源码，封面/榜单权威参考）、`refs/lx-music-mobile/`、`refs/samples/`、`slimserver/`（LMS 源码）
