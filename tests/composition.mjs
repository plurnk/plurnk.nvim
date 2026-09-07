import { spawn, execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { startOpenAiCompatibleFixture } from "./fixtures/openai-compatible.mjs";

const run = promisify(execFile);
const root = resolve(import.meta.dirname, "..");
const serviceRoot = resolve(process.env.PLURNK_SERVICE_DIR ?? join(root, "../plurnk-service"));
const clientRoot = resolve(process.env.PLURNK_CLIENT_DIR ?? join(root, "../plurnk"));
const temp = await mkdtemp(join(tmpdir(), "plurnk-nvim-composition-"));
const installed = join(temp, "site", "pack", "plurnk", "start", "plurnk.nvim");
const clientBin = join(temp, "bin");
const home = join(temp, "home");
const project = join(temp, "project");
const port = await new Promise((accept, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
        const address = server.address();
        server.close(() => accept(address.port));
    });
});

const stop = async (child) => {
    if (child === undefined || child.exitCode !== null) return;
    const exited = new Promise((accept) => child.once("exit", accept));
    child.kill("SIGTERM");
    await Promise.race([exited, new Promise((accept) => setTimeout(accept, 5_000))]);
    if (child.exitCode === null) child.kill("SIGKILL");
    await exited;
};

let daemon;
let fixture;
let passed = false;
try {
    await run("npm", ["run", "build"], {
        cwd: serviceRoot,
        maxBuffer: 128 * 1024 * 1024,
    });
    await run("npm", ["run", "build"], {
        cwd: clientRoot,
        maxBuffer: 128 * 1024 * 1024,
    });
    await mkdir(installed, { recursive: true });
    for (const directory of ["lua", "doc", "conformance"]) {
        await cp(join(root, directory), join(installed, directory), { recursive: true });
    }
    await mkdir(clientBin, { recursive: true });
    await symlink(join(clientRoot, "bin/plurnk.js"), join(clientBin, "plurnk"));
    await mkdir(project, { recursive: true });
    await writeFile(join(project, "README.md"), "# Installed journey fixture\n");
    await writeFile(join(project, "journey.txt"), "pending\n");
    await run("git", ["init", "--quiet"], { cwd: project });
    await run("git", ["add", "README.md", "journey.txt"], { cwd: project });
    await run("git", [
        "-c", "user.name=Plurnk Test",
        "-c", "user.email=test@plurnk.invalid",
        "commit", "--quiet", "-m", "test: seed installed journey",
    ], { cwd: project });
    fixture = await startOpenAiCompatibleFixture();
    const lua = join(temp, "composition.lua");
    await writeFile(lua, `
vim.opt.rtp:prepend(${JSON.stringify(installed)})
require("plurnk").setup({ host = "127.0.0.1", port = ${port} })
local language = require("plurnk.language")
local root_commands = language.complete("", "AI /", 0)
assert(vim.tbl_contains(root_commands, "/help") and vim.tbl_contains(root_commands, "/agents"),
  "installed command registry omitted supported root verbs")
assert(vim.deep_equal(language.complete("", "AI /mcp di", 0), { "disable", "discover" }),
  "installed command registry omitted contextual Functionality verbs")
assert(require("plurnk.command_registry").render_help("mcp"):match(":AI/mcp enable <alias>"),
  "installed contextual help omitted exact MCP usage")
local markdown = require("plurnk.markdown")
local table_source = "| Surface | Use |\\n| --- | --- |\\n| TUI | A deliberately long explanation that wraps. |\\n| CLI | Pipe-friendly output. |"
local table_changed = false
markdown.render(table_source, 42, "", function() table_changed = true end)
assert(vim.wait(5000, function() return table_changed end, 25), "installed plurnk table projection timed out")
local table_projection = markdown.render(table_source, 42, "", function() end)
local table_text = table.concat(table_projection.lines, "\\n")
assert(table_text:match("├"), "installed renderer omitted table row separators")
assert(not table_text:match("deliberately long explanation that wraps%.%s*$"), "installed renderer did not wrap the table")
local changed = false
local diagram_source = "\`\`\`mermaid\\nflowchart LR\\n  A[Client] --> B[Daemon]\\n\`\`\`"
markdown.render(diagram_source, 72, "", function() changed = true end)
assert(vim.wait(5000, function() return changed end, 25), "installed plurnk Mermaid projection timed out")
local diagram = table.concat(markdown.render(diagram_source, 72, "", function() end).lines, "\\n")
assert(diagram:match("Client") and diagram:match("Daemon") and not diagram:match("\`\`\`mermaid"), "installed Mermaid projection failed")
local agui = require("plurnk.agui")
local target = require("plurnk.bridge").target()
local world = "installed-nvim-composition"
local function rpc(method, params)
  local segment
  agui.rpc(target, world, method, params or {}, function(value) segment = value end)
  if not vim.wait(10000, function() return segment ~= nil end, 25) then error(method .. " timed out") end
  if segment.state ~= "complete" then error(method .. " failed: " .. vim.inspect(segment.problem)) end
  return segment.result
end
local discovery = rpc("discover")
assert(type(discovery.actions["worker.capabilities.set"].inputSchema) == "table")
rpc("worker.capabilities.set", { policy = { deny = { { runtime = "sh" } } } })
assert(rpc("worker.capabilities.get").worker.deny[1].runtime == "sh")
print("installed Neovim composition GREEN: " .. tostring(discovery.schemaVersion) .. " · Markdown · Mermaid")
pcall(function() require("plurnk.client").stop() end)
vim.cmd("qa!")
`);
    const reopenLua = join(temp, "reopen.lua");
    await writeFile(reopenLua, `
vim.opt.rtp:prepend(${JSON.stringify(installed)})
require("plurnk").setup({ host = "127.0.0.1", port = ${port} })
local agui = require("plurnk.agui")
local target = require("plurnk.bridge").target()
local world = "installed-nvim-composition"
local function rpc(method, params)
  local segment
  agui.rpc(target, world, method, params or {}, function(value) segment = value end)
  assert(vim.wait(10000, function() return segment ~= nil end, 25), method .. " timed out")
  assert(segment.state == "complete", method .. " failed: " .. vim.inspect(segment.problem))
  return segment.result
end
local workspace
for _, candidate in ipairs(rpc("workspace.list").workspaces) do
  if candidate.name == world then workspace = candidate; break end
end
assert(workspace ~= nil, "the installed client's workspace did not survive editor restart")
local worker
for _, candidate in ipairs(rpc("workspace.workers", { id = workspace.id }).workers) do
  if candidate.origin == "model" then worker = candidate; break end
end
assert(worker ~= nil, "the installed client's model worker did not survive editor restart")
local state = require("plurnk.state")
state.set_workspace_id(world, workspace.id)
state.set_active_workspace_name(world)
state.set_worker_id(world, worker.id)
local reconciled
require("plurnk.recovery").reconcile(world, {}, function(status, problem)
  assert(problem == nil, vim.inspect(problem))
  reconciled = status
end)
assert(vim.wait(10000, function() return reconciled ~= nil end, 25), "installed reconnect timed out")
assert(state.get_transport_status(world) == nil, "installed reconnect left a stale transport overlay")
assert(state.get_runtime_status(world) ~= nil, "installed reconnect did not project authoritative STATE")
assert(rpc("worker.capabilities.get").worker.deny[1].runtime == "sh", "reopened worker lost durable capability settings")
print("installed Neovim reopen GREEN: worker " .. tostring(worker.id))
pcall(function() require("plurnk.client").stop() end)
vim.cmd("qa!")
`);

    daemon = spawn(process.execPath, [join(serviceRoot, "plurnk-core/dist/service.js"), "start"], {
        cwd: serviceRoot,
        env: {
            ...process.env,
            HOME: home,
            XDG_CONFIG_HOME: join(home, ".config"),
            XDG_DATA_HOME: join(home, ".local", "share"),
            XDG_STATE_HOME: join(home, ".local", "state"),
            XDG_CACHE_HOME: join(home, ".cache"),
            PLURNK_PORT: String(port),
            PLURNK_WS_PORT: "0",
            PLURNK_SERVICE_DB_PATH: join(temp, "plurnk.db"),
            PLURNK_SERVICE_MAX_TURNS: "8",
            PLURNK_MCP_ENABLED: "[]",
            PLURNK_MODEL: "journey",
            PLURNK_MODEL_journey: "journey-fixture/plurnk-installed-journey",
            PLURNK_PROVIDERS_PROVIDER_JOURNEY_FIXTURE_NPM: "@ai-sdk/openai-compatible",
            PLURNK_PROVIDERS_PROVIDER_JOURNEY_FIXTURE_BASE_URL: fixture.baseUrl,
            PLURNK_PROVIDERS_CONTEXT_WINDOW_journey: "32768",
            PLURNK_PROVIDERS_OUTPUT_BUDGET_journey: "4096",
            PLURNK_PROVIDERS_REASONING_journey: "adaptive",
            PLURNK_PROVIDERS_RETRY_ATTEMPTS_journey: "0",
            PLURNK_PROVIDERS_FETCH_TIMEOUT_journey: "5000",
            PLURNK_PROVIDERS_OPERATION_TIMEOUT_journey: "15000",
            PLURNK_PROVIDERS_FIRST_CONTENT_TIMEOUT_journey: "5000",
            PLURNK_PROVIDERS_STREAM_IDLE_TIMEOUT_journey: "5000",
            PLURNK_PROVIDERS_CACHE_AFFINITY_journey: "0",
            PLURNK_PROVIDERS_CACHE_WRITE_POLICY_journey: "off",
        },
        stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    daemon.stdout.setEncoding("utf8");
    daemon.stderr.setEncoding("utf8");
    daemon.stdout.on("data", (chunk) => { stdout += chunk; });
    daemon.stderr.on("data", (chunk) => { stderr += chunk; });
    await new Promise((accept, reject) => {
        const timeout = setTimeout(() => reject(new Error(`service boot timeout\n${stdout}\n${stderr}`)), 30_000);
        const ready = () => {
            if (!stdout.includes(`agui=http://127.0.0.1:${port}`)) return;
            clearTimeout(timeout);
            accept();
        };
        daemon.stdout.on("data", ready);
        daemon.once("exit", (code) => {
            clearTimeout(timeout);
            reject(new Error(`built service exited ${code}\n${stdout}\n${stderr}`));
        });
    });

    const result = await run("nvim", ["--headless", "-u", "NONE", "-l", lua], {
        env: {
            ...process.env,
            HOME: home,
            XDG_CONFIG_HOME: join(home, ".config"),
            PLURNK_HOST: "127.0.0.1",
            PLURNK_PORT: String(port),
            PLURNK_NVIM_ROOT: installed,
            PATH: `${clientBin}:${process.env.PATH ?? ""}`,
        },
        maxBuffer: 16 * 1024 * 1024,
    });
    if (!`${result.stdout}\n${result.stderr}`.includes("installed Neovim composition GREEN: 1")) {
        throw new Error(`installed plugin produced no success evidence\n${result.stdout}\n${result.stderr}`);
    }
    const reopened = await run("nvim", ["--headless", "-u", "NONE", "-l", reopenLua], {
        env: {
            ...process.env,
            HOME: home,
            XDG_CONFIG_HOME: join(home, ".config"),
            PLURNK_HOST: "127.0.0.1",
            PLURNK_PORT: String(port),
            PLURNK_NVIM_ROOT: installed,
            PATH: `${clientBin}:${process.env.PATH ?? ""}`,
        },
        maxBuffer: 16 * 1024 * 1024,
    });
    if (!`${reopened.stdout}\n${reopened.stderr}`.includes("installed Neovim reopen GREEN:")) {
        throw new Error(`installed plugin did not resume its durable worker\n${reopened.stdout}\n${reopened.stderr}`);
    }
    const journey = await run("nvim", ["--headless", "-u", "NONE", "-l", join(root, "tests/installed-journey.lua")], {
        cwd: project,
        env: {
            ...process.env,
            HOME: home,
            XDG_CONFIG_HOME: join(home, ".config"),
            PLURNK_HOST: "127.0.0.1",
            PLURNK_PORT: String(port),
            PLURNK_NVIM_ROOT: installed,
            PATH: `${clientBin}:${process.env.PATH ?? ""}`,
        },
        maxBuffer: 16 * 1024 * 1024,
    });
    if (!`${journey.stdout}\n${journey.stderr}`.includes("PASS installed Neovim default journey:")) {
        throw new Error(`installed plugin did not complete its default journey\n${journey.stdout}\n${journey.stderr}`);
    }
    if (`${journey.stdout}\n${journey.stderr}`.includes("vim.schedule callback:")) {
        throw new Error(`installed plugin raised an asynchronous callback failure\n${journey.stdout}\n${journey.stderr}`);
    }
    if (fixture.requests.length !== 4) {
        throw new Error(`installed journey made ${fixture.requests.length} inference requests instead of exactly four`);
    }
    const continuedQuestion = JSON.stringify(fixture.requests[3]?.messages ?? []);
    if (!continuedQuestion.includes("typed-through-nvim") || !continuedQuestion.includes("count")) {
        throw new Error("the continued WAIT packet did not receive the native named-field answer");
    }
    const firstRequest = JSON.stringify(fixture.requests[0]?.messages ?? []);
    if (!firstRequest.includes("Create a reviewed acceptance marker.")
        || !firstRequest.includes("The final response must confirm this multiline prompt.")) {
        throw new Error("the standards-compatible provider did not receive the native multiline prompt");
    }
    process.stdout.write(result.stdout);
    process.stderr.write(result.stderr);
    process.stdout.write(reopened.stdout);
    process.stderr.write(reopened.stderr);
    process.stdout.write(journey.stdout);
    process.stderr.write(journey.stderr);
    passed = true;
} finally {
    await stop(daemon);
    if (fixture !== undefined) await fixture.close();
    if (passed) await rm(temp, { recursive: true, force: true });
    else process.stderr.write(`installed Neovim composition evidence preserved at ${temp}\n`);
}
