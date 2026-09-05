local images = require("mdeye.images")
local document = require("mdeye.document")
local layout = require("mdeye.layout")
local render = require("mdeye.render")
local config = require("mdeye.config")

local function with_backend(fn)
  local old = package.loaded.image
  local calls = { created = 0, rendered = 0, cleared = 0 }
  package.loaded.image = {
    is_enabled = function()
      return true
    end,
    from_file = function(path, opts)
      calls.created = calls.created + 1
      calls.path, calls.opts = path, opts
      if calls.decode_error then
        error("decode failed")
      end
      return {
        image_width = 200,
        image_height = 100,
        render = function(_, geometry)
          if calls.render_error then
            error("render failed")
          end
          calls.rendered = calls.rendered + 1
          calls.geometry = geometry
        end,
        clear = function()
          calls.cleared = calls.cleared + 1
        end,
      }
    end,
  }
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir)
  vim.fn.writefile({ "fixture" }, dir .. "/local image.png")
  local src, preview = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(src, dir .. "/document.md")
  vim.api.nvim_buf_set_lines(src, 0, -1, false, {
    "![Local](local%20image.png)",
    "",
    "![Remote](https://example.com/image.png)",
    "",
    "![Missing](missing.png)",
  })
  local saved_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(0, preview)
  local session =
    { src_buf = src, preview_buf = preview, owner_win = vim.api.nvim_get_current_win() }
  local opts = vim.tbl_extend("force", config.options.images, { enabled = true })
  local ok_test, err = xpcall(function()
    fn(session, opts, calls)
  end, debug.traceback)
  images.clear(session)
  vim.api.nvim_win_set_buf(0, saved_buf)
  vim.api.nvim_buf_delete(src, { force = true })
  if vim.api.nvim_buf_is_valid(preview) then
    vim.api.nvim_buf_delete(preview, { force = true })
  end
  vim.fn.delete(dir, "rf")
  package.loaded.image = old
  if not ok_test then
    error(err)
  end
end

describe("optional local images", function()
  it("resolves paths, caches handles, reserves cells, and retains alt text", function()
    with_backend(function(session, opts, calls)
      local doc = assert(document.parse(session.src_buf))
      local specs = images.prepare(session, doc, opts)
      eq(1, calls.created)
      eq(1, vim.tbl_count(specs))
      ok(calls.path:find("local image.png", 1, true))
      eq(false, calls.opts.with_virtual_padding)
      eq(-1, calls.opts.render_offset_top)
      local plan =
        layout.plan(doc, { usable_width = 50, max_width = 44, min_margin = 3, image_specs = specs })
      eq(1, #plan.images)
      eq(44, plan.images[1].width)
      eq(11, plan.images[1].height)
      ok(table.concat(plan.lines, "\n"):find("Local", 1, true))
      ok(table.concat(plan.lines, "\n"):find("Remote", 1, true))
      render.apply(session.preview_buf, plan)
      session.plan = plan
      eq(false, images.refresh(session))
      eq(1, calls.rendered)
      eq(plan.images[1].row_start, calls.geometry.y)
      ok(#plan.lines[plan.images[1].row_start + 1] >= calls.geometry.x + calls.geometry.width)
      images.prepare(session, doc, opts)
      eq(1, calls.created)
      images.prepare(session, doc, vim.tbl_extend("force", opts, { enabled = false }))
      eq(0, vim.tbl_count(session.image_cache))
      ok(calls.cleared > 0)
    end)
  end)

  it("hides folded images and clears removed images", function()
    with_backend(function(session, opts, calls)
      local doc = assert(document.parse(session.src_buf))
      session.plan = layout.plan(doc, {
        usable_width = 50,
        max_width = 44,
        min_margin = 3,
        image_specs = images.prepare(session, doc, opts),
      })
      render.apply(session.preview_buf, session.plan)
      render.setup_window(session.owner_win)
      local image = session.plan.images[1]
      vim.cmd(("%d,%dfold"):format(image.row_start, image.row_end + 1))
      images.refresh(session)
      eq(0, calls.rendered)
      ok(calls.cleared > 0)
      vim.cmd("normal! zR")
      images.refresh(session)
      eq(1, calls.rendered)
      vim.api.nvim_buf_set_lines(session.src_buf, 0, -1, false, { "No images" })
      images.prepare(session, assert(document.parse(session.src_buf)), opts)
      eq(0, vim.tbl_count(session.image_cache))
    end)
  end)

  it("falls back for backend errors, file limits, and disabled backends", function()
    with_backend(function(session, opts, calls)
      local doc = assert(document.parse(session.src_buf))
      eq({}, images.prepare(session, doc, vim.tbl_extend("force", opts, { max_file_size = 1 })))
      eq(0, calls.created)
      calls.decode_error = true
      eq({}, images.prepare(session, doc, opts))
      calls.decode_error = false
      images.clear(session)
      local specs = images.prepare(session, doc, opts)
      session.plan =
        layout.plan(doc, { usable_width = 50, max_width = 44, min_margin = 3, image_specs = specs })
      render.apply(session.preview_buf, session.plan)
      calls.render_error = true
      eq(true, images.refresh(session))
      eq({}, images.prepare(session, doc, opts))
      ok(session.image_status:find("rendering failed", 1, true))
      package.loaded.image.is_enabled = function()
        return false
      end
      eq({}, images.prepare(session, doc, opts))
    end)
  end)
end)
