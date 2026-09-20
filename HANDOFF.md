# HANDOFF — lx-music Daphile 插件（洛雪音乐）

> **下个 session 恢复方式**：直接说「继续 lx-music 插件，先读 HANDOFF.md」
> **权威事实源**：本文档 + 磁盘（`plugin/` 源码、`repo/` 发布仓、`dist/` 打包产物、`refs/` 参考克隆、`tmp/` 工具）
> **一句话现状（2026-09-21 第九轮：插件图标 + 首次 GitHub 发版）**：设备运行 **0.11.20**（已装机验收：
> 插件管理器那一行与「应用/apps」菜单里的 LX Music 都换成了落雪官方 logo，见 §5.11.81/§5.11.82）；
> **GitHub `jackyytche/lms-plugin-lxmusic` 已从 v0.5.9 一步发到 v0.11.20**（release id `392384987`；
> zip + repo.xml + lxmusic_logo.png 三资产，`releases/latest/download/repo.xml` 终验通过，见 §5.11.83 与 §七.8）。设备侧仍优先用 LAN 仓库（`http://192.168.2.68:8765/repo.xml?v=97`）。
> 0.11.2=榜单页头；0.11.3=feed 内嵌翻页行（**作废**——用户指正那不是达菲原生翻页）；0.11.4=原生窗口
> `items+offset+total`（喜马拉雅 albumHandler 配方），Web 翻页走 UI 原生页码；
> 0.11.5~0.11.7=**修窗口数学**（上游页宽按 SDK `limit` 学，不再硬编码 50；行号改绝对序号），kw 热歌榜 6 页逐首对齐上游（§5.11.74）；
> 0.11.8~0.11.12=修 tx 无声（CDN 谎报 Content-Type）+ 元数据/码率持久化；0.11.13~0.11.16=歌单页头 + kg 真封面 + 整榜码率；
> 0.11.17~0.11.18=**修拖动进度条**（bitrate 发到直链 URL + 自实现 `getSeekData`，§5.11.79）；0.11.19=**修 mg 完全不能播**（https 直链走了明文处理器，§5.11.80）；0.11.20=换插件图标（§5.11.81）。
> **已验证**：wy/mg/tx 播放与 UI 形态拖动（mg/wy/tx）、mg 榜单行、wy 榜单行、mg（星海与裤佬各自）——全部 PASS。
> **源侧旧判决（2026-09-21 凌晨实测，独家音源时期，保留作依据）**：kw/tx 取链+播放正常；**wy/kg 走独家音源时上游网关
> 502 Bad Gateway 全档位取链失败**（不是我们管线的问题）——wy 表现为"点了没声"（autoSkip 3 连败后停止）。
> "部分榜单不显示格式码率"（kg/tx）= 取链失败的症状：取链成功的曲子 songinfo 有 type/bitrate
> （tx 实测 `type:MP3 320kbps bitrate:MP3 320kbps`）。kw 榜单调研结论与字段映射见 §5.11。
> **换源判决（2026-09-21 晚，23 源批量实测）**：wy/mg 用 **星海音乐源 v3.2.13**（主）+ **裤佬SVIP音源 v3.0.0**（备）
> ⇒ 两者都能取到 wy/mg 的真 CDN flac（mg `freetyst.nf.migu.cn` 实测 ~934kbps）——详见 §七.0。
> ⚠️ **订阅源文件绝不进仓库/发布资产**（用户明确要求）：`refs/subs_v260917/**`、`dist/src-*.js`、
> 用户导入的 `V260917.zip` 一律只在本地；发布前跑 `python tmp/audit_repo_contents.py` 体检（§5.11.83）。
> ✅ **但本地要留副本**（用户要求：免得每次升级都要重新导入）：`repo/subscriptions/`
> （**已被 `repo/.gitignore` 排除**，内含两个选定源 + 回执包；见 §5.11.85）。
> ⚠️ 历史上出过一次**自伤事故**（0.8.0 编译失败仍打包上线 → LMS 加载失败并把插件从已安装列表摘掉 →
> 全部页面 404），已用 `tmp/repair_install.py` 恢复，并立了 `tmp/precheck.ps1` 打包门禁（详见 §5.7）；
> ⚠️ 本文件也被 PowerShell 文本回环**破坏过一次**（中文整体乱码/半篇内容丢失），恢复后立了
> `python tmp/doc_audit.py` 体检（编码/乱码模式/代码围栏/表格/重复行）与「**只用 edit/write 工具改本文件**」
> 的纪律（§5.11.84）

---

## 一、共识备忘（定稿需求，勿再讨论）
- **纯插件方案**（不做旁车服务/混合路线）：Perl 插件跑在达菲内部，靠 vendored qjs 执行洛雪订阅源与内置 musicSdk
- **功能范围**：导入订阅源（粘贴 URL/文件）、音质选择、**平台×榜单浏览**、**搜索（歌曲/歌单）**、**歌单整单播放**、收藏（待做）
- **不做**：歌词/下载/登录
- **跨源 fallback 严格匹配**（宁缺毋滥）、静默降级；默认音质 **320k**
- **播放验收口径**（0.10.9 定稿）：唯一判据是"播放位置持续推进"，不是 `mode=play`；详见 §5.10.57
- 显示名**「洛雪音乐」**；发布仓库名**`jackyytche/lms-plugin-lxmusic`**；设备侧插件名**LxMusic**（tag `lxmusic`）
- 达菲订阅源优先走 **LAN 通道** `http://192.168.2.68:8765/repo.xml`（8765 指向 `dist/`，pack 即生效）；
  GitHub 通道 `https://github.com/jackyytche/lms-plugin-lxmusic/releases/latest/download/repo.xml` 作为备用
  （`repo-gh.xml` 由 pack.py 同步生成、以 `repo.xml` 之名作为 release 资产上传，见 §5.11.83）

---

## 二、当前进度（里程碑总览）
| 里程碑 | 状态 | 版本 | 验收证据 |
|---|---|---|---|
| **M0.1** 最小可播放（订阅源取链→播放） | ✅ | 0.2.8 | Run test OK ~2.1s 返回酷我直链；**HiBy FC4 出声（用户确认）** |
| **M0.2** vendor musicSdk：聚合搜索 + 四源榜单 + XMLBrowser 菜单 | ✅ | 0.3.7 | 用户实测：**搜索出结果 110 首 / 榜单曲目 / 点选播放出声**；聚合 5.8s |
| **M0.3** 歌单搜索 + 详情 + 整单播放 | ✅ | 0.4.4 | CLI/设备实测：搜索歌单 3.8s/40 个→详情 184 曲；**整单入队 100 首、mode=play、歌名全中文** |
| **M0.4** 体验对齐桌面版（封面/视图/分页/提示/封面兜底） | ✅ | 0.5.9 | 用户实测：**网格/列表切换 ✓、kw 封面 ✓、mg 封面 ✓、速度可接受**；kg 封面经代理修复（设备侧 200/image-jpeg） |
| **M0.5** 设置页 | ✅ | **0.6.4** | 入口：设置→插件→LX Music 行有 **Settings** 链接（`<optionsURL>`）；设置下拉有条目 `label="LX Music"` + `selected`；页面 100% ASCII 实体渲染（非 ASCII 字节 0、乱码 0，当时 8 个分区；**0.10.9 已有 12 个分区**，见 §八）；诊断块 = 版本 / 引擎 ok（qjs+shim+sdk 就绪）/ 日志级别 / 源路径 / 源 64094 B；保存验证：quality 320k↔flac（工具页同步读到）、bridgeTimeout 9 / concurrency 3 / TTL 300 落盘后复原、boardsWy 关闭后菜单 count 8→ 且只剩 kg/tx/mg、coverProxy 关闭后列表 image 从 `/plugins/LxMusic/cover?u=` 变 `imge.kugou.com` 直链、导入(URL+粘贴)/清除/重启恢复 + 取直链 OK 2.2s |
| **M0.6** 多源/音质 | ✅ | **0.7.2** | 设备实测：老单源自动迁移进注册表（独家音源 64094 B）；URL 导入成功 + 同内容去重 + 目录导入逐个判重；行内启停/上移下移/删除均持久；取链 `OK (2.4s) [独家音源] 320k ~320kbps verified`（音质裁剪 + HEAD 校验 + **实测码率**）；无源时页面红字提示且取链报明确错误（不再静默无声）。设置页 100% ASCII 实体、`selectFile/selectFolder` 文件选择器字段就绪 |
| **M0.7** 搜索与播放行为 | ✅ | **0.8.3** | 多平台**聚合搜索 + 相似度重排**（PC 的归一化编辑距离 `1-dist/len`，实测排序严格单调不增）；`autoSkipOnError` 开关（真实语义 =「由插件**立即**跳 + 429 不跳 + 60s 内最多 3 次防风暴」）；删掉死链源 qdy |
| **M0.8** 歌单发现 | ✅ | **0.8.5** | 菜单新增「推荐歌单 / 最热歌单 / 最新歌单」；设备 CLI 实测：最热→4 平台（kw/kg/tx/wy）、最新→3 平台（kw/kg/tx）、推荐→3 平台（kw/kg/mg）；歌单条目带`(来源 · N 首 · 作者)`与封面（走代理）；打开歌单 →「▶ 播放整个歌单（替换队列）」+ 曲目列表。**档位 id 如下**（各平台 vendored `songList.sortList`）：kw `''`(推荐)/`hot`/`new`；kg `'5'`/`'6'`/`'7'`；tx `5`/`2`；wy `hot`；mg `'15127315'`——wy/mg 上游把"最新"注释掉了，故最新只有 3 个 |
| **M0.9** 宿主契约与"静默失败" | ✅ | **0.9.6** | `lx.on/lx.send` 返回 Promise、`lx.request` 返回取消函数、`console` 全套、print 每条 flush、wait-status 误解析修正、失败带源堆栈 + 子进程日志尾部、job loop 看门狗。**结论**：10 个源中 7 个的失败全是它们自己的上游 HTTP 问题，引擎侧不再是瓶颈（§5.8.46） |
| **M0.10** 常驻解析进程 + 播放链路修复 | ✅（①②③完成） | **0.10.9** | ①**常驻 qjs worker**：取链 + 可播校验各一个常驻进程（行协议 stdin/stdout），固定开销 **306ms→51ms**（5×）；同曲目 A/B：fork 0.87s vs worker 热 0.52s（省 ~40%），冷启动 0.94s 与 fork 持平；空闲 600s 回收（实测 20s 版能被回收 + 重启后重新预热）；②**校验升级为取实体嗅探**（Range GET 2KB + 音频魔数 ID3/fLaC/OggS/ftyp，替代原 HEAD-only）；③**播放链路真凶定位**：不是插件——是**无音频后缀的脚本中转链**（长青 `yinyue.haitangw.net/kw/kw.php?...&level=exhigh`）在达菲上无声；给 LMS `formatOverride` 钩子会让 **LMS 主循环卡死**（两次实测，必须重启设备），已回退；改为 `preferStreamable` 两遍策略：先挑带 `.mp3/.flac` 后缀的直链，中转链只作兜底（且兜底不当场做 HEAD）。设备实测 `lxm://` 播放：mode=play、位置 2.4→7.4s 前进、歌名正确，LMS 全程存活 |
| **M0.11** kw 榜单复活 + 长青停用 | ✅ | **0.11.0** | ①kw 榜单：wbd 签名端点确认死亡（`10006 DECRYPT_ERROR`，key 被换、appId 仍有效）→ 换免签名 kbangserver（静态榜单 25/25 实测可用）；载荷字段适配（`formats`→档位映射、`song_duration`/`albumid`）+ `kw__` 前缀防御；菜单新增「kw榜单」（43 榜，`boardsKw` pref + 设置页复选框，默认开）；sdk.bundle.js 用 esbuild `--alias:@renderer=<sdk>/renderer` 重建（增 17KB）；榜单曲目 `lxm://` 播放位置推进实测通过；同轮**停用长青源**（用户决定，设备侧 pref，非代码） |

> **设备现状见 §八**（版本号以 `/plugins/LxMusic/index.html` 页面显示的为准——它由 `Helper::pluginVersion` 直读 install.xml，是唯一可靠判据）

---

## 三、架构与文件地图

**运行链路**（全部设备端实证）：
```
XMLBrowser 菜单 / 网页  ← Plugin.pm（feed handlers / webHandler）
  ← Helper.pm ──┬─ 常驻 worker（默认，0.10.x）：POSIX 双向管道 + Timers 轮询 sysread
                │    /tmp/LXMusic/qjs shim.mjs <source.js> serve
                │    stdin 行＝{"id":N,"action":"musicUrl","source":"kw","info":{...}}
                │    stdout READY{...} / RESULT <id> {json} / LOG ..
                │    ├─ 取链 worker：每源一个（key = 源文件路径）
                │    └─ 校验 worker：argv[1]='-'（shim 不加载任何源，只服务 probe）
                └─ fork 回退（worker 起不来/写失败/背压≈4/超时）：每请求一进程
                      /tmp/LXMusic/qjs shim.mjs <source.js|sdk.bundle.js> <action> <payloadJSON>
                        输出落临时文件 + Timers 轮询 waitpid（0.2.6 的达菲主循环约束）
  ← shim.mjs：qjs 环境 polyfill（lx 宿主 API / Buffer / navigator / node-crypto…）
                ├─ probe 分支：curl -L -r 0-2047 →响应头 + 前 2KB 实体 →音频魔数嗅探
                ├─ 源分支：加载洛雪订阅源→签名握手→lx.on('request')→musicUrl 取直链
                └─ sdk 分支：加载 vendored musicSdk bundle→search / boards / boardlist / songlist / songlistdetail
  ← HTTP：shim 用 os.exec 调系统 curl（字节精确、follow 3 跳、可调超时）
  ← Helper._parse（类方法！）→cb({ok,data,error,logs,alerts,ms,why})
  ← Helper.resolveTrack：音质阶梯（外层）→启用源（内层）→校验 + preferStreamable 两遍挑选
  ← ProtocolHandler.pm：lxm://→解析缓存(resolveTtl)→真实直链→song->streamUrl
                         →交 Slim::Player::Protocols::HTTP 取流（达菲是代理流，格式靠后缀判定）
```

**关键文件**（★ = 0.10.x 改动重点）：
| 路径 | 作用 |
|---|---|
| `plugin/LxMusic/Plugin.pm` | 插件主体：OPMLBased 菜单、feed handlers、webHandler（工具页/搜索/试听/封面代理/m3u）、prefs 初始区 |
| ★`plugin/LxMusic/Helper.pm` | qjs 编排：init 拷贝引擎（qjs/shim/sdk→tmp/LXMusic）、**常驻 worker 管理**（spawn/管道/轮询/空闲回收/shutdown）、fork 回退 + 并发闸、`probeUrl`（实体嗅探）、`resolveTrack`（音质裁剪 + 多源聚合 + `streamFriendly` 两遍挑选）、`lmsFormat`、installSource |
| ★`plugin/LxMusic/ProtocolHandler.pm` | `lxm://` 协议：解析缓存、预取/预热、封面发布、播放收尾与客户端刷新信号（**不要**碰 `formatOverride`，见 §5.10.54） |
| `plugin/LxMusic/Sources.pm` | 多源注册表：元数据解析、启停/排序/删除、URL/文件/目录导入、老单源迁移（`sourcesJson` + `<prefsdir>/lxmusic/sources/<id>.js`） |
| `plugin/LxMusic/Settings.pm` | `Slim::Web::Settings` 子类：设置页 handler + 订阅源导入/清除 + 诊断（含**常驻 worker 现场**） |
| `plugin/LxMusic/HTML/EN/plugins/LxMusic/settings/basic.html` | 设置页模板（**由 `tmp/mk_settings_template.py` 生成的纯 ASCII 实体**，勿手改） |
| ★`plugin/LxMusic/engine/shim.mjs` | qjs 宿主 shim：源分支 + sdk 分支 + probe 分支 + **serve 行协议** + curl 桥 |
| ★`plugin/LxMusic/install.xml` | 版本号（唯一版本源）、`<optionsURL>` 设置入口、**`<icon>` 插件图标**（0.11.20）、name/description 走 strings.txt token |
| `plugin/LxMusic/HTML/EN/plugins/LxMusic/html/images/logo.png` | 插件图标原图（落雪官方 256×256，Apache-2.0；`icon.png` 是同一份拷贝）。**LMS 会按需缩放**出 `logo_50x50.png`/`logo_100x100.png`，不用预先切图（§5.11.81） |
| `plugin/LxMusic/strings.txt` | `PLUGIN_LXMUSIC` / `PLUGIN_LXMUSIC_DESC`（EN/ZH_CN） |
| `plugin/LxMusic/engine/sdk/sdk.bundle.js` | vendored musicSdk 打包产物（kw/kg/tx/wy/mg；bd/xm 已裁） |
| `plugin/LxMusic/engine/sdk/renderer/…` | vendor 源码树（仅开发用，pack.py 排除不上机） |
| `plugin/LxMusic/pack.py` | 打包：zip（qjs 0755）+ SHA1 + `repo.xml`（LAN 基址）+ **`repo-gh.xml`（GitHub 基址，同 sha1，作为 release 资产以 `repo.xml` 之名上传）** + 图标拷进 `dist/`；zip 名带版本号、时间戳=打包时刻；`LX_REPO_BASE` 决定 `dist/repo.xml` 的基址 |
| `plugin/t/**`、`plugin/t_local/**` | 本地 `perl -c` 存根（Slim::* 骨架 + JSON::PP 薄封装的 JSON::XS） |
| `tmp/precheck.ps1` | **打包门禁（必用）**：所有 .pm 语法 + 模板纯 ASCII + shim 过 `node --check` |
| `tmp/shim-sim/` | **shim 层模拟器**：node loader hook 把 qjs `std`/`os` 映射到 fs/spawnSync，直接跑 shim 的 sdk 分支 |
| `repo/` | 发布用 git 仓（GitHub `lms-plugin-lxmusic`），内容 = plugin 源码镜像 |
| `repo/subscriptions/` | **本地专用（被 `repo/.gitignore` 排除，绝不提交/发布）**：导入设备用的订阅源副本 + 用户回执包。用途与恢复流程见 §5.11.85 与 `repo/subscriptions/README.txt` |
| `dist/` | `LxMusic-<ver>.zip` + `repo.xml`（pack.py 产物，LAN 直接服务） |
| `refs/lx-music-desktop/` | 洛雪 PC 端全量源码（**getPic/封面/榜单逻辑的权威参考**） |
| `slimserver/` | LMS 源码稀疏克隆（API/契约对照；**0.10.x 轮靠它定位到 `Song.pm::open` 的格式判定与 `formatOverride` 钩子**） |

