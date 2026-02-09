const std = @import("std");
const vaxis = @import("vaxis");
const types = @import("types.zig");

const Event = types.Event;

pub const Watcher = struct {
  path: []const u8,
  dir: std.fs.Dir,
  last_mtime: i128,
  last_size: u64,
  loop: *vaxis.Loop(Event),

  pub fn init(path: []const u8, loop: *vaxis.Loop(Event)) !Watcher {
    const stat = try std.fs.cwd().statFile(path);
    return .{
      .path = path,
      .dir = std.fs.cwd(),
      .last_mtime = stat.mtime,
      .last_size = stat.size,
      .loop = loop,
    };
  }

  pub fn run(self: *Watcher) void {
    while (true) {
      std.Thread.sleep(200 * std.time.ns_per_ms);
      const stat = self.dir.statFile(self.path) catch continue;
      if (stat.mtime != self.last_mtime or stat.size != self.last_size) {
        self.last_mtime = stat.mtime;
        self.last_size = stat.size;
        self.loop.postEvent(.file_changed);
      }
    }
  }
};
