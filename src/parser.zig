const std = @import("std");
const node = @import("node.zig");

const Node = node.Node;
const Arena = node.Arena;
const Bytes = node.Bytes;
const Align = Node.Table.Align;

const newNode = node.newNode;
const appendNode = node.appendNode;
const appendChild = node.appendChild;

const Scanner = struct {
  input: Bytes,
  pos: usize = 0,

  fn at(s: *const Scanner, offset: usize) u8 {
    return if (s.pos + offset < s.input.len) s.input[s.pos + offset] else 0;
  }

  fn cur(s: *Scanner) u8 {
    return s.at(0);
  }

  fn eof(s: *Scanner) bool {
    return s.pos >= s.input.len;
  }

  fn advance(s: *Scanner, n: usize) void {
    s.pos = @min(s.pos + n, s.input.len);
  }

  fn rest(s: *Scanner) Bytes {
    return s.input[s.pos..];
  }

  fn skipNewline(s: *Scanner) void {
    if (!s.eof() and s.cur() == '\n') s.advance(1);
  }

  fn skipSpaces(s: *Scanner) u8 {
    var count: u8 = 0;
    while (!s.eof() and s.cur() == ' ') : (count += 1) s.advance(1);
    return count;
  }

  fn readLine(s: *Scanner) Bytes {
    const start = s.pos;
    while (!s.eof() and s.cur() != '\n') s.advance(1);
    return s.input[start..s.pos];
  }

  fn scanUntil(s: *Scanner, delim: u8) Bytes {
    const start = s.pos;
    while (!s.eof() and s.cur() != delim) s.advance(1);
    return s.input[start..s.pos];
  }

  fn countRun(s: *Scanner, ch: u8) usize {
    var n: usize = 0;
    while (s.pos + n < s.input.len and s.input[s.pos + n] == ch) : (n += 1) {}
    return n;
  }

  fn isDigit(s: *Scanner) bool {
    return !s.eof() and s.cur() >= '0' and s.cur() <= '9';
  }

  fn readDigits(s: *Scanner) Bytes {
    const start = s.pos;
    while (s.isDigit()) s.advance(1);
    return s.input[start..s.pos];
  }
};

fn isListKind(kind: Node.Kind) bool {
  return switch (kind) {
    .list_item, .ordered_item, .task_item => true,
    else => false,
  };
}

fn lastChild(parent: *Node) ?*Node {
  var tail = parent.children orelse return null;
  while (tail.next) |nx| tail = nx;
  return tail;
}

fn isFirstItem(parent: *Node) bool {
  const prev = lastChild(parent) orelse return true;
  return !isListKind(prev.kind);
}

fn matchBr(input: Bytes, pos: usize) ?usize {
  const tags = [_]Bytes{ "<br>", "<br/>", "<br />" };
  inline for (tags) |tag| {
    if (pos + tag.len <= input.len and std.mem.eql(u8, input[pos..pos + tag.len], tag))
      return tag.len;
  }
  return null;
}

fn findClose(input: Bytes, start: usize, marker: u8, count: usize) usize {
  var s = Scanner{ .input = input, .pos = start };
  while (!s.eof()) {
    if (s.cur() != marker) {
      s.advance(1);
      continue;
    }
    const run = s.countRun(marker);
    if (run >= count) return s.pos + (run - count);
    s.advance(run);
  }
  return input.len;
}

fn flushText(arena: *Arena, root: *?*Node, last: *?*Node, input: Bytes, start: usize, end: usize) !void {
  if (end > start)
    appendNode(root, last, try newNode(arena, .{ .text = input[start..end] }));
}

