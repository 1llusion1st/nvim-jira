require("os")
-- https://developer.atlassian.com/server/jira/platform/jira-rest-api-examples/

cjson = require("cjson")
mime = require("mime")
ltn12 = require("ltn12")
io = require("io")

local api = vim.api
local buf, win
local position = 0

Jira = {host = nil, username = nil, accessToken = nil, project = nil }

-- Jira interface
function Jira:new (obj, username, accessToken, project)
    obj = obj or {}
    setmetatable(obj, self)
    self.__index = self
    self.host = host or os.getenv("JIRA_HOST")
    self.domain = os.getenv("JIRA_HOST")
    self.username = username or os.getenv("JIRA_USERNAME")
    self.accessToken = accessToken or os.getenv("JIRA_TOKEN")
    self.project = project or os.getenv("JIRA_PROJECT")
    self.http = require("ssl.https")
    -- print("jira creds: ", self.host, self.username, self.accessToken, self.project)

    return obj
end

-- GET request handler
function Jira:http_get(url)
    headers = {
        authorization = "Basic " .. mime.b64(string.format('%s:%s', self.username, self.accessToken))
    }
    response_table = {}
    response, response_code, c, h = self.http.request {
        url = url,
        headers = headers,
        sink = ltn12.sink.table(response_table)
        -- sink = ltn12.sink.file(io.stdout)
    }
    return table.concat(response_table), response_code
end
-- POST request handler
function Jira:http_post(url, body)
    headers = {
        authorization = "Basic " .. mime.b64(string.format('%s:%s', self.username, self.accessToken)),
        ["Content-Type"] = "application/json",
        ["Content-Length"] = body:len()
    }
    response_table = {}
    local source = ltn12.source.string(body)
    -- print("source:", source)
    response, response_code, c, h = self.http.request {
        url = url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(response_table),
        source = source,
    }

    return table.concat(response_table), response_code
end

-- Fetch my issues (assigned + watching)
function Jira:get_my_issues()
    url = self.host .. "/search?maxResults=100&jql=assignee+=+currentuser()%26resolution=Unresolved%26project='" .. param_encode(self.project) .. "'"
    -- print("url: ", url)
    response, response_code = self:http_get(url)

    local response_table = cjson.decode(response)

    return response_table.issues
end

-- Fetch comments on an issue

function Jira:get_issue_with_comments(issueId)
    -- print("issueId: ", issueId)
    url = self.host .. string.format("/issue/%s", issueId)
    response, response_code = self:http_get(url)

    -- print("issue raw:", dump(response), code)
    local response_table = cjson.decode(response)
    -- print("issue response table:", dump(response_table))
    return response_table
end

function Jira:get_issue_comments(issueId)
    -- print("issue ID: ", issueId)
    url = self.host .. string.format("/issue/%s/comment", issueId)
    response, response_code = self:http_get(url)
	
    -- print("issue comments raw", dump(response), code)
    local response_table = cjson.decode(response)
    -- print("issue response_table: ", dump(response_table))

    return response_table.comments
end

-- Publish comment for the issue
function Jira:publish_comment(issueId, comment)
    -- print("publishing comment for " .. issueId, comment)
    local message = comment
    if message == nil then
    	message = api.nvim_get_current_line()
    end
    while true do
	    pos, _ = message:find("\n")
	    if pos == nil then break end
	    message = message:gsub("\n", "\\n")
    end

    local url = self.host .. string.format("/issue/%s/comment", issueId)
    local body = string.format([[ {"body": { "type": "doc", "version": 1, "content": [ { "type": "paragraph", "content": [ { "text": "%s", "type": "text" } ] } ] } } ]], message)
    
    -- print("request body:", body)
    response, response_code = self:http_post(url, body)

    if response_code == 201 then
        print(string.format('Comment posted: %s', message))
    else
	print(string.format('Response server: %d', response_code), response)
    end
end

function selected_text_comment_handler()
	local text = get_visual_selection()
	-- print("selection:", text, type(text))
    	jira:publish_comment(current_issue, text)
end

-- Event handler of publish comment keymap
function publish_comment_handler()
    jira:publish_comment(current_issue)
end

-- Event handler for add comment key map
function comment_event_handler()
    local s = api.nvim_get_current_line()
    close_window()

    splits = split(s, ' ')
    current_issue = current_issue or splits[1]:gsub('%s+', '')
    init()
end

