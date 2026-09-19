#!/usr/bin/env python3
"""LxMusic 打包：zip(根=插件内容, qjs 0755) + SHA1 + repo.xml（GitHub release 基址）"""
import hashlib
import os
import re
import time
import zipfile

SRC = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(SRC, '..', '..', 'dist'))
# 发布基址：GitHub release 资产（锚定版本 tag —— /releases/latest 会被 qjs 引擎 release 占住）
GH_BASE = 'https://github.com/jackyytche/lms-plugin-lxmusic/releases/download/v{version}'
# 本地联调可切 LAN_BASE（达菲实证：repo.xml 必须在服务器根路径, lang="EN" 大写）
LAN_BASE = 'http://192.168.2.68:8765'
BASE = os.environ.get('LX_REPO_BASE', GH_BASE)
# zip 名带版本号（喜马拉雅同款）：LMS 对同名 zip 有 DownloadedPlugins 缓存/摘要校验，
# 复用 LxMusic.zip 会在连续升级时出现"下载了却不安装"（0.4.5 现场踩到）
ZIP_TMPL = 'LxMusic-{version}.zip'


def _stamp():
    """zip 条目时间戳：必须"每次打包都变新"。

    LMS 用 Archive::Zip::extractTree 解压并**保留 zip 里的 mtime**，而 Template
    Toolkit 按 mtime 判编译缓存（COMPILE_DIR=<cachedir>/templates，STAT_TTL=3600）。
    曾经这里写死 (2026,9,18)，于是版本间模板 mtime 完全相同 —— 0.6.1 改了设置页模板，
    设备却仍渲染 0.6.0 的编译结果（页面逐字节相同，现场踩到）。用打包时刻即可；
    需要可复现构建时设 SOURCE_DATE_EPOCH（秒）。
    """
    epoch = os.environ.get('SOURCE_DATE_EPOCH')
    t = time.gmtime(int(epoch)) if epoch else time.gmtime()
    if t.tm_year < 1980:                     # DOS 时间下限
        t = time.gmtime(315532800)
    return (t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec)


def main():
    with open(os.path.join(SRC, 'install.xml'), encoding='utf-8') as fh:
        install = fh.read()
    version = re.search(r'<version>(.*?)</version>', install).group(1)
    base = BASE.replace('{version}', version)
    zip_name = ZIP_TMPL.format(version=version)

    os.makedirs(OUT, exist_ok=True)
    zip_path = os.path.join(OUT, zip_name)
    if os.path.exists(zip_path):
        os.remove(zip_path)

    entries = []
    for root, dirs, files in os.walk(SRC):
        dirs[:] = [d for d in dirs if d not in ('.git', '__pycache__', 't')]
        for f in files:
            if f in ('pack.py',):
                continue
            full = os.path.join(root, f)
            rel = os.path.relpath(full, SRC).replace(os.sep, '/')
            # 设备端只需要打包产物：sdk 源码树/shim 源/vendor 与本地测试文件不上机
            if rel.startswith(('engine/sdk/renderer/', 'engine/sdk/shim/', 'engine/test/')) \
                    or rel in ('harness_out.txt',):
                continue
            entries.append((full, rel))
    entries.sort(key=lambda t: t[1])

    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        stamp = _stamp()
        for full, rel in entries:
            zi = zipfile.ZipInfo(rel, date_time=stamp)
            # qjs 必须带 0755 执行位（PluginDownloader 只剥 0022，其余保留）
            zi.external_attr = ((0o100755 if rel.endswith('/qjs') else 0o100644) << 16)
            zi.compress_type = zipfile.ZIP_DEFLATED
            with open(full, 'rb') as fh:
                z.writestr(zi, fh.read())

    h = hashlib.sha1()
    with open(zip_path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(65536), b''):
            h.update(chunk)
    sha1 = h.hexdigest()

    repo = f'''<?xml version="1.0" encoding="utf-8"?>
<extensions>
\t<details>
\t\t<title lang="EN">jackyytche lx-music repo</title>
\t\t<name lang="EN">jackyytche lx-music repo</name>
\t\t<url lang="EN">{base}/</url>
\t\t<description lang="EN">LX Music (luoxue) custom-source player plugin for Daphile / Lyrion Music Server.</description>
\t\t<email>noreply@example.com</email>
\t</details>
\t<plugins>
\t\t<plugin name="LxMusic" version="{version}" minTarget="7.7" maxTarget="*">
\t\t\t<title lang="EN">LX Music / 洛雪音乐</title>
\t\t\t<desc lang="EN">Play music from LX Music custom-source subscriptions: import a source, search and stream with quality selection.</desc>
\t\t\t<url>{base}/{zip_name}</url>
\t\t\t<sha>{sha1}</sha>
\t\t\t<creator>jackyytche</creator>
\t\t\t<email>noreply@example.com</email>
\t\t\t<category>musicservices</category>
\t\t</plugin>
\t</plugins>
</extensions>
'''
    with open(os.path.join(OUT, 'repo.xml'), 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(repo)

    print(f'version = {version}')
    print(f'sha1    = {sha1}')
    print(f'zip     = {zip_path} ({os.path.getsize(zip_path)} bytes)')
    print(f'repo    = {os.path.join(OUT, "repo.xml")} (base={BASE})')
    print(f'entries = {len(entries)}')
    for _, rel in entries:
        print(f'  {rel}')


if __name__ == '__main__':
    main()
