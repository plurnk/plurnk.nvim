-- The lockstep, ported from plurnk/plurnk-agui: every SPEC.md {§nvim-*} promise is
-- cited by a [§nvim-*] marker in a spec, every citation resolves to a live anchor,
-- and every §nvim-* ref in lua/ comments resolves. Doctrine that the suite enforces
-- survives any steward. Pure fs scan; no daemon.
local NAME = "38_lockstep"
local ROOT = os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim"
local H = dofile(ROOT .. "/tests/helpers.lua")
H.setup()

local function read(path)
  local f = assert(io.open(path, "r"), "unreadable: " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

local function scan_dir(dir, pattern, into)
  for _, p in ipairs(vim.fn.globpath(dir, pattern, false, true)) do
    into[#into + 1] = p
  end
end

local ok, err = pcall(function()
  local spec = read(ROOT .. "/SPEC.md")
  local anchors = {}
  for a in spec:gmatch("{§(nvim%-[%l%d%-]+)}") do anchors[a] = true end
  H.assert_truthy(next(anchors) ~= nil, "SPEC carries {§nvim-*} anchors")

  local files = {}
  scan_dir(ROOT .. "/tests/specs", "*.lua", files)
  local lua_files = {}
  scan_dir(ROOT .. "/lua", "**/*.lua", lua_files)

  local cited, refs = {}, {}
  for _, p in ipairs(files) do
    local t = read(p)
    for c in t:gmatch("%[§(nvim%-[%l%d%-]+)%]") do cited[c] = true end
  end
  for _, p in ipairs(vim.list_extend(vim.list_extend({}, files), lua_files)) do
    local t = read(p)
    for r in t:gmatch("§(nvim%-[%l%d%-]+)") do refs[#refs + 1] = { file = p, ref = r } end
  end

  local uncited = {}
  for a in pairs(anchors) do
    if not cited[a] then uncited[#uncited + 1] = a end
  end
  table.sort(uncited)
  H.assert_eq(table.concat(uncited, ", "), "", "SPEC promises cited by NO spec")

  local orphans = {}
  for c in pairs(cited) do
    if not anchors[c] then orphans[#orphans + 1] = c end
  end
  table.sort(orphans)
  H.assert_eq(table.concat(orphans, ", "), "", "citations resolving to NO anchor")

  local rotted = {}
  for _, r in ipairs(refs) do
    if not anchors[r.ref] then rotted[#rotted + 1] = r.file:gsub(ROOT .. "/", "") .. " §" .. r.ref end
  end
  table.sort(rotted)
  H.assert_eq(table.concat(rotted, "\n"), "", "comment §nvim refs resolving to NO anchor")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
