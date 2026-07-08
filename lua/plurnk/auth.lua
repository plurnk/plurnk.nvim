-- OAuth Device Authorization Grant (RFC 8628) for auth-protected execs
-- (#116 / execs-mcp#2 / svc#353). Converges the client's device-grant leg:
-- authorize → show verificationUri + userCode → poll until settled. No redirect,
-- no local server — works over a REMOTE daemon / jumpbox (the loopback flow the
-- client retired could not: its 127.0.0.1 callback landed on the daemon host).
-- The service relay is stateless; we drive the poll loop via vim.defer_fn.
local M = {}

local function notify(msg, level)
  pcall(require("plurnk.client").notify, msg, level or vim.log.levels.INFO)
end

local function now_ms()
  return (vim.uv or vim.loop).now()
end

-- Drive the flow for `target` (the exec tag needing auth, e.g. "notion").
function M.run(target)
  target = tostring(target or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if target == "" then notify("usage: :PlurnkAuth <target>  (the exec needing auth, e.g. notion)", vim.log.levels.WARN); return end
  local client = require("plurnk.client")

  client.send("auth.authorize", { target = target }, false, function(a)
    if type(a) ~= "table" or type(a.verificationUri) ~= "string" then
      notify("auth: " .. target .. " has no device-authorization endpoint — cannot authorize", vim.log.levels.ERROR)
      return
    end
    notify(string.format("🔒 authorize %s — visit %s and enter code: %s", target, a.verificationUri, tostring(a.userCode)))
    if type(a.verificationUriComplete) == "string" then
      notify("   (or open directly: " .. a.verificationUriComplete .. ")")
    end

    local interval_ms = math.max(1, tonumber(a.interval) or 5) * 1000
    local deadline = now_ms() + math.max(1, tonumber(a.expiresIn) or 900) * 1000
    local device = a.device

    local poll
    poll = function()
      if now_ms() >= deadline then
        notify("auth: " .. target .. " timed out — run :PlurnkAuth " .. target .. " again", vim.log.levels.WARN)
        return
      end
      client.send("auth.authorize.poll", { target = target, device = device }, false, function(p)
        local status = type(p) == "table" and p.status or "pending"
        if status == "authorized" then
          notify("✅ " .. target .. " authorized — retry the operation")
        elseif status == "denied" then
          notify("auth: " .. target .. " denied", vim.log.levels.ERROR)
        elseif status == "expired" then
          notify("auth: " .. target .. " expired — run :PlurnkAuth " .. target .. " again", vim.log.levels.WARN)
        else
          if status == "slow_down" then interval_ms = interval_ms + 5000 end   -- RFC 8628 §3.5
          vim.defer_fn(poll, interval_ms)
        end
      end)
    end
    vim.defer_fn(poll, interval_ms)
  end)
end

return M
