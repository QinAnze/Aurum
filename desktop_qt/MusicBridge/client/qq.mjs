// QQ 数据在此转换成资料库模型；mid 和媒体文件标识保持原值。
const array = (value) => (Array.isArray(value) ? value : []);
const identifier = (value) => (/^[a-zA-Z0-9_-]{1,80}$/.test(String(value ?? '')) ? String(value) : '');
const art = (mid) =>
    mid ? 'https://y.gtimg.cn/music/photo_new/T002R500x500M000' + encodeURIComponent(mid) + '.jpg' : '';
export function qqItem(raw, kind = 'song') {
    const d = raw.songInfo || raw.musicData || raw.data || raw;
    const album = d.album || {};
    const singers = array(d.singer || d.singers);
    // 保持原有判断顺序，仅计算当前需要的分支结果。
    // 按 QQ 条目类别读取原始标识，不混用 mid 与目录 ID。
    const selectItemIdentifier = () => {
        if (kind === 'song') {
            return d.mid ?? d.songmid;
        } else if (kind === 'album') {
            return d.mid ?? d.album_mid ?? d.albumMID ?? d.albumMid ?? d.albummid;
        } else if (kind === 'artist') {
            return d.mid ?? d.singermid;
        } else {
            return d.tid ?? d.dissid ?? d.disstid ?? d.topId ?? d.id;
        }
    };
    const id = identifier(selectItemIdentifier());
    let title;
    if (kind === 'song') {
        title = d.name ?? d.title ?? d.songname;
    } else if (kind === 'album') {
        title = d.name ?? d.album_name ?? d.albumname ?? d.albumName;
    } else if (kind === 'artist') {
        title = d.name ?? d.singername;
    } else {
        title = d.dirName ?? d.name ?? d.dissname ?? d.topTitle ?? d.title;
    }
    if (!id || typeof title !== 'string') {
        return null;
    }
    const albumID = identifier(album.mid ?? d.albummid ?? d.album_mid);
    const creator = d.creator || {};
    return {
        provider: 'qq',
        kind,
        id,
        key: 'qq:' + kind + ':' + id,
        title,
        artist:
            kind === 'playlist'
                ? String(creator.name ?? d.nickname ?? '')
                : singers
                      .map((v) => v.name)
                      .filter(Boolean)
                      .join(' / ') ||
                  d.singerName ||
                  '',
        artists: singers
            .map((v) => ({
                id: identifier(v.mid ?? v.singermid),
                name: v.name,
            }))
            .filter((v) => v.id && v.name),
        albumID,
        album: album.name ?? d.albumname ?? '',
        mediaId: identifier(d.file?.media_mid ?? d.media_mid ?? d.strMediaMid),
        cover:
            d.albumPicUrl || d.cover || d.picUrl || d.pic || d.logo || art(kind === 'album' ? id : albumID),
        creatorID: String(creator.uin ?? d.uin ?? ''),
        owned: !!d.owned,
        dirId: String(d.dirId ?? d.dirid ?? ''),
        description: d.desc ?? d.description ?? '',
        wiki: '',
        date: d.time_public ?? d.publicTime ?? d.publishDate ?? '',
        duration: Number(d.interval ?? d.duration ?? 0) * 1000,
        trackCount: Number(d.songNum ?? d.songnum ?? d.total_song_num ?? d.totalNum ?? d.total ?? 0),
        chart: d.chart === true,
        period: d.period ?? '',
    };
}

export class QQAPI {
    constructor(base) {
        this.base = base;
        base.provider = 'qq';
        this.host = base.host;
        this.provider = 'qq';
        this.songCache = new Map();
    }

    request(route, values = {}, allow = [200], valid = () => true) {
        return this.base.request('/qq' + route, values, allow, valid);
    }

    delay(ms) {
        return this.base.delay(ms);
    }

