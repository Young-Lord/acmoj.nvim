local M = {}

local function empty_cache()
  return {
    accepted_problems = {},
    token_to_username = {},
    cache_username = nil,
  }
end

function M.create(config, state, util, api)
  local function cache_path()
    return util.expand_path(config.cache_file)
  end

  local function save_cache()
    local path = cache_path()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local payload = {
      updated_at = os.time(),
      accepted_problems = state.cache.accepted_problems,
      token_to_username = state.cache.token_to_username,
      cache_username = state.cache.cache_username,
    }
    local ok, encoded = pcall(vim.json.encode, payload)
    if not ok then
      return
    end
    vim.fn.writefile({ encoded }, path)
  end

  local function load_cache()
    local path = cache_path()
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
      state.cache = empty_cache()
      return
    end

    local raw = table.concat(lines, "\n")
    local success, decoded = pcall(vim.json.decode, raw)
    if not success or type(decoded) ~= "table" then
      state.cache = empty_cache()
      return
    end

    local accepted = type(decoded.accepted_problems) == "table" and decoded.accepted_problems or {}
    local token_to_username = type(decoded.token_to_username) == "table" and decoded.token_to_username or {}
    local cache_username = type(decoded.cache_username) == "string" and decoded.cache_username or nil
    state.cache = {
      accepted_problems = accepted,
      token_to_username = token_to_username,
      cache_username = cache_username,
    }
  end

  local function hash_token(token)
    local ok, hashed = pcall(vim.fn.sha256, token)
    if ok and type(hashed) == "string" and hashed ~= "" then
      return hashed
    end
    return tostring(token)
  end

  local function mark_problem_accepted(problem_id)
    state.cache.accepted_problems[tostring(problem_id)] = true
    save_cache()
  end

  local function is_problem_accepted(problem_id)
    return state.cache.accepted_problems[tostring(problem_id)] == true
  end

  local function resolve_username(token, on_done)
    local token_key = hash_token(token)
    local username = state.cache.token_to_username[token_key]
    if type(username) == "string" and username ~= "" then
      on_done(username, nil)
      return
    end

    api.get(token, "/user/profile", function(body, err)
      if err then
        on_done(nil, "fetch /user/profile failed: " .. err)
        return
      end

      if type(body) ~= "table" or type(body.username) ~= "string" or util.trim(body.username) == "" then
        on_done(nil, "invalid /user/profile response")
        return
      end

      local fetched = util.trim(body.username)
      state.cache.token_to_username[token_key] = fetched
      save_cache()
      on_done(fetched, nil)
    end)
  end

  local function warm_accepted_cache(token, username, on_done)
    local page_limit = tonumber(config.accepted_cache_page_limit) or 50
    if page_limit < 1 then
      page_limit = 1
    end

    if state.cache.cache_username ~= username then
      state.cache.accepted_problems = {}
      state.cache.cache_username = username
    end

    local function fetch(cursor, pages)
      if pages > page_limit then
        save_cache()
        on_done(nil)
        return
      end

      local endpoint = "/submission/?status=accepted&username=" .. util.url_encode(username)
      if cursor then
        endpoint = endpoint .. "&cursor=" .. cursor
      end

      api.get(token, endpoint, function(body, err)
        if err then
          on_done(err)
          return
        end

        if type(body.submissions) == "table" then
          for _, sub in ipairs(body.submissions) do
            local pid = sub and sub.problem and sub.problem.id
            if type(pid) == "number" and type(sub.status) == "string" and sub.status:lower() == "accepted" then
              state.cache.accepted_problems[tostring(pid)] = true
            end
          end
        end
        save_cache()

        local next_url = body.next
        local next_cursor = type(next_url) == "string" and next_url:match("[?&]cursor=(%d+)") or nil
        if next_cursor then
          fetch(next_cursor, pages + 1)
          return
        end

        on_done(nil)
      end)
    end

    fetch(nil, 1)
  end

  local function refresh_cache_for_new_token(token, on_error)
    local token_key = hash_token(token)
    local cached_username = state.cache.token_to_username[token_key]
    if type(cached_username) == "string" and cached_username ~= "" then
      return
    end

    resolve_username(token, function(username, user_err)
      if user_err then
        on_error("refresh accepted cache failed: " .. user_err)
        return
      end

      warm_accepted_cache(token, username, function(cache_err)
        if cache_err then
          on_error("refresh accepted cache failed: " .. cache_err)
        end
      end)
    end)
  end

  local function clear_cache_file()
    state.cache = empty_cache()
    local path = cache_path()
    if util.path_exists(path) then
      pcall(vim.fn.delete, path)
    end
  end

  return {
    load_cache = load_cache,
    save_cache = save_cache,
    mark_problem_accepted = mark_problem_accepted,
    is_problem_accepted = is_problem_accepted,
    refresh_cache_for_new_token = refresh_cache_for_new_token,
    clear_cache_file = clear_cache_file,
  }
end

return M
