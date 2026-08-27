-- Durable worker generation policy and its lazy model catalog.

local M = {}

local function normalize(args)
  local raw = type(args) == "table" and args.args or args
  return tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function alias_matches(alias, search)
  if search == "" then return true end
  local haystack = table.concat({ alias.alias or "", alias.provider or "", alias.model or "" }, " "):lower()
  return haystack:find(search:lower(), 1, true) ~= nil
end

function M.persist_picked_policies(client, workspace, on_done)
  local state = require("plurnk.state")
  local model = client.consume_selected_model_selector()
  local child = client.consume_selected_child_selector()
  local reasoning = client.consume_selected_reasoning_policy()

  local function restore()
    if model ~= nil then state.set_selected_model_selector(model) end
    if child ~= nil then state.set_selected_child_selector(child) end
    if reasoning ~= nil then state.set_selected_reasoning_policy(reasoning) end
  end

  local function refuse(label)
    restore()
    client.notify(label .. " was not persisted; the prompt was not submitted", vim.log.levels.ERROR)
  end

  local steps = {}
  if model ~= nil then
    steps[#steps + 1] = function(next_step)
      client.send("worker.model.set", { selector = model }, false, function(result, problem)
        if problem ~= nil then refuse("Model selection"); return end
        local resolved = state.model_route_selector(result)
        if resolved == nil then refuse("Model selection"); return end
        state.set_model_selector(workspace, resolved)
        next_step()
      end)
    end
  end
  if child ~= nil then
    steps[#steps + 1] = function(next_step)
      client.send("worker.child.set", {
        selector = child == "inherit" and vim.NIL or child,
      }, false, function(result, problem)
        if problem ~= nil then refuse("Child model selection"); return end
        if child == "inherit" then
          state.set_child_selector(workspace, "inherit")
        else
          local resolved = state.model_route_selector(result)
          if resolved == nil then refuse("Child model selection"); return end
          state.set_child_selector(workspace, resolved)
        end
        next_step()
      end)
    end
  end
  if reasoning ~= nil then
    steps[#steps + 1] = function(next_step)
      client.send("worker.reasoning.set", { policy = reasoning }, false, function(result, problem)
        if problem ~= nil or type(result) ~= "table" then
          refuse("Reasoning policy")
          return
        end
        state.set_reasoning(workspace, result)
        next_step()
      end)
    end
  end

  local index = 0
  local function advance()
    index = index + 1
    local step = steps[index]
    if step then step(advance)
    elseif on_done then on_done() end
  end
  advance()
end

function M.hydrate(workspace_name)
  local client = require("plurnk.client")
  client.send("worker.model.get", {}, false, function(result)
    if type(result) ~= "table" then return end
    local state = require("plurnk.state")
    state.set_model_route(workspace_name, result.model)
    if type(result.spawnModel) == "table" then
      state.set_child_route(workspace_name, result.spawnModel)
    elseif result.spawnModel == nil then
      state.set_child_selector(workspace_name, "inherit")
    end
    pcall(vim.cmd, "redrawstatus!")
  end)
  client.send("worker.reasoning.get", {}, false, function(result)
    if type(result) ~= "table" then return end
    require("plurnk.state").set_reasoning(workspace_name, result)
    require("plurnk.worker_tab").refresh_winbar(workspace_name)
  end)
end

function M.models(args)
  local client = require("plurnk.client")
  local state = require("plurnk.state")
  local search = normalize(args)

  local function select_page(offset, aliases)
    local query = { offset = offset, limit = 50 }
    if search ~= "" then query.search = search end
    client.send("models.list", query, false, function(page)
      if type(page) ~= "table" or type(page.items) ~= "table" then return end
      local choices = {}
      if offset == 0 then
        for _, alias in ipairs(aliases) do
          if alias_matches(alias, search) then
            choices[#choices + 1] = {
              selector = alias.alias,
              label = string.format(
                "alias  %s%s  %s/%s",
                alias.alias,
                alias.active and " *" or "",
                alias.provider,
                alias.model),
            }
          end
        end
      end
      for _, model in ipairs(page.items) do
        choices[#choices + 1] = {
          selector = model.selector,
          label = string.format("model  %s  %s", model.selector, model.modelName or model.model),
        }
      end
      if type(page.nextOffset) == "number" then
        choices[#choices + 1] = {
          next_offset = page.nextOffset,
          label = string.format("more…  %d of %d", offset + #page.items, tonumber(page.total) or 0),
        }
      end
      if #choices == 0 then
        client.notify(
          search == "" and "No configured models" or ("No configured models match: " .. search),
          vim.log.levels.INFO)
        return
      end
      vim.ui.select(choices, {
        prompt = search == "" and "Plurnk model" or ("Plurnk model: " .. search),
        format_item = function(choice) return choice.label end,
      }, function(choice)
        if not choice then return end
        if choice.next_offset then select_page(choice.next_offset, aliases); return end
        M.set_model(choice.selector)
      end)
    end)
  end

  client.send("providers.list", {}, false, function(result)
    local aliases = type(result) == "table"
      and type(result.aliases) == "table"
      and result.aliases
      or {}
    state.set_available_aliases(aliases)
    select_page(0, aliases)
  end)
end

function M.set_model(args)
  local selector = normalize(args)
  if selector == "" then M.models(); return end
  local state = require("plurnk.state")
  local client = require("plurnk.client")
  local workspace = require("plurnk.workspace_context").active()
  if not workspace then
    state.set_selected_model_selector(selector)
    client.notify("Model: " .. selector .. " (applies on workspace create)", vim.log.levels.INFO)
    return
  end
  client.send("worker.model.set", { selector = selector }, false, function(result, problem)
    if problem ~= nil then return end
    local resolved = state.model_route_selector(result)
    if resolved == nil then
      client.notify("Model set failed: " .. selector, vim.log.levels.ERROR)
      return
    end
    state.set_model_selector(workspace, resolved)
    client.notify("Model: " .. resolved, vim.log.levels.INFO)
    client.send("worker.reasoning.get", {}, false, function(reasoning)
      if type(reasoning) == "table" then state.set_reasoning(workspace, reasoning) end
      require("plurnk.worker_tab").refresh_winbar(workspace)
    end)
    pcall(vim.cmd, "redrawstatus!")
  end)
end

function M.set_reasoning(args)
  local policy = normalize(args)
  local state = require("plurnk.state")
  local client = require("plurnk.client")
  local workspace = require("plurnk.workspace_context").active()
  if not workspace then
    if policy == "" then
      client.notify("No active workspace", vim.log.levels.WARN)
      return
    end
    state.set_selected_reasoning_policy(policy)
    client.notify("Reasoning: " .. policy .. " (applies on workspace create)", vim.log.levels.INFO)
    return
  end
  local method = policy == "" and "worker.reasoning.get" or "worker.reasoning.set"
  local params = policy == "" and {} or { policy = policy }
  client.send(method, params, false, function(result, problem)
    if problem ~= nil or type(result) ~= "table" then return end
    state.set_reasoning(workspace, result)
    local supported = type(result.supportedPolicies) == "table"
      and table.concat(result.supportedPolicies, ", ")
      or "none"
    client.notify(
      "Reasoning: " .. tostring(result.policy or "unavailable") .. " (supported: " .. supported .. ")",
      vim.log.levels.INFO)
    require("plurnk.worker_tab").refresh_winbar(workspace)
  end)
end

function M.set_child(args)
  local selector = normalize(args)
  local state = require("plurnk.state")
  local client = require("plurnk.client")
  local workspace = require("plurnk.workspace_context").active()
  if selector == "" then
    local current = (workspace and state.get_child_selector(workspace)) or "inherit"
    client.notify("Child model: " .. current, vim.log.levels.INFO)
    return
  end
  if not workspace then
    state.set_selected_child_selector(selector)
    client.notify("Child model: " .. selector .. " (applies on workspace create)", vim.log.levels.INFO)
    return
  end
  client.send("worker.child.set", {
    selector = selector == "inherit" and vim.NIL or selector,
  }, false, function(result, problem)
    if problem ~= nil then return end
    local resolved = state.model_route_selector(result)
    if resolved ~= nil then
      state.set_child_selector(workspace, resolved)
    elseif selector == "inherit" then
      state.set_child_selector(workspace, "inherit")
    end
    client.notify("Child model: " .. (resolved or selector), vim.log.levels.INFO)
  end)
end

return M
