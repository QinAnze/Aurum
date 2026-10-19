// 按显式白名单组装干净的应用，禁止整目录复制暂存区。
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const assert = require('node:assert/strict');
const root = path.resolve('output/resources');
const out = path.resolve(process.argv[2]);
const files = [
    'room-pmrem.bin',
    'ao-kernel.bin',
    'ao-noise.bin',
    'dfg-lut.bin',
    'archive-cassette.bin',
    'archive-cassette-indices.bin',
    'archive-cassette.json',
    'archive-assembly.bin',
    'archive-assembly-indices.bin',
    'archive-assembly.json',
    'NotoSansSymbols2-Regular.ttf',
    'slots.json',
    'scene-fixture.json',
    'boot-lettering-art.json',
    'misans-glyphs.json',
    ...['light', 'regular', 'demibold', 'bold'].map((w) => `RhineMiSans-${w}.otf`),
];
fs.mkdirSync(out, {
    recursive: true,
});
for (const name of files) {
    fs.copyFileSync(path.join(root, name), path.join(out, name));
}
const bridge = path.join(root, 'MusicBridge');
const target = path.join(out, 'MusicBridge');
fs.mkdirSync(target, {
    recursive: true,
});
for (const name of [
    'worker.cjs',
    'qq.cjs',
    'kugou.cjs',
    'lyrics-format.cjs',
    'lyrics-source.json',
    'LyricsKit-LICENSE',
    'NODE-LICENSE',
]) {
    fs.copyFileSync(path.join(bridge, name), path.join(target, name));
}
const nodeName = process.platform === 'win32' ? 'node.exe' : 'node';
fs.copyFileSync(path.join(bridge, nodeName), path.join(target, nodeName));
fs.chmodSync(path.join(target, nodeName), 0o755);
fs.cpSync(path.join(bridge, 'upstream'), path.join(target, 'upstream'), {
    recursive: true,
});
fs.cpSync(path.join(bridge, 'client'), path.join(target, 'client'), {
    recursive: true,
});
const worker = fs.readFileSync(path.join(bridge, 'worker.cjs'), 'utf8');
const routeBlock = worker.match(/const routes = Object.freeze\(\{([\s\S]*?)\}\);/)[1];
const endpoints = [...routeBlock.matchAll(/:\s*'([^']+)'/g)].map((m) => m[1]);
// 解析已安装依赖的闭包，保留运行时资源和许可证。
// 排除说明文档、开发指令、测试源码、类型声明及 source map，保留许可证。
const visited = new Set();
const excludedDirs = new Set([
    'test',
    'tests',
    '__tests__',
    'example',
    'examples',
    'docs',
    '.github',
    '.git',
    '.bin',
]);
function filter(file) {
    const parts = path.relative(bridge, file).split(path.sep);
    return (
        !parts.some((p) => excludedDirs.has(p) || p === '.DS_Store') &&
        !/\.(?:map|d\.ts|tsbuildinfo)$/.test(file) &&
        !/^(?:readme|agents|readability-plan)(?:\.|$)/i.test(path.basename(file))
    );
}

function copyPackage(name, from, optional = false) {
    if (name.startsWith('node:')) {
        return;
    }
    const req = createRequire(path.join(from, 'package.json'));
    const location = (req.resolve.paths(name + '/package.json') || [])
        .map((p) => path.join(p, name))
        .find((p) => fs.existsSync(path.join(p, 'package.json')));
    if (!location) {
        if (optional) {
            return;
        }
        throw new Error(`Missing runtime dependency: ${name}`);
    }

    assert(location.startsWith(bridge + path.sep));
    if (visited.has(location)) {
        return;
    }
    visited.add(location);
    const manifest = JSON.parse(fs.readFileSync(path.join(location, 'package.json'), 'utf8'));
    fs.cpSync(location, path.join(target, path.relative(bridge, location)), {
        recursive: true,
        filter,
    });
    const optionalDeps = manifest.optionalDependencies || {};
    for (const dep of Object.keys({
        ...manifest.dependencies,
        ...optionalDeps,
    })) {
        copyPackage(dep, location, dep in optionalDeps);
    }
}
for (const name of ['@neteasecloudmusicapienhanced/api', '@yakult-green-tea/qq-music-api', 'kugoumusicapi']) {
    copyPackage(name, bridge);
}
fs.copyFileSync('NOTICE', path.join(out, 'NOTICE'));
const readme = fs.readFileSync('README.md', 'utf8');
fs.writeFileSync(path.join(out, 'README.md'), readme);
// 随包 README 使用同一组已审核的访客截图。
const previews = path.join(out, 'Assets/previews');
fs.mkdirSync(previews, {
    recursive: true,
});
const previewNames = [...readme.matchAll(/!\[[^\]]*\]\(Assets\/previews\/([A-Za-z0-9_-]+\.png)\)/g)].map(
    (match) => match[1],
);
for (const name of new Set(previewNames)) {
    fs.copyFileSync(path.join('Assets/previews', name), path.join(previews, name));
}
// 许可证原样复制，不转换字体或替换资源。
fs.copyFileSync('licenses/NotoSansSymbols2-OFL.txt', path.join(out, 'NotoSansSymbols2-OFL.txt'));
fs.copyFileSync('licenses/MiSans-license.pdf', path.join(out, 'MiSans-license.pdf'));
fs.writeFileSync(
    path.join(out, 'runtime-packages.json'),
    JSON.stringify(
        {
            api: '4.41.1',
            qq: '3.1.5',
            kugou: 'ba3645f2c89e6b9d4fec82ff783c15287e4c5f43',
            endpoints,
            packages: [...visited]
                .map((p) => ({
                    path: path.relative(bridge, p),
                    version: JSON.parse(fs.readFileSync(path.join(p, 'package.json'))).version,
                }))
                .sort((a, b) => a.path.localeCompare(b.path)),
        },
        null,
        2,
    ) + '\n',
);
console.log(
    `Clean resources: ${files.length} files, ${endpoints.length} API endpoints, ${visited.size} dependency packages`,
);