---

## 四、版本史（为什么长这样）
| 版本 | 关键变化 |
|---|---|
| 0.1.x | 骨架；AnyEvent→Timers/dup2；版本号去掉 `-alpha`（破坏升级比较器）；诊断探针 |
| 0.2.0~0.2.6 | Buffer 重写为真 Uint8Array 子类；`rawScript`+`env/version` 契约；**CRLF 双侧规范化**（rconfig 403→200）；drain 泄漏 |
| 0.2.7 / 0.2.8 | `lx.request` 回调形状对齐 desktop preload；**`_parse` 类方法调用修复**（RESULT 从第一天起从未被解析） |
| 0.3.0~0.3.2 | vendor musicSdk 落地；**基类改 OPMLBased**（此前菜单从未注册）；curl 诊断 |
| **0.3.3** | **qjs 语义双雷修复**（见 §5.1.1）——聚合搜索首次出结果 |
| 0.3.4~0.3.7 | 超时钳制（5s→3s；migu 3s）；单位 bug 修复；聚合 5.8s |
| 0.4.0~0.4.5 | 歌单搜索/详情/整单入队；并发闸；m3u 截断；编码修复（`_u()`/`parseUrl`） |
| 0.5.0~0.5.2 | 队列元数据发布、分页、解析缓存、预取、渲染期预热 |
| 0.5.3~0.5.9 | 封面五源终态（kg albumId 推导、kw 代理、mg jpg 化）；**封面代理端点 + 新增页面注册**；修复 `SimpleAsyncHTTP->request()` 误用 |
| **0.5.9（上一轮设备版）** | 以上全部 + 封面代理修正（kg/kw 走代理、mg 直取） |
| 0.6.0 | M0.5 设置页接线：coverProxy 接 `_coverOf`、boards* 接 `handleFeed`（下钻防御）、`Helper::pluginVersion` 直读 install.xml、`engineStatus`、工具页去掉硬编码版本号 |
| 0.6.1 | 修设置页两处：模板 `params.X`→顶层变量（诊断值原本全空）、模板中文双重编码→改纯 ASCII+数字实体（生成器） |
| 0.6.2 | pack.py 固定 zip 时间戳→TT 编译缓存永不失效（0.6.1 的模板改动根本没生效）；改为打包时刻 |
| **0.6.3** | 订阅源编码两修：URL 下载字节串必须 decode（4094→72249 的二次编码）、导入不得裁剪首尾空白（差 1 字节就改签名）；`_u()` +FB_CROAK+回退；日志级别改用 `allCategories()` |
| **0.6.4（上一轮设备版）** | 补设置入口：install.xml `<optionsURL>`（插件行 Settings 链接）+ `strings.txt` 加 token 区 `name`/`description`（设置下拉不再是空白行） |
| 0.7.0 | M0.6 主体：`Sources.pm` 多源注册表 + 设置页重构（在线订阅/本地导入/源列表/音质）+ `Helper::resolveTrack`（音质裁剪·多源聚合·HEAD 校验）+ shim `probe` action + 老单源迁移 |
| 0.7.1 | 工具页两条取链（试听/Play test）也切到 resolveTrack，页面显示 `[源] 档位 ~实测码率 verified` |
| **0.7.2** | 修"混旗标串"双重编码（设置页消息乱码，见 §5.5.34）；install.xml 中文注释被 PowerShell `Set-Content` 写坏后复原（§5.5.36） |
| 0.8.0 | ⚠️ **坏版本，勿用**：Plugin.pm 编译失败（`$src` 未声明）却被打包上机→LMS 加载失败（详见 §5.7.37） |
| 0.8.1 | 修 0.8.0 的编译错误；新增「播放行为」分区（`autoSkipOnError`）；聚合搜索重排；机上被 LMS 摘除后由 `repair_install.py` 恢复 |
| **0.8.2** | 修单源搜索 die（`@{$res->{data}}` 拿 hashref 解引用，§5.7.39）；聚合搜索 + 相似度重排实测排序严格单调不增；自动跳曲 + 防连跳风暴上线 |
| **0.8.3** | 按用户决定：跳曲开关文案改清楚（"明确由插件立即跳"、限流不跳、防连跳）；删除死链源 qdy |
| 0.8.4 | **歌单发现**（M0.8）：菜单加「推荐歌单 / 最热歌单 / 最新歌单」→ 平台 →歌单列表（分页）→复用歌单详情与整单播放；shim 新增 `songlistbytag` |
| **0.8.5** | 歌单封面也走插件代理（kw/kg 的图 CDN 需对 UA/Referer） |
| 0.8.6 | **校验探测改为跟随重定向**（`curl -L --max-redirs 3` + 只读最后一个响应头块）——这是 0.8.5 的 bug：把 301 当不可播，实测把长青音源从 5/5 误判成 0/5 |
| **0.8.7** | 低码率告警（`~<64kbps` 标"疑似试听片段"，实测长青 kg flac24bit 只回 ~48kbps）；订阅源实测与治理（见 §八） |
| 0.9.0 | **M0.9 契约补齐**：`lx.on/lx.send` 改返回**Promise**、`lx.request` 返回取消函数（对齐 desktop-preload.js:238-272）；drain 上限 200→500 + 每 200 轮打点；**print 每条 flush**（子进程被 KILL 时日志不再丢） |
| 0.9.1 / 0.9.2 | 失败时把源自身 **`e.stack`** 拼进 error/判决行（M0.9 靠它定位到源第 121 行调用缺失成员） |
| 0.9.3 | **`console` 全套补齐**（group/groupEnd/table/trace/assert/time…）——实测 ikun 只因缺 `console.group` 就整个源报废 |
| 0.9.4 | 修 `httpOnce` 的 **wait-status 误解**：qjs block exec 返回纯退出码，旧代码 `&0x7f` 把 curl `exit 35`(SSL) 误报成 "signal 35"，还把 `exit 28`(超时) 分支成死代码 |
| **0.9.5** | 失败尝试带**子进程日志尾部并加 `tries`**（否则 "no RESULT line" 现场无痕；正是它暴露出六音的真因） |
| **0.9.6（上一轮设备版）** | **job loop 看门狗**：源 promise 一 settle 时显式报错（不再静默退出），并打印轮数/待处理定时器数 |
| 0.10.0 / 0.10.1 | **M0.10①常驻 worker 骨架**：shim 加 `serve` 行协议（`READY{}/RESULT <id>{}/LOG`）、`Helper` 侧管理 + fork 兜底；工具页 tries 增加耗时拆解（`ms/handler/verify/path`）与成功行也显示 tries |
| 0.10.2 | **修自己埋的坑**：空闲 2s 的回收 tick 让每个请求白等最多 2s（实测每首 +1.5s）→ 下发时 `_worker_wake`；在跑时 50ms 细粒度；`%{$w->{jobs}}` 布尔语境恒真导致**空闲回收永不触发**，改 `scalar(keys %h)` |
| 0.10.3 | **校验 worker 独立进程**（`argv[1]='-'`，shim 不加载源）——一次 HEAD 不再另起 qjs；设置页诊断显示 worker 现场 |
| 0.10.4 | ⚠️ 诊断版本（勿参考）：临时加 `$log->error` 探针，其中 `$args->{song}->url` 在播放期**抛异常**（`Slim::Player::Song` 没这个方法），日志端点又延迟 →结论一度跑偏 |
| 0.10.5 | **校验升级为取实体 + 魔数嗅探**（`curl -r 0-2047` + ID3/fLaC/OggS/ftyp/RIFF/ff-fb/APE），拒绝 HTML/JSON 开头 |
| 0.10.6 | ⚠️ **已回退**：给无后缀中转链补 LMS `formatOverride` 钩子→**把 LMS 主循环卡死**（两次实测，需重启达菲）。此版本不要装机 |
| 0.10.7 / 0.10.8 | 回退 formatOverride；改为 `preferStreamable` **两遍策略**：友好的直链直接交付，不友好的只挂起（不当场做 HEAD），最后才回头校验兜底 |
| **0.10.9（上一轮设备版）** | 修 `why` 文案的混旗标双重编码（改成 ASCII 标记）；设备实测 `lxm://` 播放位置正常前进、LMS 存活；设置页 12 分区 + 3 个 worker 现场；`verify_subscriptions.py` 的 `LX_LAN` 默认值改回 `.68` |
| **0.11.0** | **kw 榜单复活**：`kw/leaderboard.js` 弃 wbd 换免签名 kbangserver + `formats`→档位映射 + `song_duration`/`albumid` 字段适配 + `kw__` 前缀防御；菜单新增「kw榜单」（43 榜，`boardsKw` pref + 设置页复选框，默认开）；sdk.bundle.js 用 esbuild `--alias:@renderer=<sdk>/renderer` 重建（增 17KB）；榜单曲目 `lxm://` 播放位置推进实测通过；同轮**停用长青源**（用户决定，设备侧 pref，非代码） |
| 0.11.1 | ⚠️ 版本号被 0.11.1 重装坑污染：首版带致命嵌套 bug（见 §5.11.65）上线→榜单 feed 全空；修复后用同版本号 0.11.1 重装被 LMS 静默跳过**（见 §5.11.66），排查绕大弯。**此版本号不要再用** |
| **0.11.2** | **榜单页头（喜马拉雅专辑页同款）**：`kw/leaderboard.js` getList 返回 `info{name,img}`（`v9_pic2` 路径 `/120/`→`/500/` 升大图）；`sdkBoardTracksHandler` feed 级返回 `image`（榜单封面→第一首封面兜底）+ `play`/`actions`(playall/addall/insert) + `albumData`（榜单名/来源·总数），榜单名经 passthrough 第 4 参透传；`ProtocolHandler::explodePlaylist` 新增 `lxm://b/<src>/<bangid>` 整榜展开（上限 100，入队前 publish 元数据）。修 0.11.1 嵌套 bug。实测：50 首入队、推进、自动连播、kg 跨源正常 |
| **0.11.3** | ~~榜单翻页（feed 内嵌「下一页/跳页」行，48 首/页）~~ —— **方案作废**（用户指正：那不是达菲原生翻页体系，是收藏夹 HTTP 路由的无奈方案）。页 1 网格+两导航行实测 OK，但已被 0.11.4 取代 |
| 0.11.4 | **榜单翻页改原生窗口**（喜马拉雅 albumHandler 0.1.10+0.1.51 同款）：handler 吃 `$args{index,quantity}`（Web 回取时 index=start、quantity=itemsPerPage），按上游页宽 50 顺序补取攒够 `[skip, skip+window)` 再切（绝不吐空行），feed 回 `items+offset(=index)+total(全榜数)`，UI 自己渲染页码；拆出 `board_render`。实测 idx=0/qty=60 → 60 行（跨 2 页）✅ |
| 0.11.5 | **上游页宽修正①**：翻页窗口数学里的「上游页宽」从硬编码 50 改为读 SDK 响应的 `limit`（首响应不符即重算重取）。**根因见 §5.11.74**：各源上游页宽根本不是 50 |
| 0.11.6 | **曲目编号改绝对序号**（`_trackItems(..., $offset)`）：此前每页都从 `001` 重新编号，翻到第 2 页看到「001-050」＋不同歌名 ⇒ 肉眼判定「没翻页/只有一页」 |
| 0.11.7 | 页宽修正②：按源默认页宽表（kw/kg=100、tx=300、mg=200、wy=100000）**让首次请求就落在正确上游页**；首个请求若越界失败则回退探第 1 页把 `limit` 学回来 + `install.xml` 中文注释乱码复原。实测 kw 热歌榜 6 页逐首对齐上游（1-50/51-100/…/251-300）、kg 3 页正常 |
| **0.11.8** | **修"进度条走但没声音"**（tx/wy，见 §5.11.75）：CDN 撒谎的 Content-Type（QQ 的 `.flac` 直链声明 `audio/x-ogg`）被 LMS 嗅探后写进轨道类型缓存 ⇒ 把 FLAC 喂给 OGG 解码器。改为用**我们自己魔数嗅探出的真实格式**覆盖（`setContentType` + 轨道 `content_type`，播放前 `getNextTrack` 再校正一次，**只调 LMS 公开 API、不改 LMS 代码**）；顺带修 probe 的总长度（取 `Content-Range` 总量，此前 `~0kbps`）⇒ 真码率（tx 943kbps）能显示。实测 tx 茶汤/我不难过/晴天/天下 位置均推进过 5s、kw 回归正常 |
| 0.11.9 | **元数据持久化①**：解析结果带上 `secs`（时长），并在**扫描回调之后再发布一次** ct/bitrate/secs——LMS 的 `scanUrl` 会覆盖同一 URL 的属性，只发一次会出现「格式/码率闪一下就没」且 duration=0 |
| 0.11.10 | **修「拖动进度条无效」的真凶**：`getMetadataFor` 把**档位 key 当码率**发（`bitrate => 'flac24bit'`）⇒ LMS 写入 `BITRATE = 'flac24bit'*1000 = 0` ⇒ `Protocols::HTTP::canSeek`（要求 bitrate **和** duration 都已知）恒返回 0 ⇒ 所有 lxm:// 曲目都不能拖。改成发显示标签 `type` + **数字 kbps**，并把 kbps/format 存进 `cache_metadata`。**实测 tx 拖动成功（60→65.8s）** |
| 0.11.11 / 0.11.12 | 队列行的码率估算：`types[].size ÷ 时长`（kg/tx/mg/wy 有 size；kw 没有）写进行属性 ⇒ 未播放的行也能显示码率（kg 实测 1598kbps），播放后被真实探测值覆盖 |
| 0.11.13 | **歌单详情页头配方**（最新/最热/推荐歌单的曲目页）：feed 级 `image/play/actions/albumData`；`play` 一出现模板就不再渲染自动的 "All Songs" 行，同时**删掉两行冗余**（歌单名 / ▶ 播放整个歌单）⇒ 列表第一行直接是曲目 001。整单播放改由页头按钮走新增的 `lxm://l/<src>/<plid>`（`explodePlaylist` 加歌单分支）；歌单窗口也按响应 `limit` 校正页宽 |
| 0.11.14 | **kg artwork 真图**：`imge.kugou.com/stdmusic/240/<albumId>.jpg` 对不同 albumId 返回**同一张占位图**（实测 5 个 id → 同一 md5）；按官方 `kg/pic.js` 的 getPic 移植：封面代理 POST `media.store.kugou.com/v1/get_res_privilege`（KG-RC/KG-THash 头 + album_audio_id/album_id/hash）取 `info.image` 再转发。实测 5 行 → 5 张不同真图 |
| 0.11.15 | `board_render` 加诊断 warn（src/bangid/play/total/rows）——用来证明 mg 的 feed **确实**发了 play/actions（见 §5.11.78） |
| 0.11.16（**未装机，被 0.11.17 取代**） | 整榜入队也发布码率估算（与列表行一致）。装机流程见 §5.11.77。历史注：设备上从 0.11.15 直接跳到 0.11.17 那一轮（用户手工装） |
| 0.11.17（**已装机**） | **修「tx 不能拖进度条」**（§5.11.79）：`bitrate/secs` 原先只发给了 `lxm://` URL，而 LMS 的 `HTTP::getSeekData` 是拿 `$song->currentTrack()`（**直链**那条记录）查码率 ⇒ 查不到就 `return`（undef seekdata）⇒ `_JumpToTime` 的 `return unless $seekdata` 把拖动**静默丢弃**。现对 lxm:// 与直链**两个 URL 都发** ct/bitrate/secs |
| 0.11.18（**已装机**） | **自己实现 `getSeekData`**（不再依赖 LMS 的码率查询）：返回 `{timeOffset}` 恒非 undef，另按 `len*t/secs`（探测总长优先）或 `kbps*1000/8*t` 给 `sourceStreamOffset`；`_cache_put` 把记录同时挂在 lxm:// 与直链两个 URL 下；`_finish_resolve`/`_trackItems` 透传 `secs`/`length`；shim 的 probe 用 `Content-Range` 总量当 `length` |
| **0.11.19（已装机，已验收）** | **修「mg 完全不能播」**（§5.11.80）：解析出来的直链是 **https**（咪咕 `freetyst.nf.migu.cn`），而我们的处理器继承的是 `Slim::Player::Protocols::HTTP` —— 它下面是**明文** `IO::Socket::INET`，于是 LMS 拿明文 HTTP/1.0 去打 443，CDN 回 `400 Bad Request` ⇒ `PROBLEM_CONNECTING` ⇒ 70ms 就 stop。修法：有 SSL 时把基类换成 LMS 自带的 `Slim::Player::Protocols::HTTPS`（= IO::Socket::SSL + HTTP，按协议自动分流，返回对象仍是我们自己的类 ⇒ 0.11.18 的 seek 覆盖仍然生效），没 SSL 时回落 HTTP 并显式报错。**实测：wy/mg（星海）+ mg（裤佬）+ mg 榜单行全部 PASS，mg/wy/tx 拖动均 PASS** |
| **0.11.20（已装机，已验收，已发布 GitHub v0.11.20）** | **换插件图标**（§5.11.81）：`install.xml` 加 `<icon>plugins/LxMusic/html/images/logo.png</icon>`（落雪桌面版官方图标，Apache-2.0，取 `lx-music-desktop/resources/icons/256x256.png`），随包放 `HTML/EN/plugins/LxMusic/html/images/logo.png`；`pack.py` 生成的 `repo.xml` 再加一条**绝对 URL** 的 `<icon>{base}/lxmusic_logo.png</icon>`（图标同时拷进 `dist/`）。此前插件管理器显示的是分类兜底图 `html/images/musicservices.svg`、apps 菜单里是收音机图标 `html/images/radio.png`。**装机实测**：apps 项 `icon:plugins/LxMusic/html/images/logo.png` ✓；插件管理器行走 repo.xml 的绝对 URL（`/imageproxy/…/image_50x50_o` + `…_100x100_o 2x`，均 200）✓ |

