-- session.lua: real headless integration over windows, buffers, and autocmds.
local session = require("mdeye.session")
local mdeye = require("mdeye")

local root = vim.g.mdeye_test_root

mdeye.setup({ debounce_ms = 20 })

local function make_source(lines, name)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if name then
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].filetype = "markdown"
  return bufnr
end

local sample_lines = {
  "# Title",
  "",
  "First paragraph continues",
  "on a second source line.",
  "",
  "## Section",
  "",
  "- item one",
  "- item two",
  "",
  "See [other](./other.md) and [site](https://example.com).",
  "",
  "Final paragraph sits at the bottom of the document.",
}

local function preview_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

local function close_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local s = session.get(buf) or session.get_by_preview(buf)
    if s then
      session.close_session(s, { restore = false })
    end
  end
  vim.cmd("silent! only!")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function autocmd_count()
  return #vim.api.nvim_get_autocmds({
    event = {
      "BufWipeout",
      "WinClosed",
      "WinResized",
      "VimResized",
      "CursorMoved",
    },
  })
end

describe("session", function()
  it("registers the :MDEye command with completion", function()
    eq(2, vim.fn.exists(":MDEye")) -- 2: full command name defined
  end)

  it("accepts an uncapped reading width", function()
    mdeye.setup({ debounce_ms = 20, max_width = false })
    eq(false, require("mdeye.config").options.max_width)
    mdeye.setup({ debounce_ms = 20 })
  end)

  it("rejects non-Markdown buffers with one notification", function()
    close_all()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.bo[bufnr].filetype = "text"
    vim.api.nvim_set_current_buf(bufnr)
    eq(false, mdeye.open())
    eq(0, session.count())
  end)

  it("opens a current-window preview without touching the source", function()
    close_all()
    local src = make_source(sample_lines)
    vim.api.nvim_set_current_buf(src)
    -- Unsaved modification must be preserved and rendered.
    vim.api.nvim_buf_set_lines(src, 2, 3, false, { "First paragraph UNSAVED continues" })
    local before = vim.api.nvim_buf_get_lines(src, 0, -1, false)

    ok(mdeye.open({ mode = "current" }))
    local preview = vim.api.nvim_get_current_buf()
    ok(preview ~= src, "preview replaces the window buffer")
    eq("mdeye", vim.bo[preview].filetype)
    eq("nofile", vim.bo[preview].buftype)
    eq("wipe", vim.bo[preview].bufhidden)
    eq(false, vim.bo[preview].modifiable)
    eq(-1, vim.bo[preview].undolevels)
    ok(vim.api.nvim_buf_get_name(preview):find("^mdeye://"))

    local win = vim.api.nvim_get_current_win()
    eq(false, vim.wo[win].number)
    eq(false, vim.wo[win].wrap)
    eq("no", vim.wo[win].signcolumn)
    eq(false, vim.wo[win].spell)

    local text = preview_text()
    ok(text:find("UNSAVED", 1, true), "unsaved content rendered")
    ok(not text:find("# Title", 1, true), "heading markers removed")
    ok(not text:find("./other.md", 1, true), "link destinations hidden")

    -- Source untouched, still loaded, still modified.
    eq(before, vim.api.nvim_buf_get_lines(src, 0, -1, false))
    eq(true, vim.bo[src].modified)
    eq(true, vim.api.nvim_buf_is_loaded(src))
  end)

  it("restores the source buffer and view on q", function()
    close_all()
    local long = {}
    for i = 1, 80 do
      long[#long + 1] = ("paragraph %d words words words"):format(i)
      long[#long + 1] = ""
    end
    local src = make_source(long)
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 61, 3 })
    vim.cmd("normal! zt")
    local view = vim.fn.winsaveview()

    ok(mdeye.open({ mode = "current" }))
    vim.api.nvim_feedkeys("q", "x", false)
    vim.wait(50)
    eq(src, vim.api.nvim_get_current_buf())
    local restored = vim.fn.winsaveview()
    eq(view.lnum, restored.lnum)
    eq(view.topline, restored.topline)
    eq(view.col, restored.col)
    eq(0, session.count())
  end)

  it("focuses the existing preview instead of duplicating a session", function()
    close_all()
    local src = make_source(sample_lines)
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "current" }))
    local preview = vim.api.nvim_get_current_buf()
    eq(1, session.count())
    -- Opening again from the preview buffer is a no-op.
    ok(mdeye.open({ mode = "current" }))
    eq(preview, vim.api.nvim_get_current_buf())
    eq(1, session.count())
  end)

  it("toggles: :MDEye closes an open preview", function()
    close_all()
    local src = make_source(sample_lines)
    vim.api.nvim_set_current_buf(src)
    vim.cmd("MDEye")
    ok(session.count() == 1)
    vim.cmd("MDEye")
    eq(0, session.count())
    eq(src, vim.api.nvim_get_current_buf())
  end)

  it("opens a synchronized right split and updates on unsaved edits", function()
    close_all()
    local src = make_source(sample_lines)
    vim.api.nvim_set_current_buf(src)
    local src_win = vim.api.nvim_get_current_win()

    ok(mdeye.open({ mode = "split" }))
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    local s = session.get(src)
    ok(s)
    local preview_win = s.owner_win
    ok(preview_win ~= src_win)

    -- Live update: edit the source without saving.
    vim.api.nvim_buf_set_lines(src, 2, 3, false, { "Freshly TYPED content here" })
    local updated = vim.wait(2000, function()
      local lines = vim.api.nvim_buf_get_lines(s.preview_buf, 0, -1, false)
      return table.concat(lines, "\n"):find("Freshly TYPED", 1, true) ~= nil
    end, 10)
    ok(updated, "debounced update rendered unsaved edit")

    -- Source-to-preview sync: move the source cursor to the last block.
    vim.api.nvim_set_current_win(src_win)
    vim.api.nvim_win_set_cursor(src_win, { #sample_lines, 5 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = src })
    local synced = vim.wait(1000, function()
      local cursor_row = vim.api.nvim_win_get_cursor(preview_win)[1] - 1
      local lines = vim.api.nvim_buf_get_lines(s.preview_buf, 0, -1, false)
      return (lines[cursor_row + 1] or ""):find("Final paragraph", 1, true) ~= nil
    end, 10)
    ok(synced, "preview follows the source cursor block")
  end)

  it("reports active preview state for health diagnostics", function()
    close_all()
    local src = make_source(sample_lines, "/tmp/mdeye-health.md")
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "split" }))
    local s = session.get(src)
    local diagnostics = session.diagnostics()
    eq(1, #diagnostics)
    eq(src, diagnostics[1].src_buf)
    eq(s.preview_buf, diagnostics[1].preview_buf)
    eq("split", diagnostics[1].mode)
    eq(vim.api.nvim_buf_get_name(src), diagnostics[1].source_name)
    eq(true, diagnostics[1].source_valid)
    eq(true, diagnostics[1].preview_valid)
    eq(true, diagnostics[1].owner_valid)
    eq(true, diagnostics[1].owner_shows_preview)
    eq(true, diagnostics[1].rendered)
    ok(mdeye.close())
    eq({}, session.diagnostics())
  end)

  it("reflows on owner window resize and keeps the reading position", function()
    close_all()
    local blocks = { "# Top" }
    for i = 1, 60 do
      blocks[#blocks + 1] = ""
      blocks[#blocks + 1] = ("Paragraph %d with a reasonable amount of prose to wrap."):format(i)
    end
    local src = make_source(blocks)
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "split" }))
    local s = session.get(src)
    local wide_width = s.plan.width

    -- Scroll the preview so an anchor block is at the top.
    vim.api.nvim_set_current_win(s.owner_win)
    local target_row
    for i, line in ipairs(vim.api.nvim_buf_get_lines(s.preview_buf, 0, -1, false)) do
      if line:find("Paragraph 40", 1, true) then
        target_row = i
      end
    end
    ok(target_row)
    vim.api.nvim_win_set_cursor(s.owner_win, { target_row, 0 })
    vim.cmd("normal! zt")

    vim.api.nvim_win_set_width(s.owner_win, 26)
    vim.api.nvim_exec_autocmds("WinResized", {})
    local reflowed = vim.wait(2000, function()
      return s.plan.width ~= wide_width
    end, 10)
    ok(reflowed, "resize triggers a reflow")
    ok(s.plan.width < wide_width)

    local top = vim.api.nvim_win_call(s.owner_win, function()
      return vim.fn.line("w0")
    end)
    local top_line = vim.api.nvim_buf_get_lines(s.preview_buf, top - 1, top, false)[1] or ""
    ok(
      top_line:find("Paragraph 40", 1, true),
      "anchor block restored at the top, got: " .. top_line
    )
  end)

  it("jumps from a preview block to the source location with <CR>", function()
    close_all()
    local src = make_source(sample_lines)
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "current" }))
    local s = session.get_by_preview(vim.api.nvim_get_current_buf())

    -- Put the preview cursor on the "Final paragraph" block.
    local rows = vim.api.nvim_buf_get_lines(s.preview_buf, 0, -1, false)
    local row
    for i, line in ipairs(rows) do
      if line:find("Final paragraph", 1, true) then
        row = i
      end
    end
    ok(row)
    vim.api.nvim_win_set_cursor(0, { row, s.plan.margin + 2 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    vim.wait(100)

    eq(src, vim.api.nvim_get_current_buf())
    eq(13, vim.api.nvim_win_get_cursor(0)[1])
    eq(0, session.count())
  end)

  it("follows in-document heading and footnote anchors without leaving the preview", function()
    close_all()
    local src = make_source({
      "# Top",
      "",
      "Read [details](#details) and note[^n].",
      "",
      "## Details",
      "",
      "Details body.",
      "",
      "[^n]: Supporting detail.",
    })
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "current" }))
    local s = session.get_by_preview(vim.api.nvim_get_current_buf())
    local rows = vim.api.nvim_buf_get_lines(s.preview_buf, 0, -1, false)
    local link_row, link_col, note_row, note_col
    for i, line in ipairs(rows) do
      link_col = link_col or line:find("details", 1, true)
      if link_col and not link_row then
        link_row = i
      end
      local col = line:find("[1]", 1, true)
      if col and not note_row then
        note_row, note_col = i, col
      end
    end
    ok(link_row and note_row)

    vim.api.nvim_win_set_cursor(0, { link_row, link_col - 1 })
    vim.api.nvim_feedkeys("gx", "x", false)
    vim.wait(50)
    eq(s.preview_buf, vim.api.nvim_get_current_buf())
    eq(s.plan.anchors.details.row + 1, vim.api.nvim_win_get_cursor(0)[1])

    vim.api.nvim_win_set_cursor(0, { note_row, note_col - 1 })
    vim.api.nvim_feedkeys("gx", "x", false)
    vim.wait(50)
    eq(s.plan.anchors["fn-n"].row + 1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("navigates to the next and previous headings", function()
    close_all()
    local src = make_source({ "# Top", "", "body", "", "## Middle" })
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "current" }))
    local active = session.get_by_preview(vim.api.nvim_get_current_buf())
    vim.api.nvim_win_set_cursor(0, { active.plan.headings[1].row + 1, 0 })

    vim.api.nvim_feedkeys("]]", "x", false)
    vim.wait(30)
    eq(active.plan.headings[2].row + 1, vim.api.nvim_win_get_cursor(0)[1])
    vim.api.nvim_feedkeys("[[", "x", false)
    vim.wait(30)
    eq(active.plan.headings[1].row + 1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("selects a heading from the outline", function()
    close_all()
    local src = make_source({ "# Top", "", "## Middle", "", "### Bottom" })
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "current" }))
    local active = session.get_by_preview(vim.api.nvim_get_current_buf())
    local old_select = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      eq(3, #items)
      eq("mdeye headings", opts.prompt)
      eq("    Bottom", opts.format_item(items[3]))
      on_choice(items[3])
    end
    vim.api.nvim_feedkeys("gO", "x", false)
    vim.wait(30)
    vim.ui.select = old_select
    eq(active.plan.headings[3].row + 1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("copies the fenced block under the cursor", function()
    close_all()
    local src = make_source({
      "# Code",
      "",
      "```lua",
      "local answer = 42",
      "print(answer)",
      "```",
    })
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "current" }))
    local s = session.get_by_preview(vim.api.nvim_get_current_buf())
    local code = s.plan.code_blocks[1]
    vim.api.nvim_win_set_cursor(0, { code.row_start + 1, 0 })
    vim.cmd("MDEye copy-code")
    eq("local answer = 42\nprint(answer)\n", vim.fn.getreg('"'))
  end)

  it("copies live fenced content before the debounced preview update", function()
    close_all()
    local src = make_source({
      "# Code",
      "",
      "```lua",
      "local answer = 1",
      "```",
    })
    local src_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "split" }))

    vim.api.nvim_buf_set_lines(src, 3, 4, false, { "local answer = 2" })
    vim.api.nvim_set_current_win(src_win)
    vim.api.nvim_win_set_cursor(src_win, { 4, 0 })
    ok(mdeye.copy_code())
    eq("local answer = 2\n", vim.fn.getreg('"'))
  end)

  it("resolves relative links against the source path, not the cwd", function()
    close_all()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/docs", "p")
    local target = dir .. "/docs/other.md"
    vim.fn.writefile({ "# Intro", "", "## Other Target", "", "body" }, target)
    local src =
      make_source({ "A [relative](./docs/other.md#other-target) link." }, dir .. "/README.md")
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "current" }))
    local s = session.get_by_preview(vim.api.nvim_get_current_buf())

    local line = vim.api.nvim_buf_get_lines(s.preview_buf, 0, -1, false)
    local row, col
    for i, l in ipairs(line) do
      local c = l:find("relative", 1, true)
      if c then
        row, col = i, c - 1
      end
    end
    ok(row)
    vim.api.nvim_win_set_cursor(0, { row, col })
    vim.api.nvim_feedkeys("gx", "x", false)
    vim.wait(100)
    -- Compare real paths: on macOS /var is a symlink to /private/var.
    eq(vim.uv.fs_realpath(target), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("opens and closes a tab-page preview", function()
    close_all()
    local src = make_source(sample_lines)
    vim.api.nvim_set_current_buf(src)
    local tabs_before = #vim.api.nvim_list_tabpages()
    ok(mdeye.open({ mode = "tab" }))
    eq(tabs_before + 1, #vim.api.nvim_list_tabpages())
    ok(mdeye.close())
    vim.wait(50)
    eq(tabs_before, #vim.api.nvim_list_tabpages())
    eq(0, session.count())
  end)

  it("survives a preview wiped by an ordinary buffer switch", function()
    close_all()
    local src = make_source(sample_lines)
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "current" }))
    local preview = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(other)
    vim.wait(50)
    eq(false, vim.api.nvim_buf_is_valid(preview))
    eq(0, session.count())
    -- Reopening creates a fresh preview rather than focusing a stale handle.
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "current" }))
    ok(vim.api.nvim_get_current_buf() ~= preview)
    eq(1, session.count())
  end)

  it("cleans up when the source buffer is wiped", function()
    close_all()
    local src = make_source(sample_lines)
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "split" }))
    local s = session.get(src)
    vim.api.nvim_buf_delete(src, { force = true })
    vim.wait(100)
    eq(0, session.count())
    eq(false, vim.api.nvim_buf_is_valid(s.preview_buf))
  end)

  it("leaks nothing across repeated open/close cycles", function()
    close_all()
    local src = make_source(sample_lines)
    vim.api.nvim_set_current_buf(src)

    -- Warm up once so lazy state (highlights, namespaces) is created.
    ok(mdeye.open({ mode = "current" }))
    ok(mdeye.close())
    vim.wait(50)

    local bufs_before = #vim.api.nvim_list_bufs()
    local autocmds_before = autocmd_count()
    for _ = 1, 10 do
      ok(mdeye.open({ mode = "current" }))
      ok(mdeye.close())
      vim.wait(30)
    end
    eq(bufs_before, #vim.api.nvim_list_bufs())
    eq(autocmds_before, autocmd_count())
    eq(0, session.count())
    eq(src, vim.api.nvim_get_current_buf())

    for _ = 1, 5 do
      ok(mdeye.open({ mode = "split" }))
      ok(mdeye.close())
      vim.wait(30)
    end
    eq(bufs_before, #vim.api.nvim_list_bufs())
    eq(autocmds_before, autocmd_count())
    eq(1, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("keeps default highlight links across ColorScheme", function()
    local link = vim.api.nvim_get_hl(0, { name = "MDEyeHeading1", link = true }).link
    ok(link, "MDEyeHeading1 has a default link")
    vim.cmd("hi clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    local relink = vim.api.nvim_get_hl(0, { name = "MDEyeHeading1", link = true }).link
    ok(relink, "default link restored after ColorScheme")

    -- Explicit user highlights stay authoritative.
    vim.api.nvim_set_hl(0, "MDEyeStrong", { bold = true, fg = "#ff0000" })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    local user = vim.api.nvim_get_hl(0, { name = "MDEyeStrong" })
    eq("#FF0000", ("#%06X"):format(user.fg or 0):upper())
  end)

  it("renders the research fixture end to end", function()
    close_all()
    local bufnr = vim.fn.bufadd(root .. "/tests/fixtures/comprehensive.md")
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].filetype = "markdown"
    vim.api.nvim_set_current_buf(bufnr)
    ok(mdeye.open({ mode = "current" }))
    local text = preview_text()
    ok(text:find("Heading One", 1, true))
    ok(not text:find("```", 1, true))
    ok(not text:find("|%s*Column A"), "pipe borders replaced")
    ok(mdeye.close())
  end)
end)

describe("Mermaid sessions", function()
  it("validates the native rendering option", function()
    local config = require("mdeye.config")
    ok(config.setup({ mermaid = { enabled = "yes" } }))
    eq(nil, config.setup({ mermaid = { enabled = false } }))
    eq(false, config.options.mermaid.enabled)
    mdeye.setup({ debounce_ms = 20 })
  end)

  it("copies source, reflows, updates unsaved diagrams, and jumps to the fence", function()
    close_all()
    local src = make_source({ "# Diagram", "", "```mermaid", "flowchart LR", "A --> B", "```" })
    vim.api.nvim_set_current_buf(src)
    ok(mdeye.open({ mode = "split" }))
    local s = session.get(src)
    vim.api.nvim_set_current_win(s.owner_win)
    local block = s.plan.code_blocks[1]
    vim.api.nvim_win_set_cursor(0, { block.row_start + 2, 0 })
    ok(mdeye.copy_code())
    eq("flowchart LR\nA --> B\n", vim.fn.getreg('"'))
    local old_width = s.plan.width
    vim.api.nvim_win_set_width(s.owner_win, 24)
    vim.api.nvim_exec_autocmds("WinResized", {})
    ok(vim.wait(2000, function()
      return s.plan.width ~= old_width
    end, 10))
    ok(preview_text():find("  v", 1, true))
    vim.api.nvim_buf_set_lines(src, 4, 5, false, { "A --> C" })
    ok(vim.wait(2000, function()
      return preview_text():find("| C", 1, true) ~= nil
    end, 10))
    vim.api.nvim_buf_set_lines(src, 4, 5, false, { "A -->" })
    ok(vim.wait(2000, function()
      return preview_text():find("mermaid (source)", 1, true) ~= nil
    end, 10))
    vim.api.nvim_buf_set_lines(src, 4, 5, false, { "A --> D" })
    ok(vim.wait(2000, function()
      return preview_text():find("| D", 1, true) ~= nil
    end, 10))
    block = s.plan.code_blocks[1]
    vim.api.nvim_win_set_cursor(0, { block.row_end + 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    eq(src, vim.api.nvim_get_current_buf())
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    close_all()
  end)
end)
