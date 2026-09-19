import leaderboard from './leaderboard'
import { apis } from '../api-source'
import musicSearch from './musicSearch'
import songList from './songList'

// vendored+trimmed: lyric/hotSearch/comment removed
const wy = {
	leaderboard,
	musicSearch,
	songList,

	getMusicUrl(songInfo, type) {
		return apis('wy').getMusicUrl(songInfo, type)
	},
	getMusicDetailPageUrl(songInfo) {
		return `https://music.163.com/#/song?id=${songInfo.songmid}`
	},
}

export default wy
