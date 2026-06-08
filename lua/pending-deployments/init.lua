-- Review GitHub Actions pending deployments (environments protected by
-- "required reviewers") from inside Neovim.
--   - polls for runs waiting on approval and notifies via vim.notify
--   - :PendingDeployments opens a floating panel showing, per run, the
--     environments awaiting review and the CI job status, then lets you
--     approve / reject without leaving the editor
local gh = require "pending-deployments.gh"

local M = {}

local NOTIFY = "pending-deployments"

M.config = {
  -- Repositories to watch, e.g. { "owner/repo" }. Empty = polling disabled.
  repos = {},
  -- Restrict notifications / panel to these environment names (empty = all).
  -- Useful to watch only your own team's gate, e.g. { "my_team_gate" }.
  environments = {},
  poll_interval = 60, -- polling interval (seconds)
  initial_delay = 10, -- delay before the first poll (seconds); avoids a gh call at startup
  width = 0.7,
  height = 0.7,
  border = "rounded",
  title = " Pending Deployments ",
  -- Jobs whose name matches this Lua pattern are treated as the approval gate
  -- itself and excluded from the CI list (they show under "Gate"). nil = none.
  approval_job_pattern = nil, ---@type string|nil
  -- Optional diff view bound to `d`: inspect a job's log (e.g. a terraform or
  -- flux plan) before approving. Disabled unless `job_filter` is set.
  diff = {
    -- return true for jobs whose logs should be fetched for the diff view
    job_filter = nil, ---@type nil|fun(job: table): boolean
    -- transform a job's raw log text into display lines
    extract = function(raw) return vim.split(raw, "\n", { plain = true }) end,
    syntax = "diff", -- syntax highlighting for the diff buffer
  },
}

M._timer = nil ---@type uv.uv_timer_t|nil
M._notified = {} ---@type table<string, table<integer, boolean>> repo -> run_id set
M._entries = nil -- last fetch result (used to redraw from the diff view via q)
M._win = nil

-- ──────────────────────────── polling / notify ────────────────────────────

