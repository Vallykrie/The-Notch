import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { EventEmitter } from 'node:events';
import { join } from 'node:path';
import assert from 'node:assert/strict';

const calls = [];
const spawn = (path, args, options) => {
  const child = new EventEmitter();
  child.stdin = new EventEmitter();
  child.stdin.end = data => { calls.push({ path, args, options, payload: JSON.parse(data) }); child.emit('exit', 0); };
  child.kill = () => {};
  return child;
};
const context = vm.createContext({ setTimeout, clearTimeout });
const module = new vm.SourceTextModule(readFileSync(process.argv[2], 'utf8'), { context });
await module.link(name => {
  const exports = name === 'node:child_process' ? { spawn } : name === 'node:os' ? { homedir: () => '/test home' } : { join };
  return new vm.SyntheticModule(Object.keys(exports), function () { for (const [key, value] of Object.entries(exports)) this.setExport(key, value); }, { context });
});
await module.evaluate();
const hooks = await module.namespace.TheNotch({ directory: '/a project' });
await hooks.event({ event: { type: 'session.created', properties: { info: { id: 's1' } } } });
await hooks['chat.message']({ sessionID: 's1' });
await hooks['tool.execute.before']({ sessionID: 's1', tool: 'bash' }, { args: { command: 'echo hi' } });
await hooks.event({ event: { type: 'permission.asked', properties: { sessionID: 's1' } } });
await hooks.event({ event: { type: 'session.idle', properties: { sessionID: 's1' } } });
await hooks.event({ event: { type: 'session.created', properties: {} } });
assert.deepEqual(calls.map(x => x.args[3]), ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'AttentionRequired', 'Stop']);
assert.equal(calls[0].path, '/test home/.the-notch/bin/notch-hook');
assert.equal(calls[2].payload.tool_name, 'bash');
assert.equal(calls[2].payload.cwd, '/a project');
assert.equal(calls[3].options.stdio[1], 'ignore');
console.log('PASS: OpenCode native plugin session, prompt, tool, attention and completion events');
