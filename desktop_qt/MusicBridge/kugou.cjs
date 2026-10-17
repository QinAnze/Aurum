// 酷狗标准版协议由锁定上游原包执行；此层只管理设备、私有凭据和响应模型。
const fs = require('node:fs');
const path = require('node:path');
const ROUTES = Object.freeze([
    '/login/qr/key',
    '/login/qr/create',
    '/login/qr/check',
    '/login/token',
    '/user/detail',
    '/user/playlist',
    '/search',
    '/search/suggest',
    '/privilege/lite',
    '/song/url',
    '/register/dev',
    '/playlist/detail',
    '/playlist/track/all',
    '/playlist/track/all/new',
    '/top/playlist',
    '/playlist/tags',
    '/rank/list',
    '/rank/audio',
    '/rank/info',
    '/everyday/recommend',
    '/top/album',
    '/album',
    '/album/detail',
    '/album/songs',
    '/artist/detail',
    '/artist/audios',
    '/artist/albums',
    '/search/lyric',
    '/lyric',
]);
const SECRET_KEYS = new Set([
    'token',
    'vip_token',
    'secu_params',
    't1',
    't2',
    't3',
    'cookie',
    'dfid',
    'ssaCode',
    'sid',
    'edt',
]);
function publicBody(value) {
    if (Array.isArray(value)) {
        return value.map(publicBody);
    }
    if (value && typeof value === 'object') {
        return Object.fromEntries(
            Object.entries(value)
                .filter(([key]) => !SECRET_KEYS.has(key))
                .map(([key, entry]) => [key, publicBody(entry)]),
        );
    }
    return value;
}
/**
 * 使用上游的设备生成函数保存固定设备身份；账号 Cookie 只在父子进程私有管道传递。
 * 测试可以注入原接口响应，不需要访问真实账号。
 */
function createBridge(api, device) {
    async function dispatch(message) {
        const route = String(message.route || '').replace(/^\/kugou/, '');
        if (!ROUTES.includes(route)) {
            throw new Error('Unsupported Kugou route');
        }
        const cookie = { ...device, ...(message.cookies?.__kugou || {}) };
        const call = async (endpoint, params = {}) => {
            let result;
            try {
                result = await api[endpoint.slice(1).replaceAll('/', '_')]({ ...params, cookie });
            } catch (error) {
                // 上游网络异常可能包含请求配置，禁止把原始异常或签名参数发给脚本。
                const code = Number(error.body?.error_code || 0);
                const failure = new Error('酷狗请求失败');
                failure.body = {
                    code: 502,
                    message: '酷狗请求失败' + (code ? '（' + code + '）' : '，请稍后重试'),
                };
                throw failure;
            }
            for (const line of result.cookie || []) {
                const match = /^([^=;]+)=([^;]*)/.exec(line);
                if (match && !['undefined', 'null'].includes(match[2])) {
                    cookie[match[1]] = match[2];
                }
            }
            return result.body;
        };
        if (['/song/url', '/search', '/user/detail'].includes(route) && !cookie.dfid) {
            const registration = await call('/register/dev');
            if (registration?.status !== 1 || !cookie.dfid) {
                return { body: { code: 503, message: '酷狗设备注册失败，请稍后重试' } };
            }
        }
        const params = { ...(message.params || {}) };
        // Cookie、设备和权限由私有层确定，不接受脚本传入的身份覆盖。
        for (const key of ['cookie', 'token', 'userid', 'dfid', 'platform']) {
            delete params[key];
        }
        if (route === '/user/detail' && cookie.token && cookie.userid) {
            await call('/login/token');
        }
        const raw = await call(route, params);
        let body =
            route === '/lyric'
                ? require('./lyrics-format.cjs').normalizeLyrics('kugou', raw, params)
                : publicBody(raw);
        if (route === '/login/qr/key') {
            body = { code: 200, data: { unikey: raw?.data?.qrcode } };
        } else if (route === '/login/qr/create') {
            body = { code: 200, data: { qrimg: raw?.data?.base64 } };
        } else if (route === '/login/qr/check') {
            const codes = { 0: 800, 1: 801, 2: 802, 4: 803 };
            const code = codes[raw?.data?.status];
            const hasCredential = !!cookie.token && Number(cookie.userid) > 0;
            body = { code: code === 803 && !hasCredential ? 503 : (code ?? 503) };
        } else {
            const failed = raw?.status === 0 || (raw?.error_code && Number(raw.error_code) !== 0);
            body = { ...body, code: failed ? 502 : 200 };
            if (failed) {
                body.message = '酷狗接口返回错误 ' + Number(raw.error_code || 0) + '，请检查登录或稍后重试';
            }
            if (route === '/user/detail' && !failed) {
                body.profile = {
                    id: String(cookie.userid || ''),
                    nickname: String(raw?.data?.nickname || raw?.data?.nick_name || '酷狗音乐用户'),
                };
            }
        }
        return { body, cookies: [], kugouCredentials: cookie };
    }
    return { dispatch };
}
let bridge;
function initialize() {
    // 上游在模块加载时选择 appid 与登录配置，必须在 require 前确定版本。
    if (process.env.RHINE_KUGOU_EDITION === 'lite') {
        process.env.platform = 'lite';
    } else {
        delete process.env.platform;
    }
    const root = path.dirname(require.resolve('kugoumusicapi/package.json'));
    const util = require(path.join(root, 'util/util'));
    const { cryptoMd5 } = require(path.join(root, 'util/crypto'));
    const location = process.env.RHINE_KUGOU_DEVICE_STATE_PATH;
    let device;
    if (location && fs.existsSync(location)) {
        device = JSON.parse(fs.readFileSync(location, 'utf8'));
    }
    if (!device?.KUGOU_API_GUID || !device?.KUGOU_API_DEV || !device?.KUGOU_API_WEBGL) {
        const guid = cryptoMd5(util.getGuid());
        device = {
            KUGOU_API_GUID: guid,
            KUGOU_API_MID: util.calculateMid(guid),
            KUGOU_API_DEV: util.randomString(10).toUpperCase(),
            KUGOU_API_MAC: '02:00:00:00:00:00',
            KUGOU_API_WEBGL: util.generateWebGLHash(),
            KUGOU_API_PLATFORM: 'standard',
        };
        if (location) {
            fs.mkdirSync(path.dirname(location), { recursive: true });
            const temporary = location + '.tmp';
            fs.writeFileSync(temporary, JSON.stringify(device), { mode: 0o600 });
            fs.renameSync(temporary, location);
        }
    }
    // 相同固定设备可选择版本，但账号令牌由父进程分开保存。
    device.KUGOU_API_PLATFORM = process.env.platform || 'standard';
    return createBridge(require('kugoumusicapi'), device);
}
module.exports = {
    ROUTES,
    createBridge,
    dispatch(message) {
        bridge ||= initialize();
        return bridge.dispatch(message);
    },
};
