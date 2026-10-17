import assert from 'node:assert/strict';
import { KugouAPI, kugouItem } from '../../MusicBridge/client/kugou.mjs';
import { API } from '../../MusicBridge/client/netease.mjs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { createBridge, ROUTES } = require('../../MusicBridge/kugou.cjs');
const hash = 'A5BF5F27C007E1C1AC5914345B07CD28';
const song = { hash, name: '歌手 - 曲目', album_id: '123', mixsongid: 456, timelen: 180000 };
const calls = [];
const bridge = createBridge(
    {
        register_dev: async ({ cookie }) => {
            assert.equal(cookie.token, 'saved-token');
            calls.push('register');
            return { body: { status: 1 }, cookie: ['dfid=registered-device'] };
        },
        song_url: async ({ cookie, hash: selected }) => {
            calls.push('url');
            assert.equal(cookie.dfid, 'registered-device');
            assert.equal(selected, hash);
            return { body: { status: 1, url: ['https://fs.kugou.com/test.mp3'] }, cookie: [] };
        },
        login_qr_check: async () => ({
            body: { data: { status: 4, token: 'new-token', userid: 42 } },
            cookie: ['token=new-token', 'userid=42'],
        }),
    },
    { KUGOU_API_GUID: 'fixed-device' },
);
let response = await bridge.dispatch({
    route: '/kugou/song/url',
    params: { hash, token: 'malicious-token' },
    cookies: { __kugou: { token: 'saved-token' } },
});
assert.deepEqual(calls, ['register', 'url']);
assert.equal(response.kugouCredentials.dfid, 'registered-device');
response = await bridge.dispatch({
    route: '/kugou/song/url',
    params: { hash },
    cookies: { __kugou: response.kugouCredentials },
});
assert.deepEqual(calls, ['register', 'url', 'url']);
response = await bridge.dispatch({ route: '/kugou/login/qr/check' });
assert.equal(response.body.code, 803);
assert.equal(response.kugouCredentials.token, 'new-token');
assert.equal(JSON.stringify(response.body).includes('new-token'), false);
for (const [status, code] of [
    [0, 800],
    [1, 801],
    [2, 802],
    [3, 503],
]) {
    const api = createBridge(
        { login_qr_check: async () => ({ body: { data: { status } }, cookie: [] }) },
        {},
    );
    assert.equal((await api.dispatch({ route: '/kugou/login/qr/check' })).body.code, code);
}
const failure = createBridge(
    {
        search: async () => {
            throw { body: { msg: { config: { token: 'private-secret' } } } };
        },
    },
    {},
);
await assert.rejects(
    failure.dispatch({ route: '/kugou/search', cookies: { __kugou: { dfid: 'registered' } } }),
    (error) => !JSON.stringify(error.body).includes('private-secret'),
);
assert(ROUTES.includes('/lyric') && ROUTES.includes('/search/lyric'));
for (const route of ['/mv/detail', '/comment/music', '/user/cloud', '/song/url/new']) {
    assert.equal(ROUTES.includes(route), false);
    await assert.rejects(bridge.dispatch({ route: '/kugou' + route }));
}
const requests = [];
let active = 'kugou';
const prefs = new Map([
    ['provider', 'kugou'],
    ['account-id-kugou-standard', '42'],
    ['welcome-name-kugou-standard', '酷狗用户'],
]);
const host = {
    preference: (key) => prefs.get(key),
    setPreference: (key, value) => prefs.set(key, value),
    setProvider: (provider) => {
        active = provider;
    },
    authenticated: () => true,
    hasCredential: () => true,
    delay: (ms, callback) => callback(),
    request(route, params, callback) {
        requests.push([route, params]);
        let body = { code: 200 };
        if (route === '/kugou/user/detail') {
            body.profile = { id: '42', nickname: '酷狗用户' };
        } else if (route === '/user/account') {
            body.account = { id: 7 };
            body.profile = { userId: 7, nickname: '网易云用户' };
        } else if (route === '/qq/user/detail') {
            body.profile = { musicid: '8', nickname: 'QQ 用户' };
        } else if (route === '/kugou/user/playlist') {
            body.data = {
                total: 2,
                info: [
                    { global_collection_id: 'own-list', listid: 1, type: '0', name: '我喜欢', is_def: 0 },
                    { global_collection_id: 'saved-list', listid: 2, type: 1, name: '收藏' },
                ],
            };
        } else if (route === '/kugou/playlist/track/all/new') {
            body.data = { count: 1, songs: [song] };
        } else if (route === '/kugou/song/url') {
            body.url = params.quality === '128' ? ['https://fs.kugou.com/test.mp3'] : [];
        } else if (route === '/kugou/search') {
            body.data = { total: 61, lists: [song] };
        }
        callback(JSON.stringify({ body }), '');
    },
    acceptCookies() {},
    mediaControl() {},
    mediaState: () => ({}),
};
const api = new KugouAPI(new API(host));
const parsed = kugouItem(song);
assert.equal(parsed.id, hash);
assert.equal(parsed.albumAudioID, '456');
assert.equal(parsed.duration, 180000);
const albumTrack = kugouItem({
    base: { audio_name: '曲目', album_id: 123, album_audio_id: 456 },
    audio_info: { hash, duration: 180000 },
});
assert.equal(albumTrack.albumID, '123');
assert.equal(albumTrack.id, hash);
assert.equal(kugouItem({ hash: '456', name: '无效 ID' }), null);
const search = await api.search('曲目', 'song', 30);
assert.equal(search.more, true);
assert.deepEqual(requests.at(-1)[1], { keywords: '曲目', type: 'song', page: 2, pagesize: 30 });
const playlists = await api.userPlaylists('42');
assert.equal(playlists.items[0].creatorID, '42');
assert.equal(playlists.items[1].creatorID, '');
const favorites = await api.likedSongs();
assert.equal(favorites.items[0].id, hash);
assert.equal(requests.at(-1)[1].listid, '1');
assert.equal(requests.at(-1)[1].type, 0);
const track = await api.playback(parsed, 'lossless', false, () => true);
assert.equal(track.qualityFallback, '标准');
assert.equal(requests.at(-1)[1].album_audio_id, '456');
const pages = [];
const paged = new KugouAPI({
    host: {},
    request: async (route, params) => {
        pages.push(params.page);
        const first = Array.from({ length: 100 }, () => ({}));
        first[99] = song;
        return {
            data: { total: 101, songs: params.page === 1 ? first : [{ ...song, hash: 'B'.repeat(32) }] },
        };
    },
});
const [, pagedSongs] = await paged.detail({ kind: 'playlist', id: 'example-list' });
assert.deepEqual(pages, [1, 2]);
assert.equal(pagedSongs.length, 2);

