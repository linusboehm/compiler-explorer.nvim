local ce = require("compiler-explorer.lazy")

local api, fn = vim.api, vim.fn

local M = {}

M.state = {}
M.buffers = {}

M.create = function()
  local sessions = {}
  local id = 1
  local lang
  for source_bufnr, asm_data in pairs(M.state) do
    if api.nvim_buf_is_loaded(source_bufnr) then
      local compilers = {}
      for asm_bufnr, data in pairs(asm_data) do
        if api.nvim_buf_is_loaded(asm_bufnr) then
          lang = data.lang
          data.compiler.options = data.options
          table.insert(compilers, data.compiler)
        end
      end

      local lines = api.nvim_buf_get_lines(source_bufnr, 0, -1, false)
      local source = table.concat(lines, "\n")

      table.insert(sessions, {
        language = lang,
        id = id,
        source = source,
        compilers = compilers,
      })
      id = id + 1
    end
  end

  if vim.tbl_isempty(sessions) then
    return nil
  end
  return { sessions = sessions }
end

------------------------------
--- Body example:
-----------------
-- {
--   allowStoreCodeDebug = true,
--   compiler = {
--     compilerType = "",
--     id = "g141",
--     instructionSet = "amd64",
--     lang = "c++",
--     name = "x86-64 gcc 14.1",
--     semver = "14.1"
--   },
--   lang = "",
--   options = {
--     compilerOptions = {
--       produceCfg = false,
--       produceDevice = false,
--       produceGccDump = {},
--       produceLLVMOptPipeline = false,
--       producePp = false
--     },
--     filters = {
--       binary = false,
--       commentOnly = true,
--       demangle = true,
--       directives = true,
--       execute = true,
--       intel = true,
--       labels = true,
--       libraryCode = true,
--       trim = false
--     },
--     libraries = {},
--     tools = {},
--     userArguments = "-O1"
--   },
--   source = '#include<iostream>\n\nint foo(){\n  std::cout << "hello" << std::endl;\n  return 0;\n}'
-- }

M.save_info = function(source_bufnr, asm_bufnr, body)
  M.state[source_bufnr] = M.state[source_bufnr] or {}

  M.state[source_bufnr][asm_bufnr] = {
    compiler = body.compiler,
    lang = body.compiler.lang,
    options = body.options.userArguments,
    filters = body.options.filters,
    libs = vim.tbl_map(function(lib)
      return { name = lib.id, ver = lib.version }
    end, body.options.libraries),
  }
end

M.get_last_bufwinid = function(source_bufnr)
  for _, asm_buffer in ipairs(vim.tbl_keys(M.state[source_bufnr] or {})) do
    local winid = fn.bufwinid(asm_buffer)
    if winid ~= -1 then
      return winid
    end
  end
  return nil
end

return M
