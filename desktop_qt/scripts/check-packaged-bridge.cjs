// 发布包内执行真实协议模块，只替换上游 HTTP 响应；不访问实际音乐 API。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const bridge = path.resolve(process.argv[2]);
const temp = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'rhine-package-check-'));
const hook = path.resolve(__dirname, '../Qt/tests/fixtures/bridge-http.cjs');
const deviceContext = require(
    path.join(bridge, 'node_modules/@yakult-green-tea/qq-music-api/dist/src/services/auth/deviceContext.js'),
);
async function main() {
    let child;
    try {
        child = spawn(
            path.join(bridge, process.platform === 'win32' ? 'node.exe' : 'node'),
            ['--require', hook, path.join(bridge, 'worker.cjs')],
            {
                cwd: bridge,
                env: {
                    ...process.env,
                    TMPDIR: temp,
                    TEMP: temp,
                    LANG: 'en_US.UTF-8',
                    RHINE_TEST_BRIDGE: bridge,
                    RHINE_QQ_DEVICE_STATE_PATH: path.join(temp, 'qq-device.json'),
                    RHINE_KUGOU_DEVICE_STATE_PATH: path.join(temp, 'kugou-device.json'),
                },
                stdio: ['pipe', 'pipe', 'pipe'],
            },
        );
        let errors = '';
        let buffer = '';
        const pending = new Map();
        child.stderr.on('data', (d) => (errors += d));
        child.stdout.on('data', (data) => {
            buffer += data;
            let end;
            while ((end = buffer.indexOf('\n')) >= 0) {
                const line = buffer.slice(0, end);
                buffer = buffer.slice(end + 1);
                let result;
                try {
                    result = JSON.parse(line);
                } catch (error) {
                    for (const p of pending.values()) {
                        p.reject(error);
                    }
                    return;
                }
                const p = pending.get(result.id);
                if (p) {
                    clearTimeout(p.timer);
                    pending.delete(result.id);
                    p.resolve(result);
                }
            }
        });
        function request(id, route, params = {}, cookies = {}) {
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => {
                    pending.delete(id);
                    reject(new Error('IPC timeout (' + id + '): ' + errors));
                }, 15000);
                pending.set(id, {
                    resolve,
                    reject,
                    timer,
                });
                child.stdin.write(
                    JSON.stringify({
                        id,
                        route,
                        params,
                        cookies,
                    }) + '\n',
                );
            });
        }
        const search = await request('search', '/search', {
            keywords: 'fixture',
            type: 1,
        });
        assert.equal(search.body.code, 200);
        const nativeSearch = await request('native-search', '/native/netease/search', {
            args: ['fixture', 'song', 0],
        });
        assert.equal(nativeSearch.body.code, 200);
        assert.deepEqual(nativeSearch.body.value.items, []);
        assert.equal(nativeSearch.body.value.total, 0);
        const audio = await request('audio', '/song/url/v1', {
            id: '1',
            level: 'lossless',
            unblock: false,
        });
        assert.equal(audio.body.code, 200);
        assert(audio.body.data[0].url);
        const standard = await request('standard', '/song/url/v1', {
            id: '1',
            level: 'standard',
            unblock: false,
        });
        assert.equal(standard.body.code, 200);
        assert(standard.body.data[0].url);
        assert.equal(audio.body.data[0].requestedBr, 999000);
        assert.equal(standard.body.data[0].requestedBr, 128000);
        const authenticated = await request(
            'authenticated',
            '/song/url/v1',
            {
                id: '1',
                level: 'exhigh',
                unblock: false,
            },
            {
                MUSIC_U: 'fixture-account',
            },
        );
        assert.equal(authenticated.body.data[0].authenticated, true);
        assert.equal(authenticated.body.data[0].requestedBr, 320000);
        const denied = await request('denied', '/song/url/v1', {
            id: '2',
            level: 'standard',
            unblock: false,
        });
        assert.equal(denied.body.code, 403);
        const savedDevice = deviceContext.createAndroidDevice();
        const qq = await request(
            'qq',
            '/qq/getSearchByKey',
            { key: 'fixture' },
            {
                qqmusic_session: 'fixture-session',
                __qqSessions: [
                    null,
                    {
                        token: 'fixture-session',
                        credential: { musicid: '42', musickey: 'fixture-key', loginType: 6 },
                        device: savedDevice,
                        expiresAt: Date.now() + 3600000,
                    },
                ],
            },
        );
        assert.equal(qq.body.response.data.song.list[0].mid, 'fixtureMID');
        const deviceRecord = JSON.parse(fs.readFileSync(path.join(temp, 'qq-device.json')));
        assert.deepEqual(deviceRecord.device, savedDevice);
        assert.equal(deviceRecord.device.musickey, undefined);
        const charts = await request('charts', '/qq/getTopLists');
        assert.equal(charts.body.response.data.topList[0].id, 4);
        const chart = await request('chart', '/qq/getRanks', {
            topId: 4,
            period: charts.body.response.data.topList[0].period,
            limit: 100,
            page: 0,
        });
        assert.equal(chart.body.response.req_1.data.songInfoList[0].mid, 'fixtureMID');
        const kugouKey = await request('kugou-key', '/kugou/login/qr/key');
        assert.equal(kugouKey.body.data.unikey, 'fixture-kugou-qr');
        const kugouImage = await request('kugou-image', '/kugou/login/qr/create', {
            key: kugouKey.body.data.unikey,
            qrimg: true,
            timestamp: Date.now(),
        });
        assert.match(kugouImage.body.data.qrimg, /^data:image\/png;base64,/);
        const kugouLogin = await request('kugou-login', '/kugou/login/qr/check', {
            key: kugouKey.body.data.unikey,
        });
        assert.equal(kugouLogin.body.code, 803);
        assert.equal(kugouLogin.kugouCredentials.token, 'fixture-kugou-token');
        assert.equal(JSON.stringify(kugouLogin.body).includes('fixture-kugou-token'), false);
        const kugouSearch = await request(
            'kugou-search',
            '/kugou/search',
            { keywords: '本地歌曲', type: 'song' },
            {
                __kugou: { ...kugouLogin.kugouCredentials, dfid: 'fixture-dfid' },
            },
        );
        assert.equal(kugouSearch.body.data.lists[0].SongName, '本地歌曲');
        const kugouDevice = JSON.parse(fs.readFileSync(path.join(temp, 'kugou-device.json')));
        assert.equal(kugouDevice.KUGOU_API_GUID, kugouLogin.kugouCredentials.KUGOU_API_GUID);
        assert.equal(kugouDevice.token, undefined);
        // 发布包通过真实锁定协议和解码器读取三种形态，再交付相同毫秒模型。
        const neteaseLyrics = await request('lyrics-netease', '/lyric/new', { id: '1' });
        const qqLyrics = await request('lyrics-qq', '/qq/getLyric', { songmid: 'fixtureMID' });
        const lyricSearch = await request('lyrics-kugou-search', '/kugou/search/lyric', {
            hash: 'A'.repeat(32),
        });
        assert.equal(lyricSearch.body.candidates[0].id, '42');
        const kugouLyrics = await request('lyrics-kugou', '/kugou/lyric', {
            id: '42',
            accesskey: 'fixture-key',
            fmt: 'krc',
            decode: true,
        });
        for (const response of [neteaseLyrics, qqLyrics, kugouLyrics]) {
            assert.equal(response.body.code, 200);
            assert.deepEqual(
                response.body.document.lines.map((line) => line.startMs),
                [1000, 3000],
            );
            assert.equal(response.body.document.lines[0].text, '本地歌词');
        }
        assert.equal(kugouLyrics.body.document.timing, 'word');
        assert.equal(kugouLyrics.body.document.lines[0].words[1].startMs, 1500);
        assert(fs.existsSync(path.join(bridge, 'LyricsKit-LICENSE')));
        // 验证原服务失败诊断
        const failedLogin = await request('failed-login', '/qq/login/qr/key', { channel: 'qq' });
        assert.equal(failedLogin.body.code, 502);
        assert.equal(failedLogin.body.failureStage, 'device-bootstrap');
        assert(failedLogin.body.retryAfterMs > 0);
        const backedOff = await request('backed-off-login', '/qq/login/qr/key', { channel: 'qq' });
        assert.equal(backedOff.body.code, 429);
        assert.equal(backedOff.body.failureReason, 'local-backoff');
        assert.equal(backedOff.body.lastFailure.failureStage, 'device-bootstrap');
        for (const route of [
            '/cloud',
            '/mv/url',
            '/personal_fm',
            '/qq/getComments',
            '/kugou/user/cloud',
            '/kugou/song/url/new',
        ]) {
            const rejected = await request(route, route);
            assert.equal(rejected.body.code, 503);
        }
        child.stdin.end();
        const exit = await new Promise((resolve) => {
            child.once('exit', (code, signal) => resolve({ code, signal }));
        });
        assert.equal(exit.code, 0, 'packaged bridge must finish cleanly after stdin closes');
        assert.equal(exit.signal, null);
        assert.equal(errors, '');
        console.log(
            'Packaged NetEase Enhanced and QQ IPC, real dependency loading, local responses and core route allowlists passed',
        );
    } finally {
        if (child && child.exitCode === null) {
            child.kill();
        }
        fs.rmSync(temp, {
            recursive: true,
            force: true,
        });
    }
}
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
