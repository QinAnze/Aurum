// 同一资源与构建流程；平台分支仅处理 Qt 部署和系统签名。
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
process.chdir(root);
const win = process.platform === 'win32';
const mac = process.platform === 'darwin';
if (!win && !mac) {
    throw Error('Supported platforms: macOS and Windows');
}
const python = process.env.PYTHON || (win ? 'python' : 'python3');
const nodeName = win ? 'node.exe' : 'node';
/**
 * 串行执行构建或部署命令，失败立即终止。
 * 命令和参数分开传递，不经过 Shell 解释。
 */
function run(command, args = [], env = {}) {
    const result = spawnSync(command, args, {
        stdio: 'inherit',
        env: {
            ...process.env,
            ...env,
        },
        shell: false,
    });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        throw Error(`${command} exited with ${result.status}`);
    }
}

function npmCi(folder) {
    run(process.execPath, [
        process.env.npm_execpath,
        'ci',
        '--prefix',
        folder,
        '--omit=dev',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
    ]);
}
/**
 * 准备字体、模型、锁定桥接依赖和运行时资源；保持原有导出与检查顺序。
 */
function prepareResources() {
    fs.mkdirSync('output', {
        recursive: true,
    });
    run(python, ['scripts/check-qt-project.py']);
    run(python, ['scripts/export-assets.py']);
    for (const file of fs.readdirSync('Assets/fonts')) {
        fs.copyFileSync(path.join('Assets/fonts', file), path.join('output/resources', file));
    }

    run(process.execPath, ['scripts/check-music-upstream.cjs']);
    const bridge = 'output/resources/MusicBridge';
    fs.mkdirSync(bridge, {
        recursive: true,
    });
    for (const file of [
        'worker.cjs',
        'qq.cjs',
        'kugou.cjs',
        'lyrics-format.cjs',
        'lyrics-source.json',
        'LyricsKit-LICENSE',
        'package.json',
        'package-lock.json',
    ]) {
        fs.copyFileSync(path.join('MusicBridge', file), path.join(bridge, file));
    }
    fs.cpSync('MusicBridge/upstream', path.join(bridge, 'upstream'), {
        recursive: true,
    });
    fs.cpSync('MusicBridge/client', path.join(bridge, 'client'), {
        recursive: true,
    });
    const bridgePackages = {
        '@neteasecloudmusicapienhanced/api': '4.41.1',
        '@yakult-green-tea/qq-music-api': '3.1.5',
        kugoumusicapi: '1.6.2',
    };
    if (
        Object.entries(bridgePackages).some(([name, version]) => {
            try {
                return (
                    JSON.parse(fs.readFileSync(path.join(bridge, 'node_modules', name, 'package.json')))
                        .version !== version
                );
            } catch {
                return true;
            }
        })
    ) {
        npmCi(bridge);
    }
    const binary =
        process.env.RHINE_NODE_BINARY ||
        (mac && process.arch === 'arm64' ? path.resolve('vendor/node-arm64/node') : process.execPath);
    const license = process.env.RHINE_NODE_LICENSE || path.join(path.dirname(binary), 'LICENSE');
    if (!fs.existsSync(binary) || !fs.existsSync(license)) {
        throw Error('Provide RHINE_NODE_BINARY and its matching RHINE_NODE_LICENSE');
    }
    if (mac) {
        const deps = spawnSync('otool', ['-L', binary], {
            encoding: 'utf8',
        });
        if (
            deps.status !== 0 ||
            /\/opt\/|\/Users\/|@rpath/.test(deps.stdout.split('\n').slice(1).join('\n'))
        ) {
            throw Error('Node must be an official standalone distribution');
        }
    }
    fs.copyFileSync(binary, path.join(bridge, nodeName));
    fs.copyFileSync(license, path.join(bridge, 'NODE-LICENSE'));
    fs.chmodSync(path.join(bridge, nodeName), 0o755);
    for (const name of ['dfg-lut.bin', 'ao-kernel.bin', 'ao-noise.bin']) {
        fs.copyFileSync(path.join('Assets/lighting', name), path.join('output/resources', name));
    }
    fs.copyFileSync('Assets/room-pmrem.bin', 'output/resources/room-pmrem.bin');
    // 同步清理旧暂存文件，开发运行与发布包使用相同的纯原生资源。
    for (const name of [
        'runtime.js',
        'timeline.js',
        'qt-logic.js',
        'archive-cassette-geometry.json',
        'archive-assembly-geometry.json',
    ]) {
        fs.rmSync(path.join('output/resources', name), { force: true });
    }
}
/**
 * 验证 Qt kit 后串行配置和编译，返回部署所需的路径与构建类型。
 */
