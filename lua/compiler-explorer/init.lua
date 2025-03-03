local ce = require("compiler-explorer.lazy")

local api, fn = vim.api, vim.fn

local M = {}

-- ---@generic T
-- ---@param items T[] Arbitrary items
-- ---@param opts? {prompt?: string, format_item?: (fun(item: T): string), kind?: string}
-- ---@param on_choice fun(item?: T, idx?: number)
local function my_select(items, opts, on_choice)
  assert(type(on_choice) == "function", "on_choice must be a function")
  opts = opts or {}

  ---@type snacks.picker.finder.Item[]
  local finder_items = {}
  for idx, item in ipairs(items) do
    local text = (opts.format_item or tostring)(item)
    table.insert(finder_items, {
      formatted = text,
      text = text,
      item = item,
      idx = idx,
    })
  end

  local title = opts.prompt or "Select"
  title = title:gsub("^%s*", ""):gsub("[%s:]*$", "")
  local completed = false

  ---@type snacks.picker.finder.Item[]
  return Snacks.picker.pick({
    source = "select",
    items = finder_items,
    format = "text",
    title = title,
    actions = {
      confirm = function(picker, item)
        if completed then
          return
        end
        completed = true
        picker:close()
        vim.schedule(function()
          on_choice(item and item.item, item and item.idx)
        end)
      end,
    },
    on_close = function()
      if completed then
        return
      end
      completed = true
      vim.schedule(on_choice)
    end,
  })
end

-- Return a function to avoid caching the vim.ui functions
local get_select = function()
  return ce.async.wrap(my_select, 3)
end
local get_input = function()
  return ce.async.wrap(Snacks.input.input, 2)
end

M.setup = function(user_config)
  ce.config.setup(user_config or {})
end

---@param out_buf integer
local function display_output(response, out_buf)
  local function collect_output(output)
    local result = {}
    for _, v in pairs(output) do
      if v.text then
        table.insert(result, v.text)
      end
    end
    return result
  end

  local stdout = collect_output(response.stdout)
  local stderr = collect_output(response.stderr)
  stdout = (stdout and next(stdout) ~= nil) and stdout or { "---" }
  stderr = (stderr and next(stderr) ~= nil) and stderr or { "---" }

  local lines = {
    "exit code: " .. response.code,
    "stdout:",
    table.unpack(stdout),
    "stderr:",
    table.unpack(stderr),
  }
  vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, lines)
end

---@class ce.compile.compiler
---@field compilerType string
---@field id string
---@field instructionSet string
---@field lang string
---@field name string
---@field semver string

---@class ce.compile.config
---@field line1 integer
---@field line2 integer
---@field asm_buf? integer
---@field bang? boolean
---@field compiler? ce.compile.compiler
---@field fargs? table
---@field flags? string
---@field default_flags? string
---@field lang? string
---@field out_buf? integer
---@field on_selected? function

