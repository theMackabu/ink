const std = @import("std");

pub const Bytes = []const u8;
pub const Writer = *std.Io.Writer;
pub const Arena = std.heap.ArenaAllocator;

pub const Node = struct {
  kind: Kind,
  next: ?*Node = null,
  children: ?*Node = null,

  pub const Link = struct { 
    label: Bytes, url: Bytes 
  };
  
  pub const List = struct {
    indent: u8, first: bool = false
  };

  pub const Ordered = struct { 
    indent: u8, number: u32, first: bool = false
  };
  
  pub const Task = struct { 
    indent: u8, checked: bool, first: bool = false
  };

  pub const CodeBlock = struct { 
    lang: Bytes, content: Bytes 
  };

  pub const Callout = struct {
    kind: CalloutKind,
    pub const CalloutKind = enum { 
      note, tip, important, warning, caution 
    };
  };

  pub const Table = struct {
    cols: u16,
    alignments: []const Align,
    pub const Align = enum { left, center, right };
  };

  pub const Kind = union(enum) {
    text: Bytes,
    heading: u3,
    bold, italic,
    code: Bytes,
    link: Link,
    list_item: List,
    task_item: Task,
    table: Table,
    callout: Callout,
    ordered_item: Ordered,
    code_block: CodeBlock,
    table_row, table_header, table_cell,
    paragraph, blockquote, hr, linebreak,
  };

  pub fn jsonStringify(self: *const Node, jw: *std.json.Stringify) !void {
    try jw.beginObject();
    try jw.objectField("type");

    switch (self.kind) {
      .text => |txt| {
        try jw.write("text");
        try jw.objectField("value");
        try jw.write(txt);
      },
      .heading => |level| {
        try jw.write("heading");
        try jw.objectField("level");
        try jw.write(level);
      },
      .bold => try jw.write("bold"),
      .italic => try jw.write("italic"),
      .code => |txt| {
        try jw.write("code");
        try jw.objectField("value");
        try jw.write(txt);
      },
      .link => |lnk| {
        try jw.write("link");
        try jw.objectField("label");
        try jw.write(lnk.label);
        try jw.objectField("url");
        try jw.write(lnk.url);
      },
      .list_item => |li| {
        try jw.write("list_item");
        try jw.objectField("indent");
        try jw.write(li.indent);
      },
      .ordered_item => |ol| {
        try jw.write("ordered_item");
        try jw.objectField("number");
        try jw.write(ol.number);
        try jw.objectField("indent");
        try jw.write(ol.indent);
      },
      .task_item => |ti| {
        try jw.write("task_item");
        try jw.objectField("checked");
        try jw.write(ti.checked);
        try jw.objectField("indent");
        try jw.write(ti.indent);
      },
      .code_block => |cb| {
        try jw.write("code_block");
        try jw.objectField("lang");
        try jw.write(cb.lang);
        try jw.objectField("content");
        try jw.write(cb.content);
      },
      .table => |tbl| {
        try jw.write("table");
        try jw.objectField("cols");
        try jw.write(tbl.cols);
      },
      .callout => |co| {
        try jw.write("callout");
        try jw.objectField("kind");
        try jw.write(@tagName(co.kind));
      },
      .table_row => try jw.write("table_row"),
      .table_header => try jw.write("table_header"),
      .table_cell => try jw.write("table_cell"),
      .paragraph => try jw.write("paragraph"),
      .blockquote => try jw.write("blockquote"),
      .hr => try jw.write("hr"),
      .linebreak => try jw.write("linebreak"),
    }

    if (self.children) |_| {
      try jw.objectField("children");
      try jw.beginArray();
      var cur = self.children;
      while (cur) |child| : (cur = child.next) try jw.write(child);
      try jw.endArray();
    }

    try jw.endObject();
  }
};

pub fn newNode(arena: *Arena, kind: Node.Kind) !*Node {
  const n = try arena.allocator().create(Node);
  n.* = .{ .kind = kind };
  return n;
}

pub fn appendNode(root: *?*Node, last: *?*Node, n: *Node) void {
  if (root.* == null) root.* = n;
  if (last.*) |l| l.next = n;
  last.* = n;
}

pub fn appendChild(parent: *Node, child: *Node) void {
  if (parent.children == null) {
    parent.children = child;
    return;
  }
  
  var tail = parent.children.?;
  while (tail.next) |nx| tail = nx;
  tail.next = child;
}