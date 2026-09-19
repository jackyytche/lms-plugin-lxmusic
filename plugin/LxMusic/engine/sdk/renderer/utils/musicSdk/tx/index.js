import leaderboard from './leaderboard'
import songList from './songList'
import musicSearch from './musicSearch'
import { apis } from '../api-source'

// vendored+trimmed: lyric/hotSearch/comment removed
const tx = {
	leaderboard,
	songList,
	musicSearch,

	getMusicUrl(songInfo, type) {
		return apis('tx').getMusicUrl(songInfo, type)
	},
	async getPic(songInfo) {
		return `https://y.gtimg.cn/music/photo_new/T002R500x500M000${songInfo.albumId}.jpg`
	},
	getMusicDetailPageUrl(songInfo) {
		return `https://y.qq.com/n/yqq/song/${songInfo.songmid}.html`
	},
}

export default tx