-- environment names in `pending` that match the configured filter (empty filter = all)
local function matched_envs(pending)
  local filter, names = M.config.environments, {}
  for _, p in ipairs(pending or {}) do
    local name = p.environment and p.environment.name
    if name and (#filter == 0 or vim.tbl_contains(filter, name)) then names[#names + 1] = name end
  end
  return names
end

local function poll()
  for _, repo in ipairs(M.config.repos) do
    gh.waiting_runs(repo, function(runs)
      if not runs then return end -- failures (offline etc.) are ignored; retry next tick
      M._notified[repo] = M._notified[repo] or {}
      local notified, current = M._notified[repo], {}
      for _, run in ipairs(runs) do
        current[run.databaseId] = true
        if not notified[run.databaseId] then
          -- only notify for runs with a matching environment awaiting review
          gh.pending_deployments(repo, run.databaseId, function(pending)
            -- a fetch failure / empty pending (environment may be undetermined right
            -- after entering waiting) leaves notified unset so the next poll re-evaluates
            if not pending or #pending == 0 then return end
            if notified[run.databaseId] then return end -- guard against concurrent double-notify
            notified[run.databaseId] = true
            local envs = matched_envs(pending)
            if #envs > 0 then
              -- only list environment names when filtering (otherwise the list gets long)
              local detail = #M.config.environments > 0 and ("\n(" .. table.concat(envs, ", ") .. ")") or ""
              vim.notify(
                ("Deployment awaiting review:\n%s%s\n→ :PendingDeployments"):format(run.displayTitle, detail),
                vim.log.levels.INFO,
                { title = NOTIFY }
              )
            end
          end)
        end
      end
      -- clear flags for runs that disappeared (approved etc.) so they re-notify if they wait again
      for id in pairs(notified) do
        if not current[id] then notified[id] = nil end
      end
    end)
  end
end

local function start_timer()
  if M._timer then
    M._timer:stop()
    M._timer:close()
    M._timer = nil
  end
  local t = vim.uv.new_timer()
  if not t then return end
  M._timer = t
  -- timer callbacks run on the libuv thread, so wrap in vim.schedule
  t:start(M.config.initial_delay * 1000, M.config.poll_interval * 1000, function()
    vim.schedule(poll)
  end)
end

-- ──────────────────────────── data fetch ────────────────────────────

-- For each waiting run, fetch jobs / pending_deployments in parallel, then cb(entries)
local function fetch(cb)
  local entries, remaining = {}, #M.config.repos
  local function done()
    remaining = remaining - 1
    if remaining == 0 then cb(entries) end
  end
  for _, repo in ipairs(M.config.repos) do
    gh.waiting_runs(repo, function(runs, err)
      if not runs then
        table.insert(entries, { repo = repo, err = err })
        return done()
      end
      if #runs == 0 then return done() end
      remaining = remaining + #runs * 2
      for _, run in ipairs(runs) do
        local entry = { repo = repo, run = run }
        table.insert(entries, entry)
        gh.run_jobs(repo, run.databaseId, function(jobs, jerr)
          entry.jobs, entry.jobs_err = jobs, jerr
          done()
        end)
        gh.pending_deployments(repo, run.databaseId, function(pending, perr)
          entry.pending, entry.pending_err = pending, perr
          done()
        end)
      end
      done()
    end)
  end
end

-- Classify CI jobs by state, excluding the approval gate job (see approval_job_pattern)
local function classify_jobs(jobs)
  local ci = { ok = {}, ng = {}, running = {}, skipped = 0 }
  local approval = M.config.approval_job_pattern
  for _, j in ipairs(jobs or {}) do
    if approval and j.name:find(approval) then -- luacheck: ignore
      -- the gate job itself; shown under pending_deployments instead
    elseif j.conclusion == "skipped" or j.conclusion == "neutral" then
      ci.skipped = ci.skipped + 1
    elseif j.status ~= "completed" then
      table.insert(ci.running, j)
    elseif j.conclusion == "success" then
      table.insert(ci.ok, j)
    else
      table.insert(ci.ng, j)
    end
  end
  ci.all_green = #ci.ng == 0 and #ci.running == 0
  return ci
end

-- ──────────────────────────── panel rendering ────────────────────────────

local function build_lines(entries)
  local lines, hls, ranges = {}, {}, {}
  local function add(text, hl)
    table.insert(lines, text)
    if hl then table.insert(hls, { line = #lines - 1, hl = hl }) end
  end

  if #entries == 0 then add("No deployments awaiting review", "PendingDeploymentsMuted") end

  for _, e in ipairs(entries) do
    if #lines > 0 then add "" end
    local start_line = #lines + 1
    if e.err then
      add(("✗ %s: fetch failed (%s)"):format(e.repo, e.err), "PendingDeploymentsNg")
    else
      add(("● %s"):format(e.run.displayTitle), "PendingDeploymentsHeader")
      add(
        ("  %s │ run %d │ %s"):format(e.repo, e.run.databaseId, (e.run.createdAt or ""):sub(1, 16):gsub("T", " ")),
        "PendingDeploymentsMuted"
      )
      add "  Gate:"
      if e.pending_err then
        add(("    ✗ pending_deployments fetch failed (%s)"):format(e.pending_err), "PendingDeploymentsNg")
      elseif e.pending and #e.pending > 0 then
        for _, p in ipairs(e.pending) do
          local mark = p.current_user_can_approve and "(can approve)" or "(no permission)"
          add(("    ⏳ %s %s"):format(p.environment.name, mark), "PendingDeploymentsWait")
        end
      else
        add("    (no environment awaiting review)", "PendingDeploymentsMuted")
      end
      add "  CI:"
      if e.jobs_err then
        add(("    ✗ jobs fetch failed (%s)"):format(e.jobs_err), "PendingDeploymentsNg")
      else
        local ci = classify_jobs(e.jobs)
        for _, j in ipairs(ci.running) do
          add(("    ⏳ %s (%s)"):format(j.name, j.status), "PendingDeploymentsWait")
        end
        for _, j in ipairs(ci.ng) do
          add(("    ✗ %s (%s)"):format(j.name, j.conclusion), "PendingDeploymentsNg")
        end
        for _, j in ipairs(ci.ok) do
          add(("    ✓ %s"):format(j.name), "PendingDeploymentsOk")
        end
        if ci.skipped > 0 then add(("    ○ skipped %d"):format(ci.skipped), "PendingDeploymentsMuted") end
      end
    end
    table.insert(ranges, { first = start_line, last = #lines, entry = e })
  end

  if M._hidden and M._hidden > 0 then
    add ""
    add(("(%d hidden by environment filter)"):format(M._hidden), "PendingDeploymentsMuted")
  end
  add ""
  local keys = "[a]pprove  [r]eject  [o]pen browser  [R]efresh  [q]uit"
  if M.config.diff.job_filter then keys = "[d]iff  " .. keys end
  add(keys, "PendingDeploymentsMuted")
  return lines, hls, ranges
end

-- Drop runs that don't match the environment filter. Entries we can't judge
-- (fetch error / empty pending = waiting but environment undetermined) are kept
-- visible, erring on the safe side.
local function filter_entries(entries)
  if #M.config.environments == 0 then
    M._hidden = 0
    return entries
  end
  local kept, hidden = {}, 0
  for _, e in ipairs(entries) do
    if e.err or e.pending_err or not e.pending or #e.pending == 0 or #matched_envs(e.pending) > 0 then
      table.insert(kept, e)
    else
      hidden = hidden + 1
    end
  end
  M._hidden = hidden
  return kept
end

-- exposed for pure-function tests
M._filter_entries = filter_entries

local ns = vim.api.nvim_create_namespace "pending_deployments"

local function set_content(buf, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h.line, 0, { end_row = h.line + 1, hl_group = h.hl, hl_eol = true })
  end
end

local function close_panel()
  if M._win and vim.api.nvim_win_is_valid(M._win) then vim.api.nvim_win_close(M._win, true) end
  M._win = nil
end

-- the entry whose block the cursor is on
local function entry_at_cursor(ranges)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, r in ipairs(ranges) do
    if row >= r.first and row <= r.last then return r.entry end
  end
end

-- ──────────────────────────── approve / reject ────────────────────────────

local function review(entry, state)
  if not entry or entry.err then return end
  if entry.pending_err then
    vim.notify(
      "pending_deployments fetch failed earlier (press R to reload): " .. entry.pending_err,
      vim.log.levels.ERROR,
      { title = NOTIFY }
    )
    return
  end
  local env_ids, env_names = {}, {}
  for _, p in ipairs(entry.pending or {}) do
    if p.current_user_can_approve then
      table.insert(env_ids, p.environment.id)
      table.insert(env_names, p.environment.name)
    end
  end
  if #env_ids == 0 then
    vim.notify("No environment you can approve", vim.log.levels.WARN, { title = NOTIFY })
    return
  end

  local ci = classify_jobs(entry.jobs)
  local action = state == "approved" and "approve" or "reject"
  local msg = ("%s this deployment?\n\n%s\nrun %d (%s)\nenvironment: %s"):format(
    action,
    entry.run.displayTitle,
    entry.run.databaseId,
    entry.repo,
    table.concat(env_names, ", ")
  )
  if not ci.all_green then
    msg = msg .. ("\n\n⚠ CI is not complete (running %d / failed %d)"):format(#ci.running, #ci.ng)
  end
  if vim.fn.confirm(msg, "&Yes\n&No", 2, "Question") ~= 1 then return end
  -- approving while CI is incomplete/failing requires a second confirmation
  if state == "approved" and not ci.all_green then
    if vim.fn.confirm("CI is not all green. Approve anyway?", "&Yes\n&No", 2, "Warning") ~= 1 then
      return
    end
  end

  -- guard against acting on stale data: re-fetch pending_deployments right
  -- before the POST and bail if the approvable set changed (e.g. someone else
  -- approved, or a different environment became pending, while you read the diff)
  gh.pending_deployments(entry.repo, entry.run.databaseId, function(fresh, perr)
    if not fresh then
      vim.notify("Aborted: failed to re-check current state: " .. (perr or "?"), vim.log.levels.ERROR, { title = NOTIFY })
      return
    end
    local fresh_ids = {}
    for _, p in ipairs(fresh) do
      if p.current_user_can_approve then fresh_ids[p.environment.id] = p.environment.name end
    end
    local changed = false
    for _, id in ipairs(env_ids) do
      if not fresh_ids[id] then changed = true end
    end
    for id in pairs(fresh_ids) do
      if not vim.tbl_contains(env_ids, id) then changed = true end
    end
    if changed then
      vim.notify(
        "The approvable environments changed (approved elsewhere?). Reloading — please re-check.",
        vim.log.levels.WARN,
        { title = NOTIFY }
      )
      M.open()
      return
    end

    gh.review(entry.repo, entry.run.databaseId, env_ids, state, "from nvim pending-deployments", function(_, err)
      if err then
        vim.notify(action .. " failed: " .. err, vim.log.levels.ERROR, { title = NOTIFY })
      else
        vim.notify(("%s done:\n%s"):format(action, entry.run.displayTitle), vim.log.levels.INFO, { title = NOTIFY })
        M.open() -- redraw with fresh state
      end
    end)
  end)
end

-- ──────────────────────────── diff view ────────────────────────────

local function open_diff_buffer(entry, sections)
  close_panel() -- a split can't be created from a floating window, so close the panel first
  local buf = vim.api.nvim_create_buf(false, true)
  -- show how to get back at the top (the q keymap is defined below)
  local lines = { "[q] back to panel" }
  for _, sec in ipairs(sections) do
    if #lines > 0 then table.insert(lines, "") end
    table.insert(lines, ("═══ %s (%s) ═══"):format(sec.name, sec.conclusion or "running"))
    vim.list_extend(lines, sec.lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, ("pending-deployments-diff-%d"):format(entry.run.databaseId))
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.cmd "botright split"
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].filetype = "pending-deployments-diff"
  vim.cmd("setlocal syntax=" .. M.config.diff.syntax) -- keep our own filetype, borrow diff highlighting
  -- q returns to the panel (redraw from cache, no refetch)
  vim.keymap.set("n", "q", function()
    if #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(0, true)
    else
      -- the only window can't be closed, so swap to another buffer (the diff is bufhidden=wipe)
      local alt = vim.fn.bufnr "#"
      if alt > 0 and vim.api.nvim_buf_is_valid(alt) then
        vim.api.nvim_win_set_buf(0, alt)
      else
        vim.cmd "enew"
      end
    end
    M.open { cached = true }
  end, { buffer = buf, nowait = true })
end

local function show_diff(entry)
  if not entry or entry.err then return end
  local filter = M.config.diff.job_filter
  if not filter then
    vim.notify("Diff view is not configured (set config.diff.job_filter)", vim.log.levels.WARN, { title = NOTIFY })
    return
  end
  local targets = {}
  for _, j in ipairs(entry.jobs or {}) do
    if j.conclusion ~= "skipped" and filter(j) then table.insert(targets, j) end
  end
  if #targets == 0 then
    vim.notify("No jobs matched the diff filter", vim.log.levels.WARN, { title = NOTIFY })
    return
  end
  vim.notify(("Fetching logs... (%d job(s))"):format(#targets), vim.log.levels.INFO, { title = NOTIFY })
  local sections, remaining = {}, #targets
  for i, j in ipairs(targets) do
    gh.job_log(entry.repo, j.databaseId, function(raw, err)
      sections[i] = {
        name = j.name,
        conclusion = j.conclusion,
        lines = raw and M.config.diff.extract(raw) or {
          "failed to fetch log: " .. (err or "?"),
          -- the jobs/{id}/logs API returns 404 for jobs that haven't completed
          (err or ""):find "Not Found"
              and "(the job may not have finished yet; press q to return, then d again once it completes)"
            or "",
        },
      }
      remaining = remaining - 1
      if remaining == 0 then open_diff_buffer(entry, sections) end
    end)
  end
end

-- ──────────────────────────── panel ────────────────────────────

local function open_panel_window(lines)
  local ui = vim.api.nvim_list_uis()[1]
  local win_width = math.floor(ui.width * M.config.width)
  local win_height = math.min(math.floor(ui.height * M.config.height), math.max(#lines + 1, 5))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "pending-deployments"

  close_panel()
  M._win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = win_width,
    height = win_height,
    row = math.floor((ui.height - win_height) / 2),
    col = math.floor((ui.width - win_width) / 2),
    style = "minimal",
    border = M.config.border,
    title = M.config.title,
    title_pos = "center",
  })

  vim.api.nvim_set_hl(0, "PendingDeploymentsHeader", { fg = "#bd93f9", bold = true, default = true })
  vim.api.nvim_set_hl(0, "PendingDeploymentsOk", { fg = "#50fa7b", default = true })
  vim.api.nvim_set_hl(0, "PendingDeploymentsNg", { fg = "#ff5555", default = true })
  vim.api.nvim_set_hl(0, "PendingDeploymentsWait", { fg = "#f1fa8c", default = true })
  vim.api.nvim_set_hl(0, "PendingDeploymentsMuted", { fg = "#6272a4", default = true })

  vim.keymap.set("n", "q", close_panel, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close_panel, { buffer = buf, nowait = true })
  return buf
end

local function render(buf, entries)
  M._entries = entries
  local lines, hls, ranges = build_lines(entries)
  set_content(buf, lines, hls)
  -- grow the window to fit (starts as a single "Loading..." line)
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    local ui = vim.api.nvim_list_uis()[1]
    vim.api.nvim_win_set_height(M._win, math.min(math.floor(ui.height * M.config.height), math.max(#lines + 1, 5)))
  end
  vim.keymap.set("n", "R", function() M.open() end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "d", function() show_diff(entry_at_cursor(ranges)) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "a", function() review(entry_at_cursor(ranges), "approved") end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "r", function() review(entry_at_cursor(ranges), "rejected") end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "o", function()
    local e = entry_at_cursor(ranges)
    if e and e.run then vim.ui.open(e.run.url) end
  end, { buffer = buf, nowait = true })
end

---@param opts? { cached?: boolean } cached=true redraws from the last fetch (used when returning from the diff view)
function M.open(opts)
  if #M.config.repos == 0 then
    vim.notify(
      "No repositories configured. Pass `repos` to setup():\n"
        .. "  require('pending-deployments').setup({ repos = { 'owner/repo' } })",
      vim.log.levels.WARN,
      { title = NOTIFY }
    )
    return
  end
  if (opts or {}).cached and M._entries then
    local buf = open_panel_window {}
    render(buf, M._entries)
    return
  end
  local buf = open_panel_window { "Loading..." }
  fetch(function(entries)
    if not vim.api.nvim_buf_is_valid(buf) then return end -- closed while fetching
    render(buf, filter_entries(entries))
  end)
end

-- Call from a session manager's pre-save hook: keep the panel / diff out of the session
function M.close_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
    if ft == "pending-deployments" or ft == "pending-deployments-diff" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local ft = vim.bo[buf].filetype
      if ft == "pending-deployments" or ft == "pending-deployments-diff" then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
  M._win = nil
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("PendingDeployments", function() M.open() end, { desc = "Review pending deployments" })

  if vim.fn.executable "gh" ~= 1 or #M.config.repos == 0 then
    -- no gh / no repos configured: don't poll (the command still exists)
    return
  end
  start_timer()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("PendingDeploymentsCleanup", { clear = true }),
    callback = function()
      if M._timer then
        M._timer:stop()
        M._timer:close()
        M._timer = nil
      end
    end,
  })
end

return M
