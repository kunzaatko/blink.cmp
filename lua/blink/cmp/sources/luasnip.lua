--- @class blink.cmp.LuasnipSourceOptions
--- @field use_show_condition? boolean Whether to use show_condition for filtering snippets
--- @field show_autosnippets? boolean Whether to show autosnippets in the completion list
--- @field global_snippets? string[] Snippet filetypes to always include in the completion list

--- @class blink.cmp.LuasnipSource : blink.cmp.Source
--- @field config blink.cmp.LuasnipSourceOptions
--- @field items_cache table<string, blink.cmp.CompletionItem[]>

--- @type blink.cmp.LuasnipSource
--- @diagnostic disable-next-line: missing-fields
local source = {}

local defaults_config = {
  use_show_condition = true,
  show_autosnippets = true,
  global_snippets = { 'all' },
}

function source.new(opts)
  local config = vim.tbl_deep_extend('keep', opts or {}, defaults_config)
  vim.validate({
    use_show_condition = { config.use_show_condition, 'boolean' },
    show_autosnippets = { config.show_autosnippets, 'boolean' },
  })
  local self = setmetatable({}, { __index = source })
  self.config = config
  self.items_cache = {}
  return self
end

function source:enabled()
  local ok, _ = pcall(require, 'luasnip')
  return ok
end

function source:get_completions(ctx, callback)
  local ft = vim.bo.filetype

  if not self.items_cache[ft] then
    --- @type blink.cmp.CompletionItem[]
    local items = {}

    -- Gather filetype snippets and, optionally, autosnippets
    local ls = require('luasnip')
    local snippets = {}

    for _, extra_ft in ipairs(self.config.global_snippets) do
      vim.list_extend(snippets, ls.get_snippets(extra_ft, { type = 'snippets' }))
    end
    vim.list_extend(snippets, ls.get_snippets(ft, { type = 'snippets' }))
    if self.config.show_autosnippets then
      for _, extra_ft in ipairs(self.config.global_snippets) do
        vim.list_extend(snippets, ls.get_snippets(extra_ft, { type = 'autosnippets' }))
      end
      vim.list_extend(snippets, ls.get_snippets(ft, { type = 'snippets' }))
    end
    snippets = vim.tbl_filter(function(snip) return not snip.hidden end, snippets)

    -- Get the max priority for use with sortText
    local max_priority = 0
    for _, snip in ipairs(snippets) do
      if not snip.hidden then max_priority = math.max(max_priority, snip.effective_priority or 0) end
    end

    for _, snip in ipairs(snippets) do
      -- Convert priority of 1000 (with max of 8000) to string like "00007000|||asd" for sorting
      -- This will put high priority snippets at the top of the list, and break ties based on the trigger
      local inversed_priority = max_priority - (snip.effective_priority or 0)
      local sort_text = ('0'):rep(8 - tostring(inversed_priority), '') .. inversed_priority .. '|||' .. snip.trigger

      --- @type lsp.CompletionItem
      local item = {
        kind = require('blink.cmp.types').CompletionItemKind.Snippet,
        label = snip.trigger,
        insertText = snip.trigger,
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
        sortText = sort_text,
        data = { snip_id = snip.id, show_condition = snip.show_condition },
      }
      table.insert(items, item)
    end

    self.items_cache[ft] = items
  end

  local items = self.items_cache[ft] or {}

  -- Filter items based on show_condition, if configured
  if self.config.use_show_condition then
    local line_to_cursor = ctx.line:sub(0, ctx.cursor[2] - 1)
    items = vim.tbl_filter(function(item) return item.data.show_condition(line_to_cursor) end, items)
  end

  callback({
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = items,
    context = ctx,
  })
end

function source:resolve(item, callback)
  local snip = require('luasnip').get_id_snippet(item.data.snip_id)

  local resolved_item = vim.deepcopy(item)

  local detail = snip:get_docstring()
  if type(detail) == 'table' then detail = table.concat(detail, '\n') end
  resolved_item.detail = detail

  if snip.dscr then
    resolved_item.documentation = {
      kind = 'markdown',
      value = table.concat(vim.lsp.util.convert_input_to_markdown_lines(snip.dscr), '\n'),
    }
  end

  callback(resolved_item)
end

function source:execute(_, item)
  local luasnip = require('luasnip')
  local snip = luasnip.get_id_snippet(item.data.snip_id)

  -- if trigger is a pattern, expand "pattern" instead of actual snippet.
  if snip.regTrig then snip = snip:get_pattern_expand_helper() end

  -- get (0, 0) indexed cursor position
  -- the completion has been accepted by this point, so ctx.cursor is out of date
  local cursor = vim.api.nvim_win_get_cursor(0)
  cursor[1] = cursor[1] - 1

  local expand_params = snip:matches(require('luasnip.util.util').get_current_line_to_cursor())

  local clear_region = {
    from = { cursor[1], cursor[2] - #item.insertText },
    to = cursor,
  }
  if expand_params ~= nil and expand_params.clear_region ~= nil then
    clear_region = expand_params.clear_region
  elseif expand_params ~= nil and expand_params.trigger ~= nil then
    clear_region = {
      from = { cursor[1], cursor[2] - #expand_params.trigger },
      to = cursor,
    }
  end

  luasnip.snip_expand(snip, { expand_params = expand_params, clear_region = clear_region })
end

function source:reload() self.items_cache = {} end

return source
