const std = @import("std");
const node = @import("node.zig");
const hl = @import("highlight.zig");

const Node = node.Node;
const Writer = node.Writer;
const Bytes = node.Bytes;

const Heading = struct { 
  color: Bytes, 
  prefix: Bytes 
};

const Style = struct {
  bold: bool = false,
  italic: bool = false,
  quoted: bool = false,
  ambient: ?Bytes = null,
};

const ansi = struct {
  pub const RESET = "\x1b[0m";
  pub const BOLD = "\x1b[1m";
  pub const DIM = "\x1b[2m";
  pub const ITALIC = "\x1b[3m";
  pub const UNDERLINE = "\x1b[4m";
  pub const BOLD_ITALIC = "\x1b[1;3m";
  pub const RED = "\x1b[31m";
  pub const GREEN = "\x1b[32m";
  pub const YELLOW = "\x1b[33m";
  pub const BLUE = "\x1b[34m";
  pub const MAGENTA = "\x1b[35m";
  pub const CYAN = "\x1b[36m";
  pub const GRAY = "\x1b[90m";
  pub const LIGHT_GRAY = "\x1b[37m";
  pub const BRIGHT_WHITE = "\x1b[97m";
  pub const BG_GRAY = "\x1b[48;5;236m";
  pub const PURPLE = "\x1b[35m";
  pub const BRIGHT_RED = "\x1b[91m";
  pub const PINK = "\x1b[38;5;212m";
};

const CalloutStyle = struct {
  emoji: Bytes,
  label: Bytes,
  color: Bytes,
  border_color: Bytes,
};

const callout_styles = blk: {
  const S = CalloutStyle;
  break :blk [_]S{
    .{ .emoji = "ℹ️", .label = "Note", .color = ansi.BLUE, .border_color = "\x1b[34m" },
    .{ .emoji = "💡", .label = "Tip", .color = ansi.GREEN, .border_color = "\x1b[32m" },
    .{ .emoji = "💬", .label = "Important", .color = ansi.PURPLE, .border_color = "\x1b[35m" },
    .{ .emoji = "⚠️", .label = "Warning", .color = ansi.YELLOW, .border_color = "\x1b[33m" },
    .{ .emoji = "🛑", .label = "Caution", .color = ansi.BRIGHT_RED, .border_color = "\x1b[91m" },
  };
};

const headings = [_]Heading{
  .{ .color = "", .prefix = "" },
  .{ .color = ansi.BOLD ++ ansi.RED, .prefix = "# " },
  .{ .color = ansi.BOLD ++ ansi.YELLOW, .prefix = "## " },
  .{ .color = ansi.BOLD ++ ansi.GREEN, .prefix = "### " },
  .{ .color = ansi.BOLD ++ ansi.CYAN, .prefix = "#### " },
  .{ .color = ansi.BOLD ++ ansi.BLUE, .prefix = "##### " },
  .{ .color = ansi.BOLD ++ ansi.MAGENTA, .prefix = "###### " },
};

