-- The :AI command language has one inventory for routing, help, and bounded
-- contextual completion. Functionality aliases are fetched only where an
-- existing alias is syntactically required.
local NAME = "53_command_discovery"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local sent, echoes = {}, {}
  local client = require("plurnk.client")
  client.send = function(method, params, _, callback)
    sent[#sent + 1] = { method = method, params = params }
    if method == "worker.mcp.list" and callback then
      callback({
        definitions = {
          { alias = "brave", state = "active", definition = {} },
          { alias = "browser", state = "disabled", definition = {} },
          { alias = "gitea", state = "active", definition = {} },
        },
      })
    elseif method == "worker.skills.list" and callback then
      callback(nil, { detail = "unavailable" })
    end
  end
  client.notify = function() end
  vim.api.nvim_echo = function(chunks)
    echoes[#echoes + 1] = chunks[1][1]
  end

  local state = require("plurnk.state")
  state.set_active_workspace_name("discovery-test")
  state.set_workspace_id("discovery-test", 1)
  state.set_worker_id("discovery-test", 7)

  local language = require("plurnk.language")
  local expected = table.concat({
    "/accept", "/agents", "/cancel", "/child", "/clear", "/drop",
    "/edit", "/help", "/hide", "/log", "/mcp", "/members", "/model",
    "/models", "/next", "/open", "/pick", "/ping", "/prev",
    "/reasoning", "/reconnect", "/reject", "/rename", "/script",
    "/skills", "/stop", "/view", "/worker", "/workers", "/workspace",
    "/workspaces", "/yolo",
  }, ",")
  H.assert_eq(table.concat(language.complete("", "AI /", 0), ","), expected,
    "root completion is the complete supported :AI/ inventory")

  H.assert_eq(table.concat(language.complete("", "AI /help re", 0), ","),
    "reasoning,reconnect,reject,rename",
    "/help completes command names from the same inventory")
  H.assert_eq(table.concat(language.complete("", "AI /mcp di", 0), ","),
    "disable,discover", "Functionality lifecycle syntax completes")

  local aliases = language.complete("", "AI /mcp enable br", 0)
  if #aliases == 0 then aliases = language.complete("", "AI /mcp enable br", 0) end
  H.assert_eq(table.concat(aliases, ","), "brave,browser",
    "an alias-taking MCP command lazily completes current definitions")
  H.assert_eq(sent[1].method, "worker.mcp.list",
    "alias completion demand-loads only its Functionality family")
  H.assert_eq(#sent, 1, "cached alias completion does not repeat catalog reads")

  local before = #sent
  H.assert_eq(#language.complete("", "AI /skills enable any", 0), 0,
    "a failed alias lookup produces no completion")
  H.assert_eq(#sent, before + 1, "the failed lookup remains one bounded read")

  local path = vim.fn.tempname() .. ".plk"
  vim.fn.writefile({ "# PLAN0" }, path)
  local prefix = path:sub(1, #path - 2)
  H.assert_truthy(#language.complete("", "AI /script " .. prefix, 0) > 0,
    "path-consuming commands use native file completion")
  vim.fn.delete(path)

  language.run({ args = "/help mcp", range = 0 })
  H.assert_eq(#sent, before + 1, "contextual help performs no daemon request")
  H.assert_match(echoes[#echoes], ":AI/mcp enable <alias>",
    "contextual help includes exact nested usage")
  H.assert_match(echoes[#echoes], "Enable or specialize a current MCP server",
    "contextual help includes the nested action's purpose")

  local root = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
  local readme = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
  local helpdoc = table.concat(vim.fn.readfile(root .. "/doc/plurnk.txt"), "\n")
  H.assert_match(readme, ":AI/help {verb}", "README points users at contextual command guidance")
  H.assert_match(helpdoc, ":AI/help {verb}", "help doc points users at contextual command guidance")
  H.assert_match(readme, "deliberate editor controls", "README names the native command divergence")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
