#!/usr/bin/env python3
"""kuwo 歌曲探测 v4：ast.literal_eval 直解单引号 dict"""
import ast
import sys
import urllib.request
import urllib.parse

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

q = urllib.parse.quote('晴天 周杰伦')
api = ('http://search.kuwo.cn/r.s?all=%s&ft=music&itemset=web_2016&client=kt'
       '&pn=0&rn=5&rformat=json&encoding=utf8&vipver=MUSIC_8.0.3.1_WQD' % q)

req = urllib.request.Request(api, headers={'User-Agent': 'Mozilla/5.0'})
raw = urllib.request.urlopen(req, timeout=15).read().decode('gbk', 'replace')
obj = ast.literal_eval(raw)
for s in obj.get('abslist', [])[:5]:
    rid = (s.get('MUSICRID') or '').replace('MUSIC_', '')
    print(rid, '|', s.get('SONGNAME'), '|', s.get('ARTIST'), '|', s.get('ALBUM'))