    rows(raw, kind = 'song') {
        return array(raw)
            .map((d) => qqItem(d, kind))
            .filter(Boolean)
            .map((v) => {
                if (kind === 'song') {
                    const full = this.songCache.get(v.id);
                    if (full?.playbackReady) {
                        return full;
                    }
                    this.songCache.set(v.id, v);
                }
                return v;
            });
    }

    response(body) {
        const r = body.response ?? body;
        if (r.code !== undefined && ![0, 200].includes(r.code)) {
            throw new Error('QQ 音乐返回 ' + r.code);
        }
        return r;
    }

    module(r, key) {
        const m = r[key] || {};
        if (m.code !== undefined && ![0, 200].includes(m.code)) {
            throw new Error('QQ 音乐返回 ' + m.code);
        }
        return m.data || {};
    }

    async search(text, kind, offset = 0, valid = () => true) {
        if (kind !== 'song') {
            throw new Error('QQ 当前支持歌曲搜索，可从歌曲浏览专辑和歌手');
        }
        const r = this.response(
            await this.request(
                '/getSearchByKey',
                {
                    key: text,
                    limit: 30,
                    page: Math.floor(offset / 30) + 1,
                },
                [200],
                valid,
            ),
        );
        const data = r.data?.song || {};
        const raw = array(data.list);
        const total = Number(data.totalnum ?? 0); // 上游旧搜索可能返回空列表；只补首页相关歌曲，并读取完整媒体标识。
        if (!raw.length && offset === 0) {
            const hints = this.response(
                await this.request(
                    '/getSmartbox',
                    {
                        key: text,
                    },
                    [200],
                    valid,
                ),
            );
            const ids = [
                ...new Set(
                    array(hints.data?.song?.itemlist)
                        .map((v) => identifier(v.mid))
                        .filter(Boolean),
                ),
            ].slice(0, 10);
            if (ids.length) {
                const items = await this.songs(ids, valid);
                return {
                    items,
                    total: items.length,
                    rawCount: items.length,
                    more: false,
                    notice: 'QQ 搜索暂不可用，显示相关歌曲',
                };
            }
        }
        return {
            items: this.rows(raw),
            total,
            rawCount: raw.length,
            more: offset + raw.length < total && raw.length > 0,
        };
    }

    async songs(ids, valid = () => true, forPlayback = false) {
        const result = [];
        for (const id of ids) {
            if (!valid()) {
                throw new Error('Stale operation');
            }
            const cached = this.songCache.get(id);
            if (cached && (!forPlayback || cached.playbackReady)) {
                result.push(cached);
                continue;
            }
            const r = this.response(
                await this.request(
                    '/getSongInfo',
                    {
                        songmid: id,
                    },
                    [200],
                    valid,
                ),
            );
            const data = this.module(r, 'songinfo');
            const song = qqItem(data.track_info || data);
            if (song) {
                song.playbackReady = true;
                this.songCache.set(song.id, song);
                result.push(song);
            }
        }
        return result;
    }

