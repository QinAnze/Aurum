import assert from 'node:assert/strict';
import { QQAPI, qqItem } from '../../MusicBridge/client/qq.mjs';
import { API } from '../../MusicBridge/client/netease.mjs';
const song = {
    mid: 'songMID',
    name: 'QQ 曲目',
    singer: [
        {
            mid: 'singerMID',
            name: '歌手',
        },
    ],
    album: {
        mid: 'albumMID',
        name: '专辑',
    },
    file: {
        media_mid: 'mediaMID',
    },
    interval: 123,
};
const replies = {
    '/qq/getSearchByKey': {
        response: {
            code: 0,
            data: {
                song: {
                    list: [song],
                    totalnum: 31,
                },
            },
        },
    },
    '/qq/getSongInfo': {
        response: {
            code: 0,
            songinfo: {
                code: 0,
                data: {
                    track_info: song,
                },
            },
        },
    },
    '/qq/user/detail': {
        code: 200,
        profile: {
            str_musicid: '42',
            info: {
                nick: '微信用户',
            },
        },
    },
    '/qq/user/playlist': {
        code: 200,
        playlist: [
            {
                tid: 1,
                dirName: '自己的私密歌单',
                uin: 42,
                dirId: 1,
            },
            {
                tid: 2,
                name: '收藏他人歌单',
                uin: 9,
                dirId: 1,
            },
            {
                tid: 3,
                dirName: '我喜欢',
                uin: 42,
                dirId: 201,
            },
        ],
    },
    '/qq/user/albums': {
        code: 200,
        albums: [
            {
                albumMID: 'albumMID',
                albumName: '专辑',
            },
        ],
        total: 1,
        more: false,
    },
    '/qq/user/liked-songs': {
        code: 200,
        songs: [song],
        total: 1,
        more: false,
    },
    '/qq/getMusicPlay': {
        data: {
            playUrl: {
                songMID: {
                    url: 'https://sjy6.stream.qqmusic.qq.com/fixture.mp3',
                },
            },
        },
    },
    '/qq/getTopLists': {
        response: {
            code: 0,
            data: {
                topList: [
                    {
                        id: 4,
                        topTitle: '榜单',
                        picUrl: 'cover',
                        period: '2026-10-12',
                    },
                ],
            },
        },
    },
    '/qq/getRecommend': {
        response: {
            code: 0,
            new_song: {
                code: 0,
                data: {
                    songlist: [song],
                },
            },
            new_album: {
                code: 0,
                data: {
                    albums: [
                        {
                            mid: 'albumMID',
                            name: '专辑',
                        },
                    ],
                },
            },
        },
    },
    '/qq/login/qr/key': {
        code: 200,
        data: {
            unikey: 'qr-fixture',
        },
    },
    '/qq/login/qr/create': {
        code: 200,
        data: {
            qrimg: 'data:image/png;base64,iVBORw0KGgo=',
        },
    },
    '/qq/login/qr/check': {
        code: 803,
    },
    '/qq/login/qr/cancel': {
        code: 200,
    },
};
let epoch = 0;
let saved = 0;
let provider = 'netease';
const calls = [];
const host = {
    preference: () => '',
    fromLink: () => '',
    cover() {},
    setPreference() {},
    setProvider(v) {
        provider = v;
        epoch++;
    },
    authenticated: () => false,
    acceptCookies() {},
    qrImage: () => 'fixture-qr',
    saveCredential() {
        saved++;
        return '';
    },
    mediaControl() {},
    mediaLoad: () => true,
    delay(ms, done) {
        done();
    },
    request(route, params, done) {
        calls.push({
            route,
            params,
        });
        const body = replies[route];
        assert(body, 'Unexpected route ' + route);
        done(
            JSON.stringify({
                body,
                _epoch: epoch,
            }),
            '',
        );
    },
};
const api = new QQAPI(new API(host));
const parsed = qqItem(song);
assert.equal(parsed.duration, 123000);
assert.equal(parsed.mediaId, 'mediaMID');
assert.equal(parsed.key, 'qq:song:songMID');
assert.equal(
    qqItem(
        {
            albumMid: 'artistAlbumMID',
            albumName: '歌手专辑',
            publishDate: '2026-03-25',
        },
        'album',
    ).id,
    'artistAlbumMID',
);
assert.equal(
    qqItem({
        songmid: 'legacySongMID',
        songname: '专辑曲目',
        strMediaMid: 'legacyMediaMID',
    }).mediaId,
    'legacyMediaMID',
);
const page = await api.search('曲目', 'song', 0);
assert(page.more);
assert.equal(page.items[0].albumID, 'albumMID');
replies['/qq/getSearchByKey'] = {
    response: {
        code: 0,
        data: {
            song: {
                list: [],
                totalnum: 0,
            },
        },
    },
};
replies['/qq/getSmartbox'] = {
    response: {
        code: 0,
        data: {
            song: {
                itemlist: [
                    {
                        mid: 'songMID',
                        name: '仅有提示',
                    },
                ],
            },
        },
    },
};
const fallback = await new QQAPI(new API(host)).search('曲目', 'song');
assert.equal(fallback.items[0].mediaId, 'mediaMID');
assert.equal(fallback.items[0].title, 'QQ 曲目');
assert.equal(fallback.more, false);
assert.match(fallback.notice, /相关歌曲/);
const requestsBeforeMore = calls.length;
assert.equal((await api.search('曲目', 'song', 30)).items.length, 0);
assert.equal(calls.length, requestsBeforeMore + 1);
replies['/qq/getSmartbox'] = {
    response: {
        code: 0,
        data: {
            song: {
                itemlist: [],
            },
        },
    },
};
assert.equal((await api.search('无结果', 'song')).items.length, 0);
assert.equal((await api.account())[0], '42');
const personal = await api.userPlaylists('42');
assert.equal(personal.items.length, 2);
assert(personal.items[0].owned);
assert.equal(personal.items[1].creatorID, '9');
assert.equal((await api.likedAlbums()).items[0].title, '专辑');
assert.equal((await api.likedSongs()).items[0].provider, 'qq');
let offset = [];
host.request = (route, params, done) => {
    calls.push({
        route,
        params,
    });
    if (route === '/qq/user/playlist-detail') {
        offset.push(params.offset);
        done(
            JSON.stringify({
                body: {
                    code: 200,
                    songs: [
                        {
                            ...song,
                            mid: 'page' + params.offset,
                        },
                    ],
                    total: 2,
                    more: params.offset === 0,
                },
            }),
            '',
        );
    } else {
        done(
            JSON.stringify({
                body: replies[route],
            }),
            '',
        );
    }
};
const owned = await api.detail(personal.items[0]);
assert.deepEqual(offset, [0, 1]);
assert.equal(owned[1].length, 2);
const top = await api.discover('playlists');
assert(top.items[0].chart);
assert.equal(calls.at(-1).route, '/qq/getTopLists');
const chartOffsets = [];
const beforeChart = host.request;
host.request = (route, params, done) => {
    if (route === '/qq/getRanks') {
        chartOffsets.push(params.page);
        assert.equal(params.period, '2026-10-12');
        done(
            JSON.stringify({
                body: {
                    response: {
                        code: 0,
                        req_1: {
                            code: 0,
                            data: {
                                data: {
                                    totalNum: 2,
                                },
                                songInfoList: [
                                    {
                                        ...song,
                                        mid: 'chart' + params.page,
                                    },
                                ],
                            },
                        },
                    },
                },
            }),
            '',
        );
    } else {
        beforeChart(route, params, done);
    }
};
assert.equal((await api.detail(top.items[0]))[1].length, 2);
assert.deepEqual(chartOffsets, [0, 1]);
host.request = beforeChart;
await api.discover('daily');
assert.equal(calls.at(-1).route, '/qq/getRecommend');
await api.playback(parsed, 'lossless', false, () => true);
assert.equal(calls.at(-1).params.mediaId, 'mediaMID');
assert.equal(calls.at(-1).params.quality, 'flac');
const completeCalls = calls.filter((v) => v.route === '/qq/getSongInfo').length;
api.rows([
    {
        ...song,
        file: undefined,
    },
]);
assert.equal(api.songCache.get('songMID').mediaId, 'mediaMID');
await api.playback(
    {
        ...parsed,
        mediaId: '',
    },
    'standard',
    false,
    () => true,
);
assert.equal(calls.filter((v) => v.route === '/qq/getSongInfo').length, completeCalls);
assert.equal(calls.at(-1).params.mediaId, 'mediaMID');
const sparse = new QQAPI(new API(host));
sparse.rows([
    {
        ...song,
        file: undefined,
    },
]);
const beforeSparse = calls.length;
await sparse.playback(
    {
        ...parsed,
        mediaId: 'wrongMID',
    },
    'standard',
    false,
    () => true,
);
assert.deepEqual(
    calls.slice(beforeSparse).map((v) => v.route),
    ['/qq/getSongInfo', '/qq/getMusicPlay'],
);
assert.equal(calls.at(-1).params.mediaId, 'mediaMID');
const normalRequest = host.request;
host.request = (route, params, done) => {
    if (route === '/qq/getMusicPlay') {
        calls.push({
            route,
            params,
        });
        done(
            JSON.stringify({
                body: {
                    data: {
                        playUrl: {
                            songMID: {
                                url:
                                    params.quality === '128'
                                        ? 'https://sjy6.stream.qqmusic.qq.com/fixture.mp3'
                                        : '',
                            },
                        },
                    },
                },
            }),
            '',
        );
    } else {
        normalRequest(route, params, done);
    }
};
const downgraded = await sparse.playback(parsed, 'lossless', false, () => true);
assert.equal(downgraded.qualityFallback, '标准');
assert.deepEqual(
    calls.slice(-2).map((v) => v.params.quality),
    ['flac', '128'],
);
host.request = (route, params, done) => {
    if (route === '/qq/getMusicPlay') {
        calls.push({
            route,
            params,
        });
        done(
            JSON.stringify({
                body: {
                    data: {
                        playUrl: {
                            songMID: {
                                url: '',
                            },
                        },
                    },
                },
            }),
            '',
        );
    } else {
        normalRequest(route, params, done);
    }
};
const beforeUnavailable = calls.length;
host.authenticated = () => true;
await assert.rejects(() => sparse.playback(parsed, 'exhigh', false, () => true), /平台未返回标准音质音源/);
assert.equal(calls.length, beforeUnavailable + 2);
const beforeStandard = calls.length;
await assert.rejects(() => sparse.playback(parsed, 'standard', false, () => true), /平台未返回标准音质音源/);
assert.equal(calls.length, beforeStandard + 1);
host.authenticated = () => false;
host.request = (route, params, done) => {
    if (route === '/qq/getMusicPlay') {
        calls.push({
            route,
            params,
        });
        done(
            JSON.stringify({
                body: {
                    code: 401,
                    message: '登录已失效',
                },
            }),
            '',
        );
    } else {
        normalRequest(route, params, done);
    }
};
const beforeExpired = calls.length;
await assert.rejects(() => sparse.playback(parsed, 'lossless', false, () => true), /401/);
assert.equal(calls.length, beforeExpired + 1);
host.request = normalRequest;
console.log('QQ SDK 标识、账号列表、私有歌单分页、推荐映射和音质回退通过');