function buildQt() {
    const qt = process.env.QT_ROOT || (mac ? path.join(os.homedir(), 'Qt/6.12.0/macos') : '');
    if (!qt || !fs.existsSync(path.join(qt, 'lib/cmake/Qt6/Qt6Config.cmake'))) {
        throw Error('Set QT_ROOT to a Qt desktop kit with Shader Tools and private headers');
    }
    const config = process.env.RHINE_BUILD_TYPE || 'Release';
    run('cmake', [
        '-S',
        '.',
        '-B',
        'output/qt-build',
        '-G',
        'Ninja',
        `-DCMAKE_PREFIX_PATH=${qt}`,
        `-DCMAKE_BUILD_TYPE=${config}`,
        '-DRHINE_PACKAGE_APP=OFF',
    ]);
    run('cmake', ['--build', 'output/qt-build']);
    return {
        qt,
        config,
    };
}
/**
 * MSVC 运行库部署
 * 仅从当前开发环境的可分发目录取 DLL；缺少运行库时禁止生成不完整的发布包。
 */
function deployWindowsRuntime(app, config) {
    let redist = process.env.VCToolsRedistDir;
    if (!redist) {
        const base = path.join(process.env.VCINSTALLDIR || '', 'Redist/MSVC');
        if (!fs.existsSync(base)) {
            throw new Error('MSVC redist directory missing; build in a Visual Studio developer shell');
        }
        const versions = fs.readdirSync(base).filter((name) => /^\d+\.\d+\.\d+$/.test(name));
        versions.sort((first, second) => second.localeCompare(first, undefined, { numeric: true }));
        if (!versions.length) {
            throw new Error('MSVC redistributable runtime missing');
        }
        redist = path.join(base, versions[0]);
    }
    const debug = config === 'Debug';
    const architecture = path.join(redist, ...(debug ? ['debug_nonredist', 'x64'] : ['x64']));
    const directory = fs
        .readdirSync(architecture)
        .find((name) => (debug ? /^Microsoft\.VC\d+\.DebugCRT$/ : /^Microsoft\.VC\d+\.CRT$/).test(name));
    if (!directory) {
        throw new Error('MSVC x64 runtime DLL directory missing');
    }
    const runtime = path.join(architecture, directory);
    const libraries = fs.readdirSync(runtime).filter((name) => name.toLowerCase().endsWith('.dll'));
    const suffix = debug ? 'd.dll' : '.dll';
    for (const name of ['msvcp140' + suffix, 'vcruntime140' + suffix, 'vcruntime140_1' + suffix]) {
        if (!libraries.includes(name)) {
            throw new Error(`MSVC runtime library missing: ${name}`);
        }
    }
    for (const name of libraries) {
        fs.copyFileSync(path.join(runtime, name), path.join(app, name));
    }
}

/**
 * 根据 Qt 插件实际依赖部署 FFmpeg 动态库，避免 Mac 发布包静默回落到原生后端。
 * 只复制当前 kit 中被引用的库，兼容不同 Qt 补丁版本使用的 FFmpeg 主版本。
 */
function deployMacAudioLibraries(qt, app) {
    const frameworks = path.join(app, 'Contents/Frameworks');
    fs.mkdirSync(frameworks, { recursive: true });
    const plugin = path.join(app, 'Contents/PlugIns/multimedia/libffmpegmediaplugin.dylib');
    const pending = [plugin];
    const deployed = new Set();
    while (pending.length) {
        const binary = pending.pop();
        const result = spawnSync('otool', ['-L', binary], { encoding: 'utf8' });
        if (result.status !== 0) {
            throw new Error(`Cannot inspect multimedia dependency: ${binary}`);
        }
        const pattern =
            /@(?:rpath|loader_path)\/(lib(?:avcodec|avformat|avutil|avfilter|avdevice|swresample|swscale)\.\d+(?:\.\d+)*\.dylib)/g;
        for (const match of result.stdout.matchAll(pattern)) {
            const name = match[1];
            if (deployed.has(name)) {
                continue;
            }
            const source = path.join(qt, 'lib', name);
            fs.copyFileSync(source, path.join(frameworks, name));
            deployed.add(name);
            pending.push(source);
        }
    }
    // 插件位于 Contents/PlugIns/multimedia；音频库位于 Contents/Frameworks。
    run('install_name_tool', ['-add_rpath', '@loader_path/../../Frameworks', plugin]);
}

/**
 * 组装独立应用并执行平台部署和签名，所有文件沿用原资源清单。
 */