    async detail(value, valid = () => true) {
        if (value.kind === 'song') {
            const song = (await this.songs([value.id], valid))[0];
            if (!song) {
                throw new Error('歌曲暂不可读取');
            }
            return [song, [], []];
        }
        if (value.kind === 'artist') {
            const r = this.response(
                await this.request(
                    '/getSingerHotsong',
                    {
                        singermid: value.id,
                        limit: 100,
                        page: 1,
                    },
                    [200],
                    valid,
                ),
            );
            const d = this.module(r, 'singer');
            return [value, this.rows(d.songlist), []];
        }
        if (value.chart) {
            const songs = [];
            let offset = 0;
            let total = 0;
            do {
                const r = this.response(
                    await this.request(
                        '/getRanks',
                        {
                            topId: value.id,
                            limit: 100,
                            page: offset,
                            period: value.period,
                        },
                        [200],
                        valid,
                    ),
                );
                const d = this.module(r, 'req_1');
                const next = this.rows(d.songInfoList || d.songlist);
                songs.push(...next);
                total = Number(d.data?.totalNum ?? d.totalNum ?? d.total_song_num ?? next.length);
                offset += next.length;
                if (!next.length) {
                    break;
                }
            } while (offset < total);
            return [
                {
                    ...value,
                    trackCount: total,
                },
                songs,
                [],
            ];
        }
        if (value.kind === 'album') {
            const r = this.response(
                await this.request(
                    '/getAlbumInfo',
                    {
                        albummid: value.id,
                    },
                    [200],
                    valid,
                ),
            );
            const d = r.data || {};
            return [
                {
                    ...value,
                    description: d.desc || value.description,
                    date: d.aDate || value.date,
                },
                this.rows(d.list || d.songlist),
                [],
            ];
        }
        if (value.owned) {
            const songs = [];
            let offset = 0;
            let total = 0;
            do {
                const d = await this.request(
                    '/user/playlist-detail',
                    {
                        tid: value.id,
                        offset,
                        limit: 100,
                    },
                    [200],
                    valid,
                );
                const next = this.rows(d.songs);
                songs.push(...next);
                total = Number(d.total ?? songs.length);
                offset += next.length;
                if (!d.more || !next.length) {
                    break;
                }
            } while (offset < total);
            return [
                {
                    ...value,
                    trackCount: total,
                },
                songs,
                [],
            ];
        }
        const r = this.response(
            await this.request(
                '/getSongListDetail',
                {
                    disstid: value.id,
                },
                [200],
                valid,
            ),
        );
        const d = array(r.cdlist)[0] || {};
        return [
            {
                ...value,
                description: d.desc || value.description,
                trackCount: Number(d.total_song_num ?? value.trackCount),
            },
            this.rows(d.songlist),
            [],
        ];
    }

    async artistAlbums(id, offset = 0, valid = () => true) {
        const r = this.response(
            await this.request(
                '/getSingerAlbum',
                {
                    singermid: id,
                    limit: 30,
                    page: offset,
                },
                [200],
                valid,
            ),
        );
        const d = this.module(r, 'singer');
        const raw = array(d.albumList);
        return {
            items: this.rows(raw, 'album'),
            rawCount: raw.length,
            more: offset + raw.length < Number(d.total ?? raw.length),
        };
    }

    async wiki() {
        return 'QQ 音乐 / 歌曲资料';
    }

    async account(valid = () => true) {
        const d = await this.request('/user/detail', {}, [200], valid);
        const p = d.profile || {};
        const info = p.info || p;
        const id = identifier(p.str_musicid ?? p.musicid ?? p.uin ?? info.uin);
        if (!id) {
            const failure = new Error('请登录 QQ 音乐');
            failure.authExpired = true;
            throw failure;
        }
        return [id, String(info.nick ?? info.nickname ?? p.nickname ?? p.nick ?? 'QQ 音乐用户')];
    }

    async userPlaylists(uid, valid = () => true) {
        const d = await this.request(
            '/user/playlist',
            {
                uid,
            },
            [200],
            valid,
        );
        const raw = array(d.playlist);
        const items = this.rows(
            raw.map((v) => ({
                ...v,
                owned: typeof v.dirName === 'string' && String(v.uin) === uid,
            })),
            'playlist',
        ).filter((v) => v.dirId !== '201');
        // QQ 自建目录和收藏目录的形状不同，不能仅根据 dirId 判断归属。
        for (const v of items) {
            if (v.owned) {
                v.creatorID = uid;
            } else if (v.creatorID === uid) {
                v.creatorID = '';
            }
        }
        return {
            items,
            total: Number(d.total ?? items.length),
            rawCount: raw.length,
            more: false,
        };
    }

