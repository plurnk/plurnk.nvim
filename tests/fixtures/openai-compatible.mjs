import { once } from "node:events";
import { createServer } from "node:http";
import { setTimeout as delay } from "node:timers/promises";

const MODEL = "plurnk-installed-journey";

const programs = Object.freeze([
    {
        reasoning: "I will make one reviewed local change, then verify the settled result.",
        content: [
            "# PLAN0",
            '[{"content":"Create the requested acceptance marker through review.","priority":"high","status":"in_progress"}]',
            "## EXEC0 [sh] (.)",
            "printf 'accepted\\n' > journey.txt",
            "## SEND0 [102]",
            "Next: Confirm the reviewed command completed.",
        ].join("\n"),
    },
    {
        reasoning: "The reviewed command succeeded, so I can conclude the requested journey.",
        content: [
            "# PLAN0",
            '[{"content":"Create the requested acceptance marker through review.","priority":"high","status":"completed"}]',
            "## SEND0 [200]",
            "The reviewed multiline journey is complete.",
        ].join("\n"),
    },
]);

const readJson = async (request) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    return JSON.parse(body);
};

const frame = (value) => `data: ${JSON.stringify(value)}\n\n`;

const streamProgram = async (response, program, index) => {
    response.writeHead(200, {
        "cache-control": "no-cache",
        connection: "keep-alive",
        "content-type": "text/event-stream",
    });
    const id = `journey-${index + 1}`;
    const chunk = (delta, finishReason = null) => ({
        id,
        object: "chat.completion.chunk",
        created: index + 1,
        model: MODEL,
        choices: [{ index: 0, delta, finish_reason: finishReason }],
    });
    response.write(frame(chunk({ reasoning_content: program.reasoning })));
    await delay(10);
    const midpoint = Math.ceil(program.content.length / 2);
    response.write(frame(chunk({ content: program.content.slice(0, midpoint) })));
    await delay(10);
    response.write(frame(chunk({ content: program.content.slice(midpoint) })));
    await delay(10);
    response.write(frame({
        ...chunk({}, "stop"),
        usage: {
            prompt_tokens: 400,
            completion_tokens: 80,
            total_tokens: 480,
            completion_tokens_details: { reasoning_tokens: 12 },
        },
    }));
    response.end("data: [DONE]\n\n");
};

export const startOpenAiCompatibleFixture = async () => {
    const requests = [];
    const server = createServer(async (request, response) => {
        try {
            const url = new URL(request.url ?? "/", "http://fixture.invalid");
            if (request.method !== "POST" || url.pathname !== "/v1/chat/completions") {
                response.writeHead(404, { "content-type": "application/json" });
                response.end(JSON.stringify({ error: { message: "fixture route not found" } }));
                return;
            }
            const body = await readJson(request);
            const program = programs[requests.length];
            requests.push(body);
            if (program === undefined) {
                response.writeHead(409, { "content-type": "application/json" });
                response.end(JSON.stringify({ error: { message: "unexpected extra inference turn" } }));
                return;
            }
            if (body.model !== MODEL || body.stream !== true) {
                response.writeHead(400, { "content-type": "application/json" });
                response.end(JSON.stringify({ error: { message: "invalid installed-journey request" } }));
                return;
            }
            await streamProgram(response, program, requests.length - 1);
        } catch (error) {
            response.writeHead(500, { "content-type": "application/json" });
            response.end(JSON.stringify({ error: { message: String(error) } }));
        }
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const address = server.address();
    if (address === null || typeof address === "string") throw new Error("fixture did not bind a TCP port");
    return {
        baseUrl: `http://127.0.0.1:${address.port}/v1`,
        requests,
        close: async () => {
            server.close();
            server.closeAllConnections();
            await once(server, "close");
        },
    };
};
