-- [§nvim-auth-device-grant]
-- #116: OAuth Device Authorization Grant leg. auth.run(target) → auth.authorize
-- → show verificationUri + userCode → poll auth.authorize.poll until authorized/
-- denied/expired. No redirect, no local server (works over a remote daemon).
-- vim.defer_fn is stubbed to run synchronously so the poll loop drives instantly.
local NAME = "34_auth"
local H = dofile((os.getenv("PLURNK_NVIM_ROOT") or "/home/hyzen/repo/plurnk/plurnk.nvim") .. "/tests/helpers.lua")
H.setup()

local ok, err = pcall(function()
  local auth = require("plurnk.auth")
  local client = require("plurnk.client")

  local sent, notes, poll_queue = {}, {}, {}
  client.send = function(method, params, _isnotif, cb)
    table.insert(sent, { method = method, params = params })
    if method == "auth.authorize" then
      cb({ verificationUri = "https://provider/device", userCode = "WDJB-MJHT", device = { d = "opaque" }, interval = 5, expiresIn = 900 })
    else
      cb({ status = table.remove(poll_queue, 1) or "authorized" })  -- terminal fallback: never loop forever
    end
  end
  client.notify = function(msg) table.insert(notes, msg) end
  vim.defer_fn = function(fn) fn() end   -- run the poll loop synchronously

  -- Happy path: pending → authorized
  poll_queue = { "pending", "authorized" }
  auth.run("notion")
  H.assert_eq(sent[1].method, "auth.authorize", "authorize first")
  local joined = table.concat(notes, "\n")
  H.assert_match(joined, "https://provider/device", "verification URL shown")
  H.assert_match(joined, "WDJB%-MJHT", "user code shown")
  H.assert_match(joined, "authorized", "reached authorized")
  local polls = {}
  for _, s in ipairs(sent) do if s.method == "auth.authorize.poll" then polls[#polls + 1] = s end end
  H.assert_eq(#polls, 2, "polled through pending to authorized")
  H.assert_eq(polls[1].params.device.d, "opaque", "device blob round-tripped verbatim")
  H.assert_eq(polls[1].params.target, "notion", "target on the poll")

  -- Denied
  sent, notes, poll_queue = {}, {}, { "denied" }
  auth.run("notion")
  H.assert_match(table.concat(notes, "\n"), "denied", "denied surfaced")

  -- Expired → re-run hint
  sent, notes, poll_queue = {}, {}, { "expired" }
  auth.run("notion")
  H.assert_match(table.concat(notes, "\n"), "expired.*PlurnkAuth notion", "expired hints the re-run")

  -- No device endpoint → clean fail (execs-mcp ruling: no fallback)
  sent, notes = {}, {}
  client.send = function(method, _params, _isnotif, cb)
    table.insert(sent, { method = method })
    if method == "auth.authorize" then cb({}) end  -- no verificationUri
  end
  auth.run("notion")
  H.assert_match(table.concat(notes, "\n"), "no device%-authorization endpoint", "no-endpoint fails clean")
  H.assert_eq(#sent, 1, "never polled without an authorization")

  -- Empty target → usage, no wire call
  sent = {}
  auth.run("")
  H.assert_eq(#sent, 0, "empty target sends nothing")
end)

if ok then H.finish(NAME) else H.fail(NAME, err) end
