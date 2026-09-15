import assert from "node:assert/strict";

// Each conversation chooses its own sequence; scheduling cannot choose a program.
export const concurrentPrograms = () => {
    const counts = new Map();
    const gates = new Map(["parallel-alice", "parallel-bob"].map((name) => [name, Promise.withResolvers()]));
    const fence = (name, body) => ["```" + name, body, "```"].join("\n");
    return {
        counts,
        selectProgram(body) {
            const packet = JSON.stringify(body.messages);
            const name = ["parallel-alice", "parallel-bob", "other-alice"].find((value) => packet.includes(value));
            assert.ok(name, "concurrent fixture requires an explicit conversation marker");
            const index = counts.get(name) ?? 0;
            counts.set(name, index + 1);
            assert.ok(index < 2, "unexpected extra inference in " + name);
            const task = (status) => fence("TASK", JSON.stringify([{ content: name, status }]));
            if (name === "parallel-alice") return {
                reasoning: "Live reasoning for parallel-alice.",
                ready: gates.get(name).promise,
                content: fence("question (question)", JSON.stringify({ message: "Alice's question", requestedSchema: {
                    type: "object", properties: { answer: { type: "string" } }, required: ["answer"],
                } })) + "\n" + task("waiting"),
            };
            if (name === "parallel-bob" && index === 0) return {
                reasoning: "Live reasoning for parallel-bob.",
                ready: gates.get(name).promise,
                content: fence("sh", "printf 'bob accepted\\n' > bob.txt") + "\n" + task("in_progress"),
            };
            if (name === "parallel-bob") {
                assert.ok(packet.includes("bob-command-injection"), "command-line injection must reach Bob's next packet");
                assert.ok(packet.includes("bob-buffer-injection"), "input-buffer injection must reach Bob's next packet");
                assert.ok(!packet.includes("Alice's question"), "Alice's question must not reach Bob");
            }
            return { reasoning: "Completed " + name + ".", content: fence("SEND", name + " complete.") + "\n" + task("completed") };
        },
        control(request, response, url) {
            if (request.method !== "POST" || !url.pathname.startsWith("/release/")) return false;
            const gate = gates.get(url.pathname.slice("/release/".length));
            assert.ok(gate, "unknown fixture gate");
            gate.resolve();
            response.writeHead(204).end();
            return true;
        },
    };
};
