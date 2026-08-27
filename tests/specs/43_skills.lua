-- Agent Skills management is a thin :AI/ projection over the Worker's common
-- Functionality actions: no package manager, no registry, no local copy.
local NAME = "43_skills"
local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(root .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent, notices = {}, {}
  local results = {
    ["worker.skills.list"] = {
      definitions = {
        { alias = "grep", origin = "service", state = "active", definition = { name = "grep", scope = "project" }, detail = { scope = "project", description = "Find text" } },
        { alias = "review", origin = "worker", state = "disabled", definition = { name = "review", scope = "global", source = "acme/kit" } },
        { alias = "bad", origin = "service", state = "unavailable", definition = { name = "bad", scope = "global" }, problem = { detail = "requires YAML frontmatter" } },
      },
    },
    ["worker.skills.discover"] = {
      candidates = { { alias = "changelog", summary = "1200 installs", definition = { name = "changelog", scope = "project", source = "acme/kit" }, provenance = { kind = "registry", source = "acme/kit", reference = "https://skills.sh/acme/kit/changelog" } } },
    },
    ["worker.skills.add"] = { status = 201, alias = "changelog", definition = { alias = "changelog", state = "active" } },
    ["worker.skills.enable"] = { status = 200, alias = "changelog", definition = { alias = "changelog", state = "active" } },
    ["worker.skills.disable"] = { status = 200, alias = "changelog", definition = { alias = "changelog", state = "disabled" } },
    ["worker.skills.remove"] = { status = 200, alias = "changelog", removed = true },
  }
  local client = require("plurnk.client")
  client.check_daemon_once = function() end
  client.notify = function(message) notices[#notices + 1] = message end
  client.send = function(method, params, _, callback)
    sent[#sent + 1] = { method = method, params = params }
    if callback then callback(results[method]) end
  end
  local state = require("plurnk.state")
  state.set_active_workspace_name("skills-test")
  state.set_workspace_id("skills-test", 1)

  local commands = require("plurnk.language")
  local ai = commands.run

  ai({ args = "/skills", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.skills.list", params = {} }), ":AI/skills lists the Worker's skills")
  H.assert_match(notices[#notices], "grep%s+active%s+project%s+Find text", "list renders active service skills with their description")
  H.assert_match(notices[#notices], "review%s+disabled%s+global%s+acme/kit%s+%(worker%)", "list renders disabled Worker-owned skills with their source")
  H.assert_match(notices[#notices], "bad%s+unavailable%s+global%s+— requires YAML frontmatter", "list renders unavailable skills with their problem")

  sent, notices = {}, {}
  ai({ args = "/skills discover react changelog", range = 0 })
  ai({ args = "/skills discover acme/kit", range = 0 })
  ai({ args = "/skills discover ./vendor/skills", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.skills.discover", params = { query = "react changelog" } }), "multi-word terms are registry queries")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "worker.skills.discover", params = { source = "acme/kit" } }), "a package reference is a source")
  H.assert_truthy(vim.deep_equal(sent[3], { method = "worker.skills.discover", params = { source = "./vendor/skills" } }), "a path is a source")
  H.assert_match(notices[#notices], "changelog%s+candidate%s+acme/kit%s+1200 installs%s+https://skills%.sh/acme/kit/changelog", "discover renders inert candidates")

  sent, notices = {}, {}
  ai({ args = "/skills add changelog acme/kit", range = 0 })
  ai({ args = "/skills add changelog acme/kit --global", range = 0 })
  ai({ args = "/skills enable changelog", range = 0 })
  ai({ args = "/skills disable changelog", range = 0 })
  ai({ args = "/skills remove changelog", range = 0 })
  H.assert_truthy(vim.deep_equal(sent[1], { method = "worker.skills.add", params = { alias = "changelog", definition = { name = "changelog", scope = "project", source = "acme/kit" } } }), "add composes a project-scope definition")
  H.assert_truthy(vim.deep_equal(sent[2], { method = "worker.skills.add", params = { alias = "changelog", definition = { name = "changelog", scope = "global", source = "acme/kit" } } }), "--global selects the global scope")
  H.assert_truthy(vim.deep_equal(sent[3], { method = "worker.skills.enable", params = { alias = "changelog" } }), "enable action shape")
  H.assert_truthy(vim.deep_equal(sent[4], { method = "worker.skills.disable", params = { alias = "changelog" } }), "disable action shape")
  H.assert_truthy(vim.deep_equal(sent[5], { method = "worker.skills.remove", params = { alias = "changelog" } }), "remove action shape")
  H.assert_match(notices[1], "added: changelog %(active%)", "add renders the daemon state")
  H.assert_match(notices[3], "enabled: changelog %(active%)", "enable renders the daemon state")
  H.assert_match(notices[4], "disabled: changelog %(disabled%)", "disable renders the daemon state")
  H.assert_match(notices[5], "removed: changelog", "remove confirms")

  results["worker.skills.add"] = { status = 201, alias = "ghost", definition = { alias = "ghost", state = "unavailable", problem = { detail = "could not be installed" } } }
  sent, notices = {}, {}
  ai({ args = "/skills add ghost acme/kit", range = 0 })
  H.assert_match(notices[#notices], "added: ghost %(unavailable%)%s+— could not be installed", "an unavailable outcome renders its Problem")

  sent, notices = {}, {}
  for _, input in ipairs({
    "/skills add",
    "/skills add one",
    "/skills add one two three",
    "/skills discover",
    "/skills enable",
    "/skills disable a b",
    "/skills remove",
    "/skills update",
    "/skills add echo 'unterminated",
  }) do
    ai({ args = input, range = 0 })
  end
  H.assert_eq(#sent, 0, "malformed client command shapes never dispatch")
  H.assert_eq(#notices, 9, "each malformed command has one usage diagnosis")

  H.assert_eq(table.concat(commands.complete("", "AI /skills di", 0), ","), "disable,discover", "skills verbs complete")
  print(NAME .. " ok")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
