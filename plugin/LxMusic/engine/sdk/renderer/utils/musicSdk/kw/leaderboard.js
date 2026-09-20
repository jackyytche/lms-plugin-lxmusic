import { httpFetch } from '../../request'
import { formatPlayTime, decodeName } from '../../index'
import { formatSinger } from './util'


const boardList = [{ id: 'kw__93', name: '飙升榜', bangid: '93' }, { id: 'kw__17', name: '新歌榜', bangid: '17' }, { id: 'kw__16', name: '热歌榜', bangid: '16' }, { id: 'kw__158', name: '抖音热歌榜', bangid: '158' }, { id: 'kw__292', name: '铃声榜', bangid: '292' }, { id: 'kw__284', name: '热评榜', bangid: '284' }, { id: 'kw__290', name: 'ACG新歌榜', bangid: '290' }, { id: 'kw__286', name: '台湾KKBOX榜', bangid: '286' }, { id: 'kw__279', name: '冬日暖心榜', bangid: '279' }, { id: 'kw__281', name: '巴士随身听榜', bangid: '281' }, { id: 'kw__255', name: 'KTV点唱榜', bangid: '255' }, { id: 'kw__280', name: '家务进行曲榜', bangid: '280' }, { id: 'kw__282', name: '熬夜修仙榜', bangid: '282' }, { id: 'kw__283', name: '枕边轻音乐榜', bangid: '283' }, { id: 'kw__278', name: '古风音乐榜', bangid: '278' }, { id: 'kw__264', name: 'Vlog音乐榜', bangid: '264' }, { id: 'kw__242', name: '电音榜', bangid: '242' }, { id: 'kw__187', name: '流行趋势榜', bangid: '187' }, { id: 'kw__204', name: '现场音乐榜', bangid: '204' }, { id: 'kw__186', name: 'ACG神曲榜', bangid: '186' }, { id: 'kw__185', name: '最强翻唱榜', bangid: '185' }, { id: 'kw__26', name: '经典怀旧榜', bangid: '26' }, { id: 'kw__104', name: '华语榜', bangid: '104' }, { id: 'kw__182', name: '粤语榜', bangid: '182' }, { id: 'kw__22', name: '欧美榜', bangid: '22' }, { id: 'kw__184', name: '韩语榜', bangid: '184' }, { id: 'kw__183', name: '日语榜', bangid: '183' }, { id: 'kw__145', name: '会员畅听榜', bangid: '145' }, { id: 'kw__153', name: '网红新歌榜', bangid: '153' }, { id: 'kw__64', name: '影视金曲榜', bangid: '64' }, { id: 'kw__176', name: 'DJ嗨歌榜', bangid: '176' }, { id: 'kw__106', name: '真声音', bangid: '106' }, { id: 'kw__12', name: 'Billboard榜', bangid: '12' }, { id: 'kw__49', name: 'iTunes音乐榜', bangid: '49' }, { id: 'kw__180', name: 'beatport电音榜', bangid: '180' }, { id: 'kw__13', name: '英国UK榜', bangid: '13' }, { id: 'kw__164', name: '百大DJ榜', bangid: '164' }, { id: 'kw__246', name: 'YouTube音乐排行榜', bangid: '246' }, { id: 'kw__265', name: '韩国Genie榜', bangid: '265' }, { id: 'kw__14', name: '韩国M-net榜', bangid: '14' }, { id: 'kw__8', name: '香港电台榜', bangid: '8' }, { id: 'kw__15', name: '日本公信榜', bangid: '15' }, { id: 'kw__151', name: '腾讯音乐人原创榜', bangid: '151' }]

const sortQualityArray = array => {
  const qualityMap = {
    flac24bit: 4,
    flac: 3,
    '320k': 2,
    '128k': 1,
  }
  const rawQualityArray = []
  const newQualityArray = []

  array.forEach((item, index) => {
    const type = qualityMap[item.type]
    if (!type) return
    rawQualityArray.push({ type, index })
  })

  rawQualityArray.sort((a, b) => a.type - b.type)

  rawQualityArray.forEach(item => {
    newQualityArray.push(array[item.index])
  })

  return newQualityArray
}

