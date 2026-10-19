// 用锁定上游的设备仓库跨两个真实进程验证设备身份恢复，不访问实际音乐 API。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-device-state-'));
const devicePath = path.join(temporaryDirectory, 'qq-device.json');
const bridge = path.resolve('output/resources/MusicBridge');
const runtime = path.join(bridge, process.platform === 'win32' ? 'node.exe' : 'node');
const modulePath = path.join(
    bridge,
    'node_modules/@yakult-green-tea/qq-music-api/dist/src/services/auth/deviceContext.js',
);
const source = `
const context = require(process.env.RHINE_TEST_DEVICE_MODULE);
const store = context.createDeviceContextStore(context.createDefaultDeviceContextRepository());
const device = store.get();
store.persist();
const digest = require('node:crypto').createHash('sha256').update(JSON.stringify(device)).digest('hex');
process.stdout.write(digest);
`;
function readDeviceDigest() {
    const result = spawnSync(runtime, ['-e', source], {
        encoding: 'utf8',
        env: {
            ...process.env,
            LOG_LEVEL: 'silent',
            QQ_AUTH_STATE_PATH: devicePath,
            RHINE_TEST_DEVICE_MODULE: modulePath,
        },
    });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
}
try {
    const firstDigest = readDeviceDigest();
    const secondDigest = readDeviceDigest();
    assert.match(firstDigest, /^[a-f0-9]{64}$/);
    assert.equal(firstDigest, secondDigest);
    const record = JSON.parse(fs.readFileSync(devicePath));
    assert.equal(record.version, 1);
    assert.equal(record.device.musickey, undefined);
    assert.equal(record.device.qqmusic_session, undefined);
    console.log('上游设备身份跨进程复用，不在设备配置中写入登录凭据');
} finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}