-- Format the comment lines fetched
function get_formatted_issue_with_comments(issue_with_comments)
    render = {}

    local i = issue_with_comments
    local f = i.fields

    table.insert(render, string.format(
    	"%s(%s)-%s-%s: %s",
		i.key, f.issuetype.name,
		f.priority.name,
		string.format("%d", f.watches.watchCount),
		f.status.name
    ))
    table.insert(render, string.format("%s/browse/%s", jira.domain, i.key))
    table.insert(render, f.summary)
    table.insert(render, string.format(
    	"%s by %s", f.created, f.creator.displayName))

    table.insert(render, "------------ DESCRIPTION ------------")
    local simple_description = process_node(f.description)
    -- print("DESCRIPTION: ", simple_description)
    for _, line in ipairs(split(simple_description, "\n")) do
	    table.insert(render, line)
    end
    -- print("DESCRIPTION processing DONE")

    table.insert(render, "------------ COMMENTS ------------")

    for comment_idx, comment in ipairs(f.comment.comments) do
        local author = comment.author.displayName .. ' posted at: ' .. comment.created
        local underline = ''
        for i=1,string.len(author) do
            underline = underline .. '='
        end
	print(string.format("%d: by %s", comment_idx, author))

        table.insert(render, underline)
        table.insert(render, author)
        table.insert(render, underline)
        table.insert(render, '')
        for content_idx, content in ipairs(comment.body.content) do
	      local content_to_print = process_node(content)
	      -- print("OUT chunk: ", content_to_print)
	      for _, line in ipairs(split(content_to_print, "\n")) do
		    table.insert(render, line)
	      end
--            local comment_line = ''
--            for text_idx, text in ipairs(content.content) do
--                 if text.type == "paragraph" then
--                     table.insert(render, comment_line .. text.paragraph)
--                     comment_line = ''
--                 elseif text.type == "text" then
--                     if text.text ~= ' ' then
--                         table.insert(render, comment_line .. text.text)
--                         comment_line = ''
--                     end
--                 elseif text.type == "hardBreak" then
--                     table.insert(render, '')
--                 elseif text.type == "mention" then
--                     comment_line = comment_line .. string.format("[%s]", text.attrs.text)
--                 else
--                 end
--                 if text.text == nil then
--                     table.insert(render, '')
--                 end
--            end
        end
        table.insert(render, '')
    end -- for comment_table
    return render
end -- func

function process_paragraph(paragraph)
	local content_items = ""
	for idx, paragraph_item in ipairs(paragraph.content) do
		if paragraph_item.type == "text" then
			content_items = content_items .. " " .. process_text(paragraph_item) .. " "
		end 
	end
	return content_items
end

function process_text(text)
	local text_marks = process_marks(text.marks)
	if text_marks ~= "" then
		return string.format("[%s]%s", text.text, text_marks)
	end
	return text.text
end

function process_marks(marks)
	if marks == nil then return "" end

	local result = "("
	for idx, mark in ipairs(marks) do
		if mark.type == "link" then 
			result = result .. mark.attrs.href
		end
	end
	return result .. ")"
end

function process_blockquote(blockquote)
	local result = ""
	for idx, content_item in ipairs(blockquote.content) do
		result = result .. process_node(content_item)
	end
	return "||| " .. result
end

function process_node(node, level)
	if level == nil then level = 0 end
	local prefix = string.rep("\t", level)
	print(prefix .. "process node" .. dump(node))
	print(prefix .. "process_node(node .type = ", node.type, ")")
	if node.type == nil then
		print(prefix .."processing array")
		local result = ""
		for idx, element in ipairs(node) do
			print(prefix .. string.format("[%d]:", idx))
			result = result .. process_node(element, level + 1)
		end
		return result
	end
	print(prefix .. "parsing node .type = ", node.type)
	if node.type == "paragraph" then
		print(prefix .. "processing paragraph")
		return process_paragraph(node)
	elseif node.type == "text" then
		print(prefix .. "processing text")
		return process_text(node)
	elseif node.type == "blockquote" then
		print(prefix .. "processing blockquote")
		return process_blockquote(node)
	elseif node.type == "doc" then
		print(prefix .. "processing doc")
		local result = ""
		for _, element in ipairs(node.content) do
			result = result .. process_node(element, level + 1)
		end
		return result
	elseif node.type == "orderedList" or node.type == "bulletList" then
		print(prefix .. "processing orderedList")
		return process_node(node.content, level + 1)
	elseif node.type == "listItem" then
		print(prefix .. "processing listItem")
		return "\n\t * " .. process_node(node.content, level + 1)
	else
		print(prefix .. "node.type: ", node.type)
		return ""
	end
