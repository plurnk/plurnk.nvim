import { spawn, execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = resolve(import.meta.dirname, "..");
const serviceRoot = resolve(process.env.PLURNK_SERVICE_DIR ?? join(root, "../plurnk-service"));
const clientRoot = resolve(process.env.PLURNK_CLIENT_DIR ?? join(root, "../plurnk"));
const temp = await mkdtemp(join(tmpdir(), "plurnk-nvim-composition-"));
const installed = join(temp, "site", "pack", "plurnk", "start", "plurnk.nvim");
const clientBin = join(temp, "bin");
const home = join(temp, "home");
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
    const lua = join(temp, "composition.lua");
    await writeFile(lua, `
vim.opt.rtp:prepend(${JSON.stringify(installed)})
require("plurnk").setup({ host = "127.0.0.1", port = ${port} })
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
assert(type(discovery.actions["worker.settings.set"].inputSchema) == "table")
rpc("worker.settings.set", { settings = { requestUserInput = true } })
assert(rpc("worker.settings.get").requestUserInput == true)
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
assert(rpc("worker.settings.get").requestUserInput == true, "reopened worker lost durable settings")
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
            PLURNK_SERVICE_EMBED_DISABLE: "1",
            PLURNK_MCP_ENABLED: "[]",
            PLURNK_MODEL: "",
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
    process.stdout.write(result.stdout);
    process.stderr.write(result.stderr);
    process.stdout.write(reopened.stdout);
    process.stderr.write(reopened.stderr);
    passed = true;
} finally {
    await stop(daemon);
    if (passed) await rm(temp, { recursive: true, force: true });
    else process.stderr.write(`installed Neovim composition evidence preserved at ${temp}\n`);
}