---

## 五、开发经验与坑（长期有效，按类归档）

### 5.1 qjs / shim（最容易翻车）
1. **⚠️ qjs 语义双雷（0.3.3 修复，本项目最大坑）**
   - `os.exec(args,{block:true})` 返回**纯数字退出码**，不是 `{exit_code}` 对象（quickjs-libc.c 注释 "exec -> exitcode"）。读 `r.exit_code` 得 undefined ⇒ 所有成功请求被误判失败 ⇒ 源重试耗尽报 `try max num` /「无法连接服务器」
   - `FILE.write` **只接受 ArrayBuffer(offset,length)，不收字符串**（POST body 写字符串直接 `TypeError: ArrayBuffer object expected`）
   - 教训：**模拟器 stub 必须照抄 C 实现契约**（我最初的 stub 顺手支持了对字符串，把两个雷全掩盖）；golden 依据 = bellard quickjs `quickjs-libc.c`
2. **qjs 顶层不跑 promise 微任务**：必须 `await` 让出栈；`await` 必须在 async 函数内。源脚本要手动 drain 到 `inited`
3. **count/units 陷阱**：桥的 `opts.timeout` 是**毫秒**，而钳制常量用**秒**（0.3.6 写成 `Math.min(3000, 15)`（毫秒混秒）⇒所有请求回到 15s，修复被无声回退）。**验尸金标准**：页面日志里 curl stderr 的 `timed out after N milliseconds`
4. shim 的 Buffer polyfill **必须在 `new`**（vendor 树有 `new Buffer(x)`）；`navigator.userAgent` 在模块加载期就被 kg infSign 读取（qjs 无 navigator ⇒ bundle 加载崩）
5. `node --check` 对 `.mjs` 按 CJS 解析会误报顶层 await——真实 ESM 验证用 `node -e "import('file:///…')"`

### 5.2 LMS / 达菲（契约层）
6. **主循环不驱动 AnyEvent**：回调永不触发。配置 = 子进程输出落临时文件 + `Slim::Utils::Timers` 轮询 `waitpid(WNOHANG)` + `POSIX::open/dup2` 重定向 fd（`open(STDOUT,…)` 会死在 Log::Trapper 的 tie 上）
7. **达菲过滤 info 级日志** ⇒ 诊断输出必须 `$log->warn`（或 `$log->error`）
8. **插件日志分类必须注册**：只 `logger('plugin.lxmusic')` 不注册 ⇒ 调试页不列出、重启后 warn/info 静默丢失。修法：`Slim::Utils::Log->addLogCategory({category=>'plugin.lxmusic', defaultLevel=>'ERROR', description=>'LX Music'})`；开 DEBUG 时必须带 **`persist=1`**（不带则重启即失效）
9. **插件基类必须 `Slim::Plugin::OPMLBased`**（0.1~0.3.0 误用 Base ⇒ feed/tag/menu 被无视，菜单/CLI 从未注册，是潜伏 bug）
10. **XMLBrowser 契约**：feed coderef 是`($client,$cb,\%args,@passthrough_flat)`（位置参数）；下钻靠 `item_id:<层级>`；CLI 搜索=`search:<词>`；**web 表单=`index=<序号>&q=<词>`**（不是 `search=`）
11. **新增 web 页面必须注册**：`Slim::Web::Pages->addPageFunction('plugins/LxMusic/cover', …)`——漏注册会落到 LMS 默认 404（0.5.6 现场：代理端点 404）
12. **`SimpleAsyncHTTP` 没有 `->request($req)`**：自定义 header 是作为 `get($url, @headers)` 的额外参数传给 Net::HTTP::NB::formatRequest（源码 L49-53 注释明示）。用错 ⇒ 页面处理器整体崩溃、端点对任何 URL 都返回连接失败（0.5.8 现场：改了 kg 却把原本正常的 mg 一起弄坏）
13. **LMS 把远程 m3u 当单条链式流**：`playlist play <m3u>` 队列里只有 1 条（顺序播但不可见不可跳）。**整单正确做法 = 插件侧展开**：feed 带`type=link` 项→handler 里 `Slim::Control::Request::executeRequest($player,['playlist','clear'|'play'|'add',$url])`（实测 `playlist add` 共 5-7ms）
14. **队列/正在播放元数据**：渲染期 `Slim::Music::Info::setRemoteMetadata($url,{title,secs,cover})`（否则队列行只有裸 URL）；解析完成 `currentPlaylistUpdateTime(time())` + `notifyFromArray($client,['playlist','newmetadata'])`（否则轮询客户端不刷新面板）
15. **分页**：handler 吃 `$args->{index}/{quantity}`，`page=int(index/50)+1`、`skip=index%50`；避免返回的 rows < 上报 total（会被补空行）。**0.11.4 起榜单走原生窗口（§5.11.71），此公式即其雏形**
16. **`Slim::Web::Settings`**：子类 + `require` + `->new()`（`if (main::WEBUI)`）；模板 `HTML/EN/plugins/<Name>/settings/basic.html`；基类会把**声明的每一 pref 都用表单值覆盖**（未勾选的 checkbox ⇒ 置空），所以模板里必须为每个声明的 pref 提供字段
17. CLI **9090** 是可靠通道（CLI 命令可下钻查状态）；`/jsonrpc.js` 可用但异常时 items 查询会返回空；POST 到`/` 只会返回皮肤 HTML

### 5.3 编码 / 中文
18. **`uri_unescape` 返回未打 UTF-8 旗标的字节串**，交给 LMS（`getMetadataFor`/`setRemoteMetadata`）会被按 latin1 再编码⇒队列/正在播放乱码（`å¨æ°ä¼¦`）。修法：`parseUrl` 里 `Encode::decode('UTF-8', …)`（FB_CROAK，失败保留原值）
19. **`join(' · ', …)` 混用旗标/未旗标串**会把非 ASCII 分隔符搞坏⇒分隔符也要过 `_u()`；m3u 是字节流 ⇒`Encode::encode('UTF-8', …)` 显式落字节
20. **PowerShell `Set-Content` 会写坏 UTF-8 中文（多次事故，禁令级）**——改文件一律用 python bytes replace / write·edit 工具；PS 拼 curl.exe 传 JSON 会吃内嵌双引号（body 用 `--data-binary @file`）。**（2026-09-21 第五次：`Get-Content -Raw | -replace | Set-Content` 把 HANDOFF.md 整个写成乱码，靠确定性反演恢复，见 §5.3.73）**

### 5.4 自主升级链（本项目最大工程资产）
21. **LMS 插件下载按 zip 文件名做 digest 校验**：同名 `LxMusic.zip` 连续升级报 `digest does not match` →**静默不装**（表现为"POST 成功但版本不变"）。**必须版本化文件名** `LxMusic-<ver>.zip`（pack.py 已改）
22. **仓库缓存 300s TTL**：两次 POST 间隔 <5min 会拿旧仓数据判无更新 ⇒等满 5 分钟再 POST，或用 `--repos=…?v=N` 换新 URL 破缓存
23. **安装序列**：`diag_plugin_install.py post LxMusic` →（等 TTL）→ `restart`（**有正在播放则中止守卫**，需先 stop 播放器）→**只看 `/plugins/LxMusic/index.html` 的页面版本号**确认
24. **日志端点延迟可达 10+ 分钟**（`/server.log?zip=1`、mslog、log.txt 都一样）⇒别把它当实时通道；实时诊断优先用「插件自己渲染在页面上的 logs 块」与 CLI/JSONRPC 查询。**2026-09-21 再次确认（0.10.x 轮）**：为了看播放链路，把 `player.source` 调到 DEBUG、等了一轮又一轮，`/server.log` 里连自己刚写的 `$log->error` 都看不到（只有启动行）——最后是靠**本地 `slimserver/` 源码 + 对照实验**定案的，别再指望它
25. 首次打包/升级的隐形前提：**Helper init 会重建 `/tmp/LXMusic`**；init 曾因 qjs 拷贝失败提前 return 导致 shim 停在旧版（已加固：shim/sdk 先拷、qjs 失败仅降级）

### 5.5 LMS 设置页 / TT 模板 / 打包（M0.5 现场，8 条全是设备实测踩出来的）
26. **TT 模板里的非 ASCII 会被双重编码**（本页第一乱码源）：`Slim/Web/Template/SkinManager.pm` 的 `Template->new({...})` **没有 ENCODING** ⇒模板文件里的 UTF-8 字面量按 latin-1 当字符读入，输出时再 UTF-8 编码 ⇒浏览器看到`å°é¢ä»£ç`（实测`封面代理`）**做法：本插件设置页模板一律"纯 ASCII + HTML 数字实体"**，由 `tmp/mk_settings_template.py` 生成（改文案改生成器后重跑）；Perl 侧动态串用`Settings::_ent()`（非 ASCII 与`&<>"'` 一起转实体）实体是 ASCII，管道里任何编码环节都改不坏，也不依赖服务器语言（达菲是 EN，照显示中文）*对照*：喜马拉雅设置页全用 `strings.txt` token + `| string`，在 EN 服务器上渲染英文——想让设置页显示中文就别走 token 路线
27. **LMS 设置模板的 stash 是顶层**：`$params->{lxVersion}` 在模板里必须写`[% lxVersion %]`！写成 `[% params.lxVersion %]` 会静默变空串（0.6.0 现场：诊断块三个值全是空的，最容易误判成"后端没数据"）只有 `prefs.pref_x` 带前缀（基类专门往 stash 塞了 `prefs` 键）
28. **页面里有两个 `<form>`**：皮肤顶部的 `setup_chooser`（action=`/setup.html`）与真正的 `settingsForm`（action=`/plugins/LxMusic/settings/basic.html?playerid=…`）。表单回放脚本必须认 `name="settingsForm"`。另外`settings/footer.html` 自带 `<input type="hidden" name="saveSettings" value="1">`，所以自定义按钮（`name="lxAction"`）提交时 `saveSettings` 也在，不必自己加但**同名参数出现两次会被 LMS 解析成数组引发**（`lxAction` 重复 ⇒`eq 'import'` 恒假、静默不导入）
29. **复选框 pref 的"取消勾选"会在重启后自己弹回**：未勾选⇒表单不带该字段⇒基类 `set($pref, undef)`，而`Prefs::Base::init` 把`undef` 当"未初始化"，下次启动重灌默认值(1)**修法：handler 里在调 SUPER 之前，把表单未出现的布尔 pref 显式置 `0`**（才是持久值）
30. **zip 内的固定时间戳会让 TT 编译缓存永久命中**：`Archive::Zip::extractTree`（PluginDownloader）解压**保留 zip 的 mtime**，而 TT 按 mtime 判编译缓存（`COMPILE_DIR=<cachedir>/templates`、`STAT_TTL=3600`）pack.py 曾写死`(2026,9,18)` ⇒0.6.1 改了设置页模板，设备仍渲染 0.6.0 的编译结果（**页面逐字节相同**）**pack.py 现在用打包时刻**（`SOURCE_DATE_EPOCH` 可复现）。判据：改 `.html` 没生效时，先比对页面字节数与文案代次（旧代次缓存命中），再怀疑装机
31. **URL 下载来的订阅源是字节流**：`_fetch`/curl 给的是原始字节，而`installSource` 用`:encoding(UTF-8)` 落盘 ⇒必须先 decode 成字符，否则每个非 ASCII 字节被再编码一次（实测：4094 B 的源落盘成**72249 B**！源被改坏 ⇒签名握手失败、取不到直链）。已收敛到`Helper::installSource` 一处（字节串→字符；非纯 UTF-8 原样保留）
32. **导入订阅源绝不能裁剪首尾空白**：lx 源的完整性签名基于原始字节，尾部少一个换行落盘就坏（**64093 B**，0.6.2 现场，`_installSource` 多了一次`s/^\s+|\s+$//g`）。判形态可以裁剪副本，落盘必须原样另：LMS 9.0 已无 `logLevelForCategory`，取日志级别用`Slim::Utils::Log->allCategories()->{category}`
33. **设置入口是两道独立手续，缺一个就是"没有入口"**（0.6.3 现场，用户报"settings 的入口没有"）：
    - **插件行的 Settings 链接**来自 `install.xml` 的**`<optionsURL>`**（`Slim/Utils/ExtensionsManager.pm` `settings => $entry->{optionsURL}`）；漏了它 = 设置 →插件 那一行没有 Settings 可点
    - **设置下拉/页面标题的可见文字**来自 `Slim::Web::Settings::name()`，而它的契约是**返回 strings.txt 的 token**（基类把它当键做 `addPageLinks`，皮肤用 `| string` 渲染）。返回显示串会渲染成**空标签**（实测`<option value="LX Music" label="">`，下拉里是一行空白）。修法：`name()` 返回 `PLUGIN_LXMUSIC` + 插件根加 `strings.txt`（EN/ZH_CN）；`install.xml` 的`<name>`/`<description>` 同理必须是 token
    - 判据/取证：`tmp/probe_settings_entry.py`（下拉条目 + 插件行链接 + selected）、`tmp/probe_chooser_option.py`（原始 option 标记）、`tmp/probe_chooser_js.py`（chooser 的`case "TOKEN" -> url` 跳转表）
    - 注意：chooser 的 URL 跳转表是**按注册值生成**的，所以漏 token 时导入 case 仍在（`case "LX Music"`），症状只表现为"看不见、点不动"——别被"JS 里有 case"误导

### 5.6 多源 / 音质 / 编码（M0.6 现场，3 条）
34. **"混旗标串"会把中文字面量按字节逐个转义 ⇒双重编码乱码**：本插件的`.pm` 中文字面量是**字节串**，而 JSON 解出的值（源名/路径）是**旗标串**；`'已添加在线订阅：' . $rec->{name}` 一拼，整串变旗标串，字面量的每个字节被当成一个字符⇒上层 `_ent`/`encode_entities` 逐字节转义⇒页面显示 `å·²æ·»å ` **修法：拼文案一律走 `_m(@parts)`（先把每个片段 `_chars` 归一，再 join）**，`Settings.pm` 与`Sources.pm` 各有一份。同族坑见§5.3.19（join 分隔符）。判据：消息里出现"部分中文正常、部分乱码"就是它
35. **prefs 里存 JSON 不要用`JSON::XS->utf8`**：`utf8` 模式产出的是"含高位字节的字节串"，落到 `YAML::XS::Dump`（`Prefs/Namespace.pm:327`）会出二进制/乱码风险。用**字符模式**（非 ASCII 转`\uXXXX`，落盘纯 ASCII，读写往返稳定）。另：`plugin/t_local/JSON/XS.pm` 原来是手写假实现（不转义非 ASCII，decode 直接喀 decode_json），会把"存进去读不出"这类问题在本地测试里静默掩盖——已换成 **JSON::PP 薄封装**
36. **`Set-Content` 又写坏了一次中文**（install.xml 注释，第四次）：改文件**只用 write/edit 工具**！"哪怕只改个版本号"也别用 PowerShell（`-replace | Set-Content` 会按 ANSI 读、UTF8 写）另：在`.pm` 里中文时若用脚本批量替换，替换后务必 `perl -c` + 跑一次设备页面验收

### 5.7 打包门禁与"插件被 LMS 摘除"的恢复（M0.7 现场，5 条，含一次自伤事故）
37. **【事故】编译失败仍打包上机 ⇒LMS 把插件从"已安装"列表摘掉**（0.8.0 的 Plugin.pm 有 `Global symbol "$src"`（我改搜索时漏了变量作用域），`perl -c` 的失败我没当门禁，pack 照跑；装机时 LMS 加载失败（`Slim::bootstrap::tryModuleLoad` 警告 "failed to load"），后果不是"插件不工作"而是 **插件从已安装列表消失**：插件页只剩仓库候选（`<input name="LxMusic" class="unsafePlugin">` + 空的`install:LxMusic`），所有插件页面 404，且**此后所有 POST 都装不上也启不了**（因为 `update:<plugin>` 对未安装的插件是空操作）修法：**先立门禁** `powershell -ExecutionPolicy Bypass -File tmp/precheck.ps1`（所有 .pm 必须 `syntax OK` + 模板纯 ASCII + shim.mjs 过 `node --check`），**通过才允许 pack**；再用 `tmp/repair_install.py`（见 38）重新安装启用 + 重启即可恢复
38. **插件设置页表单有重复字段名（`repos` 两条），必须用保序 (name,value) 列表回放**：我用 dict 收字段（`d[n]=v`）跑"修复"脚本，把两条 repos 并成一条⇒`Slim::Web::Settings::Server::Plugins` 按提交的 repos 集合与当前集合做增量⇒**把 LAN 仓库删了**，插件候选直接从页面消失（比事故本身更难查）。正解：沿用 `tmp/repair_install.py`（列表式 + 浏览器语义 + `--repos=` 覆盖 + `install:<name>` 标记 + `<name>` 勾选）回放
39. **单源搜索返回 hashref、跨源返回 arrayref**：`_webSearch` 里`@{$res->{data}}` 在单源时直接 die（"Not an ARRAY reference"）⇒ 页面挂到超时（浏览器/urllib 都只看到 hang，没有错误页）正解：`my @groups = length $src ? ($res->{data}) : @{ $res->{data} };`
40. **解析缓存会污染故障注入测试**：同一 `lxm://` URL 只要曾经解析成功就会命中缓存 ⇒故意"注入失败"的测试会得到"能播"的假象。做失败路径测试必须让 URL 唯一（改 `n=` 查询参数即可）
41. **LMS 本身在"取不到 URL"时就会跳下一首**：实测把 `autoSkipOnError` 关掉、禁用全部订阅源，LMS 照样从 index 0 跳到 1。所以本开关的真实语义是「**立即跳**（不等 LMS 自己的错误流程）+ **限流(429)时不跳** + **防连跳风暴（60s 内最多 3 次）**」，而不是"是否跳"若用户要"失败即停住不跳"，得另想办法（LMS 的行为不可由插件关闭）