fn parseEmphasis(arena: *Arena, root: *?*Node, last: *?*Node, s: *Scanner) !usize {
  const c = s.cur();
  const run = s.countRun(c);

  if (run >= 3) {
    s.advance(3);
    const close = findClose(s.input, s.pos, c, 3);
    const inner = s.input[s.pos..@min(close, s.input.len)];
    const italic = try newNode(arena, .italic);
    italic.children = try parseInline(arena, inner);
    const bold = try newNode(arena, .bold);
    bold.children = italic;
    appendNode(root, last, bold);
    s.pos = if (close < s.input.len) close + 3 else close;
  } else if (run == 2) {
    s.advance(2);
    const close = findClose(s.input, s.pos, c, 2);
    const inner = s.input[s.pos..@min(close, s.input.len)];
    const bold = try newNode(arena, .bold);
    bold.children = try parseInline(arena, inner);
    appendNode(root, last, bold);
    s.pos = if (close < s.input.len) close + 2 else close;
  } else {
    s.advance(1);
    const close = findClose(s.input, s.pos, c, 1);
    if (close < s.input.len) {
      const italic = try newNode(arena, .italic);
      italic.children = try parseInline(arena, s.input[s.pos..close]);
      appendNode(root, last, italic);
      s.pos = close + 1;
    } else {
      appendNode(root, last, try newNode(arena, .{ .text = s.input[s.pos - 1 .. s.pos] }));
    }
  }
  return s.pos;
}

fn parseInlineCode(arena: *Arena, root: *?*Node, last: *?*Node, s: *Scanner) !usize {
  s.advance(1);
  const content = s.scanUntil('`');
  appendNode(root, last, try newNode(arena, .{ .code = content }));
  if (!s.eof()) s.advance(1);
  return s.pos;
}

fn parseLink(arena: *Arena, root: *?*Node, last: *?*Node, s: *Scanner) !usize {
  s.advance(1);
  const label = s.scanUntil(']');
  var url: Bytes = "";
  if (!s.eof()) {
    s.advance(1);
    if (!s.eof() and s.cur() == '(') {
      s.advance(1);
      url = s.scanUntil(')');
      if (!s.eof()) s.advance(1);
    }
  }
  appendNode(root, last, try newNode(arena, .{ .link = .{ .label = label, .url = url } }));
  return s.pos;
}

pub fn parseInline(arena: *Arena, input: Bytes) error{OutOfMemory}!?*Node {
  if (input.len == 0) return null;

  var root: ?*Node = null;
  var last: ?*Node = null;
  var text_start: usize = 0;
  var s = Scanner{ .input = input };

  while (!s.eof()) {
    const c = s.cur();

    switch (c) {
      '*', '_' => {
        try flushText(arena, &root, &last, input, text_start, s.pos);
        text_start = try parseEmphasis(arena, &root, &last, &s);
      },
      '`' => {
        try flushText(arena, &root, &last, input, text_start, s.pos);
        text_start = try parseInlineCode(arena, &root, &last, &s);
      },
      '[' => {
        try flushText(arena, &root, &last, input, text_start, s.pos);
        text_start = try parseLink(arena, &root, &last, &s);
      },
      '<' => {
        if (matchBr(input, s.pos)) |len| {
          try flushText(arena, &root, &last, input, text_start, s.pos);
          appendNode(&root, &last, try newNode(arena, .linebreak));
          s.advance(len);
          text_start = s.pos;
        } else s.advance(1);
      },
      else => s.advance(1),
    }
  }

  try flushText(arena, &root, &last, input, text_start, s.pos);
  return root;
}

fn isSeparatorCell(cell: Bytes) bool {
  var i: usize = 0;
  while (i < cell.len and cell[i] == ' ') : (i += 1) {}
  if (i >= cell.len) return false;
  const has_left = cell[i] == ':';
  if (has_left) i += 1;
  var dashes: usize = 0;
  while (i < cell.len and cell[i] == '-') : (i += 1) dashes += 1;
  if (dashes == 0) return false;
  if (i < cell.len and cell[i] == ':') i += 1;
  while (i < cell.len and cell[i] == ' ') : (i += 1) {}
  return i == cell.len;
}

