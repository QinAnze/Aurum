// 发布包测试使用本地 HTTP 响应，保持真实上游协议模块参与执行。
const path = require('node:path');
const bridge = process.env.RHINE_TEST_BRIDGE;
const axios = require(
    require.resolve('axios', {
        paths: [bridge],
    }),
);
const upstreamCrypto = require(
    path.join(bridge, 'node_modules/@neteasecloudmusicapienhanced/api/util/crypto'),
);
axios.defaults.adapter = async (settings) => {
    const destination = (settings.baseURL || '') + settings.url;
    if (/\.kugou\.com/.test(destination)) {
        if (destination.endsWith('/v1/search')) {
            return {
                status: 200,
                data: { status: 200, candidates: [{ id: '42', accesskey: 'fixture-key' }] },
                headers: {},
                config: settings,
            };
        }
        if (destination.endsWith('/download')) {
            const content = '[1000,1000]<0,500,0>本地<500,500,0>歌词\n[3000,1000]<0,1000,0>第二句';
            const bytes = require('node:zlib').deflateSync(Buffer.from(content));
            const key = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105];
            for (let i = 0; i < bytes.length; i++) {
                bytes[i] ^= key[i % key.length];
            }
            return {
                status: 200,
                data: {
                    status: 200,
                    contenttype: 0,
                    content: Buffer.concat([Buffer.from('krc1'), bytes]).toString('base64'),
                },
                headers: {},
                config: settings,
            };
        }
        // 保留酷狗原包的签名和 Cookie 注入，只提供本地 HTTP 响应。
        if (!settings.params?.mid || !settings.params?.signature) {
            throw new Error('Kugou upstream device or signature missing');
        }
        let data = { status: 1, data: { info: [{ rankid: 1, rankname: '本地榜单' }] } };
        if (destination.endsWith('/v2/qrcode')) {
            const config = require(path.join(bridge, 'node_modules/kugoumusicapi/util/config.json'));
            const appid = process.env.RHINE_KUGOU_EDITION === 'lite' ? config.liteAppid : config.appid;
            if (!settings.params.qrcode_txt.includes('appid=' + appid + '&')) {
                throw new Error('Kugou QR used the wrong edition appid');
            }
            data = { status: 1, data: { qrcode: 'fixture-kugou-qr' } };
        } else if (destination.endsWith('/v2/get_userinfo_qrcode')) {
            data = { status: 1, data: { status: 4, token: 'fixture-kugou-token', userid: 42 } };
        } else if (destination.endsWith('/v2/search/song')) {
            if (settings.params.token !== 'fixture-kugou-token' || settings.params.dfid !== 'fixture-dfid') {
                throw new Error('Kugou credentials or registered device missing');
            }
            data = {
                status: 1,
                data: { lists: [{ FileHash: 'A'.repeat(32), SongName: '本地歌曲' }], total: 1 },
            };
        }
        return { status: 200, data, headers: {}, config: settings };
    }
    if (!/music\.163\.com|y\.qq\.com/.test(destination)) {
        throw new Error('Unexpected upstream');
    }
    const qq = destination.includes('qq.com');
    if (qq && process.env.QQ_AUTH_STATE_PATH !== process.env.RHINE_QQ_DEVICE_STATE_PATH) {
        throw new Error('QQ bridge discarded persistent device path');
    }
    let data = qq
        ? {
              code: 0,
              data: {
                  song: {
                      list: [
                          {
                              mid: 'fixtureMID',
                              name: 'QQ fixture',
                              singer: [],
                              album: {
                                  mid: 'albumMID',
                              },
                          },
                      ],
                      totalnum: 1,
                  },
                  topList: [
                      {
                          id: 4,
                          topTitle: 'Fixture chart',
                      },
                  ],
              },
          }
        : {
              code: 200,
              result: {
                  songs: [],
                  songCount: 0,
              },
              data: [
                  {
                      id: 1,
                      url: 'https://music.126.net/fixture',
                  },
              ],
          };
    if (destination.includes('/song/lyric/v1')) {
        data = { code: 200, lrc: { lyric: '[00:01.00]本地歌词\n[00:03.00]第二句' } };
    }
    if (destination.includes('fcg_query_lyric_new.fcg')) {
        data = { code: 0, lyric: Buffer.from('[00:01.00]本地歌词\n[00:03.00]第二句').toString('base64') };
    }
    if (qq && settings.params?.data) {
        const request = JSON.parse(settings.params.data);
        if (request.req_1?.method === 'GetAll') {
            data = {
                code: 0,
                req_1: {
                    code: 0,
                    data: {
                        group: [
                            {
                                toplist: [
                                    {
                                        topId: 4,
                                        title: 'Fixture chart',
                                        period: '2026-10-12',
                                    },
                                ],
                            },
                        ],
                    },
                },
            };
        } else if (request.req_1?.method === 'GetDetail') {
            if (request.req_1.param.period !== '2026-10-12') {
                throw new Error('Chart period changed');
            }
            data = {
                code: 0,
                req_1: {
                    code: 0,
                    data: {
                        data: {
                            totalNum: 1,
                        },
                        songInfoList: [
                            {
                                mid: 'fixtureMID',
                                name: 'QQ fixture',
                            },
                        ],
                    },
                },
            };
        }
    }
    if (destination.endsWith('/api/bsr/sk/get') || destination.includes('/xeapi/')) {
        throw new Error('Playback must not depend on unavailable xeapi key registration');
    }
    if (
        destination.includes('/song/enhance/player/url') &&
        !destination.split('?')[0].endsWith('/eapi/song/enhance/player/url')
    ) {
        throw new Error('Expected documented song_url fallback with upstream default protocol');
    }
    if (destination.split('?')[0].endsWith('/eapi/song/enhance/player/url')) {
        const payload = upstreamCrypto.eapiReqDecrypt(new URLSearchParams(settings.data).get('params')).data;
        data.data[0].requestedBr = payload.br;
        data.data[0].authenticated = payload.header.MUSIC_U === 'fixture-account';
        if (JSON.parse(payload.ids)[0] === '2') {
            data = {
                code: 403,
                message: 'fixture permission denied',
            };
        }
    }
    return {
        status: 200,
        data,
        headers: {},
        config: settings,
    };
};
