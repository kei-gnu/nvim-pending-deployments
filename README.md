# nvim-pending-deployments

Review GitHub Actions **pending deployments** — the approval gate created by an
environment's [*required reviewers*](https://docs.github.com/actions/managing-workflow-runs/reviewing-deployments)
protection rule — without leaving Neovim. It polls for runs waiting on
approval, shows the environments and CI status, and lets you approve / reject
in place.

> Built to replace the "Slack ping → open the browser → approve" round trip for
> deployments protected by required reviewers.

## Features

- **Background polling**: watches the configured repos for runs in the
  `waiting` state and notifies you via `vim.notify` when one needs review.
- **One panel per run**: `:PendingDeployments` opens a floating panel showing,
  for each waiting run:
  - **Gate** — environments awaiting review (from the `pending_deployments`
    API), including whether *you* can approve them.
  - **CI** — the status of the other jobs in the same run, so you can see
    whether checks passed before approving.
- **Approve / reject in place** (`a` / `r`) via the `pending_deployments` API,
  with a confirmation dialog and a second confirmation when CI isn't all green.
  Re-checks the approvable set right before the POST to avoid acting on stale
  data.
- **Optional diff view** (`d`): fetch a job's log and display it in a split —
  e.g. a `terraform plan` or `flux diff` rendered before you approve. Bring your
  own job filter and log extractor (see Configuration).

## Requirements

- Neovim >= 0.10 (uses `vim.uv` and `vim.system`)
- [`gh`](https://cli.github.com/) CLI, authenticated (`gh auth login`).
  Without `gh`, polling is disabled but the command still loads.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kei-gnu/nvim-pending-deployments",
  lazy = false, -- poll from startup
  config = function()
    require("pending-deployments").setup({
      repos = { "owner/repo" },
    })
    vim.keymap.set("n", "<Leader>Gp", "<cmd>PendingDeployments<CR>", { desc = "Pending deployments" })
  end,
}
```

## Configuration

Defaults:

```lua
require("pending-deployments").setup({
  repos = {},          -- repos to watch, e.g. { "owner/repo" }. Empty = no polling.
  environments = {},   -- restrict notifications/panel to these environment names (empty = all)
  poll_interval = 60,  -- seconds
  initial_delay = 10,  -- seconds before the first poll
  width = 0.7,
  height = 0.7,
  border = "rounded",
  title = " Pending Deployments ",
  -- Jobs matching this Lua pattern are treated as the approval gate itself and
  -- excluded from the CI list. nil = don't exclude any.
  approval_job_pattern = nil,
  -- Optional `d` diff view. Disabled unless `job_filter` is set.
  diff = {
    job_filter = nil, -- fun(job): boolean — jobs whose logs to fetch
    extract = function(raw) return vim.split(raw, "\n", { plain = true }) end,
    syntax = "diff",
  },
})
```

### Keeping repos out of version control

If your watch list differs per machine, keep it in a machine-local,
git-ignored file and load it from your config:

```lua
local ok, local_opts = pcall(require, "pending-deployments-local")
require("pending-deployments").setup(ok and local_opts or {})
-- pending-deployments-local.lua (git-ignored):
--   return { repos = { "owner/repo" } }
```

### Diff view example (flux)

The diff view is generic: you decide which jobs to read and how to turn their
logs into display lines. For a pipeline where a `flux-ci` job runs `flux diff`:

```lua
diff = {
  job_filter = function(job)
    return job.name:find("^flux%-ci / k8s") ~= nil
  end,
  -- gh job logs are "<job>\t<step>\t<ISO timestamp> <message>"; keep the
  -- lines from "$ flux diff" onward and strip ANSI escapes
  extract = function(raw)
    local out, started = {}, false
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
      local msg = line:match("^[^\t]*\t[^\t]*\t%S+ ?(.*)$")
      if msg then
        msg = msg:gsub("\27%[[0-9;]*[mK]", "")
        if msg:find("%$ flux diff") then started = true end
        if started then table.insert(out, msg) end
      end
    end
    return out
  end,
}
```

## Usage

- `:PendingDeployments` (or the short alias `:Pending`) — open the panel.
- Inside the panel (cursor on a run's block):

  | key | action |
  | --- | --- |
  | `a` | approve the run's approvable environments |
  | `r` | reject |
  | `d` | show the diff view (if configured) |
  | `o` | open the run in your browser |
  | `R` | refetch |
  | `q` / `<Esc>` | close |

## How it works

A run targeting an environment with *required reviewers* enters the `waiting`
state. This plugin lists those runs (`gh run list --status waiting`), reads the
environments awaiting review (`pending_deployments` API) and the run's jobs,
and POSTs your decision back to `pending_deployments`.

Because approval and CI jobs can live in the same run without a `needs`
dependency, it's possible to approve before checks finish — so the panel shows
CI status alongside the gate, and warns (with a second confirmation) if you
approve while CI isn't all green.

## Integration notes

<details>
<summary>Session managers (auto-session etc.)</summary>

The panel (floating window) and diff (scratch split) aren't serialized into
`mksession`, but as a defensive measure close them before save:

```lua
pre_save_cmds = {
  function() pcall(function() require("pending-deployments").close_all() end) end,
}
```

The relevant filetypes are `pending-deployments` and `pending-deployments-diff`.
Keep the diff buffer as a scratch buffer (`buftype` ≠ `""`) so it never leaks
into a session as an `enew`.
</details>

## License

MIT