fn cellAlignment(cell: Bytes) Align {
  var start: usize = 0;
  while (start < cell.len and cell[start] == ' ') : (start += 1) {}
  var end = cell.len;
  while (end > start and cell[end - 1] == ' ') end -= 1;
  if (end <= start) return .left;
  const left = cell[start] == ':';
  const right = cell[end - 1] == ':';
  if (left and right) return .center;
  if (right) return .right;
  return .left;
}

fn splitCells(input: Bytes) struct { cells: [64]Bytes, count: u16 } {
  var cells: [64]Bytes = undefined;
  var count: u16 = 0;
  var pos: usize = 0;

  if (pos < input.len and input[pos] == '|') pos += 1;

  while (pos <= input.len and count < 64) {
    const start = pos;
    while (pos < input.len and input[pos] != '|') : (pos += 1) {}
    const cell = input[start..pos];
    if (pos < input.len) {
      cells[count] = cell;
      count += 1;
      pos += 1;
    } else {
      const trimmed = std.mem.trimRight(u8, cell, " ");
      if (trimmed.len > 0) {
        cells[count] = cell;
        count += 1;
      } break;
    }
  }
  return .{ .cells = cells, .count = count };
}

fn isSeparatorRow(line: Bytes) bool {
  const result = splitCells(line);
  if (result.count == 0) return false;
  for (result.cells[0..result.count]) |cell| {
    if (!isSeparatorCell(cell)) return false;
  }
  return true;
}

fn isTableLine(input: Bytes, pos: usize) bool {
  if (pos >= input.len or input[pos] != '|') return false;
  var p = pos;
  while (p < input.len and input[p] != '\n') : (p += 1) {}
  return p > pos + 1;
}

fn parseTableRow(arena: *Arena, s: *Scanner, kind: Node.Kind) !*Node {
  const line = s.readLine();
  const result = splitCells(line);
  const row = try newNode(arena, kind);
  for (result.cells[0..result.count]) |cell| {
    const trimmed = std.mem.trim(u8, cell, " ");
    const cell_node = try newNode(arena, .table_cell);
    cell_node.children = try parseInline(arena, trimmed);
    appendChild(row, cell_node);
  }
  s.skipNewline();
  return row;
}

fn parseTable(arena: *Arena, s: *Scanner, root: *Node) !void {
  const header_row = try parseTableRow(arena, s, .table_header);

  var col_count: u16 = 0;
  var child = header_row.children;
  while (child) |ch| : (child = ch.next) col_count += 1;

  const sep_start = s.pos;
  const sep_line = s.readLine();
  s.skipNewline();

  var alignments: []Align = &.{};
  if (isSeparatorRow(sep_line)) {
    const result = splitCells(sep_line);
    const aligns = try arena.allocator().alloc(Align, result.count);
    for (0..result.count) |i| aligns[i] = cellAlignment(result.cells[i]);
    alignments = aligns;
  } else {
    s.pos = sep_start;
  }

  const table = try newNode(arena, .{ .table = .{ .cols = col_count, .alignments = alignments } });
  appendChild(table, header_row);

  while (isTableLine(s.input, s.pos)) {
    const row = try parseTableRow(arena, s, .table_row);
    appendChild(table, row);
  }

  appendChild(root, table);
}

fn skipLeadingSpaces(input: Bytes, pos: usize) usize {
  var p = pos;
  while (p < input.len and input[p] == ' ') : (p += 1) {}
  return p;
}

fn isBlockStartAt(input: Bytes, pos: usize) bool {
  if (pos >= input.len) return true;
  const s = Scanner{ .input = input, .pos = pos };
  return switch (s.input[pos]) {
    '\n', '#', '>', '|' => true,
    '-', '*' => |c| (s.at(1) == c and s.at(2) == c) or s.at(1) == ' ',
    '`' => s.at(1) == '`' and s.at(2) == '`',
    '0'...'9' => blk: {
      var p = pos;
      while (p < input.len and input[p] >= '0' and input[p] <= '9') : (p += 1) {}
      break :blk p + 1 < input.len and input[p] == '.' and input[p + 1] == ' ';
    },
    else => false,
  };
}

