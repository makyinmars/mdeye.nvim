local mermaid_image = require("mdeye.mermaid_image")
local document = require("mdeye.document")
local layout = require("mdeye.layout")
local config = require("mdeye.config")

local TINY_PNG = vim.base64.decode(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwADhQGAhNmMIwAAAABJRU5ErkJggg=="
)

local function write_png(path)
  local fd = assert(vim.uv.fs_open(path, "w", 420))
  assert(vim.uv.fs_write(fd, TINY_PNG))
  vim.uv.fs_close(fd)
end

local function mermaid_doc(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  local doc = assert(document.parse(buf))
  return buf, doc
end

local function fence_byte(doc)
  local byte
  local function walk(blocks)
    for _, block in ipairs(blocks) do
      if block.kind == "code" then
        byte = block.source.start_byte
      end
      if block.blocks then
        walk(block.blocks)
      end
    end
  end
  walk(doc.blocks)
  return byte
end

local function make_fake_mmdc(kind)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir)
  local png = dir .. "/tiny.png"
  write_png(png)
  local bin = dir .. "/mmdc"
  local lines
  if kind == "ok" then
    lines = {
      "#!/bin/sh",
      'touch "' .. dir .. '/invoked"',
      "out=",
      "while [ $# -gt 0 ]; do",
      '  if [ "$1" = "--output" ]; then out="$2"; shift 2',
      "  else shift",
      "  fi",
      "done",
      'cp "' .. png .. '" "$out"',
    }
  elseif kind == "fail" then
    lines = { "#!/bin/sh", "exit 3" }
  else
    lines = { "#!/bin/sh", "sleep 30" }
  end
  vim.fn.writefile(lines, bin)
  vim.fn.setfperm(bin, "rwx------")
  return dir, bin
end

local function image_opts(command, extra)
  extra = extra or {}
  return {
    enabled = extra.enabled or "auto",
    command = command,
    timeout_ms = extra.timeout_ms or 1500,
    theme = extra.theme or "dark",
    background = extra.background or "transparent",
  }
end

