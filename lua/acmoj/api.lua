local M = {}

function M.create(config, util)
  local function request_json(args, on_done)
    vim.system(args, { text = true }, function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          local err = util.trim((obj.stderr or "") .. " " .. (obj.stdout or ""))
          on_done(nil, string.format("curl failed (%d): %s", obj.code, err))
          return
        end

        local body = obj.stdout or ""
        if body == "" then
          on_done({}, nil)
          return
        end

        local ok, decoded = pcall(vim.json.decode, body)
        if not ok then
          on_done(nil, "failed to parse JSON response")
          return
        end
        on_done(decoded, nil)
      end)
    end)
  end

  local function build_curl_headers(token)
    return {
      "-H",
      "Authorization: Bearer " .. token,
      "-H",
      "Accept: application/json",
    }
  end

  local function api_get(token, endpoint, on_done)
    local args = { "curl", "-sS", config.base_url .. endpoint }
    vim.list_extend(args, build_curl_headers(token))
    request_json(args, on_done)
  end

  local function api_submit(problem_id, language, code, token, on_done)
    local args = {
      "curl",
      "-sS",
      "-X",
      "POST",
      config.base_url .. "/problem/" .. problem_id .. "/submit",
      "-H",
      "Content-Type: application/x-www-form-urlencoded",
      "--data-urlencode",
      "language=" .. language,
      "--data-urlencode",
      "code=" .. code,
    }
    vim.list_extend(args, build_curl_headers(token))

    request_json(args, function(body, err)
      if err then
        on_done(nil, err)
        return
      end

      if type(body) ~= "table" or type(body.id) ~= "number" then
        on_done(nil, "submit failed: response does not include submission id")
        return
      end
      on_done(body.id, nil)
    end)
  end

  return {
    get = api_get,
    submit = api_submit,
  }
end

return M
