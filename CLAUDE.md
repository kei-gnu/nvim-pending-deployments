# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A Neovim plugin to review GitHub Actions **pending deployments** — the approval
gate created by an environment's *required reviewers* protection rule — without
leaving the editor. Goal: replace the "Slack ping → open browser → approve"
round trip.

## What it does

1. Polls `gh run list --status waiting` (default 60s) and notifies via
   `vim.notify` when a run with a matching environment awaits review.
2. `:PendingDeployments` (alias `:Pending`) opens a floating panel showing, per
   run:
   - **Gate**: environments awaiting review (`pending_deployments` API; whether
     you can approve is shown).
   - **CI**: job status of the same run (the approval/gate job is excluded via
     `approval_job_pattern`).
3. Panel keys: `d` diff view (if configured), `a`/`r` approve/reject (with
   confirmation; a second confirmation when CI isn't all green), `o` open in
   browser, `R` refetch, `q`/`<Esc>` close.

## Structure

```
lua/pending-deployments/
  init.lua  -- setup(), polling timer, panel UI, approve/reject, diff view
  gh.lua    -- async gh CLI wrapper (vim.system; callbacks are vim.schedule'd)
```

## Configuration & genericity

This plugin is intentionally **site-agnostic**. Anything employer/tool-specific
is passed in via config, not baked in:

- `approval_job_pattern` (Lua pattern) — jobs treated as the approval gate and
  excluded from the CI list. nil = none.
- `diff.job_filter` / `diff.extract` — the `d` view is generic: the caller
  decides which jobs' logs to fetch and how to turn raw logs into display lines
  (e.g. extract a `terraform plan` or `flux diff`). Disabled unless
  `job_filter` is set.
- `environments` — restrict notifications/panel to given environment names
  (empty = all). This is a generic feature and lives in the plugin.
- `repos` — repositories to watch (empty = polling disabled).

## Assumptions / background

- Depends on the `gh` CLI (authenticated). Without it, polling is disabled but
  the command still loads.
- A run targeting an environment with required reviewers enters the `waiting`
  state. Approval and CI jobs can share a run without a `needs` dependency, so
  it's possible to approve before checks finish — hence the panel shows CI
  status alongside the gate and warns on approve-while-not-green.
- `environments` filter applies to both notify and panel. Entries that can't be
  judged (fetch error, or empty `pending` = waiting but environment
  undetermined) are kept visible, erring safe (`_filter_entries` is exposed for
  pure-function tests).

## Design gotchas (easy to break)

- Always wrap nvim API calls from libuv timer / `vim.system` callbacks in
  `vim.schedule` (gh.lua already does; be careful if adding raw `vim.uv`
  callbacks in init.lua).
- The poll timer is a single `M._timer`. On `setup` re-run (`:Lazy reload`)
  stop+close before recreating; also close on `VimLeavePre` (a leak warns at
  exit).
- Session pollution: the panel is a floating window and the diff is a `nofile`
  scratch split — neither serializes into `mksession`. As a defensive layer,
  `close_all()` is called from a session manager's pre-save hook. Filetypes are
  `pending-deployments` / `pending-deployments-diff`. **Do not** make the diff a
  normal buffer (`buftype = ""`) or it leaks as an `enew`.
- A split can't be created from a floating window, so close the panel before
  opening the diff (`open_diff_buffer`).
- Job logs are fetched via `gh api repos/{repo}/actions/jobs/{id}/logs`, not
  `gh run view --job --log` (the latter is rejected until the whole run
  completes; a gate-waiting run is always in progress). The jobs/{id}/logs API
  returns 404 for jobs that haven't finished.
- Approve API: `POST repos/{repo}/actions/runs/{run_id}/pending_deployments`
  (`environment_ids[]` are integers; `comment` required, may be empty).

## Development

- Manual check: `:PendingDeployments` / `:Lazy reload pending-deployments`.
- Verify the timer doesn't multiply: repeated `:Lazy reload` must not increase
  uv handles.
- Commits: English messages, and keep the `Co-Authored-By: Claude Code` trailer
  (this is a self-made plugin).
