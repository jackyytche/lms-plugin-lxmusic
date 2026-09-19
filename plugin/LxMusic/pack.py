#!/usr/bin/env python3
"""LxMusic 打包：zip(根=插件内容, qjs 0755) + SHA1 + repo.xml（GitHub release 基址）"""
import hashlib
import os
import re
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
        for full, rel in entries:
            zi = zipfile.ZipInfo(rel, date_time=(2026, 9, 18, 0, 0, 0))
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
