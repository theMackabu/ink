const std = @import("std");

pub const Memory = struct {
  show_lines: bool = false,
  show_urls: bool = false,
  margin: u16 = 2,
  line_wrap_percent: u8 = 90,

  pub fn load(alloc: std.mem.Allocator) Memory {
    const path = configPath(alloc) orelse return .{};
    defer alloc.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch {
      const m: Memory = .{};
      m.save(alloc);
      return m;
    };
    defer file.close();

    const content = file.readToEndAlloc(alloc, 4096) catch return .{};
    defer alloc.free(content);

    const m = std.json.parseFromSliceLeaky(Memory, alloc, content, .{
      .ignore_unknown_fields = true,
    }) catch Memory{};
    m.save(alloc);
    return m;
  }

  pub fn save(self: Memory, alloc: std.mem.Allocator) void {
    ensureDir(alloc) catch return;

    const path = configPath(alloc) orelse return;
    defer alloc.free(path);

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var jw: std.json.Stringify = .{
      .writer = &w,
      .options = .{ .whitespace = .indent_2 },
    };
    
    jw.write(self) catch return;
    jw.writer.flush() catch return;
    file.writeAll(buf[0..w.end]) catch {};
  }
};

fn ensureDir(alloc: std.mem.Allocator) !void {
  const dir = configDir(alloc) orelse return error.NoHome;
  defer alloc.free(dir);
  std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
    error.PathAlreadyExists => {},
    else => return err,
  };
}

fn configDir(alloc: std.mem.Allocator) ?[]const u8 {
  if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
    return std.fmt.allocPrint(alloc, "{s}/ink", .{xdg}) catch null;
  }
  const home = std.posix.getenv("HOME") orelse return null;
  return std.fmt.allocPrint(alloc, "{s}/.config/ink", .{home}) catch null;
}

fn configPath(alloc: std.mem.Allocator) ?[]const u8 {
  if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
    return std.fmt.allocPrint(alloc, "{s}/ink/memory.json", .{xdg}) catch null;
  }
  const home = std.posix.getenv("HOME") orelse return null;
  return std.fmt.allocPrint(alloc, "{s}/.config/ink/memory.json", .{home}) catch null;
}
