local util = require("acmoj.util")

local M = {}

function M.tz_offset_seconds_at(epoch_seconds)
	local local_t = os.date("*t", epoch_seconds)
	local utc_t = os.date("!*t", epoch_seconds)
	return os.difftime(os.time(local_t), os.time(utc_t))
end

function M.parse_datetime_to_epoch(value)
	if type(value) ~= "string" then
		return nil
	end
	local s = util.trim(value)
	if s == "" then
		return nil
	end

	s = s:gsub("(%d%d:%d%d:%d%d)%.%d+", "%1")

	local tz = s:match("([Zz])$") or s:match("([+-]%d%d:?%d%d)$")
	local tz_seconds = nil
	if tz then
		if tz == "Z" or tz == "z" then
			tz_seconds = 0
		else
			local sign, hh, mm = tz:match("^([+-])(%d%d):?(%d%d)$")
			if sign and hh and mm then
				tz_seconds = (tonumber(hh) * 60 + tonumber(mm)) * 60
				if sign == "-" then
					tz_seconds = -tz_seconds
				end
			end
		end
		s = s:gsub(vim.pesc(tz) .. "$", "")
	end

	s = s:gsub(" ", "T")

	local ok, base_epoch = pcall(vim.fn.strptime, "%Y-%m-%dT%H:%M:%S", s)
	if not ok or type(base_epoch) ~= "number" then
		return nil
	end

	local local_offset = M.tz_offset_seconds_at(base_epoch)
	if tz_seconds == nil then
		tz_seconds = local_offset
	end

	return base_epoch - (tz_seconds - local_offset)
end

function M.problemset_deadline_epoch(problemset)
	if type(problemset) ~= "table" then
		return nil
	end
	return M.parse_datetime_to_epoch(problemset.late_submission_deadline)
		or M.parse_datetime_to_epoch(problemset.end_time)
end

return M