const Ctx = struct {
  w: Writer,
  highlighter: ?*hl.Highlighter,
  margin: u16,
  show_urls: bool,
  tui: bool = false,

  fn writeMargin(self: Ctx) anyerror!void {
    var i: u16 = 0;
    while (i < self.margin) : (i += 1) try self.w.writeAll(" ");
  }

  fn styled(self: Ctx, n: ?*Node, depth: u32, style: Style) anyerror!void {
    var cur = n;
    while (cur) |nd| : (cur = nd.next) try self.renderNode(nd, depth, style);
  }

  fn writeIndent(self: Ctx, n: u32) anyerror!void {
    var i: u32 = 0;
    while (i < n) : (i += 1) try self.w.writeAll(" ");
  }

  fn restoreStyle(self: Ctx, style: Style) anyerror!void {
    if (style.ambient) |a| try self.w.writeAll(a);
    if (style.bold and style.italic) try self.w.writeAll(ansi.BOLD_ITALIC ++ ansi.BRIGHT_WHITE)
    else if (style.bold) try self.w.writeAll(ansi.BOLD ++ ansi.BRIGHT_WHITE) 
    else if (style.italic) try self.w.writeAll(ansi.ITALIC);
  }

  fn renderCode(self: Ctx, txt: Bytes, style: Style) anyerror!void {
    try self.w.writeAll(ansi.BG_GRAY ++ ansi.BRIGHT_WHITE ++ " ");
    try self.w.writeAll(txt);
    try self.w.writeAll(" " ++ ansi.RESET);
    try self.restoreStyle(style);
  }

  fn renderBold(self: Ctx, nd: *Node, depth: u32, style: Style) anyerror!void {
    if (style.ambient) |_| try self.w.writeAll(ansi.BOLD) else {
      try self.w.writeAll(if (style.italic) ansi.BOLD_ITALIC else ansi.BOLD);
      try self.w.writeAll(ansi.BRIGHT_WHITE);
    }
    try self.styled(nd.children, depth, .{
      .bold = true,
      .italic = style.italic,
      .ambient = style.ambient,
    });
    try self.w.writeAll(ansi.RESET);
    if (style.ambient) |a| try self.w.writeAll(a) else if (style.italic) try self.w.writeAll(ansi.ITALIC);
  }

  fn renderItalic(self: Ctx, nd: *Node, depth: u32, style: Style) anyerror!void {
    if (style.ambient) |_| try self.w.writeAll(ansi.ITALIC) else {
      try self.w.writeAll(if (style.bold) ansi.BOLD_ITALIC ++ ansi.BRIGHT_WHITE else ansi.ITALIC);
    }
    try self.styled(nd.children, depth, .{
      .bold = style.bold,
      .italic = true,
      .ambient = style.ambient,
    });
    try self.w.writeAll(ansi.RESET);
    if (style.ambient) |a| try self.w.writeAll(a) else if (style.bold) {
      try self.w.writeAll(ansi.BOLD);
      try self.w.writeAll(ansi.BRIGHT_WHITE);
    }
  }

  fn isFragment(url: Bytes) bool {
    return url.len > 0 and url[0] == '#';
  }

  fn renderLink(self: Ctx, lnk: Node.Link, style: Style) anyerror!void {
    const clickable = lnk.url.len > 0 and !isFragment(lnk.url);
    const is_frag = isFragment(lnk.url);
    if (clickable and !self.tui) {
      try self.w.writeAll("\x1b]8;;");
      try self.w.writeAll(lnk.url);
      try self.w.writeAll("\x1b\\");
    }
    if (self.tui and (is_frag or clickable)) {
      try self.w.writeAll("\x1b_L;");
      if (is_frag) try self.w.writeAll(lnk.url[1..])
      else try self.w.writeAll(lnk.url);
      try self.w.writeAll("\x1b\\");
    }
    try self.w.writeAll(ansi.UNDERLINE ++ ansi.CYAN);
    try self.w.writeAll(lnk.label);
    try self.w.writeAll(ansi.RESET);
    if (self.tui and (is_frag or clickable)) {
      try self.w.writeAll("\x1b_E\x1b\\");
    }
    if (clickable and !self.tui) {
      try self.w.writeAll("\x1b]8;;\x1b\\");
    }
    if (clickable and self.show_urls) {
      try self.w.writeAll(" \x1b[38;5;239m(");
      try self.w.writeAll(lnk.url);
      try self.w.writeAll(")" ++ ansi.RESET);
    }
    try self.restoreStyle(style);
  }

  fn renderImage(self: Ctx, img: Node.Link, style: Style) anyerror!void {
    try self.w.writeAll(ansi.GRAY);
    try self.w.writeAll("Image: ");
    try self.w.writeAll(ansi.ITALIC);
    try self.w.writeAll(img.label);
    try self.w.writeAll(ansi.RESET);
    if (img.url.len > 0) {
      try self.w.writeAll(ansi.GRAY);
      try self.w.writeAll(" → ");
      try self.w.writeAll(ansi.RESET);
      try self.w.writeAll(ansi.UNDERLINE ++ ansi.PINK);
      try self.w.writeAll(img.url);
      try self.w.writeAll(ansi.RESET);
    }
    try self.restoreStyle(style);
  }

  fn renderHeading(self: Ctx, nd: *Node, level: u3, depth: u32) anyerror!void {
    const h = headings[level];
    try self.w.writeAll("\n");
    if (self.tui) {
      var text_buf: [256]u8 = undefined;
      var text_pos: usize = 0;
      collectHeadingText(nd, &text_buf, &text_pos);
      var slug_buf: [256]u8 = undefined;
      const slug = slugify(text_buf[0..text_pos], &slug_buf);
      if (slug.len > 0) {
        try self.w.writeAll("\x1b_H;");
        try self.w.writeAll(slug);
        try self.w.writeAll("\x1b\\");
      }
    }
    try self.writeMargin();
    try self.w.writeAll(h.color);
    try self.w.writeAll(h.prefix);
    try self.styled(nd.children, depth, .{ .ambient = h.color });
    try self.w.writeAll(ansi.RESET ++ "\n");
  }

  fn renderParagraph(self: Ctx, nd: *Node, depth: u32, quoted: bool) anyerror!void {
    if (quoted) {
      try self.styled(nd.children, depth, .{});
      return;
    }
    if (depth == 0) {
      if (nd.children != null) try self.styled(nd.children, depth + 1, .{});
      return;
    }
    try self.w.writeAll("\n");
    try self.writeMargin();
    try self.styled(nd.children, depth, .{});
    try self.w.writeAll("\n");
  }

  fn renderListItem(self: Ctx, nd: *Node, li: node.Node.List, depth: u32, quoted: bool) anyerror!void {
    if (!quoted and li.first) try self.w.writeAll("\n");
    if (!quoted) try self.writeMargin();
    try self.writeIndent(if (quoted) @as(u32, li.indent) + 1 else depth + li.indent);
    try self.w.writeAll(ansi.CYAN ++ "•" ++ ansi.RESET ++ " ");
    try self.styled(nd.children, depth, .{});
    if (!quoted) try self.w.writeAll("\n");
  }

  fn renderOrderedItem(self: Ctx, nd: *Node, ol: Node.Ordered, depth: u32, quoted: bool) anyerror!void {
    if (!quoted and ol.first) try self.w.writeAll("\n");
    if (!quoted) try self.writeMargin();
    try self.writeIndent(if (quoted) @as(u32, ol.indent) + 1 else depth + ol.indent);
    try self.w.print(ansi.CYAN ++ "{d}." ++ ansi.RESET ++ " ", .{ol.number});
    try self.styled(nd.children, depth, .{});
    if (!quoted) try self.w.writeAll("\n");
  }

  fn renderTaskItem(self: Ctx, nd: *Node, ti: Node.Task, depth: u32, quoted: bool) anyerror!void {
    if (!quoted and ti.first) try self.w.writeAll("\n");
    if (!quoted) try self.writeMargin();
    try self.writeIndent(if (quoted) @as(u32, ti.indent) + 1 else depth + ti.indent);
    if (ti.checked) {
      try self.w.writeAll(ansi.LIGHT_GRAY ++ "[" ++ ansi.GREEN ++ "✓" ++ ansi.LIGHT_GRAY ++ "] " ++ ansi.RESET);
      try self.styled(nd.children, depth, .{});
      try self.w.writeAll(ansi.RESET);
    } else {
      try self.w.writeAll(ansi.LIGHT_GRAY ++ "[ ]" ++ ansi.RESET ++ " ");
      try self.styled(nd.children, depth, .{});
    }
    if (!quoted) try self.w.writeAll("\n");
  }

  fn renderBlockquote(self: Ctx, nd: *Node, depth: u32) anyerror!void {
    try self.w.writeAll("\n");
    var child = nd.children;
    while (child) |ch| : (child = ch.next) {
      try self.writeMargin();
      try self.w.writeAll(ansi.DIM ++ "┃ " ++ ansi.RESET);
      try self.renderNode(ch, depth, .{ .quoted = true });
      try self.w.writeAll("\n");
    }
  }

  fn renderCallout(self: Ctx, nd: *Node, co: Node.Callout, depth: u32) anyerror!void {
    const cs = callout_styles[@intFromEnum(co.kind)];

    try self.w.writeAll("\n");
    try self.writeMargin();
    try self.w.writeAll(cs.border_color);
    try self.w.writeAll("┃ ");
    try self.w.writeAll(ansi.RESET);
    try self.w.writeAll(cs.emoji);
    try self.w.writeAll(" ");
    try self.w.writeAll(ansi.BOLD);
    try self.w.writeAll(cs.color);
    try self.w.writeAll(cs.label);
    try self.w.writeAll(ansi.RESET);
    try self.w.writeAll("\n");

    var child = nd.children;
    while (child) |ch| : (child = ch.next) {
      try self.writeMargin();
      try self.w.writeAll(cs.border_color);
      try self.w.writeAll("┃ ");
      try self.w.writeAll(ansi.RESET);
      try self.renderNode(ch, depth, .{ .quoted = true });
      try self.w.writeAll("\n");
    }
  }

  fn renderCodeBlock(self: Ctx, cb: Node.CodeBlock) anyerror!void {
    const pad = 2;
    const max_w = codeBlockWidth(cb.content);
    const full = max_w + pad * 2;

    const alloc = std.heap.page_allocator;
    var spans: std.ArrayList(hl.Span) = .empty;
    defer spans.deinit(alloc);
    const has_hl = if (self.highlighter) |h|
      h.highlight(cb.content, cb.lang, &spans) catch false
    else
      false;

    try self.w.writeAll("\n");
    if (cb.lang.len > 0) {
      const tab_pad = 1;
      const max_label = if (full > tab_pad * 2) full - tab_pad * 2 else 0;
      const label = if (cb.lang.len > max_label) cb.lang[0..max_label] else cb.lang;
      try self.writeMargin();
      try self.w.writeAll(ansi.BG_GRAY ++ ansi.DIM ++ ansi.ITALIC);
      try writePad(self.w, tab_pad);
      try self.w.writeAll(label);
      try writePad(self.w, tab_pad);
      try self.w.writeAll(ansi.RESET ++ "\n");
    }
    try self.writeMargin();
    try self.w.writeAll(ansi.BG_GRAY);
    try writePad(self.w, full);
    try self.w.writeAll(ansi.RESET ++ "\n");
    var pos: usize = 0;
    while (pos < cb.content.len) {
      const start = pos;
      while (pos < cb.content.len and cb.content[pos] != '\n') : (pos += 1) {}
      const line_len = pos - start;
      try self.writeMargin();
      try self.w.writeAll(ansi.BG_GRAY);
      try writePad(self.w, pad);
      if (has_hl) {
        try writeHighlightedLine(self.w, cb.content, start, pos, spans.items);
      } else {
        try self.w.writeAll(ansi.BRIGHT_WHITE);
        try self.w.writeAll(cb.content[start..pos]);
      }
      try writePad(self.w, max_w - line_len + pad);
      try self.w.writeAll(ansi.RESET ++ "\n");
      if (pos < cb.content.len) pos += 1;
    }
    try self.writeMargin();
    try self.w.writeAll(ansi.BG_GRAY);
    try writePad(self.w, full);
    try self.w.writeAll(ansi.RESET ++ "\n");
  }

  fn cellTextLen(cell: *Node) usize {
    var len: usize = 0;
    var child = cell.children;
    while (child) |ch| : (child = ch.next) {
      switch (ch.kind) {
        .text => |txt| len += txt.len,
        .code => |txt| len += txt.len + 2,
        .bold, .italic => len += cellTextLen(ch),
        .link => |lnk| len += lnk.label.len,
        else => {},
      }
    }
    return len;
  }

  fn renderTable(self: Ctx, nd: *Node) anyerror!void {
    const tbl = nd.kind.table;
    const cols = tbl.cols;
    if (cols == 0) return;

    var col_widths: [64]usize = .{0} ** 64;
    const ncols = @min(cols, 64);

    var row = nd.children;
    while (row) |r| : (row = r.next) {
      var ci: usize = 0;
      var cell = r.children;
      while (cell) |c| : (cell = c.next) {
        if (ci < ncols) {
          const w = cellTextLen(c);
          if (w > col_widths[ci]) col_widths[ci] = w;
          ci += 1;
        }
      }
    }

    const pad = 1;

    try self.w.writeAll("\n");
    try self.writeMargin();
    try self.w.writeAll(ansi.DIM ++ "┌");
    for (0..ncols) |i| {
      const w = col_widths[i] + pad * 2;
      var j: usize = 0;
      while (j < w) : (j += 1) try self.w.writeAll("─");
      if (i + 1 < ncols) try self.w.writeAll("┬") else try self.w.writeAll("┐");
    }
    try self.w.writeAll(ansi.RESET ++ "\n");

    var is_first = true;
    row = nd.children;
    while (row) |r| : (row = r.next) {
      const is_header = r.kind == .table_header;

      try self.writeMargin();
      try self.w.writeAll(ansi.DIM ++ "│" ++ ansi.RESET);
      var ci: usize = 0;
      var cell = r.children;
      while (cell) |c| : (cell = c.next) {
        if (ci < ncols) {
          const w = col_widths[ci];
          const content_len = cellTextLen(c);
          const total_pad = if (w >= content_len) w - content_len else 0;

          const col_align: Node.Table.Align = if (ci < tbl.alignments.len) tbl.alignments[ci] else .left;
          const lpad = switch (col_align) {
            .left => pad,
            .right => pad + total_pad,
            .center => pad + total_pad / 2,
          };
          const rpad = switch (col_align) {
            .left => pad + total_pad,
            .right => pad,
            .center => pad + total_pad - total_pad / 2,
          };

          try writePad(self.w, lpad);
          if (is_header) try self.w.writeAll(ansi.BOLD ++ ansi.BRIGHT_WHITE);
          try self.styled(c.children, 1, .{});
          if (is_header) try self.w.writeAll(ansi.RESET);
          try writePad(self.w, rpad);
          try self.w.writeAll(ansi.DIM ++ "│" ++ ansi.RESET);
          ci += 1;
        }
      }
      try self.w.writeAll("\n");

      if (is_first and is_header) {
        try self.writeMargin();
        try self.w.writeAll(ansi.DIM ++ "├");
        for (0..ncols) |i| {
          const w = col_widths[i] + pad * 2;
          var j: usize = 0;
          while (j < w) : (j += 1) try self.w.writeAll("─");
          if (i + 1 < ncols) try self.w.writeAll("┼") else try self.w.writeAll("┤");
        }
        try self.w.writeAll(ansi.RESET ++ "\n");
      }
      is_first = false;
    }

    try self.writeMargin();
    try self.w.writeAll(ansi.DIM ++ "└");
    for (0..ncols) |i| {
      const w = col_widths[i] + pad * 2;
      var j: usize = 0;
      while (j < w) : (j += 1) try self.w.writeAll("─");
      if (i + 1 < ncols) try self.w.writeAll("┴") else try self.w.writeAll("┘");
    }
    try self.w.writeAll(ansi.RESET ++ "\n");
  }

  fn renderHr(self: Ctx) anyerror!void {
    const tw = termWidth();
    const width = if (self.tui) tw - 10 else tw / 3;
    try self.w.writeAll("\n");
    if (self.tui) try self.w.writeAll("\x1b_R\x1b\\");
    try self.writeMargin();
    try self.w.writeAll(ansi.DIM);
    var i: u16 = 0;
    while (i < width) : (i += 1) try self.w.writeAll("─");
    try self.w.writeAll(ansi.RESET ++ "\n");
  }
  
  fn renderNode(self: Ctx, nd: *Node, depth: u32, style: Style) anyerror!void {
    switch (nd.kind) {
      .text => |txt| try self.w.writeAll(txt),
      .bold => try self.renderBold(nd, depth, style),
      .italic => try self.renderItalic(nd, depth, style),
      .code => |txt| try self.renderCode(txt, style),
      .link => |lnk| try self.renderLink(lnk, style),
      .image => |img| try self.renderImage(img, style),
      .heading => |level| try self.renderHeading(nd, level, depth),
      .paragraph => try self.renderParagraph(nd, depth, style.quoted),
      .list_item => |li| try self.renderListItem(nd, li, depth, style.quoted),
      .ordered_item => |ol| try self.renderOrderedItem(nd, ol, depth, style.quoted),
      .task_item => |ti| try self.renderTaskItem(nd, ti, depth, style.quoted),
      .code_block => |cb| try self.renderCodeBlock(cb),
      .table => try self.renderTable(nd),
      .table_row, .table_header, .table_cell => try self.styled(nd.children, depth, style),
      .callout => |co| try self.renderCallout(nd, co, depth),
      .blockquote => try self.renderBlockquote(nd, depth),
      .hr => try self.renderHr(),
      .linebreak => {
        try self.w.writeAll("\n");
        try self.writeMargin();
      },
    }
  }
};