### 5.8 M0.9：宿主 API 契约与"静默失败"（M0.9 轮，5 条，全部来自设备实测）
42. **`lx.on` / `lx.send` 必须返回 Promise**（权威依据 desktop-preload.js:243-272）：返回 undefined 时，源里的`lx.on('request', h).then(...)` 直接报`not a function`（ikun/huibq/huanyin/juhe 一类源的失败原因）`lx.request` 还要返回**取消函数**（`desktop-preload.js:238-241`；同步 curl 实现里做成 noop）
43. **宿主 polyfill 缺一个成员就能废掉整个源**：ikun 只因为缺 `console.group` 就在它第 121 行 TypeError。教训：`console`（含 group/table/trace/time/assert）、`Buffer`、`navigator`、`TextEncoder/Decoder` 这类"看起来永远不会被用到"的东西，要么完整实现，要么别让源走到那儿
44. **子进程 stdout 指向文件 ⇒glibc 全缓冲⇒超时 KILL 时日志连 RESULT 全丢**（现象：父进程只看到 `no RESULT line` 且页面日志区空白）。修法：把`print` 包一层**每条都 `std.out.flush()`**这是"无痕失败"的根因，所有 Perl+fork 桥都该这么做
45. **qjs 的`os.exec({block:true})` 返回的是"纯退出码"，不是 wait status**：旧代码 `sig = status & 0x7f` 把 curl 的`exit 35`(SSL 连接错误) 误报成"killed by signal 35"，同时让 `exit 28`(curl 超时) 的专用分支永不触发（死代码）。判据：>255 才可能是原始 wait status
46. **失败必须带上子进程的最后两行日志**：把 `$res->{logs}` 尾部并进 resolveTrack 的`tries[].why` 之后，真因才显形。**M0.9 结论（0.9.6 实测全部 10 个源）**：契约诊断修完后，剩下 7 个源**没有一个是"缺宿主 API"**，全部卡在**它们自己的上游 HTTP**：
    - 六音 `failed {LOG resp: code=403 ... <title>403 Forbidden</title>}` ⇒上游拒绝本设备（源侧/上游侧）
    - ikun `curl exit 35`（SSL 连接错误）⇒ 上游 TLS 不可达
    - Huibq `unknow error` / `curl exit 56`（连接被重置）
    - 幻音 `verify: no response`（取回的直链根本连不上）
    - 野花/野草/聚合API `Error`（源自己的通用报错，上游不可用）
    ⇒**M0.9 目标达成**：引擎侧不再是瓶颈，且失败可自证；要救活它们得等上游恢复或换源
    job loop 看门狗（0.9.6）已就位：promise 一 settle 时显式报错 + 带轮数/待处理定时器数

### 5.9 订阅源实测与校验探测（3 条）
47. **取链校验必须跟随重定向**：探测用 `curl -I` 不跟 `-L` 时，301/302 会被判成"不可播"实测代价极大：长青音源因此从 **5/5 被误判成 0/5**。修法：`curl -sS -L --max-redirs 3 ...`（**-L 会在 -D 里留下中间跳的响应头块⇒必须只解析最后一个块**（否则读到 301 而不是最终 200））（真实播放链路本来就会跟随重定向，所以这是纯粹的自伤式误杀。）
48. **低码率要当异常报出来**：`Content-Length*8/时长` 若**< 64kbps**，极可能是试听片段/残缺文件（实测长青 kg flac24bit 只回 ~48kbps，而同一首在别处是 1647kbps）。现在 resolveTrack 里 `$log->warn(... SUSPECT ...)` 并在工具页判决行标`⚡码率异常低，疑似试听片段`
49. **一个源仓库里能用的往往只有少数几个，且失败要分清责任**：`pdone/lx-music-source` 的 10 个源实测只有 2 个可用（见§八矩阵）：链接真死（qdy 410）= **源侧**；`no RESULT line` / `not a function` / `curl exit 35/56` = **引擎侧或设备网络侧**。别把两者混为一谈

### 5.10 M0.10：常驻 worker + 播放链路（0.10.x 轮，9 条，全部设备实测）
50. **每请求 fork 的固定开销是"取链"里最大的一块**：常驻 worker（`shim.mjs <src> serve`，stdin 行＝`{"id":N,"action":..,"source":..,"info":{}}`，stdout `READY{}`/`RESULT <id> {}`/`LOG ..`）把「起 qjs + 解析 shim/源脚本 + 源 rconfig 握手」摊到进程生命周期里。同曲目 A/B（工具页 4 首不同曲）：**固定开销 306ms→51ms**，总耗时 0.87s→0.52s；冷启动 0.94s ≈ fork（首曲不亏）通道选**POSIX 双向管道 + Timers 轮询 `sysread`**（不能用 `open(STDOUT)`：撞 Log::Trapper tie，0.2.6）worker 起不来/写失败/超时/进程死⇒一律 kill 后**回退 fork 路径**（重试即在 fork 里完成）
51. **三个把收益吃光的坑（都在父进程侧）**：
    (a) **轮询节奏**：空闲时 2s 一次的回收 tick 会让新请求白等最多 2s（实测每首多花 1.5s）。修法：下发时`_worker_wake`（kill+重排到+50ms），在跑时 50ms 细粒度，空闲 2s⚠️ 在 poll 回调内部不要 kill+重排（会与自己抢 timer），用`local $w->{in_poll}` 标记 + `wake` 标志
    (b) **`%hash` 在布尔语境永远为真**（Perl 的标量值是 `"0/8"`）⇒ 空闲回收判断 `!%{$w->{jobs}}` 永不成立、worker 永不回收。一律写 `scalar(keys %h)`
    (c) **必须拿到 `O_NONBLOCK`**：阻塞 `sysread` 空管道= 整个 LMS 卡死。拿不到则**不启用 worker**（回退 fork），别赌
    另外：job 的超时**从真正下发那一刻起算**（排队等冷启动不该吃请求超时），背压 ≈4 个在跑就回退 fork
52. **校验探测从"HEAD"升级为"取实体 + 嗅探魔数"**：HEAD 200 完全可能是空壳/错误页。现在`probe` 是 `curl -r 0-2047 -o body --max-filesize 400000`（跟 `-L` 且只取最后一段响应头），读回前 2KB 按 ID3/fLaC/OggS/ftyp/RIFF/ff-fb/APE，并拒绝 HTML/JSON 开头；`data.magic/bytes/head` 一并回给页面⚠️ Range 响应的总长度在 `Content-Range` 里（`Content-Length` 只是这一片）——量码率要用总长
53. **真凶不是插件，是"无音频后缀的脚本中转链"**：长青的直链形如 `http://yinyue.haitangw.net/kw/kw.php?type=mp3&id=228908&level=exhigh`（末段没有`.mp3`）设备实测：**同一 URL 直接喂播放器 →正常出声（位置前进）**；走 `lxm://` →`mode=play` 但**位置永远 0 秒**（LMS 用`Slim::Music::Info::contentType($track)` 判代理流格式，lxm:// 没后缀 ⇒`unk` ⇒`Couldn't create command line for unk playback`）。而**独家音源的直链 `.../M800000bYDlc2XxKLs.mp3` 正常播放**
54. **⚠️ 达菲雷区：不要给这类 URL 加 `formatOverride`**。LMS 在`Slim/Player/Song.pm::open` 里留了 `if ($handler->can('formatOverride'))` 钩子，看似是正解；实测两次把 LMS 主循环彻底卡死（TCP 不 accept、CLI/Web 全无响应，只能重启达菲：`http://192.168.2.111/cgi-bin/Settings?ACTION=restart`）最终采用**两遍策略**（pref `preferStreamable`，默认 1）：第一遍只认播放器友好（末段带 `.mp3/.flac/.m4a/.ogg/.wav/.ape/.aac`）的直链，友好的直接交付；不友好的**当场不做 HEAD**，只挂起当兜底，等确实没有友好直链时才回头校验并使用它（兜底实测：无声但不卡死）代价：源顺序里排在前面的中转链会被跳过（每首多花 ~50ms），收益：**不再无声**
55. **⚠️ "随手加个诊断日志"会改变行为、甚至打断播放链路**（0.10.4 现场）：我在播放期回调 `ProtocolHandler::new` 里打了`$args->{song}->url`——`Slim::Player::Song` 在那一刻**没有 `url` 方法**，直接抛异常，而它抛在 `Slim::Networking::Async::HTTP::_http_read_body` 的调用栈里⇒流打不开规则：① 播放期诊断一律 `blessed($x) && $x->can('m')` 守卫 + `$log->is_info` 门控；② 诊断**验完就删**（0.10.5 已删干净）；③ 改过日志级别（`tmp/lx_set_loglevel.py` / `tmp/set_debug.py`）**收尾必须复原**（0.10.x 轮曾把`plugin.lxmusic`/`player.source` 留成 INFO/DEBUG，已复原为 ERROR——这种"现场残留"下个 session 要先查）
56. **定位"没声/卡死"要用可重复的对照实验，别只靠日志**：设备日志端点延迟 10+ 分钟（0.10.x 轮再次确认），照它下结论会跑偏。0.10.x 轮靠三条对照把假说逐个否掉：① 同一 URL「裸播（`tmp/test_url_play.py`）vs 走`lxm://`（`tmp/test_play.py`）」；② worker「开 vs 关」（改`pref_workerEnable` 即可，无需重启）；③ 探测「先跑 vs 不跑」（`tmp/test_raw_play.py` 解析出直链后再裸播）——曾误判"校验探测把中转链用掉了（毒化）/ LMS 的 UA 被拒"，两者都被实验否掉（同一 URL 裸播正常）
57. **"取链成功 / mode=play / 有 dur"都不等于能播**——本项目的播放验收口径（**必守**）：
    - 唯一判据 = **位置持续推进**（`tmp/test_play.py` 的`time` 从 0 涨到 5s+，且 `title` 正确）；
    - `mode=play` + 位置恒 0 = 无声（达菲的典型表现）；`dur` 来自我们自己的探测元数据，不能当证据
    - 每次播放/取链验证后**必查 `tmp/liveness.py`**（CLI 有响应= 主循环没卡死）；
    - 一次 CLI 无响应⇒LMS 主循环卡死，只能重启达菲（0.10.54 的 CGI）
    - ⚠️ 窗口也要够长：中转链起播可能 6~10s（**窗口太短会把"慢起播"误判成"不能播"**（0.10.x 轮就吃过一次：6s 窗口把 kw lossless 误判 NO AUDIO；4s 窗口一 4.5s 就出声）
58. **"长青是 VIP 源"不是没声的原因**（2026-09-21 用户提问后的实测结论，别再来回猜）：
    - 整条链路**没有任何 cookie/token/鉴权**：插件探针（设备 curl，无任何凭据）能取到完整实体、字节头与档位相符（lossless/hires →`fLaC`，exhigh/standard →`ID3`，见 `tmp/relay_magic.py`）；本机 curl 同样能取
    - **同一个中转链、只换档位**（`tmp/vip_tier_test.py`，同一 id、同一路径）设备侧裸播实测：
      | 平台 | standard(128k) | exhigh(320k) | lossless(flac) | hires(24bit) |
      |---|---|---|---|---|
      | kw | PLAYS | PLAYS | **PLAYS** | **PLAYS** |
      | wy | PLAYS | PLAYS | **NO AUDIO（10s 窗口位置恒 0）** | **NO AUDIO** |
      | mg | PLAYS | — | 取链即 403 | — |
      ⇒能出声的档位不少，所以**不是"会员没生效/缺鉴权"**，而是这个中转链**各平台各档位质量参差**（wy 的 flac 档在设备侧硬失败；而同一 URL 本机 curl 367KB/s 正常取回 ⇒差异在设备播放器侧，不在链本身）
    - **探针（取 2KB）抓不到这类问题**：wy lossless 的 verify 是 OK（1562ms，比 kw 的 352ms 慢 4 倍），但一播就是 0 秒。所以探针通过"不等于能播"——这正是 `preferStreamable` 要绕开脚本中转链的原因
    - 结论/口径：**长青的直链形态（自家脚本中转链、无音频后缀）才是问题**；VIP 只解释了"它为什么要给中转链"（拿不到原始 CDN 直链，只能自己中转）。要让它真正可用得由源作者返回 CDN 直链；我们这边补 `formatOverride` 会让达菲流水线卡死（§5.10.54），不值得再试

### 5.11 M0.11~M0.15：榜单翻页 / 播放元数据 / 拖动 / https / 换源 / 图标 / 发版（0.11.0~0.11.20 轮，共 27 条：59~85，本机+设备双实测）

59. **wbd 签名端点的死法要分层看**：`wbd.kuwo.cn/api/bd/bang/bang_info` 对旧实现返回 `{"code":10006,"msg":"DECRYPT_ERROR"}`——但**裸请求（无 data 参数）返回`10004 AppId错误`**，说明 `appId=y67sprxhhpws` 还在白名单里，**只是 AES key 被上游换掉了**。refs/ 各克隆（desktop/mobile/lxmusic2api）全是同一套旧实现，本地没有现成新签名。别再回去试旧 key
60. **换端点比补签名划算**：洛雪 PC 端的免签名端点`kbangserver.kuwo.cn/ksong.s` 还活着（`from=pc&fmt=json&pn=<0基>&rn=100&type=bang&data=content&id=<bangid>&show_copyright_off=0&pcmp4=1&isbang=1`），**静态榜单 25/25 全部返回有效数据**（本机+设备双端）。注意`from=phone`/`from=mbox` 会报 `no bangid`——只有`from=pc` 这条形态能用
61. **老端点的载荷也被瘦身过，字段名全变了**：没有`n_minfo`/`pic`/`albumId`/`duration`，取而代之：`formats`（`|` 分隔令牌串）/`albumid`/`song_duration`（秒；`duration` 现在是"在榜时长"，别用错）音质声明由 formats 映射：`MP3128→128k`、`MP3H→320k`、`ALFLAC→flac`、`ZP*`（臻品母带/全景声/黎音）→`DTSX→flac24bit`，其余（MV*/SMP4*/EX*/WMA*/AAC*/OGG*/BCMS）忽略。types 不是纯展示——**Perl 侧`qualityLadder` 和订阅源脚本都靠它裁剪档位**（Helper.pm:125）；映射只影响"多试几档"，映射错的代价 = 多一次失败重试，不会播不出
62. **封面缺失不是问题**：插件本来就有 kw 兜底（Plugin.pm `_coverOf`：无 img 的 kw 曲目走 `kw:<songmid>` →封面代理 →`artistpicserver.kuwo.cn/pic.web?...&rid=<songmid>`），榜单条目 `img:null` 即可，设备实测封面正常走 `/imageproxy/.../cover?u=a3c6...`
63. **动态榜单目录（`qukudata q.k tree`）活着但别用**：它返回的 sourceid 子集与 kbangserver 的 id **不同且不完整**（12 个子节点，不是 93/16 这些主榜），静态 boardList 反而更全更稳探明的死路（别再试）：`bd-api.kuwo.cn/api/service/rank/*` 全 404；`nplserver pl.svc` 不吃榜单 id（pid=93 返回空 musiclist）
64. **榜单 id 传参约定**：菜单透传的是**裸 bangid**（Plugin.pm passthrough `$_->{bangid}`），但防御起见 kg/tx 的`getList` 内部都做了`id.replace('<src>__','')`，kw 现在也照做（0.11.0 首版就是因为没剥前缀把`kw__16` 直接拼进 URL 而`try max num`；harness 一跑就现形）——`node node-sdk-harness.mjs boardlist kw 16 1` 是 kw 榜单的标准本机验证
65. **`_trackItems` 返回数组引用，不是列表**（0.11.1 致命坑）：`my @items = _trackItems(...)` 在列表语境把引用变成"单元素"，`items => \@items` 得到 `[[50 首]]` →LMS CLI 路径拿 ARRAYREF 当`{ignore}` →`Not a HASH reference at Slim/Control/XMLBrowser.pm L1012`，**feed 查询静默无响应**（无 die 标签指向插件代码！）。正确写法：`my $items = _trackItems(...); items => $items`（songlist 详情 L714 的 `push @items, @$tracks` 是佐证）。凡 die 在 Timer 回调里，日志行首是`Timer …:_poll failed:`
66. **LMS 对相同版本号的重装会静默跳过**（0.11.1 排查大弯路）：`?v=N` 只 bust 我方 repo.xml 的缓存，LMS 侧仍按 install.xml 的`<version>` 决定是否重装——0.11.1(坏) →修好后仍用 0.11.1 →POST 安装「成功」但设备跑的还是坏版。**凡修 bug 重发，版本号必须 +1**（这也是 precheck 之外的隐性门禁）症状：日志里同一 die 的时间戳一直在更新 = 修的代码根本没上机
67. **查 LMS 服务器日志的正确入口**：`http://<设备>:9000/server.log?lines=N`（`?full=1` 全量）——Daphile 的/cgi-bin/Info 页是 JS 渲染拿不到日志链接，:9000 的`settings/server/debugging.html` 页面里能 grep 出这些端点。这轮全靠它定位（裸 CLI 查询 + 日志时间戳交叉验证）
68. **达菲 CLI「响应慢」多半是自己的客户端读循环**：`lx_cli.py` 的 recv 循环在响应分多个 TCP 段时会等到 25s 超时才返回（表现=恰好 25.1s）。判别真慢 vs 假慢用**裸 socket + 每包时间戳**探针（本轮临时脚本思路：connect →send →逐 recv 打`%.1fs N B`）。`version ?` 0.0s 回= 服务器没病
69. **榜单/专辑「页头」配方（喜马拉雅 0.1.34→0.1.54 验证过的组合，本项目 0.11.2 落地）**：feed 回调（CLI 与 Web 同一路径）在返回哈希上加 feed 级`image`（Web 页顶部大图，经封面代理）、`play => 'lxm://b/<src>/<bangid>'`（触发 songinfo 页头，**同时抑制模板的 All Songs 行**）、`actions => {playall|addall|insert => {command => ['playlist',…URL], fixedParams => {}}}`（只留 *all 键！普通 play/add 留在 feed 级会盖到每一行的行内按钮）、`albumData`（页头文字行）配套 `ProtocolHandler::explodePlaylist` 认`lxm://b/` 前缀：fetch 整榜→`buildUrl` 逐曲→`_publish_cover` + `publishQueueMetadata` 后回 `\@urls`（LMS Commands L1383-1400 机制）
70. **kw 榜单封面**：kbangserver body 的`v9_pic2` 是完整封面 URL，路径段 `/120/` 可换 `/240|400|500/`（500=26KB 实测 200）；`pic` 只是目录基址不是图。壳侧 `info{name,img}` 已在 0.11.2 返回
71. **coderef feed 的翻页用原生窗口，别学收藏夹**（0.11.3→0.11.4 血泪）：0.11.3 把喜马拉雅**收藏夹 HTTP 路由**的 feed 内嵌「下一页/跳页」行方案错当它的主方案——用户指出那"是没办法的办法"，喜马拉雅专辑、榜单入口用的都是**原生翻页**：handler 吃`$args{index,quantity}`（Slim/Web/XMLBrowser L505-517 回取时 index=$stash{start}、quantity=itemsPerPage；Slim/Control 同名参数走 CLI/jive），按上游页宽顺序补取攒够窗口，feed 回`{items(该窗口), offset(=index), total(全榜数)}`（Slim/Control L787 count=total、L1002 start-=offset）。UI 页码自己渲染。**CLI 探针注意**：CLI 端对同一 menu feed 有短时缓存，连续探针会命中旧缓存切片，造成"错位"假象——判窗口正确性要么等缓存过期要么换从未请求过的窗口附：OPMLBased 的 web 路由 `plugins/<tag>/index.html` 被插件自定义 webHandler 遮蔽（我们的工具页），web 路径没法裸测，只能 CLI 数据层 + 用户目验
72. **改日志级别的正规姿势**：`diag_settings_form.py save settings/server/debugging.html plugin.lxmusic=DEBUG`（**整表回放**，单字段 POST 不生效）；完事记得 save 回 ERROR。注意达菲过滤 info 级⇒要看 resolve 细节得直接选 DEBUG（warn 级的 job 日志不受影响）
73. **【事故】PowerShell 读写把 HANDOFF.md 整个写成乱码**（2026-09-21）：`Get-Content -Raw` 按 ANSI(GBK) 读 UTF-8 文件 →`-replace` →`Set-Content -Encoding UTF8` 写回，双重编码 + '?' 有损洞。恢复 = 确定性反演（.NET cp936 全表 + EUDC/PUA 映射 + UTF-8 结构回填 + 词表软约束 DFS）+ 人工校对。**教训与 §5.3.20/36 同族**：中文文档只走 write/edit 工具；PS 只做字节级操作
74. **榜单翻页的真实契约：上游页宽 ≠ 50，且行号必须跨页连续**（0.11.5-0.11.7，用户两次报「没有翻页/只有一页」）
    - **达菲 UI 走的是 Web XMLBrowser 路径**（不是 jive）：`GET /Daphile/plugins/lxmusic/index.html?index=<树路径点分>&start=<窗口起点>`。
      注意**小写 `lxmusic`**（OPMLBased 注册 tag）没被我们的工具页遮蔽——我们的工具页注册的是大写
      `plugins/LxMusic/index.html`，只遮住大写那条。所以榜单页真身可以直接 curl 取证（不必开浏览器）：
      `curl "http://设备:9000/Daphile/plugins/lxmusic/index.html?index=2.2&start=50&player=<mac>&sess="`，
      页码条就是模板渲染的 `<div class="pagebar" id="pagebar">`（含 `?start=50` 链接 + ▶ 箭头），
      **服务端渲染没问题**——别再去 UI/CSS 里找原因（本轮在 Material/皮肤 JS/CSS 上白花了一轮时间）
    - **真 bug ①（0.11.5/0.11.7）**：各源 SDK `getList` 的上游页宽是 kw/kg **100**、tx 300、mg 200、
      wy 100000（整榜一次给），旧代码硬编码 50 ⇒ `start=50` 实际取到第 101-150 首（错位），
      `start≥150` 直接请求不存在的上游页 ⇒ 上游报 `try max num` ⇒ 页面渲染「获取失败: try max num」。
      **修法**：页宽从响应的 `limit` 学（首响应不符即重算重取），并用按源默认表让**首次**请求就落在
      正确页上——否则首次越界失败时响应里没有 `limit`，就永远学不到宽度（0.11.5 只做前者，
      start≥150 仍然全灭，正是这个"学不到"陷阱）；再加"首请求失败→探第 1 页学 limit"兜底
    - **真 bug ②（0.11.6）**：`_trackItems` 的 `%03d` 行号是**页内序号**，翻到第 2 页仍显示 `001-050`
      （歌名换了但编号没换）⇒ 用户肉眼判定「还是同一页 / 只有一页」。改成绝对序号
      `_trackItems($list, $pfx, undef, $index)` 后页码与内容才对得上（第 2 页显示 051-100）
    - **验收口径**：`tmp/verify_final.py`（逐页取真页面 → 解析 `class="primaryInfo"` 行 → 比对
      上游 `kbangserver` 原始榜单的逐首顺序），要求**编号连续 + 内容逐首一致**，而不是只看行数
    - 已知限制：**mg 榜只有 1 页**——它的 `getUrl` 完全忽略 page 参数、接口固定回 50 条且 `columnInfo`
      虽有 `contentsCount` 但没有可用的分页参数（探过 `pageNo/pageSize/needAll=1` 均无效）。
      与其报假页码（翻过去还是同样 50 首），不如保持 `total=list.length`（宁缺毋滥）。要真分页需换接口
    - 另：**别再用 PowerShell 改 `install.xml`**——本轮又发现它的中文注释是乱码（§5.3.20/36 同族事故残留），
      用 python 按行替换修好了
