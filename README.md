# lms-plugin-lxmusic

**洛雪音乐** — 为 Daphile / Lyrion Music Server 打造的 [lx-music](https://github.com/lyswhut/lx-music-desktop)
自定义音源插件（纯插件实现，无需外部服务）。

在达菲网页里直接使用洛雪订阅源：**导入订阅（在线 URL / 粘贴 / 文件 / 目录）→ 平台榜单与歌单浏览 →
聚合搜索 → 多音质选择 → 跨源自动降级 → 播放与拖动进度条**。

> 仅供个人学习研究使用。本仓库**不附带任何订阅源脚本**（源由使用者自行选择与导入）。

## 安装

达菲网页 → 设置 → 插件 → 第三方插件源 → 添加：

```
https://github.com/jackyytche/lms-plugin-lxmusic/releases/latest/download/repo.xml
```

然后安装 **LX Music / 洛雪音乐**（装完按提示重启；LMS 在启动时才落盘更新，必要时重启两次）。
安装后到 设置 → 插件 → LX Music 的 **Settings** 页导入你自己的订阅源。

## 功能

- **订阅源管理**：在线 URL / 粘贴 / 本地文件 / 目录导入；逐源启停、排序、重新拉取、删除；
  同内容自动判重；源正文落持久目录，升级插件不丢（见 `HANDOFF.md` §5.11.85）
- **浏览**：kw / kg / tx / wy / mg 五个平台的**榜单**（可翻页）、**歌单发现**（推荐 / 最热 / 最新）、
  **聚合搜索**（歌曲 + 歌单）、整个榜单 / 整张歌单入队播放
- **音质**：128k / 320k / flac / flac24bit，取链后做**可播性探测**（range GET + 音频魔数嗅探）并自动降级
- **播放链路**：
  - 常驻 qjs 解析进程（取链 + 校验各一）与解析缓存、预取，起播更快
  - 用**自己嗅探出的真实格式**覆盖 CDN 谎报的 Content-Type（QQ 的 `.flac` 会声明 `audio/x-ogg`，
    不修就是"进度条在走但没声音"）
  - **https 直链**走 LMS 自带的 HTTPS 处理器（派生自 `Slim::Player::Protocols::HTTPS`）——
    咪咕（mg）等只有 https 直链的平台因此才能播放
  - **拖动进度条可用**：码率/时长同时发布到伪 URL 与真实直链 URL，并自实现 `getSeekData`
- **封面**：五个平台的队列/正在播放封面（kg 走官方 `get_res_privilege` 取真图；kw/kg 经插件代理）
- **插件图标**：插件管理器与「应用」菜单显示洛雪官方图标

## 版本

当前 **v0.11.20**（2026-09-21）。历史：v0.5.9 之后的一整条 0.6.0 ~ 0.11.20 线此前只在本机 LAN 仓库发布，
本 release 是首次把它们公开。逐版本变化见 release 说明与 `HANDOFF.md` §四「版本史」。

## 目录结构

```
plugin/LxMusic/         插件本体（Perl：Plugin/Helper/ProtocolHandler/Settings/Sources/install.xml）
plugin/LxMusic/engine/  vendored 的 lx-music musicSdk 打包产物 + qjs 宿主 shim
plugin/LxMusic/Bin/     随包的 QuickJS（x86_64-linux / x86_64-cygwin）
engine/                 shim 的独立副本与本地测试源桩
plugin/t/               本地 perl -c 用的 LMS 存根
.github/workflows/      QuickJS 构建流水线 + 本地回归测试
HANDOFF.md              开发交接文档（权威事实源，含全部踩坑与验收记录）
```

## 构建

```bash
python plugin/LxMusic/pack.py            # 读 install.xml 版本号 → dist/LxMusic-<ver>.zip + repo.xml(+repo-gh.xml)
```

打包前请先跑 `tmp/precheck.ps1`（所有 `.pm` 语法 + 设置页模板纯 ASCII + shim `node --check`）。

## 版权

插件代码由本项目编写；`engine/sdk/**` 为 lx-music-desktop 的 musicSdk 构建产物；
插件图标取自 lx-music-desktop（Apache-2.0）。