api.playlists.unshift({ title: '音乐资料库', owned: true, isDefault: true, id: 'library', listid: '99' });
await api.likedSongs();
assert.equal(requests.at(-1)[1].listid, '1');
// 使用真实接口的数组形状与字段名，验证歌手、专辑和权益资料的转换。
const detailCalls = [];
const detailsApi = new KugouAPI({
    host: {},
    async request(route, params) {
        detailCalls.push([route, params]);
        if (route === '/kugou/artist/detail') {
            return {
                data: {
                    author_id: 789658,
                    author_name: 'HOYO-MiX',
                    intro: '音乐团队',
                    sizable_avatar: 'http://singerimg.kugou.com/{size}/artist.jpg',
                },
            };
        }
        if (route === '/kugou/artist/audios') {
            assert.equal(params.sort, 'hot');
            return {
                total: 1,
                data: [
                    {
                        hash,
                        audio_name: '曲目',
                        author_name: 'HOYO-MiX',
                        album_id: 123,
                        album_name: '专辑',
                        timelength: 180000,
                    },
                ],
            };
        }
        if (route === '/kugou/artist/albums') {
            return { total: 1, data: [{ album_id: 123, album_name: '专辑' }] };
        }
        if (route === '/kugou/album/detail') {
            return {
                data: [
                    {
                        album_id: 123,
                        album_name: '专辑',
                        intro: '专辑简介',
                        cover: 'album.jpg',
                        sizable_cover: 'http://imge.kugou.com/{size}/album.jpg',
                    },
                ],
            };
        }
        if (route === '/kugou/album/songs') {
            assert.equal(params.pagesize, 30);
            const songs = params.page === 1 ? Array.from({ length: 30 }, () => song) : [song];
            return { data: { total: 31, songs } };
        }
        assert.equal(route, '/kugou/privilege/lite');
        return {
            data: [
                {
                    hash,
                    name: '曲目',
                    album_id: '0',
                    recommend_album_id: '123',
                    albumname: '专辑',
                    info: { duration: 242000 },
                },
            ],
        };
    },
});
const [artist, artistSongs] = await detailsApi.detail({ kind: 'artist', id: '789658' });
assert.equal(artist.description, '音乐团队');
assert.match(artist.cover, /480\/artist.jpg$/);
assert.equal(artistSongs[0].title, '曲目');
assert.equal(artistSongs[0].album, '专辑');
assert.equal(artistSongs[0].duration, 180000);
assert.equal((await detailsApi.artistAlbums('789658')).items[0].id, '123');
const [album, albumSongs] = await detailsApi.detail({ kind: 'album', id: '123' });
assert.equal(album.description, '专辑简介');
assert.match(album.cover, /^https:\/\//);
assert.equal(albumSongs.length, 31);
assert.deepEqual(
    detailCalls.filter(([route]) => route.endsWith('/album/songs')).map(([, params]) => params.page),
    [1, 2],
);
const [hydrated] = await detailsApi.detail({
    ...parsed,
    duration: 0,
    artists: [{ id: '789658', name: 'HOYO-MiX' }],
});
assert.equal(hydrated.albumID, '123');
assert.equal(hydrated.duration, 242000);
assert.equal(hydrated.artists[0].id, '789658');

console.log('酷狗 SDK 标识、设备注册、30 条分页、歌曲详情补齐和音质回退通过');
