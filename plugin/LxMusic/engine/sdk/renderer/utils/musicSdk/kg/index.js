import leaderboard from './leaderboard'
import { apis } from '../api-source'
import songList from './songList'
import musicSearch from './musicSearch'

// vendored+trimmed: pic/lyric/hotSearch/comment removed
const kg = {
	leaderboard,
	songList,
	musicSearch,

	getMusicUrl(songInfo, type) {
		return apis('kg').getMusicUrl(songInfo, type)
	},

	getMusicDetailPageUrl(songInfo) {
		return `https://www.kugou.com/song/#hash=${songInfo.hash}&album_id=${songInfo.albumId}`
	},
}

export default kg
