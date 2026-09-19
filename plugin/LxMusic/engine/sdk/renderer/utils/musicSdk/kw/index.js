import { httpFetch } from '../../request'
import tipSearch from './tipSearch'
import musicSearch from './musicSearch'
import { formatSinger } from './util'
import leaderboard from './leaderboard'
import { apis } from '../api-source'
import songList from './songList'

// vendored+trimmed: lyric/pic/hotSearch/comment removed
const kw = {
	_musicInfoRequestObj: null,
	_musicInfoPromiseCancelFn: null,

	tipSearch,
	musicSearch,
	leaderboard,
	songList,

	getMusicUrl(songInfo, type) {
		return apis('kw').getMusicUrl(songInfo, type)
	},

	handleMusicInfo(songInfo) {
		return this.getMusicInfo(songInfo).then(info => {
			songInfo.name = info.name
			songInfo.singer = formatSinger(info.artist)
			songInfo.img = info.pic
			songInfo.albumName = info.album
			return songInfo
		})
	},

	getMusicInfo(songInfo) {
		if (this._musicInfoRequestObj) this._musicInfoRequestObj.cancelHttp()
		this._musicInfoRequestObj = httpFetch(`http://www.kuwo.cn/api/www/music/musicInfo?mid=${songInfo.songmid}`)
		return this._musicInfoRequestObj.promise.then(({ body }) => {
			return body.code === 200 ? body.data : Promise.reject(new Error(body.msg))
		})
	},

	getMusicDetailPageUrl(songInfo) {
		return `http://www.kuwo.cn/play_detail/${songInfo.songmid}`
	},
}

export default kw
