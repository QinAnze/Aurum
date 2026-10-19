// 网易云请求与响应校验；登录协议和 Cookie 持久化仍由 Host 与锁定上游处理。
import { providerName } from './providers.mjs';
import { parse } from './items.mjs';
import { safeLoginDetails } from './failure.mjs';
const parsed = (raw, kind) => (raw || []).map((rawItem) => parse(rawItem, kind)).filter(Boolean);
export class API {
    constructor(host) {
        this.host = host;
        this.provider = 'netease';
    }

    delay(ms) {
        return new Promise((resolve) => this.host.delay(ms, resolve));
    }
    /**
     * 通过 Host 请求元数据并校验响应。
     * 先检查请求是否仍有效，再接受 Cookie，避免旧账号请求污染当前账号。
     */
    request(route, values = {}, allow = [200], valid = () => true) {
        return new Promise((resolve, reject) =>
            this.host.request(route, values, (raw, error) => {
                if (error) {
                    reject(new Error(error));
                    return;
                }
                if (!valid()) {
                    reject(new Error('Stale operation'));
                    return;
                }
                let response;
                try {
                    response = JSON.parse(raw);
                } catch (error) {
                    reject(new Error('元数据格式无效'));
                    return;
                }
                const body = response.body;
                if (!body || typeof body !== 'object') {
                    reject(new Error('元数据格式无效'));
                    return;
                }
                if (body.code !== undefined && !allow.includes(body.code)) {
                    const failure = new Error(
                        providerName(this.provider) +
                            '返回 ' +
                            body.code +
                            '：' +
                            (body.message ?? body.msg ?? '请稍后重试'),
                    );
                    failure.code = body.code;
                    Object.assign(failure, safeLoginDetails(body));
                    reject(failure);
                    return;
                }
                this.host.acceptCookies(
                    JSON.stringify(response.cookies || []),
                    response._epoch,
                    response._credentialKey || '',
                );
                resolve(body);
            }),
        );
    }
    /**
     * 读取可播放音源；缺少 URL 时保留原有错误反馈。
     */
    async playback(value, quality, alternative, valid) {
        const responseBody = await this.request(
            '/song/url/v1',
            {
                id: value.id,
                level: quality,
                unblock: alternative,
            },
            [200],
            valid,
        );
        const track = (responseBody.data || []).find((song) => String(song.id) === value.id);
        if (!track?.url) {
            throw new Error('此歌曲暂无可用音源，请登录或在网易云打开');
        }
        return track;
    }

    async search(text, kind, offset = 0, valid = () => true) {
        const types = {
            song: 1,
            album: 10,
            artist: 100,
            playlist: 1000,
        };
        if (!types[kind]) {
            throw new Error('不支持的搜索类别');
        }
        const responseBody = await this.request(
            '/search',
            {
                keywords: text,
                type: types[kind],
                limit: 30,
                offset,
            },
            [200],
            valid,
        );
        const searchResult = responseBody.result || {};
        // 保持原有判断顺序，仅计算当前需要的分支结果。
        // 按条目类别选择上游搜索字段，保持歌单回退。
        const selectSearchResultField = () => {
            if (kind === 'song') {
                return 'songs';
            } else if (kind === 'album') {
                return 'albums';
            } else if (kind === 'artist') {
                return 'artists';
            } else {
                return 'playlists';
            }
        };
        const raw = searchResult[selectSearchResultField()] || [];
        const total = searchResult[kind + 'Count'] || 0;
        return {
            items: parsed(raw, kind),
            total,
            rawCount: raw.length,
            more: offset + raw.length < total && raw.length > 0,
        };
    }

