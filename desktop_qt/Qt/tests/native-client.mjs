import assert from 'node:assert/strict';
import { dispatch } from '../../MusicBridge/client/dispatch.mjs';

const message = (provider, operation, args, cookies = {}) => ({
    route: '/native/' + provider + '/' + operation,
    params: { args },
    cookies,
});

const netease = await dispatch(message('netease', 'search', ['本地', 'song', 0]), async (request) => {
    assert.equal(request.route, '/search');
    assert.equal(request.params.type, 1);
    return {
        body: {
            code: 200,
            result: { songCount: 1, songs: [{ id: 42, name: '本地歌曲', ar: [{ name: '测试' }] }] },
        },
        cookies: ['MUSIC_U=fixture-native; Path=/'],
    };
});
assert.equal(netease.body.value.items[0].id, '42');
assert.equal(netease.body.value.items[0].artist, '测试');
assert.equal(netease.body.value.total, 1);
assert.deepEqual(netease.cookies, ['MUSIC_U=fixture-native; Path=/']);

const sessions = [{ token: 'private-fixture', credential: { musickey: 'private-key' } }];
const qq = await dispatch(message('qq', 'request', ['/user/detail', {}]), async (request) => {
    assert.equal(request.route, '/qq/user/detail');
    return {
        body: { code: 200, profile: { musicid: '42', nick: '测试账号' } },
        qqSessions: sessions,
        cookies: [],
    };
});
assert.equal(qq.body.value.profile.musicid, '42');
assert.deepEqual(qq.qqSessions, sessions);
assert.equal(JSON.stringify(qq.body).includes('private-fixture'), false);

let kugouRequests = 0;
const kugou = await dispatch(message('kugou', 'search', ['本地', 'song', 0]), async () => {
    kugouRequests++;
    return {};
});
assert.equal(kugou.body.code, 503);
assert.match(kugou.body.message, /需要登录/);
assert.equal(kugouRequests, 0);

// 原生 Host 交付当前版本的扁平凭据；登录后搜索必须实际到达 SDK。
const authenticatedKugou = await dispatch(
    message('kugou', 'search', ['本地', 'song', 0], { __kugou: { token: 'fixture-token' } }),
    async (request) => {
        assert.equal(request.route, '/kugou/search');
        assert.equal(request.cookies.__kugou.token, 'fixture-token');
        return { body: { code: 200, data: { lists: [], total: 0 } } };
    },
);
assert.equal(authenticatedKugou.body.code, 200);
assert.equal(authenticatedKugou.body.value.total, 0);

const failure = await dispatch(message('qq', 'request', ['/login/qr/check', {}]), async () => {
    throw { body: { code: 429, failureReason: 'local-backoff', retryAfterMs: 120000, rawToken: 'secret' } };
});
assert.equal(failure.body.code, 429);
assert.equal(failure.body.retryAfterMs, 120000);
assert.equal(JSON.stringify(failure).includes('secret'), false);

const parallel = await Promise.all(
    ['A', 'B'].map((token) =>
        dispatch(message('netease', 'search', [token, 'song', 0], { MUSIC_U: token }), async (request) => {
            await new Promise((resolve) => setTimeout(resolve, token === 'A' ? 10 : 0));
            assert.equal(request.cookies.MUSIC_U, token);
            return {
                body: {
                    code: 200,
                    result: { songCount: 1, songs: [{ id: token === 'A' ? 1 : 2, name: token }] },
                },
            };
        }),
    ),
);
assert.deepEqual(
    parallel.map((result) => result.body.value.items[0].title),
    ['A', 'B'],
);
const unsupported = await dispatch(message('netease', 'constructor', []), async () => {
    throw new Error('Unsupported operations must not reach the SDK');
});
assert.equal(unsupported.body.code, 400);
console.log('Native SDK client normalization, private credentials, errors and concurrent contexts passed');
