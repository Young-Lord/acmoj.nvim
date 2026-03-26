local M = {}

local command_help_lines

local subcommands = {
  help = { run = function(_, _, notify)
    notify(table.concat(command_help_lines(), "\n"), vim.log.levels.INFO)
  end, desc = "show command help", min_args = 0, max_args = 0 },
  push = { run = function(actions)
    actions.submit()
  end, desc = "submit current buffer", min_args = 0, max_args = 0 },
  test = { run = function(actions, args)
    actions.test_samples(args[1])
  end, desc = "run samples (or one by index)", min_args = 0, max_args = 1 },
  run = { run = function(actions)
    actions.run_current()
  end, desc = "compile and run current file", min_args = 0, max_args = 0 },
  sets = { run = function(actions)
    actions.problemsets()
  end, desc = "show problemsets selector", min_args = 0, max_args = 0 },
  set = { run = function(actions, args)
    actions.problemset(args[1])
  end, desc = "load problemset by id", min_args = 1, max_args = 1 },
  next = { run = function(actions)
    actions.problem_next()
  end, desc = "open next problem", min_args = 0, max_args = 0 },
  prev = { run = function(actions)
    actions.problem_prev()
  end, desc = "open previous problem", min_args = 0, max_args = 0 },
  open = { run = function(actions, args)
    actions.problem_jump(args[1])
  end, desc = "open by index/problem id", min_args = 1, max_args = 1 },
  list = { run = function(actions)
    actions.problem_list()
  end, desc = "focus current problem list", min_args = 0, max_args = 0 },
  token = { run = function(actions)
    actions.prompt_set_token()
  end, desc = "prompt and save token", min_args = 0, max_args = 0 },
  tmpl = { run = function(actions)
    actions.template()
  end, desc = "open template file", min_args = 0, max_args = 0 },
  clear = { run = function(actions)
    actions.clear_cache()
  end, desc = "clear local cache", min_args = 0, max_args = 0 },
  desc = { run = function(actions)
    actions.toggle_problem_description()
  end, desc = "toggle problem description panel", min_args = 0, max_args = 0 },
}

command_help_lines = function()
  local lines = { "usage: :Acmoj <subcmd> [args]", "subcommands:" }
  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  for _, name in ipairs(names) do
    table.insert(lines, string.format("  %-2s %s", name, subcommands[name].desc))
  end
  return lines
end

function M.create(actions, notify)
  vim.api.nvim_create_user_command("Acmoj", function(cmd_opts)
    local args = cmd_opts.fargs or {}
    local cmd = args[1]
    if not cmd or cmd == "" then
      subcommands.sets.run(actions, {}, notify)
      return
    end

    local spec = subcommands[cmd]
    if not spec then
      notify(string.format("unknown subcommand: %s", cmd), vim.log.levels.ERROR)
      notify(table.concat(command_help_lines(), "\n"), vim.log.levels.INFO)
      return
    end

    local payload = {}
    for i = 2, #args do
      table.insert(payload, args[i])
    end

    local count = #payload
    if count < spec.min_args or count > spec.max_args then
      notify(string.format("invalid args for :Acmoj %s", cmd), vim.log.levels.ERROR)
      return
    end

    spec.run(actions, payload, notify)
  end, {
    nargs = "*",
    desc = "ACMOJ command hub",
    complete = function(arg_lead, cmd_line)
      local split = vim.split(cmd_line, "%s+", { trimempty = true })
      local at_subcommand = #split <= 2
      if not at_subcommand then
        return {}
      end

      local names = vim.tbl_keys(subcommands)
      table.sort(names)
      local out = {}
      for _, name in ipairs(names) do
        if name:find("^" .. vim.pesc(arg_lead)) then
          table.insert(out, name)
        end
      end
      return out
    end,
  })
end

return M
