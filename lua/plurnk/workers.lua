-- Worker directory helpers (nvim#27): the topology projection of
-- `workspace.workers` and the conversation-name candidates for `/attach`.
-- Lifecycle glyphs for workers other than the bound one arrive with
-- plurnk-service#523; nothing is inferred from row coordinates.
local M = {}

-- Newest first (nvim#27): the child you just spawned is the one `<leader>al` enters.
local function by_created(a, b)
  if a.created_at ~= b.created_at then return (a.created_at or "") > (b.created_at or "") end
  return a.id > b.id
end

-- Model-origin workers are the attachable conversations; client and _plurnk
-- workers are the connection's and the daemon's own scratch.
function M.conversations(workers)
  local out = {}
  for _, worker in ipairs(workers or {}) do
    if worker.origin == "model" then out[#out + 1] = worker end
  end
  return out
end

-- Rows in forest order: the bound worker's tree first, roots by creation,
-- children by creation; each row carries its worker and a tree string whose
-- marker is ● for the bound worker and ○ otherwise. A worker whose parent is
-- not in the directory stands as a root.
function M.topology(workers, bound_id)
  local by_id = {}
  for _, worker in ipairs(workers) do by_id[worker.id] = worker end
  local function parent_of(worker)
    local parent = worker.parentWorkerId
    if parent ~= nil and parent ~= vim.NIL and by_id[parent] then return parent end
    return nil
  end
  local children = {}
  for _, worker in ipairs(workers) do
    local parent = parent_of(worker) or 0
    children[parent] = children[parent] or {}
    table.insert(children[parent], worker)
  end
  for _, siblings in pairs(children) do table.sort(siblings, by_created) end
  local function root_of(worker)
    local current = worker
    while parent_of(current) do current = by_id[parent_of(current)] end
    return current
  end
  local bound_root = bound_id and by_id[bound_id] and root_of(by_id[bound_id]).id or nil
  local roots = children[0] or {}
  table.sort(roots, function(a, b)
    if a.id == bound_root then return true end
    if b.id == bound_root then return false end
    return by_created(a, b)
  end)
  local rows = {}
  local function walk(worker, prefix, connector)
    local marker = worker.id == bound_id and "●" or "○"
    rows[#rows + 1] = { worker = worker, tree = prefix .. connector .. marker .. " " .. worker.name }
    local kids = children[worker.id] or {}
    local child_prefix = connector == "" and "" or (prefix .. (connector:sub(1, #"└") == "└" and "   " or "│  "))
    for index, kid in ipairs(kids) do
      walk(kid, child_prefix, index == #kids and "└─ " or "├─ ")
    end
  end
  for _, root in ipairs(roots) do walk(root, "", "") end
  return rows
end

-- {§nvim-worker-hops} — one hop over the tree (plurnk-service#523): "parent" climbs, "enter"
-- descends to the newest child, "next"/"prev" walk siblings (older/newer) and wrap. Places are
-- conversations and their descendants; the daemon's and a connection's scratch workers are not.
-- Returns the target worker, or nil and the reason nothing moved.
local function by_recency(a, b)
  if a.created_at ~= b.created_at then return (a.created_at or "") > (b.created_at or "") end
  return a.id > b.id
end

local function index_directory(workers)
  local by_id = {}
  for _, worker in ipairs(workers) do by_id[worker.id] = worker end
  local function parent_of(worker)
    local parent = worker.parentWorkerId
    if parent ~= nil and parent ~= vim.NIL and by_id[parent] then return by_id[parent] end
    return nil
  end
  return by_id, parent_of
end

local function siblings_of(workers, current, parent_of)
  local parent = parent_of(current)
  local out = {}
  for _, worker in ipairs(workers) do
    local same_parent = parent_of(worker)
    if (worker.origin == "model" or worker.id == current.id)
      and ((same_parent and same_parent.id) == (parent and parent.id)) then
      out[#out + 1] = worker
    end
  end
  table.sort(out, by_recency)
  return out
end

function M.hop(workers, bound_id, direction)
  local _, parent_of = index_directory(workers)
  local current
  for _, worker in ipairs(workers) do if worker.id == bound_id then current = worker end end
  if not current then return nil, "no bound worker yet" end
  if direction == "parent" then
    local parent = parent_of(current)
    if not parent then return nil, "at the root: no parent" end
    return parent
  end
  if direction == "enter" then
    local children = {}
    for _, worker in ipairs(workers) do
      local parent = parent_of(worker)
      if worker.origin == "model" and parent and parent.id == current.id then children[#children + 1] = worker end
    end
    table.sort(children, by_recency)
    if #children == 0 then return nil, "no children" end
    return children[1]
  end
  local siblings = siblings_of(workers, current, parent_of)
  if #siblings < 2 then return nil, "no siblings" end
  local index
  for i, worker in ipairs(siblings) do if worker.id == current.id then index = i end end
  local step = direction == "next" and 1 or -1
  return siblings[((index - 1 + step) % #siblings) + 1]
end

-- The lineage from the tree root to the bound worker. `~` is a display cursor,
-- not a resource alias: `/~main`, `/main/fork-1/~recheck`, or `/~` before binding.
function M.path(workers, bound_id)
  local _, parent_of = index_directory(workers)
  local current
  for _, worker in ipairs(workers) do if worker.id == bound_id then current = worker end end
  if not current then return "/~" end
  local segments = { "~" .. current.name }
  local parent = parent_of(current)
  while parent do
    current = parent
    table.insert(segments, 1, current.name)
    parent = parent_of(current)
  end
  return "/" .. table.concat(segments, "/")
end

-- The bound worker's place among its siblings, newest first, or nil when it has none.
function M.position(workers, bound_id)
  local _, parent_of = index_directory(workers)
  local current
  for _, worker in ipairs(workers) do if worker.id == bound_id then current = worker end end
  if not current then return nil end
  local siblings = siblings_of(workers, current, parent_of)
  if #siblings < 2 then return nil end
  for i, worker in ipairs(siblings) do if worker.id == current.id then return { index = i, count = #siblings } end end
  return nil
end

-- Conversation names for completion: the cached directory, refreshed once
-- when empty (the same demand-loading the model alias completion uses).
function M.name_candidates(prefix)
  local state = require("plurnk.state")
  local workspace = require("plurnk.workspace_context").active()
  if not workspace then return {} end
  local names = state.get_worker_names(workspace)
  if #names == 0 then
    local workspace_id = state.get_workspace_id(workspace)
    if workspace_id then
      pcall(function()
        require("plurnk.client").send("workspace.workers", { id = workspace_id }, false, function(result)
          if type(result) == "table" and type(result.workers) == "table" then
            M.remember_names(workspace, result.workers)
          end
        end)
      end)
    end
  end
  local out = {}
  for _, name in ipairs(names) do
    if vim.startswith(name, prefix or "") then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

function M.remember_names(workspace, workers)
  local names = {}
  for _, worker in ipairs(M.conversations(workers)) do names[#names + 1] = worker.name end
  local state = require("plurnk.state")
  state.set_worker_names(workspace, names)
  state.set_worker_directory(workspace, workers)
end

-- The winbar's position segments from the cached directory: `[~/fork-1/recheck]` and `(2/3)`.
function M.position_label(workspace)
  local state = require("plurnk.state")
  local rows = state.get_worker_directory(workspace)
  local bound = state.get_worker_id(workspace)
  local label = "[" .. M.path(rows, bound) .. "]"
  local position = M.position(rows, bound)
  if position then label = label .. " (" .. position.index .. "/" .. position.count .. ")" end
  return label
end

return M
