const std = @import("std");

pub fn getGitCommit(b: *std.Build) ?[]const u8 {
  const result = std.process.Child.run(.{
    .allocator = b.allocator,
    .argv = &.{ "git", "rev-parse", "HEAD" },
    .cwd = b.build_root.path orelse ".",
  }) catch return null;
  if (result.term.Exited != 0) return null;
  return std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
}

pub fn getGitBranch(b: *std.Build) ?[]const u8 {
  const result = std.process.Child.run(.{
    .allocator = b.allocator,
    .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
    .cwd = b.build_root.path orelse ".",
  }) catch return null;
  if (result.term.Exited != 0) return null;
  return std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
}

pub fn readVersionFile(b: *std.Build) ?[]const u8 {
  const path = b.build_root.path orelse return null;
  const file = std.fs.path.join(b.allocator, &.{ path, "ink.version" }) catch return null;
  const contents = std.fs.cwd().readFileAlloc(b.allocator, file, 64) catch return null;
  return std.mem.trim(u8, contents, &std.ascii.whitespace);
}

pub fn isGitDirty(b: *std.Build) bool {
  const result = std.process.Child.run(.{
    .allocator = b.allocator,
    .argv = &.{ "git", "status", "--porcelain" },
    .cwd = b.build_root.path orelse ".",
  }) catch return false;
  if (result.term.Exited != 0) return false;
  return result.stdout.len > 0;
}