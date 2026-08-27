-- File members management is a thin :AI/ projection over the Worker's common
-- Functionality actions — the same lifecycle as /mcp, /skills, and /agents.
-- The client composes one exact { glob } definition and renders the daemon's
-- verdicts; against the live daemon an added glob makes an untracked file a
-- member the model can READ, a `!glob` excludes it, and the gutter follows.
local NAME = "23_membership"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent, notices = {}, {}
  local results = {
    ["worker.members.list"] = {
      definitions = {
        { alias = "docs", origin = "service", state = "active", definition = { glob = "docs/**", provenance = { kind = "service-configuration", source = "PLURNK_MEMBERS_DOCS" } }, detail = { effect = "include", pattern = "docs/**", matched = 12, files = { "docs/a.md" }, ignored = 3 } },
        { alias = "no-tokenizer", origin = "worker", state = "active", definition = { glob = "!**/tokenizer.json" }, detail = { effect = "exclude", pattern = "**/tokenizer.json", matched = 4, files = { "a/tokenizer.json" }, ignored = 0 } },
        { alias = "note", origin = "worker", state = "active", definition = { glob = "note.md" }, detail = { effect = "include", pattern = "note.md", matched = 1, files = { "note.md" }, ignored = 0 } },
        { alias = "drafts", origin = "worker", state = "disabled", definition = { glob = "drafts/*.md" } },
        { alias = "bad", origin = "worker", state = "unavailable", definition = { glob = "../x/**" }, problem = { detail = "outside the project root" } },
      },
    },
    ["worker.members.discover"] = {
      candidates = { { alias = "readme-md", definition = { glob = "README.md" }, provenance = { kind = "member", source = "README.md" }, summary = "member — tracked by git" } },
    },
    ["worker.members.add"] = { status = 201, alias = "docs", definition = { alias = "docs", state = "active" } },
    ["worker.members.enable"] = { status = 200, alias = "docs", definition = { alias = "docs", state = "active" } },
    ["worker.members.disable"] = { status = 200, alias = "docs", definition = { alias = "docs", state = "disabled" } },
    ["worker.members.remove"] = { status = 200, alias = "docs", removed = true },
  }
  local client = require("plurnk.client")
  local real_send, real_check = client.send, client.check_daemon_once
  client.check_daemon_once = function() end
  client.notify = function(message) notices[#notices + 1] = message end
  client.send = function(method, params, _, callback)
    sent[#sent + 1] = { method = method, params = params }
    if callback then callback(results[method]) end
  end
  local state = require("plurnk.state")
  state.set_active_workspace_name("members-test")
  state.set_workspace_id("members-test", 1)
  state.set_worker_id("members-test", 7)
  state.set_project_path("/proj")

  local commands = require("plurnk.language")
  local ai = commands.run

  ai({ args = "/members", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.members.list", params = {} }), ":AI/members lists the Worker's file members")
  H.assert_match(notices[#notices], "docs%s+active%s+include docs/%*%* → 12 files %(3 ignored%)%s+%(service%)", "list renders a service inclusion with what it resolved to")
  H.assert_match(notices[#notices], "no%-tokenizer%s+active%s+exclude %*%*/tokenizer%.json → 4 members", "list renders an exclusion with the members it removed")
  H.assert_match(notices[#notices], "note%s+active%s+include note%.md → 1 file\n", "list counts one file singularly")
  H.assert_match(notices[#notices], "drafts%s+disabled%s+include drafts/%*%.md\n", "list renders a disabled definition without a resolution")
  H.assert_match(notices[#notices], "bad%s+unavailable%s+include %.%./x/%*%*%s+— outside the project root", "list renders an unavailable definition with its problem")

  sent, notices = {}, {}
  vim.cmd("PlurnkMembers")
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.members.list", params = {} }), ":PlurnkMembers is the native spelling of :AI/members")
  results["worker.members.list"] = { definitions = {} }
  sent, notices = {}, {}
  ai({ args = "/members", range = 0 })
  H.assert_match(notices[#notices], "file members: none", "an empty list says so")

  sent, notices = {}, {}
  ai({ args = "/members discover README.md", range = 0 })
  ai({ args = "/members discover docs/**", range = 0 })
  ai({ args = "/members discover !**/tokenizer.json", range = 0 })
  vim.cmd("PlurnkMembers discover !**/tokenizer.json")
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.members.discover", params = { query = "README.md" } }), "a path is the discover query")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "worker.members.discover", params = { query = "docs/**" } }), "a glob is the discover query")
  H.assert_truthy(vim.deep_equal(sent[3], { method = "worker.members.discover", params = { query = "!**/tokenizer.json" } }), "a `!` glob passes through verbatim")
  H.assert_truthy(vim.deep_equal(sent[4], sent[3]), "the native command passes a `!` glob through verbatim")
  H.assert_match(notices[#notices], "readme%-md%s+member%s+README%.md%s+member — tracked by git", "discover renders the daemon's verdict")

  results["worker.members.discover"] = {
    candidates = { { alias = "docs", definition = { glob = "docs/**" }, provenance = { kind = "preview", source = "docs/**" }, summary = "would include 2 files (1 already members, 0 ignored): docs/a.md, docs/b.md" } },
  }
  sent, notices = {}, {}
  ai({ args = "/members discover docs/**", range = 0 })
  H.assert_match(notices[#notices], "docs%s+preview%s+docs/%*%*%s+would include 2 files", "discover renders a glob preview")

  -- The vim move: a bare discover asks about the current file buffer by its
  -- project-relative path; a non-file buffer has nothing to ask about.
  sent, notices = {}, {}
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "/proj/src/widget.lua")
  vim.api.nvim_set_current_buf(buf)
  ai({ args = "/members discover", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.members.discover", params = { query = "src/widget.lua" } }), "a bare discover asks about the current file")
  sent, notices = {}, {}
  local scratch = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(scratch, "plurnk-nvim://workspace/x")
  vim.api.nvim_set_current_buf(scratch)
  ai({ args = "/members discover", range = 0 })
  H.assert_eq(#sent, 0, "a bare discover in a non-file buffer sends nothing")
  H.assert_match(notices[#notices], "usage: :AI/members discover %[path|glob%]", "a bare discover without a file diagnoses usage")
  vim.api.nvim_set_current_buf(buf)

  sent, notices = {}, {}
  ai({ args = "/members add docs docs/**", range = 0 })
  ai({ args = "/members add no-tokenizer !**/tokenizer.json", range = 0 })
  ai({ args = "/members enable docs", range = 0 })
  ai({ args = "/members disable docs", range = 0 })
  ai({ args = "/members remove docs", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.members.add", params = { alias = "docs", definition = { glob = "docs/**" } } }), "add composes one exact { glob } definition")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "worker.members.add", params = { alias = "no-tokenizer", definition = { glob = "!**/tokenizer.json" } } }), "add passes a `!` glob through verbatim")
  H.assert_truthy(vim.deep_equal(sent[3], { method = "worker.members.enable", params = { alias = "docs" } }), "enable action shape")
  H.assert_truthy(vim.deep_equal(sent[4], { method = "worker.members.disable", params = { alias = "docs" } }), "disable action shape")
  H.assert_truthy(vim.deep_equal(sent[5], { method = "worker.members.remove", params = { alias = "docs" } }), "remove action shape")
  H.assert_match(notices[1], "added: docs %(active%)", "add renders the daemon state")
  H.assert_match(notices[3], "enabled: docs %(active%)", "enable renders the daemon state")
  H.assert_match(notices[4], "disabled: docs %(disabled%)", "disable renders the daemon state")
  H.assert_match(notices[5], "removed: docs", "remove confirms")

  results["worker.members.add"] = { status = 201, alias = "ghost", definition = { alias = "ghost", state = "unavailable", problem = { detail = "the workspace has no project root" } } }
  sent, notices = {}, {}
  ai({ args = "/members add ghost docs/**", range = 0 })
  H.assert_match(notices[#notices], "added: ghost %(unavailable%)%s+— the workspace has no project root", "an unavailable outcome renders its Problem")

  sent, notices = {}, {}
  for _, input in ipairs({
    "/members add",
    "/members add one",
    "/members enable",
    "/members disable a b",
    "/members remove",
    "/members update",
    "/members add echo 'unterminated",
  }) do
    ai({ args = input, range = 0 })
  end
  H.assert_eq(#sent, 0, "malformed client command shapes never dispatch")
  H.assert_eq(#notices, 7, "each malformed command has one usage diagnosis")

  H.assert_eq(table.concat(commands.complete("", "AI /members di", 0), ","), "disable,discover", "members verbs complete")
  results["worker.members.list"] = { definitions = { { alias = "docs", state = "active", definition = { glob = "docs/**" } }, { alias = "drafts", state = "disabled", definition = { glob = "drafts/*.md" } } } }
  local aliases = commands.complete("", "AI /members enable d", 0)
  if #aliases == 0 then aliases = commands.complete("", "AI /members enable d", 0) end
  H.assert_eq(table.concat(aliases, ","), "docs,drafts", "an alias-taking members command lazily completes current definitions")
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "# note" }, path)
  local prefix = path:sub(1, #path - 2)
  H.assert_truthy(#commands.complete("", "AI /members discover " .. prefix, 0) > 0, "the discover position completes local paths")
  H.assert_truthy(#commands.complete("", "AI /members add note " .. prefix, 0) > 0, "the add glob position completes local paths")
  H.assert_truthy(#vim.fn.getcompletion("PlurnkMembers add note " .. prefix, "cmdline") > 0, "the native command completes the same positions")
  vim.fn.delete(path)

  -- Against the live daemon: git-tracked files are members on their own; an
  -- added glob makes an untracked file a member the model can READ; a `!glob`
  -- excludes it; disable, enable, and remove follow.
  client.send, client.check_daemon_once = real_send, real_check
  local project = vim.fn.tempname()
  vim.fn.mkdir(project .. "/docs", "p")
  vim.fn.writefile({ "# tracked" }, project .. "/README.md")
  vim.fn.writefile({ "# loose guide" }, project .. "/docs/guide.md")
  local function git(...)
    local run = vim.system({
      "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", ...,
    }, { cwd = project, env = { HOME = project, GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1" }, text = true }):wait()
    H.assert_eq(run.code, 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(run.stderr))
  end
  git("init", "-q")
  git("add", "README.md")
  git("commit", "-q", "--no-verify", "-m", "chore: seed")

  local workspace = "nvim-members-" .. tostring(vim.uv.hrtime())
  local created = H.call("workspace.create", { name = workspace, projectRoot = project })
  state.set_active_workspace_name(workspace)
  state.set_workspace_id(workspace, created.id)
  state.set_project_path(project)
  local function verdict(file)
    return H.call("worker.members.discover", { query = file }, 20000).candidates[1].provenance.kind
  end
  local function settle(input, pattern, label)
    notices = {}
    ai({ args = input, range = 0 })
    H.wait_for(function() return #notices > 0 end, 20000, label)
    H.assert_match(notices[#notices], pattern, label)
  end
  -- The daemon materializes a new member's content after the add settles
  -- (its workspace warm), so a READ is awaited within a bound, quietly.
  local function look(file)
    local deadline = vim.uv.hrtime() + 20 * 1000 * 1000 * 1000
    while vim.uv.hrtime() < deadline do
      local settled, outcome = false, nil
      client.send("op.look", { text = "## LOOK0 (file:///" .. file .. ")" }, false, function(result)
        outcome, settled = result, true
      end, { quiet = true })
      H.wait_for(function() return settled end, 20000, "look " .. file)
      if type(outcome) == "table" and outcome.status == 200 then return outcome end
      vim.wait(200)
    end
    error("the included file never became readable: " .. file)
  end
  H.assert_eq(verdict("README.md"), "member", "a git-tracked file is a member on its own")
  H.assert_eq(verdict("docs/guide.md"), "candidate", "an untracked file is dark until a definition includes it")

  settle("/members add guide docs/**", "added: guide %(active%)", "the live add is active")
  H.assert_eq(verdict("docs/guide.md"), "member", "the added glob includes the untracked file")
  local read = look("docs/guide.md")
  H.assert_match(read.content, "# loose guide", "the model reads the included file's content")
  settle("/members", "guide%s+active%s+include docs/%*%* → 1 file", "the live list reports what the glob resolved to")

  settle("/members add no-guide !docs/guide.md", "added: no%-guide %(active%)", "the live exclusion is active")
  H.assert_eq(verdict("docs/guide.md"), "excluded", "an exclusion wins over the inclusion")

  settle("/members disable no-guide", "disabled: no%-guide %(disabled%)", "the live disable renders the daemon state")
  H.assert_eq(verdict("docs/guide.md"), "member", "a disabled exclusion no longer applies")
  settle("/members enable no-guide", "enabled: no%-guide %(active%)", "the live enable renders the daemon state")
  H.assert_eq(verdict("docs/guide.md"), "excluded", "an enabled exclusion applies again")
  settle("/members remove no-guide", "removed: no%-guide", "the live remove confirms")
  H.assert_eq(verdict("docs/guide.md"), "member", "removing the exclusion restores the member")

  vim.cmd("bwipeout!")
  vim.fn.delete(project, "rf")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
