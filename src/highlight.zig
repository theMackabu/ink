const std = @import("std");
const syntax = @import("syntax");
const Bytes = @import("node.zig").Bytes;

const Syntax = syntax;
const FileType = syntax.FileType;
const QueryCache = syntax.QueryCache;

pub const Span = struct {
  start: usize,
  end: usize,
  scope: Bytes,
};

pub const Highlighter = struct {
  allocator: std.mem.Allocator,
  query_cache: *QueryCache,

  pub fn init(allocator: std.mem.Allocator) !Highlighter {
    return .{
      .allocator = allocator,
      .query_cache = try QueryCache.create(allocator, .{}),
    };
  }

  pub fn highlight(self: *Highlighter, content: Bytes, lang: Bytes, spans: *std.ArrayList(Span)) !bool {
    const parser = Syntax.create_file_type_static(self.allocator, lang, self.query_cache) catch return false;
    
    defer parser.destroy(self.query_cache);
    parser.refresh_full(content) catch return false;

    const Ctx = struct {
      spans: *std.ArrayList(Span),
      alloc: std.mem.Allocator,
      last_end: usize = 0,

      fn cb(ctx: *@This(), range: Syntax.Range, scope: Bytes, _: u32, idx: usize, _: *const Syntax.Node) error{Stop}!void {
        if (idx > 0) return;
        if (range.start_byte < ctx.last_end) return;
        ctx.spans.append(ctx.alloc, .{
          .start = range.start_byte,
          .end = range.end_byte,
          .scope = scope,
        }) catch return error.Stop;
        ctx.last_end = range.end_byte;
      }
    };

    var ctx: Ctx = .{ .spans = spans, .alloc = self.allocator };
    parser.render(&ctx, Ctx.cb, null) catch return spans.items.len > 0;
    return true;
  }
};

pub fn scopeColor(scope: Bytes) ?Bytes {
  const map = .{
    .{ "keyword", "\x1b[38;2;255;123;114m" },
    .{ "function", "\x1b[38;2;210;168;255m" },
    .{ "type", "\x1b[38;2;126;231;135m" },
    .{ "string", "\x1b[38;2;165;214;255m" },
    .{ "number", "\x1b[38;2;121;192;255m" },
    .{ "constant", "\x1b[38;2;121;192;255m" },
    .{ "comment", "\x1b[38;2;139;148;158m" },
    .{ "operator", "\x1b[38;2;230;237;243m" },
    .{ "variable", "\x1b[38;2;255;166;87m" },
    .{ "property", "\x1b[38;2;121;192;255m" },
    .{ "attribute", "\x1b[38;2;230;237;243m" },
    .{ "punctuation", "\x1b[38;2;139;148;158m" },
    .{ "tag", "\x1b[38;2;126;231;135m" },
    .{ "label", "\x1b[38;2;210;168;255m" },
  };

  inline for (map) |entry| {
    if (std.mem.startsWith(u8, scope, entry[0])) return entry[1];
  }
  
  return null;
}