fn isBlockStart(input: Bytes, pos: usize) bool {
  if (isBlockStartAt(input, pos)) return true;
  const after = skipLeadingSpaces(input, pos);
  if (after == pos) return false;
  return isBlockStartAt(input, after);
}

fn tryParseTask(s: *Scanner) ?bool {
  if (s.pos + 2 >= s.input.len) return null;
  if (s.input[s.pos] != '[') return null;
  const mark = s.input[s.pos + 1];
  if (mark != ' ' and mark != 'x') return null;
  if (s.input[s.pos + 2] != ']') return null;
  s.advance(3);
  if (!s.eof() and s.cur() == ' ') s.advance(1);
  return mark == 'x';
}

fn parseListItem(arena: *Arena, s: *Scanner, parent: *Node, indent: u8) !void {
  if (tryParseTask(s)) |checked| {
    const line = s.readLine();
    const item = try newNode(arena, .{ .task_item = .{ .indent = indent, .checked = checked, .first = isFirstItem(parent) } });
    item.children = try parseInline(arena, line);
    appendChild(parent, item);
    s.skipNewline();
    try appendItemContinuation(arena, item, s);
  } else {
    const line = s.readLine();
    const item = try newNode(arena, .{ .list_item = .{ .indent = indent, .first = isFirstItem(parent) } });
    item.children = try parseInline(arena, line);
    appendChild(parent, item);
    s.skipNewline();
    try appendItemContinuation(arena, item, s);
  }
}

fn parseOrderedItem(arena: *Arena, s: *Scanner, parent: *Node, indent: u8) !bool {
  const saved = s.pos;
  const digits = s.readDigits();
  if (digits.len == 0 or s.pos + 1 >= s.input.len or s.cur() != '.' or s.at(1) != ' ') {
    s.pos = saved;
    return false;
  }
  const number = std.fmt.parseInt(u32, digits, 10) catch 0;
  s.advance(2);
  const line = s.readLine();
  const item = try newNode(arena, .{ .ordered_item = .{ .indent = indent, .number = number, .first = isFirstItem(parent) } });
  item.children = try parseInline(arena, line);
  appendChild(parent, item);
  s.skipNewline();
  try appendItemContinuation(arena, item, s);
  return true;
}

fn parseParagraphLine(arena: *Arena, s: *Scanner, parent: *Node) !void {
  const line = s.readLine();
  if (line.len > 0) {
    const para = try newNode(arena, .paragraph);
    para.children = try parseInline(arena, line);
    appendChild(parent, para);
  }
  s.skipNewline();
}

fn isIndentedContinuation(input: Bytes, pos: usize) bool {
  if (pos >= input.len) return false;
  if (input[pos] != ' ') return false;
  const after = skipLeadingSpaces(input, pos);
  if (after == pos or after >= input.len) return false;
  if (input[after] == '\n') return false;
  return !isBlockStartAt(input, after);
}

fn appendItemContinuation(arena: *Arena, item: *Node, s: *Scanner) !void {
  while (isIndentedContinuation(s.input, s.pos)) {
    _ = s.skipSpaces();
    const cont = s.readLine();
    if (cont.len == 0) break;

    const tail = blk: {
      var t = item.children.?;
      while (t.next) |nx| t = nx;
      break :blk t;
    };
    if (tail.kind != .linebreak) appendChild(item, try newNode(arena, .{ .text = " " }));

    var inl = try parseInline(arena, cont);
    while (inl) |n| {
      const next = n.next;
      n.next = null;
      appendChild(item, n);
      inl = next;
    }
    s.skipNewline();
  }
}

