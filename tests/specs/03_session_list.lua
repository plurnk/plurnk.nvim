-- session.list returns { sessions: [{ id, name, project_root?, ... }] }.
local NAME = "03_session_list"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()
local ok, err = pcall(function()
  local r = H.call("session.list")
  H.assert_type(r, "table", "session.list result")
  H.assert_type(r.sessions, "table", "session.list.sessions")
  for i, s in ipairs(r.sessions) do
    H.assert_type(s.id, "number", "sessions[" .. i .. "].id")
    H.assert_type(s.name, "string", "sessions[" .. i .. "].name")
  end
end)
if ok then H.finish(NAME) else H.fail(NAME, err) end