75. **【重要】"进度条在走但完全没声音"= CDN 撒谎的 Content-Type 让 LMS 选错解码器**（0.11.8，tx/wy 主症状）
    - **取证方法（下次直接照做）**：开 `player.source=DEBUG` + `plugin.lxmusic=DEBUG` → 用
      `tmp/test_play.py <曲> <src> flac 5` 播一次 → `tmp/read_fresh_log.py` 看格式决策行（`tmp/read_format_log.py` 是过滤版）。
      **判据**：日志里出现 `Checking formats for: <X>-<X>-*-*` 与 `Transcoder: streamformat=<X>`。
    - **坏的样子**（tx，2026-09-21 现场）：
      ```
      LxMusic: resolved via [独家音源] type=flac verified=1 ~0kbps fmt=flc     ← 我们知道是真 flac
      TranscodingHelper: Checking formats for: ogg-ogg-*-*
      Matched: ogg->wav via: [Decode] -F ogg-wav-daphile-* ...
      Song::open (427) Transcoder: streamMode=I, streamformat=ogg              ← 把 FLAC 交给 OGG 解码器
      ```
      表现 = `mode=play`、位置可能先走几秒（或恒 0）、**完全无声**，随后复位/跳曲。
    - **根因**：QQ 音乐的 `.flac` 直链返回 `Content-Type: audio/x-ogg`（用 `tmp/inspect_stream.py` 一测便知：
      容器=flac 44.1k/16bit 940kbps，但 `Content-Type=audio/x-ogg`）。LMS 的
      `Slim::Player::Protocols::HTTP::parseHeaders` 会把这个头用 `mimeToType` 映射后
      `setContentType($url, 'ogg')`；而 `Song::open` 的 `my $format = contentType($track)`
      对 **track 对象**直接读 `content_type` 字段 ⇒ 扫描回来的那个 track（它已被重指向 lxm:// URL）
      带着 ogg。kw 之所以一直正常：kuwo CDN 老实声明 `audio/x-flac`。
    - **修法（只动我们插件，绝不改 LMS 代码）**：
      ① `ProtocolHandler::_finish_resolve`：`ct` 不再用档位标签猜，改用**我们嗅探出的 `$fmt`**；
        再 `Slim::Music::Info::setContentType($url, $fmt)` + 对 `$direct` 也设一次；
      ② `SUPER::scanUrl` 的回调里把扫描回来的 `$track->content_type($fmt)` 改回真实格式；
      ③ `getNextTrack`（正好在 `Song::open` 之前）用解析缓存再校正一次（兜底）。
      ⚠️ 仍然**不要**碰 `formatOverride`（§5.10.54 卡死主循环的前科）；用 `setContentType` +
      轨道字段这条路足够，且完全走 LMS 公开 API。
    - **顺带修好的显示问题**：`~0kbps` 是因为 probe 用范围响应的 `Content-Length`（只有 2KB）算码率
      ⇒ 改成优先取 `Content-Range` 的总量（`bytes 0-2047/34600000`）。现在 tx 显示 **943kbps**；
      `setRemoteMetadata` 的 `bitrate` 字段（kbps）负责让 UI 显示"格式码率"。
    - **验收（0.11.8 实测）**：tx 茶汤/我不难过/晴天/天下 四首位置均推进过 5s（PASS），kw 回归 PASS；
      日志从 `ogg-ogg-*` 变为 `flc-flc-*` → `Matched: flc->wav via [Decode]`。
    - **wy 现状**：解析报「没有可用的订阅源」当且仅当**订阅源被关掉**（本轮现场：独家音源被关，
      `tmp/list_sources.py` 一眼可见；启用字段名是 `src_enabled_<id>`，**没有** `pref_` 前缀——
      用 `tmp/lx_settings_post.py save src_enabled_ae78880c=1` 打开）。wy 自身的取链仍不稳，
      用户决定"稍后换别的订阅源试"，所以**别急着改代码**。
76. **【重要】"编码/码率显示不对"与"不能拖进度条"是同一个坑：元数据发布**（0.11.9~0.11.12）
    - **判据/取证**：`tmp/check_nowplaying.py <榜单index>`（播该榜首行并打印 LMS 报告的
      duration/bitrate/samplerate/samplesize/coverid）、`tmp/check_queue_attrs.py <index>`（看整个队列每行属性）。
      前者查"正在播放"，后者查"队列行"（两者的元数据来源不同！）
    - **三个坑**（都在我们侧，全部只调 LMS 公开 API）：
      ① **只发一次会被扫描冲掉**：`_finish_resolve` 里 `SUPER::scanUrl($direct)` 之后 LMS 会用嗅探结果
         重写同一 URL 的属性 ⇒ 必须在**扫描回调里再发布一次**（否则"格式码率闪一下就没"）；
      ② **duration 必须显式发**：`secs` 来自曲目 `interval`（榜单条目都有），不发就是 0，
         而 `canSeek` 要求 duration 已知；
      ③ **码率必须是数字**：`getMetadataFor` 曾把**档位 key**（`flac24bit`）当 `bitrate` 发 ⇒
         LMS 存成 `BITRATE = 'flac24bit'*1000 = 0`（Perl 字符串转数字）⇒ 把真码率覆盖成 0
         ⇒ `Protocols::HTTP::canSeek`（`$song->bitrate()` 与 `duration()` 都非 0 才允许拖）
         恒返回 0 ⇒ **所有 lxm:// 曲目都拖不动**。改成 `type => qualityLabel(key)` +
         `bitrate => 数字 kbps`，并在 `getNextTrack` 开播前再校正一次。
      ⚠️ 结论：**"不能拖进度条"先查元数据（bitrate/duration），别去怀疑 CDN 或 LMS 的 seek 实现**——
      本轮实测两个 CDN 的 Range 语义完全一致（206 + 正确 Content-Range），kw 能拖 tx 不能拖的唯一差别
      就是 tx 的码率被写成了 0
    - **队列行的码率**：未播放的曲目 LMS 不知道码率，用 SDK 的 `types[].size ÷ 时长` 估算并写进行属性
      （kg 实测 1598kbps；kw 的 types 没有 size ⇒ 估不出，播放后显示真值）
    - **wy/mg 的诊断结论（本轮）**：开 DEBUG 后日志明示
      `resolving src=wy want=flac24bit` → `resolve failed: 全部订阅源都取不到直链（独家音源@flac: unknow error
      || at <anonymous> (…/sources/ae78880c.js:13:2705)）`；mg 是 `get music url failed`。三档位全失败 ⇒
      **源侧问题**（用户看到的"进度条跑几秒无声复位"就是 LMS 的 "Getting stream info" 假进度 + 停止）。
      换订阅源后再按 §5.11.75 的方法复测即可
77. **【流程】装机必须"POST + 两次重启"，而且字段名是 `install:<Plugin>`**（0.11.13~0.11.16 现场，
    用户明确吐槽"你的更新流程肯定有问题"——确实有，两个 bug）
    - **bug①字段名**：插件页表单里**没有 `update:<Plugin>`**，真正触发安装的是隐藏字段
      **`install:<Plugin>`**（`<input name="install:LxMusic" type="hidden">`）。以前发的是不存在的字段，
      能装上纯属表单快照里恰好带着 `install:`。
    - **bug②少 `saveSettings`**：回放表单时**必须带 `saveSettings=Save Settings`**，
      否则 LMS 不认这次 POST（表现为"什么都没发生"）。
    - **bug③只重启一次不够**：POST（带上面两项）后响应里会立刻出现
      `Changes will take place at the next application restart`（=更新已登记），但 LMS 是
      **在启动过程中才下载并暂存** zip 的 ⇒ 第一次重启只完成"下载+暂存"，**要再重启一次才生效**。
      这解释了为什么我前几轮反复 POST+重启 2~3 次才成功。
    - 正规脚本：**`tmp/lx_update.py [--target X] [--no-restart]`**（读 repo.xml 拿目标版本 →
      POST（含 install:/saveSettings/repos?v=epoch）→ 等"需重启"提示 → **有播放器在播就中止** →
      重启 → 轮询工具页版本号验证）。⚠️ 仍然要**自己再重启一次**（见 bug③）；脚本会把两段都提示出来。
    - 用户手工装机更靠谱（达菲 Web 界面 → 设置 → 插件 → 更新）：本轮 0.11.15 就是用户手工装的。
      **下次要装机先问用户**，别反复 POST/重启折腾他的设备（重启会打断他正在听的歌）。
78. **mg 的已知限制（0.11.19 后只剩页头按钮一条）**
    - ✅ **mg 完全不能播（"点在走、没声音/立刻 stop"）已在 0.11.19 修掉**——根因跟源无关，是 https 直链走了明文处理器，
      见 §5.11.80。**装机实测：mg 搜索曲 `周杰伦-晴天` 位置推进 PASS；mg 榜单 6.0 行 0 PASS（dur=233.794）**
    - **页头没有播放/添加按钮**：**不是**我们没发 play/actions——0.11.15 的诊断行实证
      `board_render: src=mg bangid=27553319 play=lxm://b/mg/27553319 total=50 rows=50`，
      与 kw（`src=kw bangid=93 play=lxm://b/kw/93 total=300`）形状一致；但 Daphile 模板渲染出的
      `<div id="songInfoPlayLinks">` 对 mg 是**空的**，kw/kg/tx 有内容。已排除的假设：
      ① total 太小（mg 6.1 是 total=100 仍无按钮）② bangid 缺失 ③ 页面/feed 缓存（反复换 URL 一样）
      ④ 模板/CSS 隐藏（HTML 里就没有锚点）。下一步建议：对比 Daphile 皮肤模板（`songinfo` 相关条件），
      或在 feed 里补 `type => 'playlist'` + `playlist` 键做实验（LMS Web 对 playlist 属性有特判，见
      `Slim/Web/XMLBrowser.pm` L336-344）
    - ~~**mg 列表行没有时长**~~ ✅ **已自愈/不成立（2026-09-21 晚复测）**：设备上 mg 榜单页实测有完整时长
      （mg 榜单 6.0 行 0 → `dur=233.794`，搜索载荷里也带 `interval="04:30"`）；当初 `without-duration=50`
      只出现在**那一版 mg 榜单行**上，而 `Plugin::_secsOf` 本来就同时吃 `interval` 与 `duration`，
      所以**不需要**改 SDK/esbuild（那条 esbuild 待办可以划掉）。若以后又见空时长，先跑
      `python tmp/dump_payload.py mg 晴天` 看载荷里 interval 在不在，再决定要不要动 SDK。
- **kg artwork 配方（已实现，供以后参考）**：kg 的 `img` 字段恒为 null，albumId 拼 URL 只能拿占位图；
  正解是官方 `refs/lx-music-desktop/src/renderer/utils/musicSdk/kg/pic.js` 的 getPic：
  POST `http://media.store.kugou.com/v1/get_res_privilege`，头带
  `KG-RC: 1`、`KG-THash: expand_search_manager.cpp:852736169:451`、
  `User-Agent: KuGou2012-9020-ExpandSearchManager`，body 里 `resource[0] = {album_audio_id, album_id, hash, id:0, name, type:'audio'}`，
  响应 `data[0].info.image`（`{size}` 用 `info.imgsize[0]` 替换）就是真图 URL。
  我们这边走封面代理的 `kg:<aaid>:<albumId>:<hash>` 分支（`Plugin::_coverOf` + `_coverProxy`）
79. **【重要】"拖不动进度条"的真凶：`bitrate` 必须发到直链 URL 上**（0.11.17，tx 现场；别再被 CLI 自测骗了）
    - **先纠一个方法论错误**：我最初用 `rpc(["time", 60])` 自测并报了 PASS，但用户仍说拖不动——后来发现
      达菲皮肤的进度条点击是
      ```js
      onClick: function(ev){ if (!(playerStatus.duration && playerStatus.canSeek)) return;
                             SqueezeJS.Controller.playerControl(['time', pos * duration]); }
      ```
      即**同一条 `time` 命令**，但**必须复刻 UI 的形态**（`pos*duration` 浮点、播放中、目标位置不同/连续拖多次）。
      复刻后立刻复现失败 ⇒ 教训：UI 类问题必须按 UI 的真实参数复测，别只发一个整数就宣布通过。
    - **判定链（LMS 源码）**：
      `Commands::timeCommand` → `Source::gototime` → `StreamingController::jumpToTime` →
      `_eventAction('JumpToTime')` → `_JumpToTime`：
      ```perl
      $seekdata = $song->getSeekData($newtime);
      return unless $seekdata || $restartIfNoSeek;     # ← seekdata 为 undef 就静默丢弃
      ```
      而 `Protocols::HTTP::getSeekData` 第一行：
      ```perl
      my $bitrate = $song->bitrate() || return;         # ← 码率取不到 ⇒ 返回 undef
      ```
      `$song->bitrate()` = `_bitrate() || Slim::Music::Info::getBitrate($song->currentTrack()->url)`
      —— **`currentTrack()` 是直链那条记录**，而我们把 BITRATE/SECS 只发布给了 `lxm://` URL。
      kw 能拖是因为它的 CDN 让 LMS 自己推出了码率（song 的 `_bitrate`），tx 的推不出来 ⇒ 拖动被丢。
    - **日志铁证**（同一台 HiBy FC4，`player.source=DEBUG`）：
      ```
      kw: JumpToTime → 15ms 后 Song::open (395) seek=true time=94 canSeek=2 → Transcoder: streamMode=R
      tx: JumpToTime → 完全没有 seek 的 open；之后的 open 是 seek=false → streamMode=I（不可 seek 模式）
      ```
    - **修法**：`_finish_resolve` 的 `$publish` 对 **lxm:// 与直链两个 URL 都发** ct/bitrate/secs
      （title 只发给 lxm://，避免覆盖直链行的显示名）。⚠️ 用 `$song->bitrate()` 的还有
      `canSeek`（状态里的 `can_seek`）——所以这条同时影响"UI 是否允许拖"和"拖动能否算出字节偏移"。
    - **复测脚本**：`python tmp/test_seek_ui.py <榜单index> <src> <player>`（复刻 UI 形态：浮点、
      连续两次、拖到接近末尾），对照实验用 `kw`（应当 PASS）
