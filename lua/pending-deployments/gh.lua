-- gh CLI の非同期ラッパー (vim.system)
-- コールバックは全て vim.schedule 済みで呼ばれる (nvim API を直接呼んで良い)
local M = {}

local TIMEOUT_MS = 30000

---@param args string[] gh コマンドの引数 (先頭の "gh" は不要)
---@param cb fun(stdout: string|nil, err: string|nil)
local function gh(args, cb)
  local cmd = { "gh", unpack(args) }
  local ok, err = pcall(vim.system, cmd, { text = true, timeout = TIMEOUT_MS }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        local msg = (out.stderr or ""):gsub("%s+$", "")
        if msg == "" then msg = "exit code " .. out.code end
        cb(nil, msg)
      else
        cb(out.stdout or "")
      end
    end)
  end)
  if not ok then
    vim.schedule(function() cb(nil, tostring(err)) end)
  end
end

---@param cb fun(data: any|nil, err: string|nil)
local function gh_json(args, cb)
  gh(args, function(stdout, err)
    if not stdout then return cb(nil, err) end
    local ok, data = pcall(vim.json.decode, stdout)
    if not ok then return cb(nil, "JSON parse error: " .. tostring(data)) end
    cb(data)
  end)
end

--- 承認待ち (status=waiting) の workflow run 一覧
---@param repo string e.g. "owner/repo"
function M.waiting_runs(repo, cb)
  gh_json({
    "run", "list", "-R", repo, "--status", "waiting", "--limit", "20",
    "--json", "databaseId,displayTitle,workflowName,createdAt,url",
  }, cb)
end

--- run 内の全 job (name / status / conclusion / databaseId)
function M.run_jobs(repo, run_id, cb)
  gh_json(
    { "run", "view", tostring(run_id), "-R", repo, "--json", "jobs" },
    function(data, err) cb(data and data.jobs, err) end
  )
end

--- 承認待ち environment の一覧 (environment.id/name, current_user_can_approve)
function M.pending_deployments(repo, run_id, cb)
  gh_json({ "api", ("repos/%s/actions/runs/%d/pending_deployments"):format(repo, run_id) }, cb)
end

--- deployment の approve / reject
---@param env_ids integer[]
---@param state '"approved"'|'"rejected"'
function M.review(repo, run_id, env_ids, state, comment, cb)
  local args = {
    "api", "-X", "POST",
    ("repos/%s/actions/runs/%d/pending_deployments"):format(repo, run_id),
    "-f", "state=" .. state,
    "-f", "comment=" .. (comment or ""),
  }
  for _, id in ipairs(env_ids) do
    table.insert(args, "-F")
    table.insert(args, ("environment_ids[]=%d"):format(id))
  end
  gh(args, cb)
end

--- job のログ全文 (flux diff の抽出は呼び出し側で行う)
-- 注意: `gh run view --job --log` は run 全体が完了するまで拒否するため使えない
-- (release gate 待ちの run は常に in progress)。jobs/{id}/logs API なら
-- 完了済み job のログを run 実行中でも取得できる
function M.job_log(repo, job_id, cb)
  gh({ "api", ("repos/%s/actions/jobs/%d/logs"):format(repo, job_id) }, cb)
end

return M
