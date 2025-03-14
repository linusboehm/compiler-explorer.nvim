local ce = require("compiler-explorer.lazy")

local M = {}

local ns = vim.api.nvim_create_namespace("ce-diagnostics")

local default_diagnostics = {
  underline = false,
  virtual_text = false,
  signs = false,
}

vim.diagnostic.config(default_diagnostics, ns)

local severity_map = {
  [1] = vim.diagnostic.severity.INFO,
  [2] = vim.diagnostic.severity.WARN,
  [3] = vim.diagnostic.severity.ERROR,
}

local function is_full_err(err)
  return err.tag and err.tag.column and err.tag.line and err.tag.severity and err.tag.text
end

local function trim_msg_severity(err)
  local pos1, pos2 = string.find(err, ": ")
  return pos1 and string.sub(err, pos2 + 1, -1) or ""
end

M.add_diagnostics = function(stderr, bufnr, offset)
  if stderr == vim.NIL or stderr == nil then
    return
  end

  local conf = ce.config.get_config()

  local diagnostics = {}
  for _, err in ipairs(stderr) do
    if is_full_err(err) then
      table.insert(diagnostics, {
        lnum = err.tag.line + offset - 1,
        col = err.tag.column - 1,
        message = trim_msg_severity(err.tag.text),
        bufnr = bufnr,
        severity = severity_map[err.tag.severity],
      })
    end
  end

  vim.diagnostic.reset(ns)
  vim.diagnostic.set(ns, bufnr, diagnostics)
  vim.diagnostic.setqflist({
    namespace = ns,
    open = conf.open_qflist and (#diagnostics > 0),
    title = "Compiler Explorer",
  })
end

M.get_diagnostics = function(stderr, bufnr, offset)
  if stderr == vim.NIL or stderr == nil then
    return
  end

  local diagnostics = {}
  for _, err in ipairs(stderr) do
    if is_full_err(err) then
      table.insert(diagnostics, {
        lnum = err.tag.line + offset - 1,
        col = err.tag.column - 1,
        message = trim_msg_severity(err.tag.text),
        bufnr = bufnr,
        severity = severity_map[err.tag.severity],
      })
    end
  end

  local result = {}
  for _, diagnostic in ipairs(diagnostics) do
    table.insert(result, string.format("line: %d:%d -> %s", diagnostic.lnum + 1, diagnostic.col, diagnostic.message))
  end
  return result
end

return M