function deployApp(qt, config, existingBundle = '') {
    const app = path.resolve(
        existingBundle || (mac ? 'output/RHINE MUSIC DATABASE.app' : 'output/windows/RHINE MUSIC DATABASE'),
    );
    if (!existingBundle && fs.existsSync(app)) {
        fs.renameSync(app, app + '.previous-' + Date.now());
    }
    const resources = mac ? path.join(app, 'Contents/Resources') : path.join(app, 'resources');
    if (mac && !existingBundle) {
        fs.cpSync('output/qt-build/RhineMusicDatabase.app', app, {
            recursive: true,
        });
    } else if (!mac) {
        fs.mkdirSync(app, {
            recursive: true,
        });
        fs.copyFileSync('output/qt-build/RhineMusicDatabase.exe', path.join(app, 'RHINE MUSIC DATABASE.exe'));
    }

    fs.mkdirSync(resources, { recursive: true });
    if (mac) {
        fs.mkdirSync('output/qt-icon', {
            recursive: true,
        });
        run(path.join(app, 'Contents/MacOS/RhineMusicDatabase'), ['--make-icon', 'output/qt-icon'], {
            QT_QPA_PLATFORM: 'offscreen',
        });
        run(python, ['scripts/package-icon.py', 'output/qt-icon', path.join(resources, 'AppIcon.icns')]);
        for (const plugin of [
            'platforms/libqcocoa.dylib',
            'platforms/libqoffscreen.dylib',
            'imageformats/libqjpeg.dylib',
            'imageformats/libqgif.dylib',
            'imageformats/libqico.dylib',
            'tls/libqsecuretransportbackend.dylib',
            'multimedia/libdarwinmediaplugin.dylib',
            'multimedia/libffmpegmediaplugin.dylib',
        ]) {
            const dest = path.join(app, 'Contents/PlugIns', plugin);
            fs.mkdirSync(path.dirname(dest), {
                recursive: true,
            });
            fs.copyFileSync(path.join(qt, 'plugins', plugin), dest);
        }
        deployMacAudioLibraries(qt, app);
        if (config === 'Debug') {
            for (const plugin of ['local', 'server', 'preview', 'quickprofiler', 'quickeventreplay']) {
                const dest = path.join(app, 'Contents/PlugIns/qmltooling', `libqmldbg_${plugin}.dylib`);
                fs.mkdirSync(path.dirname(dest), {
                    recursive: true,
                });
                fs.copyFileSync(path.join(qt, 'plugins/qmltooling', path.basename(dest)), dest);
            }
        }
        run(path.join(qt, 'bin/macdeployqt'), [
            app,
            '-qmldir=' + path.join(root, 'Qt/qml'),
            '-always-overwrite',
            '-no-plugins',
        ]);
        fs.writeFileSync(
            path.join(resources, 'qt.conf'),
            '[Paths]\nPrefix=.\nPlugins=PlugIns\nQmlImports=Resources/qml\n',
        );
        fs.rmSync(path.join(app, 'Contents/PlugIns/sqldrivers'), {
            recursive: true,
            force: true,
        });
    } else {
        run(path.join(qt, 'bin/windeployqt.exe'), [
            '--' + config.toLowerCase(),
            '--qmldir',
            path.join(root, 'Qt/qml'),
            '--no-translations',
            '--no-system-d3d-compiler',
            '--no-compiler-runtime',
            path.join(app, 'RHINE MUSIC DATABASE.exe'),
        ]);
        deployWindowsRuntime(app, config);
        // windeployqt 默认只带 Windows 平台插件；离线发布包测试也需要 offscreen 插件。
        const offscreen = config === 'Debug' ? 'qoffscreend.dll' : 'qoffscreen.dll';
        fs.mkdirSync(path.join(app, 'platforms'), {
            recursive: true,
        });
        fs.copyFileSync(
            path.join(qt, 'plugins/platforms', offscreen),
            path.join(app, 'platforms', offscreen),
        );
        fs.writeFileSync(path.join(app, 'qt.conf'), '[Paths]\nPlugins=.\nQmlImports=qml\n');
        fs.rmSync(path.join(app, 'sqldrivers'), {
            recursive: true,
            force: true,
        });
    }
    // 先部署 Qt，再装入大量 SDK 文件，避免部署工具逐个扫描非原生依赖。
    run(process.execPath, ['scripts/package-resources.cjs', resources]);
    fs.copyFileSync('LICENSE', path.join(resources, 'LICENSE'));
    fs.copyFileSync('vendor/qrcodegen/qrcodegen.hpp', path.join(resources, 'qrcodegen-LICENSE.hpp'));
    fs.cpSync('licenses/Qt', path.join(resources, 'Qt-Licenses'), {
        recursive: true,
    });
    const qtLicenses = path.resolve(qt, '../../Licenses');
    if (fs.existsSync(qtLicenses)) {
        fs.cpSync(qtLicenses, path.join(resources, 'Qt-Licenses'), {
            recursive: true,
        });
    }
    if (mac) {
        run('codesign', ['--force', '--sign', '-', path.join(resources, 'MusicBridge/node')]);
        run('codesign', ['--force', '--deep', '--sign', '-', app]);
    }
    return app;
}
prepareResources();
if (process.argv[2] === '--cmake-package') {
    // Qt Creator 的链接产物原地打包，不再次启动 CMake 或覆盖其他构建目录。
    const [, , , bundle, qt, config] = process.argv;
    if (!mac || !bundle || !qt || !config) {
        throw new Error('CMake packaging requires a macOS bundle, Qt kit and build configuration');
    }
    console.log(deployApp(qt, config, path.resolve(bundle)));
} else {
    const { qt, config } = buildQt();
    console.log(deployApp(qt, config));
}
