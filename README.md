# acmoj.nvim

Submit ACMOJ code from NeoVim, poll judge results, and manage problemset workflows.

## Requirements

- NeoVim with `vim.system` support.
- `curl` available in `$PATH`.
- token file at `~/.config/nvim/acmoj/token.txt` by default.

## Problem id format

The first line of the current buffer must match:

```text
ACMOJ(.+)?(\d+)
```

The trailing numeric capture is used as `problem_id`.

Examples:

```cpp
// ACMOJ 3032
```

```cpp
/* ACMOJ-Homework-3032 */
```

## Install (lazy.nvim)

```lua
{
  dir = "/path/to/acmoj.nvim",
}
```

Quick mappings are enabled by default in normal mode:

- `<leader>rl` open current problem list
- `<leader>rt` run sample tests
- `<leader>rr` compile and run current code
- `<leader>rs` submit current problem

## Optional setup

```lua
require("acmoj").setup({
  base_url = "https://acm.sjtu.edu.cn/OnlineJudge/api/v1",
  token_file = "~/.config/nvim/acmoj/token.txt",
  language = "cpp",
  poll_interval_ms = 1200,
  timeout_ms = 120000,
  map_submit = true,
  map_lhs = "<leader>s",
  map_problem_nav = true,
  map_problemsets_lhs = "<leader>ss",
  map_problem_next_lhs = "<leader>sn",
  map_problem_prev_lhs = "<leader>sp",
  map_problem_list_lhs = "<leader>sl",
  map_run = false,
  map_run_lhs = "<leader>r",
  map_quick = true,
  map_quick_list_lhs = "<leader>rl",
  map_quick_test_lhs = "<leader>rt",
  map_quick_run_lhs = "<leader>rr",
  map_quick_submit_lhs = "<leader>rs",
  solution_dir = "solutions",
  solution_ext = "cpp",
  template_file = "~/.config/nvim/acmoj/template.cpp",
  cache_file = "~/.local/state/nvim/acmoj/cache.json",
  accepted_cache_page_limit = 50,
  compile_cmd = "g++ -std=c++17 -O2 -pipe {src} -o {bin}",
  run_cmd = "{bin}",
  show_problem_description = true,
})
```

Template file placeholders:

- `{problem_id}`
- `{full_name}`
- `{problem_title}`
- `{problemset_id}`
- `{problemset_name}`

Quick mapping config:

- Set `map_quick = false` to disable the whole quick mapping group.
- Set each `map_quick_*_lhs` to a custom lhs to remap.
- Set a single `map_quick_*_lhs = false` (or `nil`) to disable only that one mapping.

## Manual command

Use a single command hub with concise subcommands:

- `:Acmoj push` submit current buffer.
- `:Acmoj test` run all samples for current problem, compare with trimmed output (strip leading/trailing blank lines and per-line surrounding whitespace), and print `输入/理论输出/实际输出` for each mismatch.
- `:Acmoj run` quick compile + run current file in an interactive terminal.
- `:Acmoj` (without subcommand) is equivalent to `:Acmoj sets`.
- `:Acmoj help` show command help.
- `:Acmoj sets` load `/user/problemsets` and open selector (newest first).
- `:Acmoj set {problemset_id}` load problemset description + problem list, then open the first unsolved problem file (fallback to first problem).
- `:Acmoj next` open next problem file (circular).
- `:Acmoj prev` open previous problem file (circular).
- `:Acmoj open {index_or_problem_id}` open by list index or problem id.
- `:Acmoj list` show/refocus the problemset view.
- `:Acmoj desc` toggle split problem description panel.
- `:Acmoj token` prompt for token with hidden input, then write token to `token_file` and refresh user mapping/cache in background.
- `:Acmoj tmpl` create `template_file` with a default C++ template when missing, then open it for editing.
- `:Acmoj clear` clear local `cache_file` and in-memory cache.

Problem description panel notes:

- Opens by default when entering a problem in a split window.
- `:Acmoj desc` can toggle it on/off.
- Content shows problem description, input format, output format, and samples (no LaTeX rendering).
- Newlines are normalized from `\r\n`/`\r` to `\n`.
- Buffer is read-only and uses `nofile`.

Notes:

- Sample testing currently supports `language = "cpp"` and compiles with local `g++`.
- If compilation fails, plugin reports compiler output directly.
- Failed `:Acmoj test` notifications are sticky (no auto-dismiss) for easier inspection.
- `compile_cmd` and `run_cmd` are global templates used by both `:Acmoj test` and `:Acmoj run`.
- Template placeholders: `{src}` for source path, `{bin}` for output binary path.

## Bind quick run to `<leader>r`

Option 1 (plugin-managed mapping):

```lua
require("acmoj").setup({
  map_run = true,
  map_run_lhs = "<leader>r",
})
```

Option 2 (manual mapping):

```lua
vim.keymap.set("n", "<leader>r", "<cmd>Acmoj run<CR>", { desc = "ACMOJ run current file" })
```

` :Acmoj run` behavior:

- Saves current buffer (`silent! w`) before running.
- Builds command as `compile_cmd && run_cmd`.
- If `Snacks.terminal.open` exists, it is used (interactive input supported).
- Otherwise falls back to Neovim terminal split (`termopen`).
- If compile/run command fails, terminal stays open and focus remains there for error inspection.
- If `compile_cmd` / `run_cmd` template is invalid, error notification is sticky (no auto-dismiss).

## File naming and initialization

- Solution file name is `{problem_id}-{full_name}.cpp`.
- `full_name` is derived from problem title and keeps readable text; only path-invalid characters are replaced.
- If target file does not exist, it is initialized from `template_file`.

## Accepted cache and UI

- Accepted problems are stored in `cache_file` and refreshed from `/submission/?status=accepted&username=<current_user>`.
- `cache_file` also stores `token_to_username` (`sha256(token)` -> `username`) and `cache_username`.
- On startup (or after `:Acmoj token`), if current token hash is not in `token_to_username`, plugin resolves `/user/profile` and refreshes accepted cache in background.
- Problemset selector shows `(accepted/total)` like `(2/3)`.
- In problemset view, each problem line shows `✓` or `✗`.
- Fully accepted problemsets and accepted problem lines are rendered dim/gray.
- Problemset selector cursor prefers the newest not-fully-solved entry; problem list cursor prefers the top unsolved entry. If none match, it falls back to the first entry (or line 1 when empty).