80. **【重要】https 直链必须走 HTTPS 基类：mg 完全不能播的根因（0.11.19，别再猜"源有问题"）**
    - 现场现象：`mg` 用 lxm:// 播放 **70ms 就 `mode=stop`**，状态里 `duration=270`（元数据发布成功）、
      日志只有 `HTTP::new (59) Couldn't create socket binding to  - ` + `PROBLEM_CONNECTING`；
      **同一条直链直接丢进播放列表却能放**（`duration=269.747`，那是 CDN 自己的值）。这个"直链能放、
      插件不能放"的组合就是本坑的指纹。
    - **铁证**（`player.streaming.remote=DEBUG` 后复现）：
      ```
      RemoteStream::new (70) Opening connection to https://freetyst.nf.migu.cn/…: [freetyst.nf.migu.cn on port 443 …]
      RemoteStream::request (145) Request: GET /public/…/60054701923151339.flac?… HTTP/1.0     ← 明文！
      RemoteStream::request (152) Response: HTTP/1.1 400 Bad Request
      RemoteStream::request (167) Warning: Invalid response code (400) …
      ```
      注意 `Invalid response code` 是 **warn** 级：日志级别停在 ERROR 时会**完全看不到**，
      只能看到后面那句无信息量的 `Couldn't create socket binding to  - `（`$!` 也是空的）。
    - **机制**：我们的 `Plugins::LxMusic::ProtocolHandler` 继承 `Slim::Player::Protocols::HTTP`
      → 其父 `Slim::Formats::RemoteStream` 是 `IO::Socket::INET`，**没有 TLS**；
      LMS 只有在"URL 自己就是 https://"时才会选它自带的 `Protocols::HTTPS`（IO::Socket::SSL + HTTP）。
      我们代理转发时，LMS 按**轨道 URL（lxm://）**选处理器 ⇒ 永远是明文路径 ⇒ 443 收到明文请求回 400。
      （`crackURL` 仍然给出 443，所以请求行看起来"对"；CDN 的 400 是它对非 TLS 字节流的回应。）
    - **修法**（只用 LMS 公开代码）：`BEGIN { 有 hasSSL 就 our @ISA = ('Slim::Player::Protocols::HTTPS') }`。
      HTTPS::new 内部按 URL 协议分流：`http:` → 走去掉 SSL 的 HTTP 路径（原行为不变），
      `https:` → `IO::Socket::SSL->new(PeerAddr, PeerPort, SSL_startHandshake)`，且
      **`$class->SUPER::new` 的 invocant 仍是我们的类** ⇒ 返回对象是我们自己的类，
      `getSeekData`/`canTranscodeSeek`/`new` 等覆盖全部继续生效。
    - **本机可复现的验证法**（不用装机、不用设备）：`tmp/lms_https_sim.pl` 用 perl 的
      `IO::Socket::SSL` 照抄 `HTTPS::new` 的构造 + `RemoteStream::requestString` 的请求行，
      对同一条新鲜直链分别走 SSL / 明文两条路：
      ```
      [ssl]   -> HTTP/1.1 206 Partial Content
      [plain] -> HTTP/1.1 400 Bad Request        ← 与设备日志逐字一致
      ```
      取链：`python tmp/fetch_mg_url.py`（写 `tmp/mg_url.txt`）。
    - **本机 ISA 断言**：`tmp/check_tls_fallback.pl`（SSL 关掉时必须回落 HTTP）+
      `perl -Iplugin\t -MJSON::XS -e "require './plugin/LxMusic/ProtocolHandler.pm'; print join(',',@Plugins::LxMusic::ProtocolHandler::ISA)"`
      ⇒ `Slim::Player::Protocols::HTTPS`。为跑通编译检查，`plugin/t/` 新增了存根：
      `Slim/Player/Protocols/HTTPS.pm`、`Slim/Networking/Async/HTTP.pm`、`Plugins/LxMusic/Helper.pm`、`JSON/XS.pm`
      （`t/` 目录不进 zip）。
    - **推论（以后选源要记）**：直链是 https 的源在 0.11.18 之前**一律不能播**；
      选源/评估时"能取到 https 直链"不等于"能在达菲上播"。
    - ✅ **装机实测（0.11.19，2026-09-21 晚）**：同一句 `GET …/60054701923151339.flac?… HTTP/1.0`
      在 0.11.18 上回 **400**、在 0.11.19 上回 **206 Partial Content** + `Opened stream!`；
      `tmp/accept_011_19.py check` → wy PASS、mg PASS（位置推进）；
      `tmp/accept_011_19.py kulou 稻香`（临时停用星海只留裤佬）→ mg PASS；
      `tmp/play_board_row.py 6.0 0` → mg 榜单行 PASS；
      **顺带确认 0.11.18 的拖动修复真的通了**：`tmp/seek_lxm.py`（严格按 UI 形态 `['time', pos*duration]`）
      对 **mg / wy / tx** 三个平台都是"3s 后到位、7s 后继续推进"，can_seek=1
81. **插件图标怎么换（0.11.20；参考实现 = 兄弟项目喜马拉雅插件）**
    - **一处声明就够**：`install.xml` 里加一行
      `<icon>plugins/<PluginName>/html/images/logo.png</icon>`，实体文件放插件包内的
      `HTML/EN/plugins/<PluginName>/html/images/logo.png`（zip 里就是这条相对路径，
      LMS 装机后按 `/plugins/<PluginName>/html/images/logo.png` 提供）。
    - **只放一张原图**：LMS 网页层支持**按需缩放**——设备实测对 `logo_50x50.png` /
      `logo_100x100.png` / `logo_33x33.png` / `logo_77x77.png` / `logo_300x300.png`
      **全部 200 且尺寸正确**（`Content-Type: image/png`），而基图不存在时
      `nope_50x50.png` 是 404、`.jpg` 也是 404（只按基图扩展名转）。所以**不需要**
      自己生成 `_50x50/_100x100`（喜马拉雅的 zip 里也只有 `logo.png`，设备上却能取到
      `logo_50x50.png`——同一机制）。
    - **这一行 <icon> 影响三处**：① 设置→插件列表那一行（插件管理器模板把路径改写成
      `_50x50.png`（src）+ `_100x100.png`（srcset 2x），并带 `onerror` 回退到
      `html/images/<category>.svg`）；② `Slim::Plugin::Base::initPlugin` 会把它注册成
      页面图标（`Slim::Web::Pages->addPageLinks("icons", {<token> => <icon>})`）；
      ③ **apps / My Apps 菜单**（达菲与 Material 都会显示的那份"应用列表"）：
      `Slim::Plugin/MyApps/Plugin.pm` 给 app 项填 `icon => $app->_pluginDataFor('icon')`，
      而 `Slim::Plugin::OPMLBased` 在**没有** icon 时会兜底注册 `html/images/radio.png`
      （L38-39）——所以此前 LX Music 在应用列表里是个**收音机**图标。
    - **CLI 直接可查（装机前后对照，最省事的判据）**：
      `python tmp/lx_cli.py "apps 0 60"`。装机前实测：
      ```
      icon:plugins/Spotty/html/images/93aac68f….png   name:Spotty   cmd:spotty
      icon:plugins/Ximalaya/html/images/logo.png      name:Ximalaya cmd:ximalaya
      icon:html/images/radio.png                      name:LX Music  cmd:lxmusic   ← 兜底收音机图
      ```
      装机后 LX Music 那项应变成 `icon:plugins/LxMusic/html/images/logo.png`
      （与 Ximalaya 同形状）。
    - **repo.xml 里要再给一条绝对 URL 的 `<icon>`**（`pack.py` 已生成
      `<icon>{base}/lxmusic_logo.png</icon>`，并把图标拷进 `dist/`）。原因：
      `Slim/Web/Settings/Server/Plugins.pm` 的 `prepareDetails` 对**未安装**的插件会把
      *相对* icon 路径重写成 `GH_IMAGE_URL`（= **LMS-Community/slimserver 官方仓库**，
      见该文件 L26），第三方插件必然 404；绝对 http(s) URL 则原样使用（`$_->{icon} =
      $data->{icon} if ... !~ /^http/`）。发 GitHub release 时要**把 `lxmusic_logo.png`
      一起作为 release 资产上传**（GH 基址是 `…/releases/download/v<version>/lxmusic_logo.png`）。
    - **素材来源**：落雪桌面版官方图标（`refs/lx-music-desktop/resources/icons/256x256.png`，
      Apache-2.0，署名放本文件即可）。同一 logo 的**透明 SVG**（`src/renderer/assets/images/icon.svg`）
      本机没法栅格化（无 imagemagick / rsvg / inkscape / PIL，ffmpeg 也没编 librsvg：
      `Decoding requested, but no decoder found for: svg`），故用官方方形 PNG（浅灰底 + 长阴影，
      与其它插件图标风格一致）。
    - **验证脚本**：`tmp/check_plugin_icon.py`（抓插件管理页里 LxMusic/Ximalaya 行的 `<img>`）、
      `tmp/dump_plugin_imgs.py`（列出页内所有 `<img>` 及其上下文）。装机后应看到
      `src="/plugins/LxMusic/html/images/logo_50x50.png"` + `srcset="…_100x100.png 2x"`，
      而不再是 `html/images/musicservices.svg` + `class="pluginFallbackIcon"`。
82. **图标装机实测（0.11.20）：两处都换了，但走的是**两条不同**的取图路径 —— 别被第一种骗了**
    - **apps/应用菜单**：`python tmp/lx_cli.py "apps 0 60"` → LX Music 项
      `icon:plugins/LxMusic/html/images/logo.png`（此前 `icon:html/images/radio.png`）。这条来自
      **包内 install.xml**，稳。
    - **设置→插件 那一行**：`python tmp/verify_icon_0_11_20.py` → 渲染出的**不是** `…/logo_50x50.png`，
      而是 `/imageproxy/http%3A%2F%2F192.168.2.68%3A8765%2Flxmusic_logo.png/image_50x50_o`（+ `_100x100_o 2x`）。
      原因：`Slim/Web/Settings/Server/Plugins.pm::prepareDetails` 里
      `$_->{icon} = $data->{icon} if $data->{icon} && $_->{icon} !~ /^http/;`
      —— **只要 repo.xml 给了绝对 URL 的 `<icon>`，它就覆盖包内的相对路径**（然后交给 imageproxy 缩放）。
      两张图实测都 200（1525 B / 3410 B）。⇒ **LAN 仓库/图标不可达时，插件管理器那一行会退化成
      `musicservices.svg` 兜底图，而 apps 菜单仍然正常**；排查图标问题时先分清是哪一处。
83. **【流程】发布到 GitHub（fine-grained PAT）+ 「订阅源文件绝不进仓库」的硬约束**
    - **推送**：token 只走环境变量或命令行内联，**不写进 `.git/config`、不落盘**：
      `git push https://x-access-token:$env:GH_TOKEN@github.com/jackyytche/lms-plugin-lxmusic main:main`
      （`repo/` 里可以放一个**不带 token** 的 `origin` 只用于 `fetch`）。
    - **远端可能领先**：`plugin-tests.yml` 会给 main 追提交（`ci: regression log [skip ci]`）。先 `git fetch origin`，
      本地领先就用 `git merge origin/main`（本轮 30 ahead / 1 behind，merge 只带回 `plugin/helper-test.log`，零冲突）。
    - **打包**：`pack.py` 一次打包产出两份仓库描述（同一个 zip/sha1）——`dist/repo.xml`（LAN）+
      `dist/repo-gh.xml`（GitHub 基址）。**绝不能各打一次包**（zip 条目时间戳=打包时刻 ⇒ 两次 sha1 不同，
      而 assets 与 repo.xml 必须严格对应）。
    - **建 release + 传三资产**：`GH_TOKEN=… python tmp/lx_gh_release.py 0.11.20`（`--verify` 只做终验）：
      资产固定名 `LxMusic-<ver>.zip`、`repo.xml`（内容=repo-gh.xml）、`lxmusic_logo.png`
      ⇒ `releases/latest/download/repo.xml` 与 `…/lxmusic_logo.png` 才能长期稳定。
    - **发布前必跑 `python tmp/audit_repo_contents.py`**：列出全部跟踪文件 + 文件名/内容特征扫描。
      用户的**订阅源回执包**（`V260917.zip`、`refs/subs_v260917/**`）与**导入用的源脚本**
      （`dist/src-xinghai-2.3.13.js`、`dist/src-kulou-3.0.0.js` 等）**只在本地**，`repo/` 里一个都不能有；
      zip 里也不能有（pack.py 只打 `plugin/LxMusic/`，实测 15 条目里零订阅源文件）。
      ⚠️ 注意区分：插件**自带的** `engine/sdk/**` 是 vendor 的 musicSdk（我们自己构建的），不是订阅源。
    - **收尾**：提醒用户吊销 PAT；把 release 的 id/URL/sha1 记进 §七.8。
84. **【纪律】交接文档的完整性：它被 PowerShell 文本回环毁过一次**
    - **事故形态**：用 `Get-Content`/`Set-Content`（或任何按 ANSI 读写的回环）处理本文件 ⇒ 中文整体乱码、
      部分段落丢失、行尾混入 CRLF；而且**复制进 `repo/` 时才被 git 记下**（远端历史里那份 0.8.5 快照就是坏的）。
    - **纪律**：本文件**只用 `read`/`edit`/`write` 工具**改；要复制只能用 `Copy-Item`（逐字节，不解码）；
      **永远不要**用 PowerShell 读进来再写回去。
    - **体检**：`python tmp/doc_audit.py`（默认查 `HANDOFF.md`）—— 一次给出：UTF-8/BOM/行尾、
      U+FFFD、典型乱码模式（`锟斤拷`、UTF-8 被当 GBK/latin1）、代码围栏奇偶、表格管道数、
      标题层级、重复长行。**判据**：UTF-8 解码 OK + 0 个 U+FFFD + 围栏偶数 + 无重复长行；
      文档里出现的 `å¨æ°ä¼¦` 这类是**故意引用的乱码样例**（讲编码坑用的），不是损坏。
    - 同族纪律：`install.xml` 的中文注释也被 PowerShell 写坏过（§5.5.36），改 XML 同样只用 edit 工具。
85. **订阅源不会因升级而丢 —— 但仍要留本地副本（用户要求）**
    - **事实**：导入的源正文存在 LMS prefs 目录 `<prefsdir>/lxmusic/sources/<id>.js`，元数据在 prefs
      `sourcesJson`；**升级插件不动 prefs**。实测证据：0.11.15 → 0.11.17 → 0.11.18 → 0.11.19 → 0.11.20
      连续升级（含两次重启/次），3 个源始终在位且全 ON（`python tmp/reimport_sources.py check`）。
      ⇒ "每次升级都要重新导入"并不是必然；会丢的场景只有 **prefs 被清空 / 卸载重装 / 换机器**。
    - **本地副本**：`repo/subscriptions/`（`src-xinghai-2.3.13.js`、`src-kulou-3.0.0.js`、`V260917.zip` +
      `README.txt`），**已被 `repo/.gitignore` 排除** —— 既保住"升级/清空后能一键补装"，又不会发上 GitHub。
    - **一键补装**（无 GUI 也能做）：`python tmp/sync_subs.py`（把副本同步进 LAN 仓库 `dist/`，
      8765 即时可下载）→ `python tmp/reimport_sources.py check|import`（对照设备已装的源，
      缺的用设置页的 `add_url` + LAN 地址补装；`--force` 全部重装）。
      ⚠️ 导入动作只有 `add_url` / `add_file` / `add_dir` 三个（`Settings.pm` L130-149）——
      **没有** `lxAction=import`（`tmp/lx_settings_post.py` 文档里那个是旧写法，别照抄）；
      判据用「正文字节数」对照（设备行里带 `NNNN 字节`）。
    - ⚠️ 因此 **`dist/src-*.js` 不要清理**（它就是 `add_url` 的目标）；换 IP 时记得 `sync_subs.py` 后用
      新 LAN 地址补装/刷新。

---

