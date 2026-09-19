import { apis } from '../api-source'
import leaderboard from './leaderboard'
import songList from './songList'
import musicSearch from './musicSearch'

// vendored+trimmed: pic/lyric/hotSearch/comment removed
const mg = {
	songList,
	musicSearch,
	leaderboard,

	getMusicUrl(songInfo, type) {
		return apis('mg').getMusicUrl(songInfo, type)
	},
	getMusicDetailPageUrl(songInfo) {
		return `http://music.migu.cn/v3/music/song/${songInfo.copyrightId}`
	},
}

export default mg
