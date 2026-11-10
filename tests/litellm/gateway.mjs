#!/usr/bin/env node
// A stand-in for a LiteLLM gateway, on 127.0.0.1, for tests/litellm.sh.
//
//   node tests/litellm/gateway.mjs CONFIG.json PORTFILE LOGFILE
//
// CONFIG is read again on every request, so a test can change how a model answers between two runs:
//   { "key": "...",                       requests without "Authorization: Bearer <key>" get 401
//     "modelInfo": true,                  false: /model/info answers 404, as a plain OpenAI-compatible server does
//     "models": [ { "id": "...",
//                   "info": [ {...} ],    one model_info object per deployment (absent: the model has no row there)
//                   "answer": "ok" | "dead" | { "billingAbove": N },
//                   "contextWindow": N }  optional: refuse a request whose prompt + output does not fit, as vLLM does
//   ] }
//
//   GET  /v1/models             {data: [{id}]}
//   GET  /v1/model/info         {data: [{model_name, litellm_params, model_info}]}, one row per deployment
//   POST /v1/chat/completions   "ok": answers OK (streamed when asked to); "dead": 500; billingAbove N: 402 when the
//                               request asks for more than N output tokens, the way OpenRouter declines a request
//                               the credit left cannot cover -- whatever the prompt
//
// The prompt is counted at 4 characters a token of the request's messages and tools as JSON, a rule of thumb of its
// own: not Pi's estimate (3.5), so a request that fits here was not sized by the same arithmetic that checks it.
// Every chat request is appended to LOGFILE as one JSON line.
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';

const [configFile, portFile, logFile] = process.argv.slice(2);
const config = () => JSON.parse(readFileSync(configFile, 'utf8'));
const json = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
};
const error = (res, status, message) => json(res, status, { error: { message, type: null, param: null, code: String(status) } });

const server = createServer((req, res) => {
  let raw = '';
  req.on('data', chunk => { raw += chunk; });
  req.on('end', () => {
    const cfg = config();
    if (req.headers.authorization !== `Bearer ${cfg.key}`) return error(res, 401, 'Authentication Error, invalid key');
    const url = req.url.split('?')[0];
    if (req.method === 'GET' && url === '/v1/models') {
      return json(res, 200, { object: 'list', data: cfg.models.map(m => ({ id: m.id, object: 'model', owned_by: 'openai' })) });
    }
    if (req.method === 'GET' && url === '/v1/model/info') {
      if (cfg.modelInfo === false) return error(res, 404, 'Not Found');
      const data = cfg.models.flatMap(m => (m.info || []).map((info, i) => ({
        model_name: m.id,
        litellm_params: { model: `upstream/${m.id}`, deployment: i },
        model_info: { id: `${m.id}#${i}`, mode: 'chat', ...info },
      })));
      return json(res, 200, { data });
    }
    if (req.method === 'POST' && url === '/v1/chat/completions') {
      let body;
      try { body = JSON.parse(raw); } catch { return error(res, 400, 'request body is not JSON'); }
      const model = cfg.models.find(m => m.id === body.model);
      const promptTokens = Math.ceil(JSON.stringify({ messages: body.messages || [], tools: body.tools || [] }).length / 4);
      const requested = body.max_completion_tokens ?? body.max_tokens ?? null;
      appendFileSync(logFile, `${JSON.stringify({
        model: body.model, max_completion_tokens: body.max_completion_tokens, max_tokens: body.max_tokens,
        stream: body.stream === true, messages: (body.messages || []).length, promptTokens,
        prompt: body.messages?.at(-1)?.content,
      })}\n`);
      if (!model) return error(res, 400, `Invalid model name passed in model=${body.model}`);
      const answer = model.answer ?? 'ok';
      if (answer === 'dead') return error(res, 500, 'litellm.InternalServerError: upstream is down');
      if (answer.billingAbove !== undefined && (requested ?? Infinity) > answer.billingAbove) {
        return error(res, 402, 'litellm.APIError: OpenrouterException - The upstream provider declined the request for a billing reason');
      }
      if (model.contextWindow && promptTokens + (requested ?? 0) > model.contextWindow) {
        return error(res, 400, `litellm.ContextWindowExceededError: This model's maximum context length is ${model.contextWindow} tokens. However, you requested ${promptTokens + requested} tokens (${promptTokens} in the messages, ${requested} in the completion).`);
      }
      const id = 'chatcmpl-stub';
      const usage = { prompt_tokens: promptTokens, completion_tokens: 1, total_tokens: promptTokens + 1 };
      if (body.stream) {
        res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
        const send = chunk => res.write(`data: ${JSON.stringify({ id, object: 'chat.completion.chunk', created: 1, model: body.model, ...chunk })}\n\n`);
        send({ choices: [{ index: 0, delta: { role: 'assistant', content: 'OK' }, finish_reason: null }] });
        send({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] });
        send({ choices: [], usage });
        return res.end('data: [DONE]\n\n');
      }
      return json(res, 200, {
        id, object: 'chat.completion', created: 1, model: body.model,
        choices: [{ index: 0, message: { role: 'assistant', content: 'OK' }, finish_reason: 'stop' }], usage,
      });
    }
    return error(res, 404, 'Not Found');
  });
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