describe("mermaid image adapter", function()
  it("hashes source, theme, and background", function()
    local a = mermaid_image.hash("flowchart LR\nA-->B", "dark", "transparent")
    local b = mermaid_image.hash("flowchart LR\nA-->B", "dark", "transparent")
    local c = mermaid_image.hash("flowchart LR\nA-->B", "default", "transparent")
    local d = mermaid_image.hash("flowchart LR\nA-->C", "dark", "transparent")
    eq(a, b)
    ok(a ~= c)
    ok(a ~= d)
    eq(64, #a)
  end)

  it("validates mermaid.image.enabled", function()
    ok(config.setup({ mermaid = { image = { enabled = "yes" } } }))
    eq(nil, config.setup({ mermaid = { image = { enabled = "off" } } }))
    eq("off", config.options.mermaid.image.enabled)
    config.setup({})
  end)

  it("does not spawn when disabled or oversized", function()
    local buf, doc = mermaid_doc({ "```mermaid", "flowchart LR", "A-->B", "```" })
    local session = { closed = false }
    local states = mermaid_image.prepare(session, doc, {
      enabled = true,
      image = image_opts("/definitely-not-mmdc", { enabled = "off" }),
    })
    eq({}, states)
    local huge = { "```mermaid", "flowchart LR", string.rep("A", 65537), "```" }
    local buf2, big = mermaid_doc(huge)
    local dir, bin = make_fake_mmdc("ok")
    states = mermaid_image.prepare({ closed = false, mermaid_cache = {}, mermaid_jobs = {} }, big, {
      enabled = true,
      image = image_opts(bin),
      cache_dir = dir .. "/cache",
    })
    eq({}, states)
    eq(0, vim.fn.filereadable(dir .. "/invoked"))
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(buf2, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  it("reuses a cached PNG without spawning", function()
    local source = "flowchart LR\nA-->B"
    local buf, doc = mermaid_doc({ "```mermaid", "flowchart LR", "A-->B", "```" })
    local dir, bin = make_fake_mmdc("ok")
    local cache_dir = dir .. "/cache"
    vim.fn.mkdir(cache_dir)
    local hash = mermaid_image.hash(source, "dark", "transparent")
    write_png(mermaid_image.cache_path(cache_dir, hash))
    local session = { closed = false, mermaid_cache = {}, mermaid_jobs = {} }
    local states = mermaid_image.prepare(session, doc, {
      enabled = true,
      image = image_opts(bin),
      cache_dir = cache_dir,
    })
    local byte = fence_byte(doc)
    eq("ready", states[byte].status)
    eq(hash, states[byte].hash)
    eq(0, vim.fn.filereadable(dir .. "/invoked"))
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  it("reserves image rows and keeps original copy text", function()
    local buf, doc = mermaid_doc({ "```mermaid", "flowchart LR", "A-->B", "```" })
    local byte = fence_byte(doc)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir)
    local png = dir .. "/diagram.png"
    write_png(png)
    local plan = layout.plan(doc, {
      usable_width = 80,
      max_width = 60,
      min_margin = 3,
      mermaid_images = {
        [byte] = { status = "ready", hash = "abc", path = png },
      },
      image_specs = {
        [byte] = { key = "k", aspect = 0.5, max_width = 40, max_height = 8 },
      },
    })
    local text = table.concat(plan.lines, "\n")
    ok(text:find("mermaid (image)", 1, true))
    ok(text:find("open image", 1, true))
    ok(not text:find("flowchart LR", 1, true))
    eq(1, #plan.images)
    eq("mermaid-image:abc", plan.row_keys[plan.images[1].row_start + 1])
    eq({ "flowchart LR", "A-->B" }, plan.code_blocks[1].lines)
    local has_link
    for _, mark in ipairs(plan.marks) do
      if mark.target and mark.target:find("diagram.png", 1, true) then
        has_link = true
      end
    end
    ok(has_link)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  it("keeps ASCII while a render is pending when the native graph exists", function()
    local buf, doc = mermaid_doc({ "```mermaid", "flowchart LR", "A-->B", "```" })
    local byte = fence_byte(doc)
    local plan = layout.plan(doc, {
      usable_width = 80,
      min_margin = 3,
      mermaid_images = { [byte] = { status = "pending", hash = "abc" } },
    })
    local text = table.concat(plan.lines, "\n")
    ok(text:find("mermaid (graph)", 1, true) or text:find("mermaid (connections)", 1, true))
    ok(not text:find("rendering mermaid", 1, true))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("shows a rendering row for pending unsupported diagrams", function()
    local buf, doc = mermaid_doc({
      "```mermaid",
      "pie",
      "title Pets",
      '"Dogs": 10',
      "```",
    })
    local byte = fence_byte(doc)
    local plan = layout.plan(doc, {
      usable_width = 80,
      min_margin = 3,
      mermaid_images = { [byte] = { status = "pending", hash = "abc" } },
    })
    local text = table.concat(plan.lines, "\n")
    ok(text:find("mermaid (image)", 1, true))
    ok(text:find("rendering mermaid", 1, true))
    ok(not text:find("title Pets", 1, true))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

if vim.fn.has("unix") == 1 then
  describe("mermaid image jobs", function()
    it("spawns mmdc and records a ready PNG", function()
      local buf, doc = mermaid_doc({ "```mermaid", "flowchart LR", "A-->B", "```" })
      local dir, bin = make_fake_mmdc("ok")
      local session = { closed = false, mermaid_cache = {}, mermaid_jobs = {} }
      local ready = false
      mermaid_image.prepare(session, doc, {
        enabled = true,
        image = image_opts(bin),
        cache_dir = dir .. "/cache",
        on_ready = function()
          ready = true
        end,
      })
      ok(
        vim.wait(2000, function()
          return ready
        end, 10),
        "mmdc did not finish"
      )
      local byte = fence_byte(doc)
      local states = mermaid_image.prepare(session, doc, {
        enabled = true,
        image = image_opts(bin),
        cache_dir = dir .. "/cache",
      })
      eq("ready", states[byte].status)
      ok(states[byte].path and vim.uv.fs_stat(states[byte].path))
      vim.api.nvim_buf_delete(buf, { force = true })
      mermaid_image.clear(session)
      vim.fn.delete(dir, "rf")
    end)

    it("maps a non-zero exit to a failed state without a spec", function()
      local buf, doc = mermaid_doc({ "```mermaid", "flowchart LR", "A-->B", "```" })
      local dir, bin = make_fake_mmdc("fail")
      local session = { closed = false, mermaid_cache = {}, mermaid_jobs = {} }
      local done = false
      mermaid_image.prepare(session, doc, {
        enabled = true,
        image = image_opts(bin),
        cache_dir = dir .. "/cache",
        on_ready = function()
          done = true
        end,
      })
      ok(vim.wait(2000, function()
        return done
      end, 10))
      local byte = fence_byte(doc)
      local states = mermaid_image.prepare(session, doc, {
        enabled = true,
        image = image_opts(bin),
        cache_dir = dir .. "/cache",
      })
      eq("failed", states[byte].status)
      eq(nil, states[byte].path)
      ok(states[byte].reason:find("exited", 1, true))
      vim.api.nvim_buf_delete(buf, { force = true })
      mermaid_image.clear(session)
      vim.fn.delete(dir, "rf")
    end)

    it("times out a stuck renderer", function()
      local buf, doc = mermaid_doc({ "```mermaid", "flowchart LR", "A-->B", "```" })
      local dir, bin = make_fake_mmdc("sleep")
      local session = { closed = false, mermaid_cache = {}, mermaid_jobs = {} }
      local done = false
      mermaid_image.prepare(session, doc, {
        enabled = true,
        image = image_opts(bin, { timeout_ms = 100 }),
        cache_dir = dir .. "/cache",
        on_ready = function()
          done = true
        end,
      })
      ok(
        vim.wait(2000, function()
          return done
        end, 10),
        "timeout was not reported"
      )
      local hash = mermaid_image.hash("flowchart LR\nA-->B", "dark", "transparent")
      eq("failed", session.mermaid_cache[hash].status)
      eq("mermaid render timed out", session.mermaid_cache[hash].reason)
      vim.api.nvim_buf_delete(buf, { force = true })
      mermaid_image.clear(session)
      vim.fn.delete(dir, "rf")
    end)

    it("ignores a completed job after the session closed", function()
      local buf, doc = mermaid_doc({ "```mermaid", "flowchart LR", "A-->B", "```" })
      local dir, bin = make_fake_mmdc("ok")
      local session = { closed = false, mermaid_cache = {}, mermaid_jobs = {} }
      local called = false
      mermaid_image.prepare(session, doc, {
        enabled = true,
        image = image_opts(bin),
        cache_dir = dir .. "/cache",
        on_ready = function()
          called = true
        end,
      })
      session.closed = true
      vim.wait(500, function()
        return called
      end, 10)
      eq(false, called)
      vim.api.nvim_buf_delete(buf, { force = true })
      mermaid_image.clear(session)
      vim.fn.delete(dir, "rf")
    end)
  end)
end