## 六、自主开发闭环（下个 session 直接复用）
0. **开工/收尾自检**：`python tmp/session_check.py` —— 一条命令看：① LMS 主循环是否活着（CLI+Web）② 运行中的插件版本 ③ `plugin.lxmusic`/`player.source` 日志级别是否都是 ERROR（诊断残留检查）④ 常驻 worker 现场 ⑤ 订阅源启停 ⑥ 内部播放器是否在播（应为 stop）。**开工第一步、收尾最后一步都跑它**
1. **改代码** →本地校验：`perl -I plugin\t_local -I plugin\t -I plugin -c plugin\LxMusic\<Module>.pm`（需要`plugin/t/**` 存根）；`node --check engine/shim.mjs`；shim 侧行为验证用 `tmp/shim-sim/`**打包前必须**跑门禁：`powershell -ExecutionPolicy Bypass -File tmp\precheck.ps1`（所有 .pm 都要 `syntax OK` + 模板纯 ASCII + shim 过）！**不通过就不许 pack**（0.8.0 事故的教训，§5.7.37）
2. **打包发布（LAN）**：`$env:LX_REPO_BASE='http://192.168.2.68:8765'; python plugin\LxMusic\pack.py`（产物进 `dist/`，LAN 即时生效）→ 同步 `repo/plugin/**`（本 session 只改 5 个文件，可用 `Copy-Item` 逐个覆盖）→ `git -C repo add -A plugin; git -C repo commit`（**新提交**，别 amend：远端 main 已有 CI 提交，新提交才能快进推送）
3. **装机**：`python _research/ximalaya-daphile-plugin/m0/diag_plugin_install.py post LxMusic '--repos=http://192.168.2.68:8765/repo.xml?v=<N>'`（**N 每次 +1**，用于破 LMS 300s 仓库缓存；0.11.16 用 **v=95**、0.11.19 用 **v=96**）→ `重启`（有"正在播放则中止"守卫）→ 轮询页面版本号⚠️ 重启后 30~60s 内`:9000` 可能连不上（0.10.x 轮遇到两次`WinError 10060`）：那是**还没起完**，等一会儿重试若**长时间** Web 超时且 CLI 也无响应，就是主循环卡死，走 §5.10.54 的 Daphile CGI 重启设备
4. **取证**：
   - CLI 9090：`tmp/lx_cli.py "lxmusic items 0 40"`（顶层菜单）、`"lxmusic items 0 8 item_id:2"`（下钻榜单）、`"lxmusic items 0 4 item_id:2.0"`（榜单曲目，**输出带 image 字段**，可验证封面代理开关）；`<playerid> status - 1 tags:cgAl`（播放状态）。裸 socket 版：`tmp/raw_cli.py "serverstatus 0 3"`（连通性/卡死判据）
   - JSONRPC：`/jsonrpc.js` POST `{"id":1,"method":"slim.request","params":["<playerid>",["playlist","play",["<url>"]]]}`
   - 页面自证：`?q=`（搜索）、`?type=pl&q=`（歌单搜索）、`?plid=&plsrc=`（歌单详情）、`?track=`（试听解析）、`?u=<b64url>`（封面代理，返回图片字节即设备侧可直连该 CDN）。**判决行现在带耗时拆解**：`源@档位: ok 453ms(handler 0ms)(verify 402ms) friendly=0 [worker]`
   - 设置页自证：`tmp/verify_settings.py`（纯 ASCII / 12 分区 / 诊断块含 worker 现场 / 全部 pref 控件）
   - 日志：设备日志端点（**延迟 10+ 分钟，0.10.x 轮确认不可用**）；插件自身 `LOG …` 行会渲染在搜索/歌单页的 logs 块里
5. **播放验证（0.10.x 起的口径，见 §5.10.57）**：`playlist clear` →`playlist add <lxm://…>`×N →`playlist jump 0` →`play` →`<playerid> status`
   - **唯一判据 = 位置持续推进**（不是`mode=play`、不是`dur`）：`python tmp/test_play.py <查询> <src> <档位> [轮数]`（走 `lxm://`，内部播放器，结束必 stop）对照实验用`python tmp/test_url_play.py "<直链>"`（裸 URL，绕过插件）或`python tmp/test_raw_play.py <查询> <src>`（插件解析出的直链再裸播）
   - **每次验证后必跑** `python tmp/liveness.py`（CLI 有响应= 主循环没卡死；CLI 有响应而 Web 超时 = 卡死前兆）
   - 取链侧验证：`python tmp/check_worker.py <查询> <src> [首数]`（含 tries 耗时拆解 + 设置页 worker 状态）、`python tmp/check_resolve.py [词] [源]`（老口径，输出 `OK (n.nn s)`）
   - ⚠️ **达菲卡死只能重启**：`http://192.168.2.111/cgi-bin/Settings?ACTION=restart`（Daphile 自己的 CGI 在 80 独立于 LMS，LMS 卡死时仍可用；见 §5.10.54）。重启会中断播放，别在用户听歌时做
6. **设置页/ 编码验收（M0.5 新增工具，都可重复跑）**：
   - `tmp/verify_settings.py` …设置页体检：非 ASCII 字节数（须 0）、**12 个分区标签**是否齐全（实体解码后）、乱码计数、诊断块取值（含常驻 worker 现场）、全部 pref 控件状态
   - `tmp/lx_settings_post.py`（**浏览器语义表单回放**（自动带 `pageAntiCSRFToken`，只提交 `settingsForm`）：`show` / `save pref_x=v -pref_y`（`-` = 取消勾选）/ `save lxAction=import sourceContent=<URL>` / `save lxAction=clear` / `save --file-source=<本地源文件>`（粘贴路径，内容随表单提交）
   - `tmp/check_resolve.py [关键词] [源]` →网页搜索 →取第一条`?track=` →解析直链，输出`OK (n.nn s)` + 直链主机名（**验证源字节完好的硬证据**）
   - `tmp/test_ent.pl` →`Settings::_ent()` 单测（字节串/旗标串都要输出纯 ASCII 实体）
   - `tmp/mk_settings_template.py` …设置页模板生成器（改文案改这里，生成纯 ASCII 实体模板）
   - 编码取证脚本：`tmp/probe_mojibake.py`、`tmp/probe_surfaces.py`、`tmp/probe_template_gen.py`（判定渲染的是哪一代模板）
   - 入口取证脚本：`tmp/probe_settings_entry.py`（设置下拉条目 + 插件行 Settings 链接 + selected）、`tmp/probe_chooser_option.py`、`tmp/probe_chooser_js.py`、`tmp/probe_plugin_row_text.py`
   - M0.6 新增：`tmp/verify_sources_page.py`（源列表/导入字段/音质控件体检）、`tmp/m0_6_acceptance.py`（多源全流程验收：导入/去重/目录/启停/排序/删除/取链）、`tmp/restore_source.py`（把设备源复原成样本源）、`tmp/test_sources.pl`（Sources.pm 单测）、`tmp/probe_url_playable.py`（HEAD/Range 可播性）、`tmp/probe_source_info.py`（源脚本各平台能力）
   - M0.7 新增：`tmp/precheck.ps1`（打包门禁，必用）、**`tmp/repair_install.py`（插件被 LMS 摘除后的恢复/重装启用）**、`tmp/verify_search_rank.py`（聚合搜索排序单调性复算）、`tmp/test_autoskip.py`（自动跳曲开关 A/B 实测）、`tmp/check_qdy_source.py` / `tmp/probe_qdy_url.py`（订阅源可用性 + 直链真伪）、`tmp/decode_qdy_error.py`（把页面上的实体乱码还原成源的真实报错）、`tmp/delete_source.py "名称子串"`（按名字删源）
   - M0.10 新增（worker / 播放链路取证，都是可重复跑的）：
     **`tmp/session_check.py`（开工/收尾自检：存活 + 版本 + 日志级别 + worker + 源 + 播放状态）**
     `tmp/check_worker.py [查询] [src] [首数]`（取链矩阵 + tries 耗时拆解 + 设置页 worker 现场）、`tmp/test_board_play.py`（**kw 榜单曲目** lxm:// 端到端播放验收，0.11.0）
     `tmp/test_play.py [查询] [src] [档位] [轮数]`（`lxm://` 播放，看位置是否前进，结束必 stop）
     `tmp/test_url_play.py "<直链>"`（裸 URL 对照）、`tmp/test_raw_play.py [查询] [src]`（插件解析→裸播，用于分辨"插件 vs 直链"）
     `tmp/liveness.py`（主循环存活判据）、`tmp/raw_cli.py "命令"`（裸 socket CLI）
     `tmp/probe_direct.py [查询] [src]`（直链在本机多种 UA/Range 下的可播性；曾用它否掉"UA 被拒"假说）
     `tmp/list_sources.py`（源 id →名称 →启停）、`tmp/verify_play_prefs.py`（设置页新开关体检）
     `tmp/vip_direct_matrix.py [查询] [平台…]`（逐平台看直链形态 + 裸播；回答"是不是 VIP 源"的用它）
     `tmp/vip_tier_test.py <平台> <id> [档位,..] [轮数]`（同一中转链只换档位的裸播对照；**轮数给大 = 排查慢起播**）
     `tmp/relay_speed.py` / `tmp/relay_magic.py`（中转链吞吐 / 声明类型 vs 实际字节头，判定"标签骗人"与"慢到播不动"）
     `tmp/set_debug.py <category=LEVEL> …`（按浏览器语义改日志级别；**收尾记得改回 ERROR**）
     `tmp/refactor_shim_serve.py`（一次性：把 shim 的 action 调用抽成 `callHandler`/`probeOnce` 并加 serve 模式；`tmp/shim.mjs.bak` 是其前备份）
     *（0.10.x 轮两轮"探针毒化"实验脚本 `test_probe_poison*.py` 已删除——假说被 `probe_direct.py` + `test_raw_play.py` 否掉，别重走。）*
   - M0.11 榜单翻页新增（§5.11.74 用它们定案，都可重复跑）：
     **`tmp/verify_final.py`（翻页验收金标准：逐页取真页面 → 解析 `class="primaryInfo"` 行号+曲名 →
     与上游 `kbangserver` 原始榜单逐首比对；要求编号连续 + 内容一致）**、`tmp/verify_sources.py`（多源翻页体检 kw/kg/tx/mg）
     `tmp/probe_board_jsonrpc.py`（jive items 响应的 count/offset/window 形状）、`tmp/cache_experiment.py`（排除 feed 缓存假象）
     **`tmp/read_fresh_log.py`（`server.log?lines=50&full=1` 取最新日志尾——只带 `?lines=N` 会返回缓存的旧切片，
     取现场必须加 `full=1`）**、`tmp/probe_mg.py`（mg 榜不可分页的取证）
   - 0.11.19 https 修复一轮新增（§5.11.80，都可重复跑）：
     **`tmp/lms_https_sim.pl`（本机复现 LMS 建流：SSL 路径 206 / 明文路径 400，不用装机就能验证判据）**、
     `tmp/fetch_mg_url.py`（取新鲜 mg 直链写 `tmp/mg_url.txt`）、`tmp/mg_url_probe.py`（同一 URL 的 curl 头变体矩阵）、
     `tmp/check_tls_fallback.pl`（无 SSL 时必须回落 HTTP 基类）、`tmp/seek_lxm.py <src> [查询] [player]`（严格按 UI 形态的拖动验收）、
     **`tmp/accept_011_19.py check|kulou`（装机验收：wy/mg 端到端 + 只走裤佬的 mg）**、
     `tmp/dump_payload.py <src> [查询]`（看搜索结果第一条的 musicInfo 全字段）、`tmp/log_window.py <日> <起> <止>`（按时间窗抓全量日志行）、
     `tmp/dump_req.py`（不截断打印 RemoteStream 的 Request/Response）、`tmp/log_scheme.py`（统计 player open 的 http/https 与建流失败次数）、
     `tmp/check_ssl.py`（SSL 可用性 + 已装版本）、`tmp/show_loglevel.py [类别…]`（看 selected 值）、
     `tmp/verify_release.py [zip]`（zip 内容/sha1 + LAN 仓库一致性）、`tmp/diag_mg.py [查询] [player]`（对照播「直链」与「lxm://」——直链能放而插件不能放 = https 坑指纹）
   - 0.11.20 图标一轮新增：`tmp/check_plugin_icon.py`（插件管理页里 LxMusic/Ximalaya 行的 `<img>` 与相对 icon 引用）、
     `tmp/dump_plugin_imgs.py`（页内所有 `<img>` + 上下文，用来确认 srcset 的 `_50x50/_100x100` 形态）、
     `tmp/check_daphile_menu_icon.py`（达菲皮肤菜单/曲目页里有没有 per-item icon 字段）、
     `tmp/dump_plugin_rows.py`（插件页里 Ximalaya/LxMusic 周边的原始 HTML）、
     **`tmp/verify_icon_0_11_20.py`（图标终验：插件行 img 取图 200 + 本地 zip sha1）**
   - 发版/文档一轮新增（§5.11.83/84 的配套工具）：
     **`tmp/audit_repo_contents.py`（发布前体检：跟踪文件全表 + 订阅源/凭据特征扫描）**、
     **`tmp/doc_audit.py [文件]`（交接文档体检：编码/乱码/结构/重复）**、
     **`tmp/lx_gh_release.py <ver> [--verify]`（建 release + 传三资产 + 终验 `releases/latest/download`）**、
     `tmp/prep_release_check.py [ver]`（发版前一览：zip 内容/图标/两份 repo.xml 的 URL 与 sha 一致性 + LAN 可达性）、
     `tmp/check_daphile_shell.py`、`tmp/grep_daphile_js_icon.py`（达菲皮肤图标相关取证）
   - 订阅源本地持久化一轮新增（§5.11.85）：**`tmp/sync_subs.py`（本地副本 → LAN 仓库 dist/）**、
     **`tmp/reimport_sources.py check|import [--force]`（对照设备已装的源，缺的用 add_url 补装）**
   - `tmp/lx_set_loglevel.py [LEVEL]` …查看/整表回放设置某个日志类别级别（带 `persist=1`，重启仍生效）

**播放器**：HiBy FC4 `5a:78:10:59:c7:74`（用户主用，验证目标）；HD-Audio Generic `5a:bf:86:1b:a6:ff`（本机声卡）；小爱音箱 squeezelite `bb:bb:69:a9:cf:23`（**会出声，勿用**）

---

## 七、下个 session 待办（按序）

0. ✅ **【本轮 0.11.20】插件图标：已装机、已验收、已随首次发版上线 GitHub**（§5.11.81/§5.11.83）
   - 装机后实测（内部播放器无关，纯网页/CLI 取证）：① `python tmp/lx_cli.py "apps 0 60"` ——
     LX Music 项从 `icon:html/images/radio.png` 变成 **`icon:plugins/LxMusic/html/images/logo.png`** ✓；
     ② `python tmp/verify_icon_0_11_20.py` —— 插件管理器那一行读的是 **repo.xml 的绝对 URL**
     （`prepareDetails` 里绝对 icon 会覆盖包内相对路径）⇒ `/imageproxy/http%3A%2F%2F192.168.2.68%3A8765%2Flxmusic_logo.png/image_50x50_o`
     + `…_100x100_o 2x`，两张图都 200（1525 B / 3410 B）✓。**副作用要知道**：那一行的图标依赖
     LAN 仓库可达（IP 变了会退化成分类兜底图），apps 菜单那份则始终来自包内 install.xml（更稳）。
   - pack.py 现在**一次打包同时产出两份仓库描述**（同一个 zip/sha1）：`dist/repo.xml`（LAN）+
     `dist/repo-gh.xml`（GitHub 基址，作为 release 资产以 `repo.xml` 之名上传）。
1. **发版（本轮已做，见 §七.7；下次照做）**：
   - 流程：`pack.py`（不带 `LX_REPO_BASE` 也可，因为 GH 那份总是生成）→ 并进 `repo/`（源码+图标+pack.py+HANDOFF）
     → `git push`（**token 只在命令行内联/环境变量，绝不写进文件**）→ 用 `tmp/lx_gh_release.py <version>`
     建 release 并上传**三资产**：`LxMusic-<ver>.zip`、`repo.xml`（= repo-gh.xml）、`lxmusic_logo.png`
     → `tmp/lx_gh_release.py 0.11.20 --verify` 终验 `releases/latest/download/repo.xml` 的 version/sha/zip 字节数。
   - ⚠️ **发布前必跑** `python tmp/audit_repo_contents.py`：确认仓库里**没有**用户导入的订阅源文件
     （`src-*.js` / `V260917.zip` / `refs/subs_*`）、没有 token；订阅源只留在本机 `dist/`、`refs/`（未跟踪）。
   - ⚠️ 发完**提醒用户吊销 PAT**（本轮 token 由用户在对话里明文给出）。
2. ✅ **【上一轮 0.11.19】mg https 修复已装机验收 + 两个新订阅源已验收**（详见 §5.11.80 与 §八"订阅源现状"）
   - 0.11.19 已装机（工具页版本号 **0.11.19**，用户手工装）。验收脚本：`python tmp/accept_011_19.py check`
     （wy/mg 各一首端到端）与 `python tmp/accept_011_19.py kulou "稻香"`（**临时停用星海**只留裤佬跑 mg，测完自动恢复）；
     榜单行用 `python tmp/play_board_row.py 6.0 0`；拖动用 `python tmp/seek_lxm.py mg|wy|tx 晴天`。
     结果：**wy PASS、mg（星海）PASS、mg（裤佬）PASS、mg 榜单行 PASS、mg/wy/tx 拖动 PASS**。
   - 用户点名的"**覆盖 wy 和 mg、稳定可靠质量好**"两个源（已导入设备并全部启用，id 见 §八）：
     **星海音乐源 v3.2.13**（文件 `src-xinghai-2.3.13.js`，源自报 `@version v3.2.13`／作者 万去了了；
     wy/mg 直链是真 CDN 直链：wy `*.music.126.net`、mg `freetyst.nf.migu.cn`，实测 mg ~934kbps flac；
     kw/kg/tx 亦通，全平台 flac）+ **裤佬SVIP音源 v3.0.0**（kw/kg/wy/mg flac；tx 只有 mp3；
     每平台多后端链，wy 有三条独立链 + 星海后端主备）。
     ⚠️ **诚实结论**：本批 23 个源里，**wy 能出 flac 的只有"星海后端"这一族**（星海自己 / 裤佬 / 星海后端链）——
     其余候选 wy 不是 403/JSON 报错就是只有 mp3（stellarwave），所以"两个源互相独立"在 **wy 上并不成立**；
     **mg 则宽松得多**（星海/裤佬/墨澜/屿溪/stellarwave 都取到同一条咪咕官方 flac）。
   - ⚠️ **mg 直链是 https**：装 0.11.19 之前，"星海/裤佬能取到 mg 的 flac 直链"**不等于**能在达菲上播出（§5.11.80）。
   - 历史注（v0.11.16 时代写的发版步骤，已被上面第 1 条取代）：本地提交序列 `e7ef7b3`（0.11.16）、
     `f7250ab`（0.11.13~0.11.14）、`9cb3026`（0.11.9~0.11.12）、`eb4a2da`（0.11.8）、`62e75d4`（0.11.5~0.11.7）、
     `a0e752c`（0.11.4）、`a8d0843`（0.11.3）、`961cda0`（0.11.2）；0.11.0 zip SHA1 `44cd31629567002319880bc9ed5f46fcaa066445`