fn appendContinuation(arena: *Arena, para: *Node, s: *Scanner) !void {
  while (!s.eof() and !isBlockStart(s.input, s.pos)) {
    const cont = s.readLine();
    if (cont.len == 0) break;

    const tail = blk: {
      var t = para.children.?;
      while (t.next) |nx| t = nx;
      break :blk t;
    };
    if (tail.kind != .linebreak) appendChild(para, try newNode(arena, .{ .text = " " }));

    var inl = try parseInline(arena, cont);
    while (inl) |n| {
      const next = n.next;
      n.next = null;
      appendChild(para, n);
      inl = next;
    }
    s.skipNewline();
  }
}

fn parseHeading(arena: *Arena, s: *Scanner, root: *Node) !void {
  var level: u3 = 0;
  while (level < 6 and s.at(level) == '#') : (level += 1) {}

  if (s.at(level) != ' ') return parseParagraphLine(arena, s, root);

  s.advance(@as(usize, level) + 1);
  const line = s.readLine();
  const h = try newNode(arena, .{ .heading = level });
  h.children = try parseInline(arena, line);
  appendChild(root, h);
  s.skipNewline();
}

fn parseHrOrList(arena: *Arena, s: *Scanner, root: *Node) !void {
  const c = s.cur();

  if (s.at(1) == c and s.at(2) == c) {
    var end = s.pos + 3;
    while (end < s.input.len and s.input[end] == c) : (end += 1) {}
    if (end >= s.input.len or s.input[end] == '\n') {
      s.pos = end;
      s.skipNewline();
      appendChild(root, try newNode(arena, .hr));
      return;
    }
  }

  if (s.at(1) != ' ') return parseParagraphLine(arena, s, root);

  s.advance(2);
  try parseListItem(arena, s, root, 0);
}

fn tryParseCalloutKind(input: Bytes, pos: usize) ?Node.Callout.CalloutKind {
  if (pos + 2 >= input.len or input[pos] != '[' or input[pos + 1] != '!') return null;
  var end = pos + 2;
  while (end < input.len and input[end] != ']') : (end += 1) {}
  if (end >= input.len) return null;
  const tag = input[pos + 2 .. end];
  if (std.ascii.eqlIgnoreCase(tag, "NOTE")) return .note;
  if (std.ascii.eqlIgnoreCase(tag, "TIP")) return .tip;
  if (std.ascii.eqlIgnoreCase(tag, "IMPORTANT")) return .important;
  if (std.ascii.eqlIgnoreCase(tag, "WARNING")) return .warning;
  if (std.ascii.eqlIgnoreCase(tag, "CAUTION")) return .caution;
  return null;
}

fn parseBlockquoteLine(arena: *Arena, s: *Scanner, parent: *Node) !void {
  const indent = s.skipSpaces();

  if (!s.eof() and (s.cur() == '-' or s.cur() == '*') and s.at(1) == ' ') {
    s.advance(2);
    try parseListItem(arena, s, parent, indent);
  } else if (s.isDigit()) {
    if (!try parseOrderedItem(arena, s, parent, indent)) {
      const line = s.readLine();
      if (line.len > 0) {
        const para = try newNode(arena, .paragraph);
        para.children = try parseInline(arena, line);
        appendChild(parent, para);
      }
      s.skipNewline();
    }
  } else {
    const line = s.readLine();
    const para = try newNode(arena, .paragraph);
    para.children = try parseInline(arena, line);
    appendChild(parent, para);
    s.skipNewline();
  }
}

