const std = @import("std");
const config = @import("config");

pub const Ctx = struct {
  allocator: std.mem.Allocator,
  
  pub fn init(allocator: std.mem.Allocator) Ctx {
    return .{ .allocator = allocator };
  }
  
  pub fn printf(self: Ctx, comptime format: []const u8, args: anytype) void {
    const buffer = self.allocator.alloc(u8, 512) catch return;
    defer self.allocator.free(buffer);
    var stdout_writer = std.fs.File.stdout().writer(buffer);
    defer stdout_writer.interface.flush() catch {};
    stdout_writer.interface.print(format, args) catch return;
  }
  
  pub fn version(self: Ctx) !void {
    const build_time = config.build_timestamp;
    const now = std.time.timestamp();
    
    const age_seconds = now - build_time;
    const epoch_seconds = @as(u64, @intCast(build_time));
    
    const epoch_day = std.time.epoch.EpochDay{ .day = @divFloor(epoch_seconds, std.time.s_per_day) };
    const year_day = epoch_day.calculateYearDay(); 
    const month_day = year_day.calculateMonthDay();
    
    const short_hash = if (config.git_commit.len > 7) config.git_commit[0..7] 
    else config.git_commit;
    
    const time_ago = try formatTimeAgo(self.allocator, age_seconds);
    defer self.allocator.free(time_ago);
    const dirty_marker = if (config.git_dirty) "-dirty" else "";
    
    self.printf("ink v{s}.{d}-g{s}{s} (released {d:0>4}-{d:0>2}-{d:0>2}, {s})\n", .{
      config.version, config.build_timestamp,
      short_hash, dirty_marker,
      year_day.year,
      month_day.month.numeric(),
      month_day.day_index + 1, time_ago,
    });
  }
};

fn formatTimeAgo(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
  const abs_seconds = if (seconds < 0) -seconds else seconds;
  if (abs_seconds < 60) return allocator.dupe(u8, "just now");
  
  const TimeUnit = struct { divisor: i64, suffix: []const u8 };
  const unit: TimeUnit = if (abs_seconds < 3600) .{ .divisor = 60, .suffix = "m ago" }
  else if (abs_seconds < 86400) .{ .divisor = 3600, .suffix = "h ago" }
  else if (abs_seconds < 2592000) .{ .divisor = 86400, .suffix = "d ago" }
  else if (abs_seconds < 31536000) .{ .divisor = 2592000, .suffix = "mo ago" }
  else .{ .divisor = 31536000, .suffix = "y ago" };
  
  return std.fmt.allocPrint(allocator, "{d}{s}", .{ @divFloor(abs_seconds, unit.divisor), unit.suffix });
}