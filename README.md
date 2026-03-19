# acmoj.nvim

Submit ACMOJ code from NeoVim with `<leader>s`, poll judge results, and manage problemset workflows.

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

Default mapping is `<leader>s` in normal mode.

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
  solution_dir = "solutions",
  solution_ext = "cpp",
  template_file = "~/.config/nvim/acmoj/template.cpp",
  cache_file = "~/.local/state/nvim/acmoj/cache.json",
  accepted_cache_page_limit = 50,
})
```

Template file placeholders:

- `{problem_id}`
- `{full_name}`
- `{problem_title}`
- `{problemset_id}`
- `{problemset_name}`

## Manual command

- `:AcmojSubmit`
- `:AcmojProblemsets` load `/user/problemsets` and open selector (newest first).
- `:AcmojProblemset {problemset_id}` load problemset description + problem list, then open first problem file.
- `:AcmojProblemNext` open next problem file (circular).
- `:AcmojProblemPrev` open previous problem file (circular).
- `:AcmojProblemJump {index_or_problem_id}` jump by list index or problem id.
- `:AcmojProblemList` show/refocus the problemset view.

## File naming and initialization

- Solution file name is `{problem_id}-{full_name}.cpp`.
- `full_name` is derived from problem title and keeps readable text; only path-invalid characters are replaced.
- If target file does not exist, it is initialized from `template_file`.

## Accepted cache and UI

- Accepted problems are stored in `cache_file` and refreshed from `/submission/?status=accepted`.
- Problemset selector shows `(accepted/total)` like `(2/3)`.
- In problemset view, each problem line shows `✓` or `✗`.
- Fully accepted problemsets and accepted problem lines are rendered dim/gray.