---@param opts ce.compile.config
---@param live? boolean
M.compile = ce.async.void(function(opts, live)
  opts = opts or {}
  opts.fargs = opts.fargs or {}
  local conf = ce.config.get_config()
  local vim_select = get_select()
  local vim_input = get_input()

  -- parse arg=val type of stuff
  local args = ce.util.parse_args(opts.fargs)

  -- Get window handle of the source code window.
  local source_winnr = api.nvim_get_current_win()

  -- Get buffer number of the source code buffer.
  local source_bufnr = api.nvim_get_current_buf()

  if not opts.compiler or not opts.compiler.id then
    if not opts.lang then
      local lang
      local lang_list = ce.rest.languages_get()
      local possible_langs = lang_list
      -- Infer language based on extension and prompt user.
      if args.inferLang then
        local extension = "." .. fn.expand("%:e")

        possible_langs = vim.tbl_filter(function(el)
          return vim.tbl_contains(el.extensions, extension)
        end, lang_list)

        if vim.tbl_isempty(possible_langs) then
          ce.alert.error("File extension %s not supported by compiler-explorer", extension)
          return
        end
      end

      if #possible_langs == 1 then
        lang = possible_langs[1]
      else
        -- Choose language
        lang = vim_select(possible_langs, {
          prompt = "Select language",
          format_item = function(item)
            return item.name
          end,
        })
      end

      if not lang then
        return
      end
      vim.cmd("redraw")
      opts.lang = lang.id
    end

    -- Extend config with config specific to the language
    local lang_conf = conf.languages[opts.lang]
    if lang_conf then
      conf = vim.tbl_deep_extend("force", conf, lang_conf)
    end

    if conf.compiler then
      opts.compiler.id = conf.compiler
    else
      -- Choose compiler
      local compilers = ce.rest.compilers_get(opts.lang)
      opts.compiler = vim_select(compilers, {
        prompt = "Select compiler",
        format_item = function(item)
          return string.format("%-20s - %s", item.id, item.name)
        end,
      })

      if not opts.compiler then
        if opts.on_selected then
          opts.on_selected(opts, false)
        end
        api.nvim_set_current_win(source_winnr)
        return
      end
      vim.cmd("redraw")
    end
  end

  if not opts.compiler.instructionSet then
    local ok
    ok, opts.compiler = pcall(ce.rest.check_compiler, opts.compiler.id)
    if not ok then
      ce.alert.error("Could not compile code with compiler id %s", opts.compiler.id)
      if opts.on_selected then
        opts.on_selected(opts, false)
      end
      return
    end
  end

  -- Choose compiler options
  if not opts.flags then
    opts.flags = vim_input({
      prompt = "Select compiler options> ",
      default = opts.default_flags,
    }) or ""
    vim.cmd("redraw")
  end

  if opts.on_selected then
    opts.on_selected(opts, true)
  end

  args.compiler = opts.compiler
  args.flags = opts.flags

  -- Get contents of the selected lines.
  local buf_contents = api.nvim_buf_get_lines(source_bufnr, opts.line1 - 1, opts.line2, false)
  args.source = table.concat(buf_contents, "\n")

  ce.async.scheduler()

  if live then
    api.nvim_create_autocmd({ "BufWritePost" }, {
      group = api.nvim_create_augroup("CompilerExplorerLive", { clear = true }),
      buffer = source_bufnr,
      callback = function()
        M.compile({
          line1 = 1,
          line2 = fn.line("$"),
          fargs = {
            "compiler=" .. args.compiler.id,
            "flags=" .. (args.flags or ""),
          },
        }, false)
      end,
    })
  end

  -- Compile
  local body = ce.rest.create_compile_body(args)
  local ok, response = pcall(ce.rest.compile_post, args.compiler.id, body)

  if not ok then
    ce.alert.error(response)
  end

  local asm_lines = vim.tbl_map(function(line)
    return line.text
  end, response.asm)

  -- opts.asm_buf = opts.asm_buf or nil
  local asm_bufnr = opts.asm_buf or ce.util.create_window_buffer(source_bufnr, args.compiler.id, opts.bang)
  api.nvim_buf_clear_namespace(asm_bufnr, -1, 0, -1)

  api.nvim_buf_set_option(asm_bufnr, "modifiable", true)
  api.nvim_buf_set_lines(asm_bufnr, 0, -1, false, asm_lines)

  if response.code ~= 0 then
    ce.alert.error("Could not compile code with %s", args.compiler.name)
  end

  if response.stderr then
    local lines = ce.stderr.get_diagnostics(response.stderr, source_bufnr, opts.line1 - 1)
    if #lines > 0 then
      vim.api.nvim_buf_set_lines(opts.out_buf, 0, -1, false, lines)
    elseif response.execResult then
      display_output(response.execResult, opts.out_buf)
    end
  end

  if args.binary then
    ce.util.set_binary_extmarks(response.asm, asm_bufnr)
  end

  -- Return to source window
  api.nvim_set_current_win(source_winnr)

  api.nvim_buf_set_option(asm_bufnr, "modifiable", false)

  ce.stderr.add_diagnostics(response.stderr, source_bufnr, opts.line1 - 1)

  if not args.binary then
    ce.autocmd.init_line_match(source_bufnr, asm_bufnr, response.asm, opts.line1 - 1)
  end

  ce.clientstate.save_info(source_bufnr, asm_bufnr, body)

  api.nvim_buf_set_var(asm_bufnr, "arch", args.compiler.instructionSet) -- used by show_tooltips
  api.nvim_buf_set_var(asm_bufnr, "labels", response.labelDefinitions) -- used by goto_label

  api.nvim_buf_create_user_command(asm_bufnr, "CEShowTooltip", M.show_tooltip, {})
  api.nvim_buf_create_user_command(asm_bufnr, "CEGotoLabel", M.goto_label, {})
  return opts
end)

-- WARN: Experimental
M.open_website = function()
  local conf = ce.config.get_config()
  Snacks.debug.inspect(conf)
  conf.language = "c++"

  local state = ce.clientstate.create()
  if state == nil then
    ce.alert.warn("No compiler configurations were found. Run :CECompile before this.")
    return
  end

  local url = table.concat({ conf.url, "clientstate", state }, "/")

  Snacks.notify(("url: [%s]"):format(url), { title = "Godbolt Browse" })
  vim.fn.setreg("+", url)
  if vim.fn.has("nvim-0.10") == 0 then
    require("lazy.util").open(url, { system = true })
    return
  end
  -- vim.ui.open(url)
end

