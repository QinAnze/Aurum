#!/usr/bin/env node
// Qt 官方 MCP 的 stdio 客户端；预览会话退出时清理本会话启动的进程组。
const { spawn } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const root = path.resolve(__dirname, '..');
const win = process.platform === 'win32';
const qt = process.env.QT_ROOT || (win ? '' : path.join(require('node:os').homedir(), 'Qt/6.12.0/macos'));
if (!qt) {
    throw new Error('Set QT_ROOT to Qt 6.12+');
}
const executable =
    process.env.RHINE_PREVIEW_EXECUTABLE ||
    path.join(
        root,
        win
            ? 'output/qt-build/RhineMusicDatabase.exe'
            : 'output/qt-build/RhineMusicDatabase.app/Contents/MacOS/RhineMusicDatabase',
    );
if (!fs.existsSync(executable)) {
    throw new Error('Run npm run build before preview');
}
const server = spawn(path.join(qt, win ? 'bin/QmlPreviewMcpServer.exe' : 'bin/QmlPreviewMcpServer'), [], {
    cwd: root,
    detached: !win,
    env: {
        ...process.env,
        RHINE_OFFLINE: '1',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
});
const send = (value) =>
    server.stdin.write(
        JSON.stringify({
            jsonrpc: '2.0',
            ...value,
        }) + '\n',
    );
let buffer = '';
server.stderr.on('data', (data) => process.stderr.write(data));
server.stdout.on('data', (data) => {
    buffer += data;
    let end;
    while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        let message;
        try {
            message = JSON.parse(line);
        } catch {
            console.log(line);
            continue;
        }
        if (message.id === 1) {
            send({
                method: 'notifications/initialized',
            });
            send({
                id: 2,
                method: 'tools/call',
                params: {
                    name: 'run_qmlPreview',
                    arguments: {
                        executable_path: executable,
                    },
                },
            });
        } else {
            console.log(JSON.stringify(message, null, 2));
        }
    }
});
const stop = () => {
    try {
        if (win) {
            require('node:child_process').spawnSync('taskkill', ['/PID', String(server.pid), '/T', '/F']);
        } else {
            process.kill(-server.pid, 'SIGTERM');
        }
    } catch {
        // 预览进程可能已退出，清理时无需再次终止。
    }
    process.exit();
};
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
server.on('exit', (code) => process.exit(code || 0));
send({
    id: 1,
    method: 'initialize',
    params: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: {
            name: 'RhineMusicDatabase',
            version: '0.4.0',
        },
    },
});
