const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
process.chdir(path.resolve(__dirname, '..'));
const mac = process.platform === 'darwin';
const python = process.env.PYTHON || (mac ? 'python3' : 'python');
const app = mac ? 'output/RHINE MUSIC DATABASE.app' : 'output/windows/RHINE MUSIC DATABASE';
if (!fs.existsSync(app)) {
    throw Error('Run npm run build first');
}

/** 发布步骤失败时抛出错误，使临时目录始终能够清理。 */
function run(cmd, args) {
    const result = spawnSync(cmd, args, {
        stdio: 'inherit',
    });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        throw new Error(`${cmd} exited with ${result.status}`);
    }
}
run(python, ['scripts/audit-qt.py', app]);
const archive = path.resolve(`output/RhineMusicDatabase-${mac ? 'macOS' : 'Windows'}-${Date.now()}.zip`);
if (mac) {
    run('codesign', ['--verify', '--deep', '--strict', app]);
    run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, archive]);
} else {
    // 只排除应用根目录的个人数据；SDK 内同名的数据资源仍需原样保留。
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'rhine-release-'));
    const cleanApp = path.join(temporary, path.basename(app));
    try {
        fs.cpSync(app, cleanApp, {
            recursive: true,
            filter: (source) => path.relative(app, source).split(path.sep)[0] !== 'data',
        });
        run(python, ['-m', 'zipfile', '-c', archive, cleanApp]);
    } finally {
        fs.rmSync(temporary, { recursive: true, force: true });
    }
}
console.log(archive);
