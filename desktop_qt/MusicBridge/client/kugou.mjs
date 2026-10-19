// 酷狗原始 hash、歌单全局 ID 与本机 listid 分别保存，不互相替换。
const array = (value) => (Array.isArray(value) ? value : []);
const identifier = (value) => (/^[a-zA-Z0-9_-]{1,100}$/.test(String(value ?? '')) ? String(value) : '');
// 权益接口可能给 album_id=0，同时通过 recommend_album_id 提供实际专辑。
const albumIdentifier = (...values) => values.map(identifier).find((value) => value && value !== '0') || '';
const cover = (value) =>
    String(value || '')
        .replace('{size}', '480')
        .replace(/^http:/, 'https:');
/**
 * 将酷狗搜索、曲库及云歌单返回的条目转换为统一听歌模型。
 * 保留播放需要的专辑音频标识，禁止使用 mixsongid 代替歌曲 hash。
 */
export function kugouItem(raw, kind = 'song') {
    const base = raw.base || {};
    const audio = raw.audio_info || {};
    const album = raw.album_info || raw.albuminfo || {};
    let id;
    let title;
    if (kind === 'song') {
        id = identifier(raw.hash || raw.FileHash || audio.hash || audio.hash_128);
        title = raw.songname || raw.audio_name || base.audio_name || raw.SongName || raw.filename || raw.name;
    } else if (kind === 'album') {
        id = identifier(raw.albumid || raw.album_id || raw.AlbumID);
        title = raw.albumname || raw.album_name || raw.AlbumName;
    } else if (kind === 'artist') {
        id = identifier(raw.author_id || raw.singerid || raw.AuthorId);
        title = raw.author_name || raw.singername || raw.AuthorName;
    } else {
        id = identifier(raw.global_collection_id || raw.rankid || raw.listid);
        title = raw.specialname || raw.rankname || raw.name;
    }
    if (!id || typeof title !== 'string' || (kind === 'song' && !/^[a-fA-F0-9]{32}$/.test(id))) {
        return null;
    }
    const artists = array(raw.authors || raw.singerinfo || raw.Authors)
        .map((artist) => {
            const author = artist.base || artist;
            return {
                id: identifier(author.author_id ?? author.id ?? author.AuthorId),
                name: String(author.author_name ?? author.name ?? author.AuthorName ?? ''),
            };
        })
        .filter((artist) => artist.id && artist.name);
    const artist =
        artists.map((entry) => entry.name).join(' / ') ||
        raw.author_name ||
        base.author_name ||
        raw.singername ||
        raw.SingerName ||
        '';
    return {
        provider: 'kugou',
        kind,
        id,
        key: 'kugou:' + kind + ':' + id.toLowerCase(),
        title,
        artist,
        artists,
        albumID: albumIdentifier(raw.album_id, base.album_id, raw.AlbumID, album.id, raw.recommend_album_id),
        albumAudioID: identifier(raw.album_audio_id || base.album_audio_id || raw.mixsongid || raw.MixSongID),
        album: album.album_name || album.name || raw.album_name || raw.albumname || raw.AlbumName || '',
        cover: cover(
            raw.sizable_cover ||
                raw.sizable_avatar ||
                raw.cover ||
                raw.imgurl ||
                raw.img_cover ||
                raw.Image ||
                raw.info?.image ||
                album.cover ||
                album.sizable_cover ||
                raw.trans_param?.union_cover,
        ),
        description: raw.intro || '',
        date: raw.publishtime || raw.publish_date || '',
        duration: Number(
            raw.timelen ||
                raw.timelength ||
                audio.duration ||
                audio.duration_128 ||
                audio.timelength ||
                raw.info?.duration ||
                0,
        ),
        trackCount: Number(raw.count || raw.songcount || raw.song_count || 0),
        creatorID: identifier(raw.list_create_userid || raw.create_userid || raw.suid),
        owned: Number(raw.type) === 0,
        listid: identifier(raw.listid),
        listType: Number(raw.type || 0),
        chart: !!raw.rankid,
        rankCid: identifier(raw.rank_cid),
        isDefault: Number(raw.is_def) === 1,
        isFavorite: Number(raw.is_def) === 2,
        wiki: '',
    };
}

export class KugouAPI {
    constructor(base) {
        this.base = base;
        base.provider = 'kugou';
        this.host = base.host;
        this.provider = 'kugou';
        this.songCache = new Map();
        this.playlists = [];
    }

    request(route, values = {}, allow = [200], valid = () => true) {
        return this.base.request('/kugou' + route, values, allow, valid);
    }

    delay(milliseconds) {
        return this.base.delay(milliseconds);
    }

