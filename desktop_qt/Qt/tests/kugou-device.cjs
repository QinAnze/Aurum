// 使用随包 Node 加载两个版本的上游模块，以本地响应验证版本配置及重启后的固定设备。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const bridge = path.resolve(process.argv[2] || 'output/resources/MusicBridge');
const temporary = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'rhine-kugou-edition-'));
const hook = path.resolve(__dirname, 'fixtures/bridge-http.cjs');
const runtime = path.join(bridge, process.platform === 'win32' ? 'node.exe' : 'node');
async function request(edition) {
    const child = spawn(runtime, ['--require', hook, path.join(bridge, 'worker.cjs')], {
        cwd: bridge,
        env: {
            ...process.env,
            TMPDIR: temporary,
            RHINE_TEST_BRIDGE: bridge,
            RHINE_KUGOU_EDITION: edition,
            RHINE_KUGOU_DEVICE_STATE_PATH: path.join(temporary, 'device.json'),
        },
        stdio: ['pipe', 'pipe', 'pipe'],
    });
    try {
        const result = await new Promise((resolve, reject) => {
            let buffer = '';
            const timer = setTimeout(
                () => reject(new Error('Kugou packaged worker timed out: ' + edition)),
                30000,
            );
            child.on('error', reject);
            child.stdout.on('data', (chunk) => {
                buffer += chunk;
                if (buffer.includes('\n')) {
                    clearTimeout(timer);
                    resolve(JSON.parse(buffer.split('\n')[0]));
                }
            });
            child.stdin.write(JSON.stringify({ id: 'edition', route: '/kugou/login/qr/key' }) + '\n');
        });
        assert.equal(result.body.code, 200);
        assert.equal(result.kugouCredentials.KUGOU_API_PLATFORM, edition);
        return result.kugouCredentials;
    } finally {
        child.stdin.end();
        await new Promise((resolve) => child.once('exit', resolve));
    }
}
(async () => {
    try {
        const standard = await request('standard');
        const lite = await request('lite');
        const restart = await request('lite');
        assert.equal(standard.KUGOU_API_GUID, lite.KUGOU_API_GUID);
        assert.equal(lite.KUGOU_API_GUID, restart.KUGOU_API_GUID);
        assert.equal(lite.KUGOU_API_DEV, restart.KUGOU_API_DEV);
        assert.equal(lite.KUGOU_API_WEBGL, restart.KUGOU_API_WEBGL);
        assert.equal(JSON.parse(fs.readFileSync(path.join(temporary, 'device.json'))).token, undefined);
        console.log('酷狗标准版与概念版二维码 appid、版本配置和三次进程重启固定设备通过');
    } finally {
        fs.rmSync(temporary, { recursive: true, force: true });
    }
})().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