3. **播放菜单逐页修订（2026-09-21 第四轮验收通过后用户提出三项）**：
   1. ✅ **榜单翻页**（0.11.4 原生窗口 + 0.11.5~0.11.7 窗口数学修正，§5.11.74）：kw 热歌榜 6 页
      （1-50/51-100/…/251-300）与 kg 3 页已**逐首对齐上游**验收；待用户在达菲界面目验翻页体验
      （页码条在曲目列表**上方**：`1 2 3 4 5 6 ▶`；点第 2 页应显示 **051** 起的曲目）
   2. ⚠️ **wy 无声=源的问题（已判决）**：独家音源的 wy 通道当时上游网关 **502 Bad Gateway**，全档位(128k/320k/flac)取链失败（DEBUG 日志 `resolve failed: 独家音源@…unknow error {resp: code=502…}`）；同源 kw/tx 同时段正常⇒管线无恙。**复测（同日晚）：kg 已恢复（取链 PASS，flac24bit 直链 1.22s）；wy 仍失败**。历史注：独家 wy 本就"偶发"（§八 4~5/5）。源侧恢复即自愈；工程侧可选改善=M0.7 的每源失败冷却 + 失败行 UI 提示
   3. ✅ **"部分榜单不显示格式码率"=第 2 条的症状（已判决）**：取链失败(502)的曲子进不了 resolve 流程，没有任何格式元数据可显示；取链成功即有（tx 实测 songinfo `type:MP3 320kbps bitrate:MP3 320kbps`，kw 同）。若用户在"能播的 kg/tx 曲目"上仍看不到格式码率 → 再查 UI 刷新路径（晚到元数据 notify 已有）
   4. ✅ **tx 曲目"进度在走但没声音"已修（0.11.8，§5.11.75）**：根因是 CDN 撒谎的 Content-Type
      （QQ `.flac` 声明 `audio/x-ogg`）让 LMS 选了 OGG 解码器。修完 tx 四首实测位置均推进过 5s，
      **码率显示也一并修好**（probe 改取 `Content-Range` 总量 ⇒ tx 943kbps）。
      ⚠️ 顺带发现：**独家音源当时处于关闭状态**（`src_enabled_ae78880c off`）——排查"解析失败/没有可用源"
      时**先跑 `tmp/list_sources.py`**，别再往代码里找
   5. ⏸️ **wy 待换源再试**（用户决定）：wy 取链不稳（本轮现场：源关闭时报「没有可用的订阅源」；
      源开启后 wy 曾报上游 502/取链失败）。用户说"稍后试试别的订阅源"⇒ **先别改代码**，
      等换源后按 §5.11.75 的方法重测（`player.source=DEBUG` + `read_fresh_log.py` 看格式决策）
4. **M0.10 剩余候选**（kw 榜单已在 0.11.0 完成）：
   - **worker 池化**：同一源进程同时服务"取链 + 校验"（`probe` 其实不依赖源）、多源并行 worker（现在多源是串行试、每源一个进程）；worker 生命周期与`bridgeTimeout` 热更新（现在改桥超时要等 worker 回收才生效）
   - 长青 `kg flac24bit ~48kbps` 试听片段的自适应处置（换源？降档？现为告警；长青已停用，优先级降低）
   - **探针的"能播性"还差一层**：现在只看状态码 + 前 2KB 是音频，抓不到 §5.10.58 那类"探针 OK 但一播就 0 秒"（wy flac：探针 1562ms OK，裸播 40s 位置恒 0）。可选做法：连续两次 Range 都成功或加吞吐门槛（如 ≈100KB/s）、或起播后回查播放器位置并自动换源；**前提是能稳定复现到设备侧**（本机 curl 该 URL 是 367KB/s 正常的），否则只是给每首加一次额外请求却抓不到信号
   - `resolveTtl` 与各 CDN 直链真实时效的对齐（现在统一 600s，过期就播不出→非 autoSkip 兜底）
5. **M0.7 剩余候选**（未做）：每源失败冷却（连续点歌不反复撞死源）；**不喜欢歌曲规则**（`歌曲名@艺术家` 三态过滤，PC 端最契合服务端的一项）；搜索排序可选增强（PC 算法 + "歌手名越短得分越高"⇒是否加"完全同名优先 / 优先某源"）；`common.sourceNameType` real/alias；繁简转换；歌词三开关；代理；热门搜索；直链缓存上限语义
6. **共识内未做功能**：**收藏**（§一定稿范围内唯一没做的）
7. **待清理**：`plugin/t_build/`（本地构建残留）、`dist/lx-6.js`、`dist/qdy.js`（历史测试副本）
   ⚠️ **但 `dist/src-xinghai-2.3.13.js` / `dist/src-kulou-3.0.0.js` 永不清理**（设备的补装 URL，§5.11.85）；；`tmp/verify_settings.py` 的分区标签断言已对齐 0.10.9（12 分区 + 全 pref）——**0.11.0 加了 boardsKw 复选框，该脚本的 pref 清单是硬编码的，下次改设置页记得同步**
8. **发布历史**：GitHub `jackyytche/lms-plugin-lxmusic`（公开仓；GitHub Actions 有两个工作流：
   `plugin-tests.yml`（跑 `plugin/t/helper-test.pl`）与 `build-quickjs.yml`；**`plugin-tests.yml` 会往 main 追一条
   `ci: regression log [skip ci]` 的提交**（更新 `plugin/helper-test.log`），所以推之前先 `git fetch origin` 看远端状态）
   - **v0.5.9（2026-09-19，历史）**：`2b28c48` = 0.3.0→0.5.9 单一提交；Release id `392124985`，
     资产 `LxMusic-0.5.9.zip`（1231509 B，SHA1 `c0959eb82a8f5d968c3e51de8e160c9cb4875180`）+ `repo.xml`
   - **v0.11.20（2026-09-21，本轮，已发布）**：把 0.6.0~0.11.20 共 30 个本地提交 + 远端 1 个 CI 提交合并后推送
     （合并提交 `b3ae56c`，只带回 `plugin/helper-test.log`，无冲突；发版内容提交 `4b01463`）；
     **Release `v0.11.20`（id `392384987`）**： https://github.com/jackyytche/lms-plugin-lxmusic/releases/tag/v0.11.20
     三资产 `LxMusic-0.11.20.zip`（1289210 B，SHA1 `04b7fcd451b1794c051e2d049a8d6265783964d2`）、
     `repo.xml`（GH 基址）、`lxmusic_logo.png`（7772 B）。**首个带插件的正式发布版本**
     （此前远端停留在 0.5.9，0.6.0~0.11.19 只在 LAN 通道）。同时刷新了公开 `README.md`（安装/功能/构建/版权）。
     **终验通过**（`python tmp/lx_gh_release.py 0.11.20 --verify`）：`releases/latest/download/repo.xml`
     → version=0.11.20、sha 与 zip 逐字节一致、icon 可取；zip 1289210 B / logo 7772 B 均 match。
     ⚠️ 本轮 token 由用户在对话里明文给出 —— **发完请吊销**。

---

## 八、现场状态与凭据

- **设备**：达菲 `192.168.2.111`（LMS 9.0.3 / perl 5.40；Web `:9000`，CGI `:80`）；运行 **0.11.20**
  （本机 `repo/` 提交 `b3ae56c` 之前的最新提交；LAN 仓库 `?v=97`；插件图标已验收，见 §七.0）。
  ⚠️ 装机后 3 个诊断日志类别已确认复位（plugin.lxmusic / player.source / player.streaming.remote 全 = ERROR）
- **通道**：① **LAN（设备当前用这条）** `http://192.168.2.68:8765/repo.xml?v=97`（8765 常驻 `python -m http.server`
  指向 `dist/`；**进程易失**，掉线就在 `dist/` 重启；`?v=N` 是 LMS 仓库缓存的破除参数，每次装机 +1；
  0.11.19 用 v=96、0.11.20 用 **v=97**）；② **GitHub（备用/公开）**
  `https://github.com/jackyytche/lms-plugin-lxmusic/releases/latest/download/repo.xml`（资产 `repo.xml` = 本地 `dist/repo-gh.xml`）
- ⚠️ **本机 IP 会飘**（2026-09-21 实测漂到 .131 又回到 .68）：IP 一变，设备就取不到 LAN 仓库（表现为"POST 成功但版本不变"、源导入报`empty download`）。处理：`ipconfig` 看当前 IP →`$env:LX_REPO_BASE='http://<当前IP>:8765'` 重新 pack →装机时`--repos=http://<当前IP>:8765/repo.xml?v=<N+1>` 把设备指过来；tmp 脚本已统一读环境变量`LX_LAN`（别硬编码）
- **设备侧现状**：订阅源 **3 个（全部启用）**——`独家音源`(ae78880c，老源，wy 偶发失败) +
  **`星海音乐源`(670c125a，v3.2.13，LAN `http://192.168.2.68:8765/src-xinghai-2.3.13.js`)** +
  **`裤佬SVIP音源(二改整合版)`(6cf9ef8a，v3.0.0，LAN `.../src-kulou-3.0.0.js`)**（长青已在早前删除）。
  **本地副本在 `repo/subscriptions/`（git-ignored）**，补装流程见 §5.11.85（`tmp/sync_subs.py` + `tmp/reimport_sources.py`）：
  1. `独家音源`（`https://raw.githubusercontent.com/pdone/lx-music-source/main/lx/latest.js`，4094 B，v6）——**取链 4~5/5**（wy 偶发），直链是 CDN 直链（如 `car-er.kuwo.cn/…M800000bYDlc2XxKLs.mp3`）⇒ **后缀可判、能正常播放**；但 `mg` 档位取链**上游 block ip**（§5.11.80 前的老现象）
     ⚠️ **2026-09-21 凌晨实测**：该源的 wy/kg 通道上游网关 **502 Bad Gateway**（全档位取链失败），kw/tx 正常——源侧故障，恢复即自愈；**同日晚复测：kg 已恢复（flac24bit 取链 PASS），wy 仍失败**
  2. `星海音乐源` v3.2.13——**本轮为 wy/mg 选定的主源**：wy/mg flac 实测可达（mg `freetyst.nf.migu.cn` ~934kbps verified）；见 §七.0
  3. `裤佬SVIP音源` v3.0.0——**备源**：wy 多条独立链 + 星海后端主备、kw/kg 有自有链；tx 只有 mp3
  - ⚠️ 老的 `长青SVIP音源`（中转链、末段无后缀、达菲放不出声）**已从设备删除**；下面的历史记录保留作依据
  - 最近一次播放（0.11.2，`tmp/test_board_explode.py` 整榜 `lxm://b/kw/17`）：**50 首入队、mode=play、位置推进、曲 1→曲 2 自动连播**，kg TOP500 跨源回归正常，LMS 全程存活；0.11.4 当天 kw/tx 单曲取链播放正常（位置推进），wy/kg 502 未播
  - 榜单页头（0.11.2）：feed 级 image/play/actions/albumData 已上机；**页头大图与 All Songs 行的消失需用户在达菲 Web 界面目验**（CLI 只能验数据层：feed 级 title 已透出）
  - kw 榜单设备实测（0.11.0）：菜单「kw榜单」43 榜；热歌榜曲目+封面代理（`kw:<songmid>` 兜底）正常
  - 翻页设备实测（0.11.4）：CLI `items 0 60` → 60 行（跨 2 上游页补取）✅；`items 96 10` → 尾窗 4 行、归一化后空 ✅
  - prefs 现值（设备）：quality **flac24bit**（用户自行改的，非本轮回滚项）；bridgeTimeout 7 / helperConcurrency 2 / resolveTtl 600 / coverProxy on / boards 全 on（**含新 boardsKw**）；qualityFallback on / verifyUrl on / autoSkipOnError on / **workerEnable on / workerIdle 600 / preferStreamable on**；`plugin.lxmusic` 日志级别 = **ERROR**、`player.source` = **ERROR**（无诊断残留）
  - **常驻 worker 现场**（设置页「诊断」区可读，`tmp/verify_settings.py` 会打出来）：`常驻解析进程：<启用中的源> pid N 已预热；可播校验 pid N 已预热`（每源 1 个 + 校验 1 个）；停用/删除的源不再预热；空闲 600s 自动退出
  - ⚠️ **0.10.x 轮重启过达菲两次**（诊断 `formatOverride` 卡死时，见§5.10.54）。重启只影响播放，插件与源配置都持久，无需补偿操作
  - **`pdone/lx-music-source` 10 个源实测矩阵**（2026-09-21，逐源隔离 × 逐平台取链 + 校验，0.9.6 后的准确原因；**"覆盖"指取链成功，不代表达菲能播**）：
    | 源 | 覆盖 | 真实原因 |
    |---|---|---|
    | changqing（长青SVIP） | **5/5** | **0.11.0 起停用**（用户决定）；取链强但直链是中转链，**达菲上放不出声**（靠 `preferStreamable` 自动跳过） |
    | lx（独家音源） | **4~5/5** | 保留（官方 URL）；直链可播（**实际出声靠它**） |
    | sixyin（六音，333 KB） | 0/5 | 上游 **403 Forbidden**（源侧，非引擎） |
    | ikun | 0/5 | `curl exit 35` TLS 不可达 |
    | Huibq | 0/5 | `unknow error` / `curl exit 56` 连接重置 |
    | huanyin（幻音） | 0/5 | `verify: no response`（直链连不上） |
    | flower / grass / juhe / qdy | 0~3/5 | 源自身 `Error` / 410 死链 / 只 128k |
  - **订阅源导入/判重/刷新/删除全链路复核**（2026-09-21 第三轮，表单回放逐项实测）：在线 URL 导入 27645 B 逐字节一致（无二次编码/无裁剪，基准=本机直抓同一 URL）；同 URL 重导入→「与已有订阅源…内容完全相同，已跳过」；本地文件导入（指向设备上独家落盘文件）→同样判重；不存在路径→干净报错「文件不存在：…」；lxRefresh →「在线订阅已是最新（内容未变）」；lxDel →「已删除订阅源」且行干净消失、其余源无损。消息全部无乱码（`_m`/`_ent` 混旗标防护有效）。① 注意：重名表单字段会被 LMS 解析成数组→ addUrl 报「URL 必须是 http…」，回放脚本必须先剔旧字段再追加（0.7.38 同族坑）；② 小文案瑕疵：判重跳过的消息前缀是「导入失败：」，语义上应该算「跳过」不算失败（低优先级，改动需重打包装机，暂不动）
  - 附带结论：**设备能直连`raw.githubusercontent.com`**（两个源都从官方原链导入），不必用 ghproxy 加速链
- **本机 IP/仓库基址**：`192.168.2.68:8765`（**DHCP 可能变化**，变了要同步 `dist/repo.xml` 的 URL 与 pack.py 的 `LAN_BASE`）
- **GitHub**：`jackyytche/lms-plugin-lxmusic`（公开）；PAT 由用户在需要时提供（**勿写入文件、勿提交**）；
  本轮（2026-09-21）已用用户提供的 fine-grained PAT 推到 **v0.11.20**（release id `392384987`）——
  **用完请吊销该 token**（§七.1）；公开 `README.md` 已同步刷新
- **可用的救援通道**（LMS 卡死时）：Daphile 自己的 CGI 在**`:80`**，与 LMS 无关 ⇒`http://192.168.2.111/cgi-bin/Settings?ACTION=restart` 重启整机；`/cgi-bin/Info?ACTION=shutdown|pmsuspend` 同理。**没有 SSH**（未配置），所以卡死时这是唯一手段
- **订阅源样本**：`refs/samples/lx-6.js`（= `lx-music-source-v6-fixed.js` = `lx-latest.js`，4094 B，与 pdone/lx-music-source 官方 `lx/6.js` 逐字节一致；`dist/lx-6.js` 是给设备做 URL 导入测试的 LAN 副本）
- **本地工具**：python 3.14（`pack.py`、诊断/验收脚本）、node 24（`tmp/shim-sim`）、达菲诊断脚本复用喜马拉雅项目 `m0/diag_plugin_install.py`（装机/重启）与 `diag_settings_form.py`（改日志级别等整表回放）

---

## 九、文档与索引

- `共识定版.md` →需求定稿（§一为其摘要）；`docs/lx-music-source-analysis.md` …订阅源深度分析；`docs/lx-music-custom-source-api.md` →lx 宿主契约（`desktop-preload.js` 为准）；`docs/js-helper-architecture.md` →Perl+qjs 助手架构设计；`docs/existing-bridges-and-lms-constraints.md` …桥接方案与约束调研；`docs/source-api-endpoint-inventory.md` …各源端点清单
- `docs/lx-desktop-settings-forensics.md` →PC 端 2.12.5 设置项逐条考古（带 `file:line` 证据，做设置项时的参考）
- `docs/m0.6-source-management-and-quality-design.md` …多源注册表 + 音质降级链设计（0.7.x 落地）；`plugin/LxMusic/engine/sdk/` →vendor 树与打包产物说明；`tmp/shim-sim/` →shim 模拟器
- **播放链路（M0.10 新增，最值得先读）**：本文档 **§5.10**（常驻 worker 三个坑 + 播放无声真凶 + `formatOverride` 雷区 + 验收口径）`tmp/session_check.py`（开工自检）、`tmp/test_play.py` / `tmp/liveness.py`（播放验证 + 存活判据）`slimserver/Slim/Player/Song.pm`（`open` 的格式判定 / `canDirectStream` 决策 / `formatOverride` 钩子）`slimserver/Slim/Player/Protocols/HTTP.pm`、`slimserver/types.conf`（LMS 内部格式名：flac=**flc**、m4a=**mp4**）；设备侧验证流程见 §六.5
- **设置页/编码（M0.5 新增）**：`tmp/mk_settings_template.py`（模板生成器，**改文案的入口**）、`tmp/verify_settings.py`（设置页体检：纯 ASCII / 12 分区 / 诊断块 / 全部 pref 控件，0.10.9 已对齐）、`tmp/lx_settings_post.py`（表单回放）、`tmp/lx_cli.py`（9090 CLI 客户端）、`tmp/check_resolve.py`（搜索→取直链）、`tmp/probe_*.py`（编码/模板代次取证）；踩坑细节见§5.5
- `refs/lx-music-desktop/`（PC 端源码，封面/榜单权威参考）、`refs/lx-music-mobile/`、`refs/samples/`、`slimserver/`（LMS 源码）