    rows(raw, kind = 'song') {
        return array(raw)
            .map((entry) => kugouItem(entry, kind))
            .filter(Boolean)
            .map((entry) => {
                if (kind === 'song') {
                    this.songCache.set(entry.id, entry);
                }
                return entry;
            });
    }

    page(raw, kind, offset, total, more) {
        const items = this.rows(raw, kind);
        const count = array(raw).length;
        return {
            items,
            rawCount: count,
            total: Number(total ?? offset + count),
            more: count > 0 && (more === undefined ? offset + count < Number(total) : !!more),
        };
    }

    async search(text, kind, offset = 0, valid = () => true) {
        const types = { song: 'song', album: 'album', playlist: 'special', artist: 'author' };
        if (!types[kind]) {
            throw new Error('酷狗不支持此搜索类别');
        }
        if (!this.host.authenticated?.()) {
            throw new Error('酷狗搜索需要登录，请先用酷狗音乐扫码');
        }
        const body = await this.request(
            '/search',
            {
                keywords: text,
                type: types[kind],
                page: Math.floor(offset / 30) + 1,
                pagesize: 30,
            },
            [200],
            valid,
        );
        const data = body.data || {};
        return this.page(data.lists || data.info, kind, offset, data.total);
    }

    async songs(ids, valid = () => true) {
        const result = [];
        for (const id of ids) {
            if (!valid()) {
                throw new Error('Stale operation');
            }
            const cached = this.songCache.get(id);
            if (cached) {
                result.push(cached);
                continue;
            }
            const body = await this.request('/privilege/lite', { hash: id }, [200], valid);
            result.push(...this.rows(body.data));
        }
        return result;
    }

    async trackPage(value, offset, valid) {
        // 专辑接口使用文档默认的 30 条；实测 100 条会返回 error_code=20010。
        const pagesize = value.kind === 'album' ? 30 : 100;
        const page = Math.floor(offset / pagesize) + 1;
        let route = '/playlist/track/all';
        let params = { id: value.id, page, pagesize };
        if (value.chart) {
            route = '/rank/audio';
            params = { rankid: value.id, rank_cid: value.rankCid, page, pagesize: 100 };
        } else if (value.kind === 'album') {
            route = '/album/songs';
        } else if (value.kind === 'artist') {
            route = '/artist/audios';
            params.sort = 'hot';
        } else if (value.listid) {
            route = '/playlist/track/all/new';
            params = { listid: value.listid, type: value.listType, page, pagesize: 100 };
        }
        const body = await this.request(route, params, [200], valid);
        const data = body.data || {};
        const raw = Array.isArray(data) ? data : data.songs || data.songlist || data.info;
        return this.page(raw, 'song', offset, data.total ?? data.count ?? body.total);
    }

    async detail(value, valid = () => true) {
        if (value.kind === 'song') {
            // 不完整搜索结果需要读取原始歌曲资料，不能直接返回相同的缓存条目。
            const body = await this.request(
                '/privilege/lite',
                { hash: value.id, album_id: value.albumID || 0 },
                [200],
                valid,
            );
            const fetched = this.rows(body.data)[0];
            const song = fetched
                ? {
                      ...value,
                      ...fetched,
                      artists: fetched.artists.length ? fetched.artists : value.artists || [],
                  }
                : this.songCache.get(value.id);
            if (!song) {
                throw new Error('酷狗歌曲资料暂不可读取');
            }
            this.songCache.set(song.id, song);
            return [song, [], []];
        }
        let updated = value;
        if (value.kind === 'artist' || value.kind === 'album') {
            const route = value.kind === 'artist' ? '/artist/detail' : '/album/detail';
            const body = await this.request(route, { id: value.id }, [200], valid);
            const raw = Array.isArray(body.data) ? body.data[0] : body.data;
            const metadata = raw && kugouItem(raw, value.kind);
            if (metadata) {
                updated = { ...value, ...metadata };
            }
        }
        const songs = [];
        let more;
        let offset = 0;
        do {
            const page = await this.trackPage(value, offset, valid);
            offset += page.rawCount;
            songs.push(...page.items);
            more = page.more;
            if (!page.rawCount || !page.items.length) {
                break;
            }
        } while (more);
        return [{ ...updated, trackCount: songs.length }, songs, []];
    }

    async artistAlbums(id, offset = 0, valid = () => true) {
        const body = await this.request(
            '/artist/albums',
            {
                id,
                page: Math.floor(offset / 30) + 1,
                pagesize: 30,
            },
            [200],
            valid,
        );
        const data = body.data || {};
        const raw = Array.isArray(data) ? data : data.info || data.albums;
        return this.page(raw, 'album', offset, data.total ?? body.total);
    }

    async wiki() {
        return '酷狗音乐 / 歌曲资料';
    }

