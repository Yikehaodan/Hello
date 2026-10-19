// Opt-in smoke test. Uses the existing official DeepSeek key in memory only.
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';

const support = join(homedir(), 'Library/Application Support');
const root = ['LightVoice', 'Knock'].map(name => join(support, name)).find(existsSync) ?? join(support, 'Hello');
const values = Object.fromEntries((await readFile(join(root, 'gateway.env'), 'utf8')).split('\n').filter(line => line.includes('=')).map(line => {
  const index = line.indexOf('='); return [line.slice(0, index).trim(), line.slice(index + 1).trim().replace(/^['"]|['"]$/g, '')];
}));
const base = values.HELLO_LLM_BASE_URL ?? values.KNOCK_LLM_BASE_URL ?? values.OPENCAS_LLM_BASE_URL;
if (new URL(base).hostname !== 'api.deepseek.com') throw new Error('Only the configured official DeepSeek provider is allowed.');
const key = values.HELLO_LLM_API_KEY ?? values.KNOCK_LLM_API_KEY ?? values.OPENCAS_LLM_API_KEY;
const directory = await mkdtemp(join(tmpdir(), 'hello-deepseek-smoke-'));
const marker = randomUUID(); await writeFile(join(directory, 'probe.txt'), marker);
const child = spawn(process.execPath, [resolve('source/agent-runtime/bridge.mjs')], { stdio: ['pipe', 'pipe', 'pipe'] });
let sawRead = false, passed = false, failure = '';
child.stderr.resume();
const send = object => child.stdin.write(JSON.stringify(object) + '\n');
const timer = setTimeout(() => { failure = 'Timed out'; send({ type: 'cancel' }); setTimeout(() => child.kill(), 3000).unref(); }, 90000);
createInterface({ input: child.stdout }).on('line', line => {
  const event = JSON.parse(line);
  if (event.type === 'activity' && event.tool === 'Read') sawRead = true;
  if (event.type === 'permission') send({ type: 'reply', id: event.id, allow: false });
  if (event.type === 'result') {
    passed = event.ok && sawRead && event.text.includes(marker);
    if (!passed) failure = String(event.text).replaceAll(key, '[redacted]');
  }
  if (event.type === 'error') failure = String(event.text).replaceAll(key, '[redacted]');
});
send({ type: 'start', test: true, prompt: '使用 Read 工具读取当前工作目录的 probe.txt，只返回文件内容。', config: {
  baseURL: 'https://api.deepseek.com/anthropic', key, model: 'deepseek-flash', auth: 'bearer', workspace: directory, stateDirectory: join(directory, 'state'),
} });
await new Promise(resolveExit => child.on('exit', resolveExit));
clearTimeout(timer); await rm(directory, { recursive: true, force: true });
if (!passed) { console.error('FAIL: DeepSeek SDK smoke: ' + failure.slice(0, 600)); process.exitCode = 1; }
else console.log('PASS: real DeepSeek + Claude Agent SDK read a random file through the Read tool and returned the correct contents.');
