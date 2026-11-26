// Synthetic Node22 detached HTTP worker; no package/SDK/provider imports.
import {spawn} from 'node:child_process';
import http from 'node:http';
const mode = process.argv[2] || 'launcher';
if (!['worker', 'server'].includes(mode)) {
  const child = spawn(process.execPath, [import.meta.filename, mode === 'double' ? 'launcher' : 'worker'], {
    detached: true, stdio: ['ignore', 'inherit', 'inherit'], env: process.env,
  });
  child.unref();
  if (mode === 'nested-hold') setInterval(() => {}, 1000);
} else {
  let count = 0;
  let candidate;
  const sockets = new Set();
  const server = http.createServer((req, res) => {
    count++;
    res.end('owned-detached-response');
  });
  server.on('connection', socket => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  server.listen(0, '127.0.0.1', () => console.log(server.address().port));
  if (mode === 'server') process.stdin.on('data', data => {
    if (data.toString().trim() === 'spawn-candidate') {
      candidate = spawn(process.execPath, ['-e', 'process.stdin.resume();process.stdin.on("end",()=>process.exit(0))'], {stdio: ['pipe', 'ignore', 'inherit']});
      console.log('candidate:' + candidate.pid);
    } else if (data.toString().trim() === 'exit-candidate') {
      candidate.stdin.end();
      console.log('candidate-ended');
    } else if (data.toString().trim() === 'close') {
      setInterval(() => {}, 1000);
      server.close(() => console.log('closed'));
    } else if (data.toString().trim() === 'close-accepted') {
      for (const socket of sockets) socket.destroy();
      console.log('closed-accepted');
    } else if (data.toString().trim() === 'count') {
      console.log('count:' + count);
    }
  });
}
