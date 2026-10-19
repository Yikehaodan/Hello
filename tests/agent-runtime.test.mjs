import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { providerEnvironment } from '../source/agent-runtime/bridge.mjs';
const bridgePath = join(process.env.HELLO_TEST_AGENT_RUNTIME ?? resolve('source/agent-runtime'), 'bridge.mjs');

test('provider settings isolate inherited provider credentials', () => {
  const env = providerEnvironment({ baseURL: 'https://api.deepseek.com/anthropic', key: 'test-key', model: 'test-model', auth: 'bearer', stateDirectory: '/tmp/test-state' },
    { PATH: '/usr/bin', ANTHROPIC_API_KEY: 'old-key', CLAUDE_CODE_USE_BEDROCK: '1', CLAUDECODE: '1' });
  assert.equal(env.ANTHROPIC_AUTH_TOKEN, 'test-key');
  assert.equal(env.ANTHROPIC_API_KEY, undefined);
  assert.equal(env.CLAUDE_CODE_USE_BEDROCK, undefined);
  assert.equal(env.CLAUDECODE, undefined);
  assert.equal(env.ANTHROPIC_DEFAULT_HAIKU_MODEL, 'test-model');
  assert.throws(() => providerEnvironment({ baseURL: 'http://example.com', key: 'x', model: 'x' }));
});

function sse(response, block, id) {
  response.writeHead(200, { 'content-type': 'text/event-stream' });
  const event = (type, data) => response.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
  event('message_start', { message: { id: `msg_${id}`, type: 'message', role: 'assistant', model: 'hello-fixture', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0 } } });
  if (block.type === 'tool_use') {
    event('content_block_start', { index: 0, content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} } });
    event('content_block_delta', { index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } });
  } else {
    event('content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
    event('content_block_delta', { index: 0, delta: { type: 'text_delta', text: block.text } });
  }
  event('content_block_stop', { index: 0 });
  event('message_delta', { delta: { stop_reason: block.type === 'tool_use' ? 'tool_use' : 'end_turn', stop_sequence: null }, usage: { output_tokens: 20 } });
  event('message_stop', {}); response.end();
}

test('real SDK reads files, calls Hello search, asks permission, resumes and cancels', { timeout: 90000 }, async () => {
  const folder = await mkdtemp(join(tmpdir(), 'hello-sdk-test-'));
  const fixture = join(folder, 'fixture.txt');
  await writeFile(fixture, 'HELLO_FILE_RESULT');
  const requests = [];
  const server = createServer(async (req, res) => {
    if (!req.url.startsWith('/v1/messages') || req.url.includes('count_tokens')) {
      res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify({ input_tokens: 20, data: [] })); return;
    }
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw); requests.push(body);
    const results = body.messages.flatMap(m => Array.isArray(m.content) ? m.content : []).filter(b => b.type === 'tool_result');
    const done = new Set(results.map(r => r.tool_use_id));
    const tool = (id, name, input) => ({ type: 'tool_use', id, name, input });
    const searchName = body.tools?.find(t => t.name.includes('hello') && t.name.endsWith('search'))?.name;
    let block;
    if (!done.has('read_1')) block = tool('read_1', 'Read', { file_path: fixture });
    else if (!done.has('search_1')) block = tool('search_1', searchName, { query: 'Hello integration' });
    else if (!done.has('write_1')) block = tool('write_1', 'Write', { file_path: join(folder, 'denied.txt'), content: 'must not be written' });
    else if (!done.has('write_2')) block = tool('write_2', 'Write', { file_path: join(folder, 'approved.txt'), content: 'APPROVED_CONTENT' });
    else if (!done.has('edit_1')) block = tool('edit_1', 'Edit', { file_path: join(folder, 'approved.txt'), old_string: 'APPROVED_CONTENT', new_string: 'EDITED_CONTENT' });
    else if (!done.has('bash_1')) block = tool('bash_1', 'Bash', { command: 'touch denied-command.txt', description: 'Create a test file' });
    else if (!done.has('question_1')) block = tool('question_1', 'AskUserQuestion', { questions: [{ question: '选择格式？', header: '格式', multiSelect: false, options: [{ label: 'Markdown', description: '文本' }, { label: 'HTML', description: '网页' }] }] });
    else block = { type: 'text', text: 'HELLO_AGENT_DONE' };
    sse(res, block, requests.length);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const config = { baseURL: `http://127.0.0.1:${server.address().port}`, key: 'fixture-key', model: 'hello-fixture', auth: 'bearer', workspace: folder, stateDirectory: join(folder, 'state') };
  const events = [];
  const run = (resume, cancelOnPermission = false) => new Promise((resolveRun, reject) => {
    const child = spawn(process.execPath, [bridgePath], { stdio: ['pipe', 'pipe', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', data => { stderr += data; });
    const lines = createInterface({ input: child.stdout });
    const send = object => child.stdin.write(JSON.stringify(object) + '\n');
    const runEvents = [];
    const timer = setTimeout(() => { child.kill(); reject(new Error(`SDK timed out: ${stderr}\n${JSON.stringify(runEvents)}`)); }, 35000);
    lines.on('line', line => {
      const event = JSON.parse(line); events.push(event); runEvents.push(event);
      if (event.type === 'lookup') send({ type: 'reply', id: event.id, sources: [{ title: 'Fixture', url: 'https://example.com', content: 'SEARCH_FIXTURE_RESULT' }] });
      if (event.type === 'permission') {
        if (cancelOnPermission) send({ type: 'cancel' });
        else send({ type: 'reply', id: event.id, allow: event.tool === 'AskUserQuestion' || event.tool === 'Edit' ||
          (event.tool === 'Write' && event.input.file_path === join(folder, 'approved.txt')), answers: { '选择格式？': 'Markdown' } });
      }
    });
    child.on('error', reject);
    child.on('exit', code => { clearTimeout(timer); code === 0 ? resolveRun(runEvents) : reject(new Error(`SDK exit ${code}: ${stderr}`)); });
    send({ type: 'start', config, prompt: 'Complete the integration fixture.', resume });
  });
  try {
    const first = await run();
    assert.equal(first.find(e => e.type === 'result')?.text, 'HELLO_AGENT_DONE', JSON.stringify(first));
    assert.ok(first.some(e => e.type === 'lookup' && e.kind === 'search'));
    assert.ok(first.some(e => e.type === 'permission' && e.tool === 'Write'));
    assert.ok(first.some(e => e.type === 'permission' && e.tool === 'Edit'));
    assert.ok(first.some(e => e.type === 'permission' && e.tool === 'Bash'));
    assert.ok(first.some(e => e.type === 'permission' && e.tool === 'AskUserQuestion'));
    await assert.rejects(readFile(join(folder, 'denied.txt')));
    await assert.rejects(readFile(join(folder, 'denied-command.txt')));
    assert.equal(await readFile(join(folder, 'approved.txt'), 'utf8'), 'EDITED_CONTENT');
    assert.ok(JSON.stringify(requests).includes('HELLO_FILE_RESULT'));
    assert.ok(JSON.stringify(requests).includes('SEARCH_FIXTURE_RESULT'));
    const session = first.find(e => e.type === 'session').id;
    const resumed = await run(session);
    assert.equal(resumed.find(e => e.type === 'session').id, session);
    assert.equal(resumed.find(e => e.type === 'result')?.text, 'HELLO_AGENT_DONE');
    const cancelled = await run(undefined, true);
    assert.ok(cancelled.some(e => e.type === 'exit' && e.cancelled));
    assert.ok(!cancelled.some(e => e.type === 'result' && e.ok));
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(folder, { recursive: true, force: true }); }
});
