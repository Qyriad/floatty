const std = @import("std");
const Allocator = std.mem.Allocator;

/// Not to be confused with null.
pub const NUL: u8 = 0;
pub const CString = [*:NUL]const u8;

pub const CmdlineArgsResult = union(enum) {
	exit: u8,
	subproc: struct {
		argc: usize,
		argv: [*:null]?CString,
	},
};

pub const VERSION: *const [:NUL]const u8 = "floatty 0.0.1";
pub const USAGE: *const [:NUL]const u8 = "Usage: floatty <program> <args...>";
pub const HELP: *const [:NUL]const u8 =
	USAGE ++
	\\
	\\OPTIONS:
	\\  --help     display this help message and exit
	\\  --version  display version information and exit
	++ "\n";

pub const MISSING: *const [:NUL]const u8 =
	\\floatty: error: the following required arguments were not provided:
	\\  <program>
	++ "\n";


fn exit(code: u8) CmdlineArgsResult
{
	return .{ .exit_code = code };
}

pub fn handleArgs(allocator: Allocator) !CmdlineArgsResult
{
	const stdout = std.io.getStdOut().writer();
	const stderr = std.io.getStdErr().writer();

	var args = try std.process.ArgIterator.initWithAllocator(allocator);
	defer args.deinit();

	// Should be impossible.
	// If we don't even have argv[0] then we were executed incorrectly in the first place.
	// On the other hand, we don't care about the actual value of argv[0].
	const executed_as = args.next() orelse unreachable;
	_ = executed_as;

	// The first argument is special.
	// We can't take any --options after accepting positional arguments, so that we don't
	// interpret things like `floatty ls --help` as `--help` for us.
	// Also we don't have any cases where --multiple --options make sense at a time, yet,
	// since we only have --version and --help.
	const first: [:NUL]const u8 = args.next() orelse {
		// No arguments provided.
		try stderr.write(MISSING);
		try stdout.write(HELP);

		return exit(255);
	};

	if (first[0] == '-') {
		// No outlet.

		if (streql(first, "--help")) {
			try stdout.write(HELP);
			return exit(0);
		}

		if (streql(first, "--version")) {
			try stdout.write(VERSION ++ "\n");
			return exit(0);
		}

		try stderr.print(
			\\floatty: unrecognized option '{s}'
			\\Try 'floatty --help' for more information
			++ "\n",
			.{first},
		);
		return exit(255);
	}

	// - 1 as we do not include the `executed_as` argument.
	const child_argc = args.inner.count - 1;

	// Note: no defer free. Caller takes ownership.
	var child_args: [*:null]?CString = try allocator.allocSentinel(?CString, child_argc, null);
	var first_copied: CString = try allocator.allocSentinel(u8, first.len, NUL);
	@memcpy(first_copied, first);
	first_copied[first.len] = NUL;
	child_args[0] = first_copied[0..first.len :NUL];

	var arg_pos: usize = 1;
	while (args.next()) |arg| : (arg_pos += 1) {
		var copied: CString = try allocator.allocSentinel(u8, arg.len, NUL);
		@memcpy(copied, arg);
		copied[arg.len] = NUL;
		child_args[arg_pos] = copied[0..arg.len :NUL];
	}

	std.debug.assert(child_argc, arg_pos);

	return .{ .subproc = .{
		.argc = arg_pos,
		.argv = child_args,
	}};
}

fn streql(lhs: []const u8, rhs: []const u8) bool
{
	return std.mem.eql(u8, lhs, rhs);
}