end

-- Open the selected issue
function open_issue()
    local s = api.nvim_get_current_line()

    splits = split(s, ' ')
    close_window()
    init()

    current_issue = splits[1]:gsub('%s+', '')
    response = jira:get_issue_with_comments(current_issue)
    info = get_formatted_issue_with_comments(response)

    api.nvim_buf_set_lines(buf, 0, 100, false, info)
end

-- Open floating window
function open_window()
    buf = vim.api.nvim_create_buf(false, true)
    local border_buf = vim.api.nvim_create_buf(false, true)

    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(buf, 'filetype', 'jira')

    local width = vim.api.nvim_get_option("columns")
    local height = vim.api.nvim_get_option("lines")

    local win_height = math.ceil(height * 0.8 - 4)
    local win_width = math.ceil(width * 0.8)
    local row = math.ceil((height - win_height) / 2 - 1)
    local col = math.ceil((width - win_width) / 2)

    local border_opts = {
      style = "minimal",
      relative = "editor",
      width = win_width + 2,
      height = win_height + 2,
      row = row - 1,
      col = col - 1
    }

    local opts = {
      style = "minimal",
      relative = "editor",
      width = win_width,
      height = win_height,
      row = row,
      col = col
    }

    local border_lines = { '╔' .. string.rep('═', win_width) .. '╗' }
    local middle_line = '║' .. string.rep(' ', win_width) .. '║'
    for i=1, win_height do
        table.insert(border_lines, middle_line)
    end
    table.insert(border_lines, '╚' .. string.rep('═', win_width) .. '╝')
    vim.api.nvim_buf_set_lines(border_buf, 0, -1, false, border_lines)

    local border_win = vim.api.nvim_open_win(border_buf, true, border_opts)
    win = api.nvim_open_win(buf, true, opts)
    api.nvim_command('au BufWipeout <buffer> exe "silent bwipeout! "'..border_buf)

    vim.api.nvim_win_set_option(win, 'cursorline', true)

    api.nvim_buf_set_lines(buf, 0, -1, false, { center('My Jira'), '', ''})
    api.nvim_command('set nofoldenable')
    api.nvim_buf_add_highlight(buf, -1, 'WhidHeader', 0, 0, -1)
end

-- Close window event handler
function close_window()
    api.nvim_win_close(win, true)
    buf = nil
    win = nil
end

-- Update and populate floating window with Jira issues
tbl_issue_states = {}
function prepare_tbl_issues_states()

	local states = os.getenv("JIRA_ISSUE_STATES")
	
	local idx = 1
	for line in states:gmatch("([^\n]*)\n?") do
		tbl_issue_states[line] = idx
		idx = idx + 1
	end

end

prepare_tbl_issues_states()

function sort_issue(k1, k2)
    local state1 = tbl_issue_states[k1.fields.status.name]
    local state2 = tbl_issue_states[k2.fields.status.name]
    -- print("processing states: ", state1, " & ", state2)
    if state1 == nil then state1 = -1 end
    if state2 == nil then state2 = -1 end
    return state1 < state2
end

symbol_tbl = {}
function prepare_symbol_table()
	local t = symbol_tbl
	t["Bug"] = "🐞"
	t["Story"] = "🧳"
	t["Task"] = "📋"
	t["Sub-task"] = "📝"
end
prepare_symbol_table()

function get_issue_symbol(name)
    local symbol = symbol_tbl[name]
    if symbol == nil then return name end
    return symbol
end

function update_view(direction)
    vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    position = position + direction
    if position < 0 then position = 0 end

    if results == nil then
        connect()
        results = jira:get_my_issues()
    end

    table.sort(results, sort_issue)

    local result = {}
    -- print(dump(results))
    local width = 70
    for idx, issue in ipairs(results) do
	local issue_summary = issue.fields.summary
	if #issue_summary > width then issue_summary = issue_summary:sub(1, width) .. "..." end
        issue_line = string.format('   %7s | %8s | %8s | <%s> | %s [%s] ',
		issue.key, get_issue_symbol(issue.fields.issuetype.name), issue.fields.priority.name, issue.fields.assignee.displayName,
		issue_summary, issue.fields.status.name)
        result[idx] = issue_line
    end
    api.nvim_buf_set_lines(buf, 3, -1, false, result)

    api.nvim_buf_add_highlight(buf, -1, 'whidSubHeader', 1, 0, -1)
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
end