fn parseBlockquote(arena: *Arena, s: *Scanner, root: *Node) !void {
  s.advance(1);
  if (!s.eof() and s.cur() == ' ') s.advance(1);

  if (tryParseCalloutKind(s.input, s.pos)) |kind| {
    var end = s.pos;
    while (end < s.input.len and s.input[end] != ']') : (end += 1) {}
    s.pos = end + 1;
    s.skipNewline();

    const callout = try newNode(arena, .{ .callout = .{ .kind = kind } });

    while (!s.eof() and s.cur() == '>') {
      s.advance(1);
      if (!s.eof() and s.cur() == ' ') s.advance(1);
      try parseBlockquoteLine(arena, s, callout);
      while (!s.eof() and s.cur() == '\n' and s.at(1) == '>') s.advance(1);
    }

    appendChild(root, callout);
    return;
  }

  const quote = try newNode(arena, .blockquote);
  try parseBlockquoteLine(arena, s, quote);

  while (!s.eof() and s.cur() == '>') {
    s.advance(1);
    if (!s.eof() and s.cur() == ' ') s.advance(1);
    try parseBlockquoteLine(arena, s, quote);
    while (!s.eof() and s.cur() == '\n' and s.at(1) == '>') s.advance(1);
  }

  appendChild(root, quote);
}

fn parseOrderedList(arena: *Arena, s: *Scanner, root: *Node) !void {
  if (!try parseOrderedItem(arena, s, root, 0))
    try parseParagraphLine(arena, s, root);
}

fn parseCodeBlock(arena: *Arena, s: *Scanner, root: *Node) !void {
  if (s.at(1) != '`' or s.at(2) != '`') return parseParagraphLine(arena, s, root);

  s.advance(3);
  const lang = s.scanUntil('\n');
  if (!s.eof()) s.advance(1);
  const content_start = s.pos;
  var content_end = s.pos;

  while (!s.eof()) {
    if (s.cur() == '\n') {
      content_end = s.pos;
      s.advance(1);
      continue;
    }
    if (s.cur() == '`' and s.at(1) == '`' and s.at(2) == '`') {
      s.advance(3);
      s.skipNewline();
      appendChild(root, try newNode(arena, .{ .code_block = .{ .lang = lang, .content = s.input[content_start..content_end] } }));
      return;
    }
    s.advance(1);
  }

  appendChild(root, try newNode(arena, .{ .code_block = .{ .lang = lang, .content = s.input[content_start..] } }));
}

fn parseIndentedItem(arena: *Arena, s: *Scanner, root: *Node) !bool {
  const saved = s.pos;
  const indent = s.skipSpaces();
  if (indent == 0 or s.eof()) {
    s.pos = saved;
    return false;
  }

  const c = s.cur();
  if ((c == '-' or c == '*') and s.at(1) == ' ') {
    s.advance(2);
    try parseListItem(arena, s, root, indent);
    return true;
  }

  if (s.isDigit()) {
    if (try parseOrderedItem(arena, s, root, indent)) return true;
  }

  if (c == '`' and s.at(1) == '`' and s.at(2) == '`') {
    try parseCodeBlock(arena, s, root);
    return true;
  }

  s.pos = saved;
  return false;
}

fn parsePlainText(arena: *Arena, s: *Scanner, root: *Node) !void {
  const line = s.readLine();
  if (line.len == 0) {
    s.skipNewline();
    return;
  }

  const para = try newNode(arena, .paragraph);
  para.children = try parseInline(arena, line);
  appendChild(root, para);
  s.skipNewline();
  try appendContinuation(arena, para, s);
}

pub fn parse(arena: *Arena, input: Bytes) !*Node {
  var s = Scanner{ .input = input };
  const root = try newNode(arena, .paragraph);

  while (!s.eof()) {
    switch (s.cur()) {
      '\n' => s.advance(1),
      '#' => try parseHeading(arena, &s, root),
      '-', '*' => try parseHrOrList(arena, &s, root),
      '>' => try parseBlockquote(arena, &s, root),
      '|' => try parseTable(arena, &s, root),
      '0'...'9' => try parseOrderedList(arena, &s, root),
      '`' => try parseCodeBlock(arena, &s, root),
      ' ' => {
        if (!try parseIndentedItem(arena, &s, root))
          try parsePlainText(arena, &s, root);
      },
      else => try parsePlainText(arena, &s, root),
    }
  }

  return root;
}