    async likedSongs(offset = 0, valid = () => true) {
        const d = await this.request(
            '/user/liked-songs',
            {
                offset,
                limit: 100,
            },
            [200],
            valid,
        );
        const raw = array(d.songs);
        return {
            items: this.rows(raw),
            total: Number(d.total ?? raw.length),
            rawCount: raw.length,
            more: !!d.more,
        };
    }

    async likedAlbums(offset = 0, valid = () => true) {
        const d = await this.request(
            '/user/albums',
            {
                offset,
                limit: 30,
            },
            [200],
            valid,
        );
        const raw = array(d.albums);
        return {
            items: this.rows(raw, 'album'),
            total: Number(d.total ?? raw.length),
            rawCount: raw.length,
            more: !!d.more,
        };
    }

    async playback(value, quality, alternative, valid) {
        const q =
            {
                standard: '128',
                higher: '128',
                exhigh: '320',
                lossless: 'flac',
                hires: 'flac',
                jymaster: 'flac',
            }[quality] || '320';
        // 列表缓存并不保证含有媒体文件标识；播放前按文档读取完整歌曲详情。
        const song = (await this.songs([value.id], valid, true))[0];
        if (!song) {
            throw new Error('QQ 歌曲资料暂不可读取');
        }
        const request = async (level) =>
            (
                await this.request(
                    '/getMusicPlay',
                    {
                        songmid: song.id,
                        mediaId: song.mediaId || '',
                        quality: level,
                    },
                    [200],
                    valid,
                )
            ).data?.playUrl?.[song.id];
        let track = await request(q);
        if (!track?.url && q !== '128') {
            track = await request('128');
            if (track?.url) {
                return {
                    ...track,
                    qualityFallback: '标准',
                };
            }
        }
        if (!track?.url) {
            throw new Error(
                this.host.authenticated?.()
                    ? 'QQ 已登录，但平台未返回标准音质音源；请确认该歌曲在 QQ 官方客户端能否播放'
                    : 'QQ 当前未登录，请用 QQ 或微信扫码登录后重试',
            );
        }
        return track;
    }

    async discover(tab, offset = 0, category = '全部', valid = () => true) {
        if (tab === 'playlists' || tab === 'charts') {
            const r = this.response(await this.request('/getTopLists', {}, [200], valid));
            const raw = array(r.data?.topList);
            return {
                items: this.rows(
                    raw.map((v) => ({
                        ...v,
                        id: v.id ?? v.topId,
                        title: v.topTitle ?? v.title,
                        chart: true,
                    })),
                    'playlist',
                ),
                more: false,
                rawCount: raw.length,
            };
        }
        if (tab === 'daily' || tab === 'albums') {
            const r = this.response(await this.request('/getRecommend', {}, [200], valid));
            const d = this.module(r, tab === 'daily' ? 'new_song' : 'new_album');
            const raw = array(tab === 'daily' ? d.songlist || d.songList : d.albums || d.albumList);
            return {
                items: this.rows(raw, tab === 'daily' ? 'song' : 'album'),
                more: false,
                rawCount: raw.length,
            };
        }
        if (tab === 'categories') {
            const r = this.response(
                await this.request(
                    '/getSongLists',
                    {
                        categoryId: category === '全部' ? '10000000' : category,
                        limit: 30,
                        page: Math.floor(offset / 30) + 1,
                    },
                    [200],
                    valid,
                ),
            );
            const d = r.data || {};
            const raw = array(d.list);
            return {
                items: this.rows(raw, 'playlist'),
                rawCount: raw.length,
                more: offset + raw.length < Number(d.sum ?? raw.length),
            };
        }
        throw new Error('QQ 暂不支持此类别');
    }

    async categories(valid = () => true) {
        const r = this.response(await this.request('/getSongListCategories', {}, [200], valid));
        return array(r.data?.categories)
            .flatMap((v) => array(v.items))
            .map((v) => ({
                id: String(v.categoryId),
                name: v.categoryName,
            }));
    }
}