function move_cursor()
   local new_pos = math.max(4, api.nvim_win_get_cursor(win)[1] - 1)
   api.nvim_win_set_cursor(win, {new_pos, 0})
end

-- Define keymappings
function set_mappings()
    local mappings = {
      ['['] = 'update_view(-1)',
      [']'] = 'update_view(1)',
      ['<cr>'] = 'open_issue()',
      ['\\com'] = 'comment_event_handler()',
      [':w'] = 'publish_comment_handler()',
      ['\\web'] = 'open_in_web()',
      q = 'close_window()',
    }

    for k,v in pairs(mappings) do
        api.nvim_buf_set_keymap(buf, 'n', k, ':lua require"jira".'..v..'<cr>', {
            nowait = true, noremap = true, silent = true
          })
    end
    api.nvim_buf_set_keymap(buf, 'v', 't', ':lua require"jira".selected_text_comment_handler()<cr>', {
            nowait = true, noremap = true, silent = true
    })
--     local other_chars = {
--       'a', 'c', 'n', 'o', 'p', 'r', 's', 't', 'v', 'x', 'y', 'z'
--     }
    local other_chars = {}
    for k,v in ipairs(other_chars) do
        api.nvim_buf_set_keymap(buf, 'n', v, '', { nowait = true, noremap = true, silent = true })
        api.nvim_buf_set_keymap(buf, 'n', v:upper(), '', { nowait = true, noremap = true, silent = true })
        api.nvim_buf_set_keymap(buf, 'n',  '<c-'..v..'>', '', { nowait = true, noremap = true, silent = true })
    end
end

-- Open issue in browser
local function open_in_web()
    local s = api.nvim_get_current_line()
    close_window()

    splits = split(s, ' ')
    current_issue = current_issue or splits[1]:gsub('%s+', '')
    local url = string.format("%s/browse/%s", os.getenv("JIRA_HOST"), current_issue)
    api.nvim_command(string.format(':!xdg-open %s', url))
end

-- function call for :Jira
function jira_load()
   init()
   update_view(0)
   api.nvim_win_set_cursor(win, {4, 0})
end

-- function call for :JiraReload
function jira_reload()
    results = nil
    jira_load()
end

-- Create Jira instance
function connect()
    jira = Jira:new{host = string.format("%s/rest/api/3", os.getenv("JIRA_HOST"))}
end

-- Initialize
function init()
    position = 0
    open_window()
    set_mappings()
end

-- Text align center
function center(str)
   local width = api.nvim_win_get_width(0)
   local shift = math.floor(width / 2) - math.floor(string.len(str) / 2)
   return string.rep(' ', shift) .. str
end

-- Split string by a delimiter
function split (inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t={}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

-- utils part

function get_visual_selection()
  local s_start = vim.fn.getpos("'<")
  local s_end = vim.fn.getpos("'>")
  local n_lines = math.abs(s_end[2] - s_start[2]) + 1
  local lines = vim.api.nvim_buf_get_lines(0, s_start[2] - 1, s_end[2], false)
  lines[1] = string.sub(lines[1], s_start[3], -1)
  if n_lines == 1 then
    lines[n_lines] = string.sub(lines[n_lines], 1, s_end[3] - s_start[3] + 1)
  else
    lines[n_lines] = string.sub(lines[n_lines], 1, s_end[3])
  end
  return table.concat(lines, '\n')
end

function has_value (tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end

    return false
end

function split_string(inputstr, sep)
   if sep == nil then
      sep = "%s"
   end
   local t={}
   for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
      table.insert(t, str)
   end
   return t
end

function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

function param_encode(param)
	while true do
		pos, _ = param:find(" ")
		if  pos == nil or pos > 0 == false then break end
		-- print("pos", pos, " param: ", param, "type: ", type(param))
		param = param:gsub(" ", "%%20")
	end
	return param
end

return {
  jira_load = jira_load,
  jira_reload = jira_reload,
  update_view = update_view,
  open_issue = open_issue,
  move_cursor = move_cursor,
  close_window = close_window,
  comment_event_handler = comment_event_handler,
  publish_comment_handler = publish_comment_handler,
  selected_text_comment_handler = selected_text_comment_handler,
  open_in_web = open_in_web
}