M.add_library = ce.async.void(function()
  local vim_select = get_select()
  local lang_list = ce.rest.languages_get()

  -- Infer language based on extension and prompt user.
  local extension = "." .. fn.expand("%:e")

  local possible_langs = vim.tbl_filter(function(el)
    return vim.tbl_contains(el.extensions, extension)
  end, lang_list)

  if vim.tbl_isempty(possible_langs) then
    ce.alert.error("File extension %s not supported by compiler-explorer.", extension)
    return
  end

  local lang
  if #possible_langs == 1 then
    lang = possible_langs[1]
  else
    -- Choose language
    lang = vim_select(possible_langs, {
      prompt = "Select language",
      format_item = function(item)
        return item.name
      end,
    })
  end

  if not lang then
    return
  end
  vim.cmd("redraw")

  local libs = ce.rest.libraries_get(lang.id)
  if vim.tbl_isempty(libs) then
    ce.alert.info("No libraries are available for %.", lang.name)
    return
  end

  -- Choose library
  local lib = vim_select(libs, {
    prompt = "Select library",
    format_item = function(item)
      return item.name
    end,
  })

  if not lib then
    return
  end
  vim.cmd("redraw")

  -- Choose version
  local version = vim_select(lib.versions, {
    prompt = "Select library version",
    format_item = function(item)
      return item.version
    end,
  })

  if not version then
    return
  end
  vim.cmd("redraw")

  -- Add lib to buffer variable, overwriting previous library version if already present
  vim.b.libs = vim.tbl_deep_extend("force", vim.b.libs or {}, { [lib.id] = version.version })

  ce.alert.info("Added library %s version %s", lib.name, version.version)
end)

M.format = ce.async.void(function()
  local vim_select = get_select()
  -- Get contents of current buffer
  local buf_contents = api.nvim_buf_get_lines(0, 0, -1, false)
  local source = table.concat(buf_contents, "\n")

  -- Select formatter
  local formatters = ce.rest.formatters_get()
  local formatter = vim_select(formatters, {
    prompt = "Select formatter",
    format_item = function(item)
      return item.name
    end,
  })
  if not formatter then
    return
  end
  vim.cmd("redraw")

  local style = formatter.styles[1] or "__DefaultStyle"
  if #formatter.styles > 0 then
    style = vim_select(formatter.styles, {
      prompt = "Select formatter style",
      format_item = function(item)
        return item
      end,
    })

    if not style then
      return
    end
    vim.cmd("redraw")
  end

  local body = ce.rest.create_format_body(source, style)
  local out = ce.rest.format_post(formatter.type, body)

  if out.exit ~= 0 then
    ce.alert.error("Could not format code with %s", formatter.name)
    return
  end

  -- Split by newlines
  local lines = vim.split(out.answer, "\n")

  -- Replace lines of the current buffer with formatted text
  api.nvim_buf_set_lines(0, 0, -1, false, lines)

  ce.alert.info("Text formatted using %s and style %s", formatter.name, style)
end)

M.show_tooltip = ce.async.void(function()
  local ok, response = pcall(ce.rest.tooltip_get, vim.b.arch, fn.expand("<cword>"))
  if not ok then
    ce.alert.error(response)
    return
  end

  vim.lsp.util.open_floating_preview({ response.tooltip }, "markdown", {
    wrap = true,
    close_events = { "CursorMoved" },
    border = "single",
    zindex = 1000, -- Set a high zindex value to ensure it is on top
  })
end)

M.goto_label = function()
  local word_under_cursor = fn.expand("<cWORD>")
  if vim.b.labels == vim.NIL then
    ce.alert.error("No label found with the name %s", word_under_cursor)
    return
  end

  local label = vim.b.labels[word_under_cursor]
  if label == nil then
    ce.alert.error("No label found with the name %s", word_under_cursor)
    return
  end

  vim.cmd("norm m'")
  api.nvim_win_set_cursor(0, { label, 0 })
end

M.load_example = ce.async.void(function()
  local vim_select = get_select()
  local examples = ce.rest.list_examples_get()

  local examples_by_lang = {}
  for _, example in ipairs(examples) do
    if examples_by_lang[example.lang] == nil then
      examples_by_lang[example.lang] = { example }
    else
      table.insert(examples_by_lang[example.lang], example)
    end
  end

  local langs = vim.tbl_keys(examples_by_lang)
  table.sort(langs)

  local lang_id = vim_select(langs, {
    prompt = "Select language",
    format_item = function(item)
      return item
    end,
  })

  if not lang_id then
    return
  end
  vim.cmd("redraw")

  local example = vim_select(examples_by_lang[lang_id], {
    prompt = "Select example",
    format_item = function(item)
      return item.name
    end,
  })
  local response = ce.rest.load_example_get(lang_id, example.file)
  local lines = vim.split(response.file, "\n")

  langs = ce.rest.languages_get()
  local filtered = vim.tbl_filter(function(el)
    return el.id == lang_id
  end, langs)
  local extension = filtered[1].extensions[1]
  local bufname = example.file .. extension

  vim.cmd("tabedit")
  api.nvim_buf_set_lines(0, 0, -1, false, lines)
  api.nvim_buf_set_name(0, bufname)
  api.nvim_buf_set_option(0, "bufhidden", "wipe")

  if fn.has("nvim-0.8") then
    local ft = vim.filetype.match({ filename = bufname })
    api.nvim_buf_set_option(0, "filetype", ft)
  else
    vim.filetype.match(bufname, 0)
  end
end)

return M