    async account(valid = () => true) {
        const body = await this.request('/user/detail', {}, [200], valid);
        if (!body.profile?.id || body.profile.id === '0') {
            const failure = new Error('请登录酷狗音乐');
            failure.authExpired = true;
            throw failure;
        }
        return [body.profile.id, body.profile.nickname];
    }

    /**
     * 分页读取本机账号的全部歌单，再按文档 type 区分自建与收藏。
     * 私人歌单保留 listid，打开时使用仅支持本人歌单的新接口。
     */
    async userPlaylists(uid, valid = () => true) {
        const items = [];
        let page = 1;
        let rawCount = 0;
        let total = 0;
        do {
            const body = await this.request('/user/playlist', { page, pagesize: 100 }, [200], valid);
            const data = body.data || {};
            const raw = array(data.info || data.lists);
            rawCount += raw.length;
            const declaredCount = Number(data.list_count || 0) + Number(data.collect_count || 0);
            total = Number(data.total ?? data.count ?? (declaredCount || rawCount));
            for (const entry of this.rows(raw, 'playlist')) {
                entry.creatorID = entry.owned ? uid : '';
                items.push(entry);
            }
            if (!raw.length) {
                break;
            }
            page++;
        } while (rawCount < total);
        this.playlists = items;
        return { items, total, rawCount, more: false };
    }

    async likedSongs(offset = 0, valid = () => true) {
        if (!this.playlists.length) {
            const [uid] = await this.account(valid);
            await this.userPlaylists(uid, valid);
        }
        const favorite = this.playlists.find(
            (entry) => entry.owned && (entry.isFavorite || entry.title.trim() === '我喜欢'),
        );
        if (!favorite) {
            throw new Error('酷狗未返回“我喜欢”歌单，请从“我的歌单”浏览');
        }
        return this.trackPage(favorite, offset, valid);
    }

    async likedAlbums() {
        throw new Error('酷狗 API 未提供收藏专辑读取，请从搜索或歌单浏览专辑');
    }

    async playback(value, quality, alternative, valid) {
        const levels = {
            standard: '128',
            higher: '128',
            exhigh: '320',
            lossless: 'flac',
            hires: 'high',
            jymaster: 'flac',
        };
        const level = levels[quality] || '320';
        const read = async (selected) => {
            const body = await this.request(
                '/song/url',
                {
                    hash: value.id,
                    album_id: value.albumID || 0,
                    album_audio_id: value.albumAudioID || 0,
                    quality: selected,
                },
                [200],
                valid,
            );
            const url = array(body.url).find(
                (entry) => typeof entry === 'string' && /^https?:\/\//.test(entry),
            );
            return url ? { url, size: Number(body.fileSize || 0), br: Number(body.bitRate || 0) } : null;
        };
        let track = await read(level);
        if (!track && level !== '128') {
            track = await read('128');
            if (track) {
                track.qualityFallback = '标准';
            }
        }
        if (!track) {
            throw new Error('酷狗未返回可播放地址，请确认账号登录及歌曲权限');
        }
        // 母带的转码格式不属于首版播放能力，明确告知实际使用的无损音质。
        if (quality === 'jymaster' && !track.qualityFallback) {
            track.qualityFallback = '无损';
        }
        return track;
    }

    async discover(tab, offset = 0, category = '全部', valid = () => true) {
        const params = { page: Math.floor(offset / 30) + 1, pagesize: 30 };
        let route;
        if (tab === 'charts') {
            route = '/rank/list';
        } else if (tab === 'daily') {
            route = '/everyday/recommend';
        } else if (tab === 'albums') {
            route = '/top/album';
        } else {
            route = '/top/playlist';
            params.category_id = category === '全部' ? 0 : category;
        }
        const body = await this.request(route, params, [200], valid);
        const data = body.data || {};
        if (tab === 'charts') {
            const raw = array(data.info).flatMap((entry) => (entry.rankid ? [entry] : array(entry.children)));
            return this.page(raw, 'playlist', offset, raw.length, false);
        }
        if (tab === 'albums') {
            return this.page(
                ['chn', 'eur', 'jpn', 'kor'].flatMap((region) => array(data[region])),
                'album',
                offset,
                0,
                false,
            );
        }
        if (tab === 'daily') {
            return this.page(data.song_list, 'song', offset, 0, false);
        }
        return this.page(data.special_list, 'playlist', offset, data.total, data.has_next);
    }

    async categories(valid = () => true) {
        const body = await this.request('/playlist/tags', {}, [200], valid);
        return array(body.data)
            .flatMap((group) => array(group.son))
            .map((entry) => ({
                id: String(entry.tag_id),
                name: entry.tag_name,
            }));
    }
}
