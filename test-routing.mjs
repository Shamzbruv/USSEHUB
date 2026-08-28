import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

const projectRoot = new URL('.', import.meta.url);
const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const server = spawn(npmCommand, ['run', 'start'], {
    cwd: projectRoot,
    env: {
        ...process.env,
        CI: '1',
        FORCE_COLOR: '0',
        NO_UPDATE_NOTIFIER: '1',
        NODE_ENV: 'production',
        PORT: '0'
    },
    detached: process.platform !== 'win32',
    stdio: ['ignore', 'pipe', 'pipe']
});

let serverOutput = '';
const serverExit = new Promise((resolve) => {
    server.once('exit', (code, signal) => resolve({ code, signal }));
});

function waitForServerPort() {
    return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
            cleanup();
            reject(new Error(`Production server did not start within 20 seconds.\n${serverOutput}`));
        }, 20_000);

        const onError = (error) => {
            cleanup();
            reject(error);
        };
        const onExit = (code, signal) => {
            cleanup();
            reject(new Error(`Production server exited before becoming ready (${signal || code}).\n${serverOutput}`));
        };
        const onData = (chunk) => {
            serverOutput += chunk.toString();
            const match = serverOutput.match(/Accepting connections at http:\/\/(?:0\.0\.0\.0|127\.0\.0\.1|localhost):(\d+)/);
            if (!match) return;
            cleanup();
            resolve(Number(match[1]));
        };
        const cleanup = () => {
            clearTimeout(timeout);
            server.off('error', onError);
            server.off('exit', onExit);
            server.stdout.off('data', onData);
            server.stderr.off('data', onData);
        };

        server.once('error', onError);
        server.once('exit', onExit);
        server.stdout.on('data', onData);
        server.stderr.on('data', onData);
    });
}

async function stopServer() {
    if (server.exitCode !== null || server.signalCode !== null) return;

    try {
        if (process.platform !== 'win32' && server.pid) process.kill(-server.pid, 'SIGTERM');
        else server.kill('SIGTERM');
    } catch (error) {
        if (error.code !== 'ESRCH') throw error;
    }

    const stopped = await Promise.race([
        serverExit.then(() => true),
        new Promise((resolve) => setTimeout(() => resolve(false), 3_000))
    ]);
    if (stopped || server.exitCode !== null || server.signalCode !== null) return;

    try {
        if (process.platform !== 'win32' && server.pid) process.kill(-server.pid, 'SIGKILL');
        else server.kill('SIGKILL');
    } catch (error) {
        if (error.code !== 'ESRCH') throw error;
    }
    await serverExit;
}

const pages = [
    { route: 'ajm-webpage-builder', title: 'AJM Webpage Builder | Advertising Hub' },
    { route: 'ajm-business-page', title: 'AJM Business Webpage | Advertising Hub' },
    { route: 'ajm-advertising-hub', title: 'AJM Advertising Hub Jamaica | Classifieds, Promotions &amp; Business Listings' }
];

try {
    const port = await waitForServerPort();
    const bodies = new Map();

    for (const page of pages) {
        for (const suffix of ['.html', '']) {
            const path = `/${page.route}${suffix}?listing=sentinel&preview=1`;
            const target = new URL(path, `http://127.0.0.1:${port}`);
            const response = await fetch(target, {
                cache: 'no-store',
                redirect: 'manual',
                signal: AbortSignal.timeout(5_000)
            });
            const body = await response.text();

            assert.equal(response.status, 200, `${path} returned HTTP ${response.status}`);
            assert.equal(response.headers.get('location'), null, `${path} unexpectedly returned a redirect`);
            assert.equal(response.url, target.href, `${path} did not preserve its query-bearing URL`);
            assert.match(response.headers.get('content-type') || '', /^text\/html\b/i, `${path} was not served as HTML`);
            assert.ok(body.includes(`<title>${page.title}</title>`), `${path} returned the wrong HTML document`);

            if (suffix === '.html') bodies.set(page.route, body);
            else assert.equal(body, bodies.get(page.route), `${path} did not resolve to the same HTML as the explicit route`);
        }
    }

    console.log(`Routing validation passed: ${pages.length * 2} query-bearing production routes served without redirects.`);
} finally {
    await stopServer();
}