    async songs(ids, valid = () => true) {
        if (!ids.length) {
            return [];
        }
        return parsed(
            (
                await this.request(
                    '/song/detail',
                    {
                        ids: ids.join(','),
                    },
                    [200],
                    valid,
                )
            ).songs,
            'song',
        );
    }
    /**
     * 按歌曲、歌手、专辑或歌单读取详情，统一返回条目、曲目和完整 ID 列表。
     */
    async detail(value, valid = () => true) {
        if (value.kind === 'song') {
            const song = (await this.songs([value.id], valid))[0];
            if (!song) {
                throw new Error('歌曲已不可读取');
            }
            return [song, [], []];
        }
        if (value.kind === 'artist') {
            const b = await this.request(
                '/artists',
                {
                    id: value.id,
                },
                [200],
                valid,
            );
            return [parse(b.artist || {}, 'artist') || value, parsed(b.hotSongs, 'song'), []];
        }
        const album = value.kind === 'album';
        const responseBody = await this.request(
            album ? '/album' : '/playlist/detail',
            {
                id: value.id,
            },
            [200],
            valid,
        );
        const info = responseBody[album ? 'album' : 'playlist'] || {};
        return [
            parse(info, value.kind) || value,
            parsed(album ? responseBody.songs : info.tracks, 'song'),
            (info.trackIds || []).filter((x) => typeof x.id === 'number').map((x) => String(x.id)),
        ];
    }

    async artistAlbums(id, offset = 0, valid = () => true) {
        const responseBody = await this.request(
            '/artist/album',
            {
                id,
                limit: 30,
                offset,
            },
            [200],
            valid,
        );
        const raw = responseBody.hotAlbums || [];
        return {
            items: parsed(raw, 'album'),
            rawCount: raw.length,
            more: !!responseBody.more && raw.length > 0,
        };
    }

    async wiki(id, valid = () => true) {
        const responseBody = await this.request(
            '/song/wiki/summary',
            {
                id,
            },
            [200],
            valid,
        );
        const basic = ((responseBody.data || {}).blocks || []).find(
            (x) => x.code === 'SONG_PLAY_ABOUT_SONG_BASIC',
        );
        const lines = [];
        for (const creative of basic?.creatives || []) {
            if (
                ![
                    'songTag',
                    'songBizTag',
                    'language',
                    'bpm',
                    'songAward',
                    'entertainment',
                    'songAuthor',
                ].includes(creative.creativeType)
            ) {
                continue;
            }
            const title = creative.uiElement?.mainTitle?.title || '';
            const values = (creative.resources || [])
                .map((searchResult) => searchResult.uiElement?.mainTitle?.title)
                .filter((value) => typeof value === 'string');
            if (title && values.length) {
                lines.push(title + '：' + values.join(' / '));
            }
        }
        return lines.length
            ? lines.join('\n') + '\n来源：网易云音乐百科'
            : '暂无歌曲百科。基础歌曲信息仍可查看。';
    }

    async account(valid = () => true) {
        const responseBody = await this.request(
            '/user/account',
            {
                timestamp: Date.now(),
            },
            [200],
            valid,
        );
        if (!responseBody.profile || typeof responseBody.profile.userId !== 'number') {
            const failure = new Error('请登录网易云');
            failure.authExpired = true;
            throw failure;
        }
        return [String(responseBody.profile.userId), responseBody.profile.nickname || '网易云用户'];
    }

    async userPlaylists(uid, valid = () => true) {
        const responseBody = await this.request(
            '/user/playlist',
            {
                uid,
                limit: 2000,
                timestamp: Date.now(),
            },
            [200],
            valid,
        );
        const raw = responseBody.playlist || [];
        return {
            items: parsed(raw, 'playlist'),
            total: 0,
            rawCount: raw.length,
            more: false,
        };
    }

    async likedIDs(uid, valid = () => true) {
        return (
            (
                await this.request(
                    '/likelist',
                    {
                        uid,
                        timestamp: Date.now(),
                    },
                    [200],
                    valid,
                )
            ).ids || []
        )
            .filter((x) => typeof x === 'number')
            .map(String);
    }

    async likedAlbums(offset = 0, valid = () => true) {
        const responseBody = await this.request(
            '/album/sublist',
            {
                limit: 2000,
                timestamp: Date.now(),
            },
            [200],
            valid,
        );
        const raw = responseBody.data || [];
        return {
            items: parsed(raw, 'album'),
            total: responseBody.count ?? offset + raw.length,
            rawCount: raw.length,
            more: false,
        };
    }
}
