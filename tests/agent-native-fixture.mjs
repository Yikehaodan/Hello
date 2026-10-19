import { createInterface } from 'node:readline';
const emit = event => process.stdout.write(JSON.stringify(event) + '\n');
const lines = createInterface({ input: process.stdin });
let resume;
lines.on('line', line => {
  const event = JSON.parse(line);
  if (event.type === 'start') {
    resume = event.resume || 'fixture-session';
    emit({ type: 'session', id: resume });
    emit({ type: 'delta', text: '正在处理' });
    emit({ type: 'lookup', id: 'search', kind: 'search', query: 'fixture' });
  }
  if (event.type === 'reply' && event.id === 'search') emit({ type: 'permission', id: 'write', tool: 'Write', input: { file_path: '/tmp/fixture', content: 'example' } });
  if (event.type === 'reply' && event.id === 'write') {
    emit({ type: 'result', session: resume, ok: true, text: event.allow ? '允许后完成' : '拒绝后完成' });
    process.exit(0);
  }
  if (event.type === 'cancel') process.exit(0);
});
