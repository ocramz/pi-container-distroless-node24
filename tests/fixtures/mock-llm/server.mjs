/**
 * A scripted, dependency-free stand-in for an OpenAI-compatible chat endpoint.
 *
 * Pi's `openai-completions` API talks to this over loopback, which lets the
 * integration tests drive a complete agent loop -- extension tool call, bash
 * tool call, final answer -- inside a container started with `--network=none`.
 * No API key, no provider, no flakiness.
 *
 * The script is driven by what is already in the transcript rather than by a
 * turn counter, so it does not care how Pi chunks the conversation:
 *
 *   1. no `greet` result yet          -> call the extension's `greet` tool
 *   2. `greet` done, no `bash` result -> call the built-in `bash` tool
 *   3. both done                      -> answer with text
 *
 * Usage: node server.mjs [port]
 */
import { createServer } from "node:http";
import { writeFileSync } from "node:fs";

const PORT = Number(process.argv[2] ?? process.env.MOCK_PORT ?? 8080);
const MODEL = "mock-1";

// Every request body is written here, so tests can assert on what Pi actually
// sent -- the system prompt (did the bundled extension modify it?) and the tool
// list (was a project-local extension trusted and loaded?).
const DUMP = process.env.MOCK_DUMP ?? "/tmp/mock-request.json";

const chunk = (delta, finishReason = null) => ({
	id: "chatcmpl-mock",
	object: "chat.completion.chunk",
	created: Math.floor(Date.now() / 1000),
	model: MODEL,
	choices: [{ index: 0, delta, finish_reason: finishReason }],
});

function send(res, events) {
	res.writeHead(200, {
		"content-type": "text/event-stream",
		"cache-control": "no-cache",
		connection: "keep-alive",
	});
	for (const event of events) {
		res.write(`data: ${JSON.stringify(event)}\n\n`);
	}
	res.write("data: [DONE]\n\n");
	res.end();
}

function toolCall(id, name, args) {
	return [
		chunk({
			role: "assistant",
			content: null,
			tool_calls: [{ index: 0, id, type: "function", function: { name, arguments: "" } }],
		}),
		chunk({ tool_calls: [{ index: 0, function: { arguments: JSON.stringify(args) } }] }),
		{
			...chunk({}, "tool_calls"),
			usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
		},
	];
}

function text(body) {
	return [
		chunk({ role: "assistant", content: "" }),
		chunk({ content: body }),
		{
			...chunk({}, "stop"),
			usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
		},
	];
}

/** Names of the tools the transcript already contains results for. */
function completedTools(messages) {
	const names = new Map(); // tool_call_id -> name
	const done = new Set();
	for (const m of messages ?? []) {
		for (const c of m.tool_calls ?? []) {
			names.set(c.id, c.function?.name);
		}
		if (m.role === "tool" && names.has(m.tool_call_id)) {
			done.add(names.get(m.tool_call_id));
		}
	}
	return done;
}

const server = createServer((req, res) => {
	if (!req.url.endsWith("/chat/completions")) {
		res.writeHead(404).end();
		return;
	}

	let body = "";
	req.on("data", (d) => (body += d));
	req.on("end", () => {
		let messages = [];
		try {
			messages = JSON.parse(body).messages ?? [];
			writeFileSync(DUMP, body);
		} catch {
			/* fall through to the text response */
		}

		const done = completedTools(messages);
		if (!done.has("greet")) {
			send(res, toolCall("call_greet", "greet", { name: "pi" }));
		} else if (!done.has("bash")) {
			send(res, toolCall("call_bash", "bash", { command: "echo ok > /tmp/marker" }));
		} else {
			send(res, text("MOCK_DONE both tools ran"));
		}
	});
});

server.listen(PORT, "127.0.0.1", () => {
	process.stdout.write(`mock-llm listening on 127.0.0.1:${PORT}\n`);
});