export default {
  list: [
    {
      id: 'kwbiaosb',
      name: '飙升榜',
      bangid: 93,
    },
    {
      id: 'kwregb',
      name: '热歌榜',
      bangid: 16,
    },
    {
      id: 'kwhuiyb',
      name: '会员榜',
      bangid: 145,
    },
    {
      id: 'kwdouyb',
      name: '抖音榜',
      bangid: 158,
    },
    {
      id: 'kwqsb',
      name: '趋势榜',
      bangid: 187,
    },
    {
      id: 'kwhuaijb',
      name: '怀旧榜',
      bangid: 26,
    },
    {
      id: 'kwhuayb',
      name: '华语榜',
      bangid: 104,
    },
    {
      id: 'kwyueyb',
      name: '粤语榜',
      bangid: 182,
    },
    {
      id: 'kwoumb',
      name: '欧美榜',
      bangid: 22,
    },
    {
      id: 'kwhanyb',
      name: '韩语榜',
      bangid: 184,
    },
    {
      id: 'kwriyb',
      name: '日语榜',
      bangid: 183,
    },
  ],
  // getUrl: (p, l, id) => `http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&pn=${p - 1}&rn=${l}&type=bang&data=content&id=${id}&show_copyright_off=0&pcmp4=1&isbang=1`,
  regExps: {
    mInfo: /level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)/,
  },
  limit: 100,
  _requestBoardsObj: null,

  // kbangserver 2026-09 起的载荷没有 n_minfo/pic，音质声明要从 formats 令牌串恢复
  // （对齐老 N_MINFO bitrate 语义：128/320/2000(flac)/4000(flac24bit)）：
  //   MP3128 -> 128k    MP3H -> 320k    ALFLAC -> flac
  //   ZP*（臻品母带/全景声/黎音）与 DTSX（24bit 无损多声道）-> flac24bit
  // 其余令牌（MV*/SMP4*/EX*/WMA*/AAC*/OGG*/BCMS 等）与播放档位无关，忽略。
  // size 不可知则置 null（album.js 同款）；插件侧只用 type 做音质裁剪。
  formatsToTypes(formats) {
    const types = []
    const _types = {}
    const tokens = String(formats || '').split('|')
    const has = re => tokens.some(t => re.test(t))
    if (has(/^MP3128$/)) { types.push({ type: '128k', size: null }); _types['128k'] = { size: null } }
    if (has(/^MP3H$/)) { types.push({ type: '320k', size: null }); _types['320k'] = { size: null } }
    if (has(/^ALFLAC$/)) { types.push({ type: 'flac', size: null }); _types.flac = { size: null } }
    if (has(/^ZP|^DTSX/)) { types.push({ type: 'flac24bit', size: null }); _types.flac24bit = { size: null } }
    return { types, _types }
  },

  getBoardsData() {
    if (this._requestBoardsObj) this._requestBoardsObj.cancelHttp()
    this._requestBoardsObj = httpFetch('http://qukudata.kuwo.cn/q.k?op=query&cont=tree&node=2&pn=0&rn=1000&fmt=json&level=2')
    return this._requestBoardsObj.promise
  },
  getData(url) {
    const requestDataObj = httpFetch(url)
    return requestDataObj.promise
  },
  filterData(rawList) {
    return rawList.map(item => {
      const { types, _types } = this.formatsToTypes(item.formats)

      return {
        singer: formatSinger(decodeName(item.artist)),
        name: decodeName(item.name),
        albumName: decodeName(item.album),
        albumId: item.albumid,
        songmid: item.id,
        source: 'kw',
        // 老载荷是 duration；现载荷时长在 song_duration（秒），duration 变成了在榜时长
        interval: formatPlayTime(parseInt(item.song_duration)),
        // 封面不随榜单下发；插件侧对 kw 有 pic.web 兜底（rid=<songmid>），置 null 即可
        img: null,
        lrc: null,
        otherSource: null,
        types: sortQualityArray(types),
        _types,
        typeUrl: {},
      }
    })
  },

  filterBoardsData(rawList) {
    // console.log(rawList)
    let list = []
    for (const board of rawList) {
      if (board.source != '1') continue
      list.push({
        id: 'kw__' + board.sourceid,
        name: board.name,
        bangid: String(board.sourceid),
      })
    }
    return list
  },
  async getBoards(retryNum = 0) {
    // if (++retryNum > 3) return Promise.reject(new Error('try max num'))
    // let response
    // try {
    //   response = await this.getBoardsData()
    // } catch (error) {
    //   return this.getBoards(retryNum)
    // }
    // console.log(response.body)
    // if (response.statusCode !== 200 || !response.body.child) return this.getBoards(retryNum)
    // const list = this.filterBoardsData(response.body.child)
    // // console.log(list)
    // console.log(JSON.stringify(list))
    // this.list = list
    // return {
    //   list,
    //   source: 'kw',
    // }
    this.list = boardList
    return {
      list: boardList,
      source: 'kw',
    }
  },

  getList(id, page, retryNum = 0) {
    if (++retryNum > 3) return Promise.reject(new Error('try max num'))

    // 调用方传的是完整榜单 id（如 kw__16），与 kg/tx 同款剥前缀
    if (typeof id == 'string') id = id.replace('kw__', '')

    // wbd.kuwo.cn（AES+MD5 签名）2026-09 实测对旧 key 返回 10006 DECRYPT_ERROR（appId 仍有效，
    // 是 key 被上游换掉），无新签名实现前弃用。kbangserver 免签名端点仍可用：
    // 25/25 静态榜单 id 逐一实测返回有效数据（2026-09-21，tmp 探针）。
    // 注意 pn 从 0 计数；total 在 num 字段；musiclist 为空数组是合法的翻页尽头，不重试。
    const requestUrl = `http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&pn=${page - 1}&rn=${this.limit}&type=bang&data=content&id=${id}&show_copyright_off=0&pcmp4=1&isbang=1`
    const request = httpFetch(requestUrl).promise

    return request.then(({ statusCode, body }) => {
      if (statusCode !== 200 || !body || !body.musiclist) return this.getList(id, page, retryNum)

      const list = this.filterData(body.musiclist)
      const total = parseInt(body.num)

      return {
        total: Number.isNaN(total) ? list.length : total,
        list,
        limit: this.limit,
        page,
        source: 'kw',
        // 榜单页头（0.11.1）：v9_pic2 是完整封面 URL（/120/ 路径段可换成 /500/，实测 200/26KB）；
        // pic 是目录级基址（非图片），仅作兜底
        info: {
          name: body.name || '',
          img: String(body.v9_pic2 || body.pic || '').replace('/120/', '/500/'),
        },
      }
    })
  },

  // getDetailPageUrl(id) {
  //   return `http://www.kuwo.cn/rankList/${id}`
  // },
}