fn termWidth() u16 {
  var ws: std.posix.winsize = .{ .col = 80, .row = 24, .xpixel = 0, .ypixel = 0 };
  const err = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
  return if (err == 0) ws.col else 80;
}

fn codeBlockWidth(content: Bytes) usize {
  var max: usize = 0;
  var pos: usize = 0;
  while (pos < content.len) {
    var len: usize = 0;
    while (pos < content.len and content[pos] != '\n') : (pos += 1) len += 1;
    if (len > max) max = len;
    if (pos < content.len) pos += 1;
  }
  return max;
}

fn writePad(w: Writer, n: usize) anyerror!void {
  var i: usize = 0;
  while (i < n) : (i += 1) try w.writeAll(" ");
}

fn writeHighlightedLine(w: Writer, content: Bytes, line_start: usize, line_end: usize, spans: []const hl.Span) anyerror!void {
  var cursor = line_start;
  for (spans) |span| {
    if (span.end <= line_start) continue;
    if (span.start >= line_end) break;
    const s = @max(span.start, line_start);
    const e = @min(span.end, line_end);
    if (cursor < s) {
      try w.writeAll(ansi.BRIGHT_WHITE);
      try w.writeAll(content[cursor..s]);
    }
    if (hl.scopeColor(span.scope)) |color| {
      try w.writeAll(color);
      try w.writeAll(content[s..e]);
      try w.writeAll(ansi.RESET ++ ansi.BG_GRAY);
    } else {
      try w.writeAll(ansi.BRIGHT_WHITE);
      try w.writeAll(content[s..e]);
    }
    cursor = e;
  }
  if (cursor < line_end) {
    try w.writeAll(ansi.BRIGHT_WHITE);
    try w.writeAll(content[cursor..line_end]);
  }
}

