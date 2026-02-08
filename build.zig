const std = @import("std");
const utils = @import("build.utils.zig");
const Bytes = @import("src/node.zig").Bytes;

pub fn build(b: *std.Build) void {
  const target = b.standardTargetOptions(.{});
  const opts: std.Build.Module.CreateOptions = .{
    .target = target,
    .optimize = .ReleaseFast,
    .omit_frame_pointer = true,
    .unwind_tables = .none,
    .strip = true,
  };
  
  const syntax_dep = b.dependency("flow_syntax", .{
    .target = target,
    .optimize = .ReleaseFast,
  });
  const vaxis_dep = b.dependency("vaxis", .{
    .target = target,
    .optimize = .ReleaseFast,
  });
  
  const clap_dep = b.dependency("clap", .{
    .target = target,
    .optimize = .ReleaseFast,
  });
  
  const lib_ink = b.addModule("ink", .{
    .root_source_file = b.path("src/ink.zig"),
    .target = opts.target,
    .optimize = opts.optimize,
    .omit_frame_pointer = opts.omit_frame_pointer,
    .unwind_tables = opts.unwind_tables,
    .strip = opts.strip,
  });
  lib_ink.addImport("syntax", syntax_dep.module("syntax"));
  lib_ink.addImport("vaxis", vaxis_dep.module("vaxis"));
  
  const ink = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = opts.target,
    .optimize = opts.optimize,
    .omit_frame_pointer = opts.omit_frame_pointer,
    .unwind_tables = opts.unwind_tables,
    .strip = opts.strip,
  }); 
  
  ink.addImport("ink", lib_ink);
  ink.addImport("clap", clap_dep.module("clap"));
  
  const bin = b.addExecutable(.{
    .name = "ink",
    .root_module = ink,
  });
  
  const version = b.option(Bytes, "version", "Version string") orelse "0.0.1";
  const timestamp = std.time.timestamp();
  
  const git_commit = utils.getGitCommit(b) orelse "unknown";
  const git_branch = utils.getGitBranch(b) orelse "unknown";
  const git_dirty = utils.isGitDirty(b);
  
  const options = b.addOptions();
  options.addOption(Bytes, "version", version);
  options.addOption(i64, "build_timestamp", timestamp);
  options.addOption(Bytes, "git_commit", git_commit);
  options.addOption(Bytes, "git_branch", git_branch);
  options.addOption(bool, "git_dirty", git_dirty);
  
  ink.addImport("config", options.createModule());
  
  b.installArtifact(bin);
  const run_cmd = b.addRunArtifact(bin);
  
  run_cmd.step.dependOn(b.getInstallStep());
  if (b.args) |args| run_cmd.addArgs(args);
  const run_step = b.step("run", "Run the markdown parser");
  run_step.dependOn(&run_cmd.step);
  
  const install_local = b.step("install-local", "Install to ~/.local/bin");
  const install_cmd = b.addSystemCommand(&.{"cp", "-f"});
  install_cmd.addFileArg(bin.getEmittedBin());
  
  const home = b.graph.env_map.get("HOME") orelse return;
  const dest_path = b.fmt("{s}/.local/bin/ink", .{home});
  
  install_cmd.addArg(dest_path);
  install_local.dependOn(&install_cmd.step);
}