// 仅格式化白名单内的自维护代码，第三方和生成资源始终排除。
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync, execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
process.chdir(root);
const checkOnly = process.argv.includes('--check');
const python = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const sourceRoots = ['Resources/', 'Qt/', 'MusicBridge/', 'scripts/', '.github/'];
const configuration = new Set([
    'package.json',
    'MusicBridge/package.json',
    'eslint.config.mjs',
    '.prettierrc.json',
    '.cmake-format.json',
    'CMakeLists.txt',
    'build.sh',
    'share.sh',
    'Qt/Info.plist.in',
    'Qt/WindowsIcon.rc.in',
    '.editorconfig',
    '.clang-format',
    '.prettierignore',
    '.gitignore',
    'pyproject.toml',
    'requirements-format.txt',
]);
const paths = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], {
    encoding: 'utf8',
})
    .split('\0')
    .filter(Boolean);
const files = [...new Set(paths)].filter((file) => {
    // 已删除的受控文件仍会出现在 Git 索引中，只检查工作区实际存在的源码。
    if (!fs.existsSync(file)) {
        return false;
    }
    if (/^(vendor|output|node_modules|MusicBridge\/upstream)\//.test(file)) {
        return false;
    }
    return (
        configuration.has(file) ||
        (sourceRoots.some((folder) => file.startsWith(folder)) &&
            (/\.(?:js|cjs|mjs|ts|cpp|h|mm|qml|py|sh|glsl|vert|frag|yml|yaml)$/.test(file) ||
                path.basename(file) === 'CMakeLists.txt'))
    );
});

/**
 * 执行锁定的格式工具，并保留失败退出状态。
 * 所有命令使用参数数组，避免文件名被解释为 Shell 指令。
 */
function run(command, args, options = {}) {
    const result = spawnSync(command, args, {
        encoding: 'utf8',
        ...options,
    });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        throw new Error(result.stderr || result.stdout || `${command} exited with ${result.status}`);
    }
    return result.stdout;
}

/**
 * 比较或写入格式结果；检查模式不修改源码。
 * 缺失外部工具会明确失败，不会跳过对应语言。
 */
async function main() {
    const prettier = await import('prettier');
    const changed = [];
    for (const file of files) {
        const source = fs.readFileSync(file, 'utf8');
        let formatted;
        if (/\.(?:js|cjs|mjs|ts|json|yml|yaml)$/.test(file)) {
            const options = await prettier.resolveConfig(file);
            formatted = await prettier.format(source, {
                ...options,
                filepath: file,
            });
        } else if (/\.(?:cpp|h|mm|glsl|vert|frag)$/.test(file)) {
            // Python wheel 固定 clang-format 版本，不使用机器上任意版本的命令。
            const assumed = /\.(glsl|vert|frag)$/.test(file) ? 'Qt/shaders/shader.cpp' : file;
            formatted = run(
                python,
                [
                    '-c',
                    'from clang_format import clang_format; clang_format()',
                    `--assume-filename=${assumed}`,
                ],
                {
                    input: source,
                },
            );
        } else if (file.endsWith('.qml')) {
            // 默认只调整排版，不排序导入和属性，保持 QML 初始化顺序。
            const qtRoot =
                process.env.QT_ROOT ||
                (process.platform === 'darwin'
                    ? path.join(require('node:os').homedir(), 'Qt/6.12.0/macos')
                    : '');
            const qmlformat =
                process.env.QMLFORMAT ||
                path.join(qtRoot, 'bin', process.platform === 'win32' ? 'qmlformat.exe' : 'qmlformat');
            formatted = run(qmlformat, ['--indent-width', '4', '--newline', 'unix', file]);
        } else if (file.endsWith('.py')) {
            formatted = run(python, ['-m', 'black', '--quiet', '--config', 'pyproject.toml', '-'], {
                input: source,
            });
        } else if (path.basename(file) === 'CMakeLists.txt') {
            formatted = run(
                python,
                ['-m', 'cmakelang.format', '--config-files', '.cmake-format.json', '--', '-'],
                {
                    input: source,
                },
            );
        } else {
            // Shell 包装脚本只含独立命令；模板与此类文件统一文本空白，不改命令语法。
            formatted = source
                .replace(/\r\n/g, '\n')
                .replace(/[\t ]+$/gm, '')
                .replace(/\n*$/, '\n');
        }
        if (source.trim() && !formatted.trim()) {
            throw new Error('格式工具返回空内容：' + file);
        }
        if (source !== formatted) {
            changed.push(file);
            if (!checkOnly) {
                fs.writeFileSync(file, formatted);
            }
        }
    }
    if (checkOnly && changed.length) {
        throw new Error('需要格式化：\n' + changed.join('\n'));
    }
    console.log(`格式${checkOnly ? '检查' : '整理'}完成：${files.length} 个文件，${changed.length} 个差异`);
}
main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
});