fn slugify(input: Bytes, buf: []u8) []const u8 {
  var len: usize = 0;
  var prev_dash = true;
  for (input) |c| {
    if (len >= buf.len) break;
    if (std.ascii.isAlphanumeric(c)) {
      buf[len] = std.ascii.toLower(c);
      len += 1;
      prev_dash = false;
    } else if ((c == ' ' or c == '-' or c == '_') and !prev_dash) {
      buf[len] = '-';
      len += 1;
      prev_dash = true;
    }
  }
  if (len > 0 and buf[len - 1] == '-') len -= 1;
  return buf[0..len];
}

fn collectHeadingText(nd: *Node, buf: []u8, pos: *usize) void {
  var child = nd.children;
  while (child) |ch| : (child = ch.next) {
    switch (ch.kind) {
      .text => |txt| {
        const avail = buf.len - pos.*;
        const n = @min(txt.len, avail);
        @memcpy(buf[pos.*..][0..n], txt[0..n]);
        pos.* += n;
      },
      .code => |txt| {
        const avail = buf.len - pos.*;
        const n = @min(txt.len, avail);
        @memcpy(buf[pos.*..][0..n], txt[0..n]);
        pos.* += n;
      },
      .link => |lnk| {
        const avail = buf.len - pos.*;
        const n = @min(lnk.label.len, avail);
        @memcpy(buf[pos.*..][0..n], lnk.label[0..n]);
        pos.* += n;
      },
      .bold, .italic => collectHeadingText(ch, buf, pos),
      else => {},
    }
  }
}

pub const Config = struct {
  margin: u16 = 2,
  show_urls: bool = true,
  highlighter: ?*hl.Highlighter = null,
  tui: bool = false,
};

pub fn render(w: Writer, n: ?*Node, config: Config) anyerror!void {
  const ctx: Ctx = .{ .w = w, 
    .highlighter = config.highlighter,
    .margin = config.margin,
    .show_urls = config.show_urls,
    .tui = config.tui,
  };
  try ctx.styled(n, 0, .{});
}

pub fn toJson(w: Writer, n: ?*Node) anyerror!void {
  var jw: std.json.Stringify = .{
    .writer = w,
    .options = .{ .whitespace = .indent_2 },
  };

  try jw.beginArray();
  var cur = n;
  while (cur) |nd| : (cur = nd.next) try jw.write(nd);
  try jw.endArray();
}
