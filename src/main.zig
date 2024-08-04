const std: type = @import("std");
const print: fn (comptime []const u8, anytype) void = std.debug.print;
const panic: fn (comptime []const u8, anytype) noreturn = std.debug.panic;
const log = std.log;
const fd_t = std.posix.fd_t;
const Allocator = std.mem.Allocator;

const STDIN_FILENO = std.posix.STDIN_FILENO;
const STDOUT_FILENO = std.posix.STDOUT_FILENO;
const STDERR_FILENO = std.posix.STDERR_FILENO;

const cstrings = @import("cstrings.zig");
const CString = cstrings.CString;
const CStringCArray = cstrings.CStringCArray;

const ContainerDecl = @import("meta.zig").ContainerDecl;

/// Not to be confused with null.
const NUL: u8 = 0;

//pub const std_options = .{
//	.log_level = .info,
//};

fn eprintln(comptime fmt: []const u8, args: anytype) void
{
	std.debug.print(fmt ++ "\n", args);
}

/// Errors writing to stdout are silently discarded, like std.debug.print.
fn println(comptime fmt: []const u8, args: anytype) void
{
	const stdout = std.io.getStdOut();
	const writer = stdout.writer();
	writer.print(fmt ++ "\n", args) catch return;
}

const fcntl = @cImport({
	@cDefine("_ISO_C11_SOURCE", "1");
	@cDefine("_POSIX_SOURCE", "200809L");
	@cDefine("_XOPEN_SOURCE", "700");
	@cInclude("fcntl.h");
	@cInclude("stdlib.h");
});

const termios = @cImport({
	@cDefine("_ISO_C11_SOURCE", "1");
	@cDefine("_POSIX_SOURCE", "200809L");
	@cDefine("_XOPEN_SOURCE", "700");
	@cInclude("termios.h");
	@cInclude("unistd.h");
	@cInclude("sys/ioctl.h");
});

const errno = @cImport({
	@cDefine("_ISO_C11_SOURCE", "1");
	@cDefine("_POSIX_SOURCE", "200809L");
	@cDefine("_XOPEN_SOURCE", "700");
	@cInclude("errno.h");
});

const unistd = @cImport({
	@cDefine("_ISO_C11_SOURCE", "1");
	@cDefine("_POSIX_SOURCE", "200809L");
	@cDefine("_XOPEN_SOURCE", "700");
	@cInclude("unistd.h");
});


const SignalInfo = struct{
	name: [:NUL]const u8,
	number: i64,
};

const SIGNAL_COUNT: comptime_int = blk: {
	var count = 0;
	for (std.meta.declarations(std.posix.SIG)) |decl| {
		if (@TypeOf(@field(std.posix.SIG, decl.name)) == comptime_int) {
			count += 1;
		}
	}
	break :blk count;
};

/// Compile-time generated constant of all Posix signals' names and signal numbers.
const SIGNALS: [SIGNAL_COUNT]SignalInfo = blk: {

	var ret: [SIGNAL_COUNT]SignalInfo = undefined;

	for (ContainerDecl.getFrom(std.posix.SIG), 0..) |decl, idx| {
		if (decl.valueIfType(comptime_int)) |value_ptr| {
			ret[idx] = .{
				.name = decl.name[0..(decl.name.len) :NUL],
				.number = value_ptr.*,
			};
		}
	}

	break :blk ret[0..SIGNAL_COUNT].*;
};

/// Lookup a signal's name (e.g. "TERM") by its number (e.g., 15).
fn signalName(number: i64) [*:NUL]const u8
{
	for (SIGNALS) |signal| {
		if (signal.number == number) {
			return signal.name;
		}
	}

	unreachable;
}

var log_file: std.fs.File = undefined;

fn printLog(comptime fmt: []const u8, args: anytype) void {
	log_file.writer().print(fmt ++ "\n", args) catch return;
}

const OpenptError = error{
	ExhaustedFileDescriptors,
	ExhaustedFiles,
	ExhaustedPtys,
	ExhaustedStreams,
} || std.posix.UnexpectedError;

const OpenptControl = enum{
	BecomeControllingTerminal,
	BecomeNonControllingTerminal,
};

fn openpt(control_type: OpenptControl) OpenptError!std.posix.fd_t
{
	const flags = switch (control_type) {
		.BecomeControllingTerminal => fcntl.O_RDWR,
		.BecomeNonControllingTerminal => fcntl.O_RDWR | fcntl.O_NOCTTY,
	};
	const fd = fcntl.posix_openpt(flags);
	switch (std.posix.errno(fd)) {
		.SUCCESS => return fd,
		.MFILE => return error.ExhaustedFileDescriptors,
		.NFILE => return error.ExhaustedFiles,
		.AGAIN => return error.ExhaustedPtys,
		.NOSR => return error.ExhaustedStreams,
		else => |e| {
			eprintln("posix_openpt() gave supposedly impossible error code {}", .{e});
			return error.Unexpected;
		},
	}
}

const PtyError = error{
	NotAFileDescriptor,
	NotAPty,
} || std.posix.UnexpectedError;

fn unlockpt(fd: std.posix.fd_t) PtyError!void
{
	const ret = fcntl.unlockpt(fd);
	switch (std.posix.errno(ret)) {
		.SUCCESS => return {},
		.BADF => return error.NotAFileDescriptor,
		.INVAL => return error.NotAPty,
		else => |e| {
			eprintln("unlockpt() gave supposedly impossible error code {}", .{e});
			return error.Unexpected;
		},
	}
}

fn ptsname(allocator: std.mem.Allocator, fd: std.posix.fd_t) ![]const u8
{
	const name: [*:0]const u8 = fcntl.ptsname(fd) orelse {
		return switch (std.posix.errno(-1)) {
			.SUCCESS => unreachable,
			.BADF => error.NotAFileDescriptor,
			.NOTTY => error.NotAPty,
			else => |e| std.posix.unexpectedErrno(e),
		};
	};


	const len = std.mem.len(name);
	const cstring: []const u8 = name[0..len :0];
	const memory: []u8 = try allocator.alloc(u8, cstring.len);
	@memcpy(memory, cstring[0..cstring.len]);
	return memory;
}

fn getwinsz(fd: std.posix.fd_t) !std.posix.winsize
{
	var winsize = termios.winsize{
		.ws_row = 0,
		.ws_col = 0,
		.ws_xpixel = 0,
		.ws_ypixel = 0,
	};
	const res = std.os.linux.ioctl(fd, termios.TIOCGWINSZ, @intFromPtr(&winsize));
	return switch (std.posix.errno(res)) {
		.SUCCESS => std.posix.winsize{
			.ws_row = winsize.ws_row,
			.ws_col = winsize.ws_col,
			.ws_xpixel = winsize.ws_xpixel,
			.ws_ypixel = winsize.ws_ypixel,
		},
		else => |e| std.posix.unexpectedErrno(e),
	};
}

fn setwinsz(fd: std.posix.fd_t, size: std.posix.winsize) !void
{
	const winsize = termios.winsize{
		.ws_row = size.ws_row,
		.ws_col = size.ws_col,
		.ws_xpixel = size.ws_xpixel,
		.ws_ypixel = size.ws_ypixel,
	};
	const res = std.os.linux.ioctl(fd, termios.TIOCSWINSZ, @intFromPtr(&winsize));
	return switch (std.posix.errno(res)) {
		.SUCCESS => {},
		else => |e| std.posix.unexpectedErrno(e),
	};
}

fn setsid() error{ CantBecomeLeader, Unexpected }!std.posix.fd_t
{
	const ret = std.os.linux.setsid();
	return switch (std.posix.errno(ret)) {
		.SUCCESS => ret,
		.PERM => error.CantBecomeLeader,
		else => |e| std.posix.unexpectedErrno(e),
	};
}

fn csctty(fd: std.posix.fd_t) error{ PermissionDenied, Unexpected }!void
{
	const ret = std.os.linux.ioctl(fd, termios.TIOCSCTTY, 0);
	return switch (std.posix.errno(ret)) {
		.SUCCESS => {},
		.PERM => error.PermissionDenied,
		else => |e| std.posix.unexpectedErrno(e),
	};
}

/// Caller owns the returned memory.
fn getHome(allocator: std.mem.Allocator) ![]const u8
{
	const from_env = std.process.getEnvVarOwned(allocator, "HOME");
	if (from_env) |home| {
		return home;
	} else |e| {
		log.warn("couldn't determine home directory from HOME: {}\nfalling back to passwd", .{e});
	}

	// Why is getuid() not in std.posix…?
	const uid = unistd.getuid();
	const user_info = std.c.getpwuid(uid) orelse return error.UserNotFound;

	const home_dir: CString = user_info.*.pw_dir orelse return error.NoHomeDir;
	const len = std.mem.len(home_dir);

	// The passwd data is vaguely owned by the kernel, so we should copy this out.
	const copied: [:NUL]u8 = try allocator.allocSentinel(u8, len, NUL);
	@memcpy(copied, home_dir[0..len]);

	return copied;
}

fn openLogFile(allocator: std.mem.Allocator) !void
{
	const home = try getHome(allocator);
	defer allocator.free(home);

	var home_dir = try std.fs.openDirAbsolute(home, .{});
	defer home_dir.close();
	var log_dir = try home_dir.makeOpenPath(".local/var/log", .{});
	defer log_dir.close();

	log_file = try log_dir.createFile("floatty.log", .{});
}

/// Caller takes ownership of the returned array list, unless an error occurs.
fn collectArgs(allocator: std.mem.Allocator) !CStringCArray
{
	var arglist = try CStringCArray.init(allocator);
	errdefer arglist.deinit();

	var args = try std.process.ArgIterator.initWithAllocator(allocator);
	defer args.deinit();

	while (args.next()) |arg| {
		var copied: [*:NUL]u8 = try allocator.allocSentinel(u8, arg.len, NUL);
		copied[arg.len] = 0;
		@memcpy(copied, arg);
		std.debug.assert(copied[arg.len] == 0);
		try arglist.append(copied[0..arg.len :NUL]);
	}

	return arglist;
}

const BasicPoller = struct{
	const Self = @This();

	fds: []const std.posix.fd_t,

	poller: std.posix.fd_t,

	events: std.ArrayList(std.os.linux.epoll_event),

	pub fn init(allocator: std.mem.Allocator, file_descriptors: []const std.posix.fd_t) !Self
	{
		var self = Self{
			.fds = file_descriptors,
			.poller = try std.posix.epoll_create1(0),
			.events = std.ArrayList(std.os.linux.epoll_event).init(allocator),
		};
		errdefer std.posix.close(self.poller);
		errdefer self.events.deinit();

		for (self.fds) |fd| {
			var poll_event = std.os.linux.epoll_event{
				.events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP,
				.data = std.os.linux.epoll_data{
					.fd = fd,
				},
			};
			try std.posix.epoll_ctl(self.poller, std.os.linux.EPOLL.CTL_ADD, fd, &poll_event);
			try self.events.append(poll_event);
		}

		return self;
	}

	/// Caller owns the ArrayList returned, unless an error occurs.
	pub fn next(self: Self, timeout: i32) !?std.ArrayList(std.posix.fd_t)
	{
		const nfds = std.posix.epoll_wait(self.poller, self.events.items, timeout);
		if (nfds < 1) {
			return null;
		}

		var fd_list = std.ArrayList(std.posix.fd_t).init(self.events.allocator);
		errdefer fd_list.deinit();

		for (0..nfds) |returned_fd_idx| {
			const event = self.events.items[returned_fd_idx];
			for (self.fds) |known_fd| {
				if (event.data.fd == known_fd) {
					try fd_list.append(event.data.fd);
				}
			}
		}

		return fd_list;
	}

	pub fn deinit(self: Self) void
	{
		std.posix.close(self.poller);
		self.events.deinit();
	}
};

/// Caller is responsible for closing the file descriptor.
pub fn handleSignalAsFile(signals: []const comptime_int) !std.posix.fd_t
{
	var set = std.posix.empty_sigset;
	inline for (signals) |sig| {
		// sigaddset() is posix standard, not sure why it's std.os.linux?
		std.os.linux.sigaddset(&set, sig);
	}

	// We have to block a signal to be able to handle it as a file.
	std.posix.sigprocmask(std.c.SIG.BLOCK, &set, null);
	// And on the other hand, signalfd() is a Linux syscall, and not posix at all.
	const filedes = std.posix.signalfd(-1, &set, std.os.linux.SFD.NONBLOCK);
	return filedes;
}

pub fn streql(lhs: []const u8, rhs: []const u8) bool
{
	return std.mem.eql(u8, lhs, rhs);
}

pub fn printUsage() void
{
	const stdout = std.io.getStdOut();
	stdout.writer().writeAll(
		// This is *the* worst multiline syntax.
		\\Usage: floatty <program> <args...>
		\\
		\\OPTIONS:
		\\  --help     display this help message and exit
		\\  --version  display version information and exit
		\\
	) catch |e| {
		// If we can't write to stdout for even the help message, then we might as well
		// at least let the caller process know *something* went wrong.
		// Writing to stderr probably won't work either, but we'll throw an attempt in anyway.
		eprintln("floatty: error writing help message to stdout: {}", .{e});
		std.process.exit(254);
	};
}

pub fn printHexString(str: []const u8) void
{
	var iterator = std.unicode.Utf8Iterator{
		.bytes = str,
		.i = 0,
	};

	while (iterator.nextCodepoint()) |codepoint| {
		if (codepoint <= 0x7F) {
			const ch: u8 = @intCast(codepoint);
			if (ch == '\n') {
				print("\\n", .{});
			} else if (ch == '\r') {
				print("\\r", .{});
			} else if (ch == '\t') {
				print("\\t", .{});
			} else if (ch == ' ') {
				print(" ", .{});
			} else if (std.ascii.isControl(ch)) {
				print("\\x{x:0>2}", .{ch});
			} else {
				print("{c}", .{ch});
			}
		} else {
			print("\\u{x:0>4}", .{codepoint});
		}
	}
}

test "countLinesInWin" {
	const buffer: []const u8 = " \r100%|\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}"
		++ "\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}| 1/1 [00:00<00:00, 63550.06it/s]\r\n";

	var text = std.ArrayList(u21).init(std.heap.c_allocator);
	var iterator = std.unicode.Utf8Iterator{
		.bytes = buffer,
		.i = 0,
	};
	while (iterator.nextCodepoint()) |codepoint| {
		try text.append(codepoint);
	}

	const allocator = std.testing.allocator;
	const hist = text.items;

	// lol zig doesn't have inner functions or function expressions so we have to do this.
	const winsz = struct{
		fn winsz(width: comptime_int) std.posix.winsize
		{
			return .{
				.ws_col = width,
				.ws_row = 39,
				.ws_xpixel = 0,
				.ws_ypixel = 0,
			};
		}
	}.winsz;

	var reflow_320 = try countForReflow(allocator, hist, winsz(320));
	defer reflow_320.deinit();
	var reflow_160 = try countForReflow(allocator, hist, winsz(160));
	defer reflow_160.deinit();

	try std.testing.expectEqual(1, reflow_320.total_lines);
	try std.testing.expectEqual(2, reflow_160.total_lines);
}

pub const WinLines = struct{
	pub const Line = struct{
		width: u32,
		// Caller continues to own these codepoints.
		codepoints: []const u21,
	};
	lines: std.ArrayList(Line),
};

const Cursor = struct{
	row: u32 = 1,
	col: u32 = 1,
};

const TermRow = struct{
	columns: u32,
	text: []const u21,
};

const ReflowData = struct{
	total_lines: u32,
	term_rows: std.ArrayList(TermRow),

	pub fn deinit(self: *ReflowData) void
	{
		self.*.term_rows.deinit();
	}
};

/// Reads and executes a callback on each buffer read until a read would block.
fn readAndDo(
	reader: anytype,
	handler: type,
) (@TypeOf(reader).Error || handler.Error)!void
{
	var buffer = std.mem.zeroes([4096]u8);
	var count: usize = 1;
	while (count > 0) {
		if (reader.read(&buffer)) |amount_read| {
			count = amount_read;
		} else |err| switch (err) {
			error.WouldBlock => return,
			else => |e| return e,
		}

		try handler.callback(buffer[0..count]);
	}
}

const printHandler = struct{
	const Error = std.fs.File.WriteError;
	fn callback(buffer: []const u8) std.fs.File.WriteError!void
	{
		try std.io.getStdOut().writeAll(buffer);
	}
};

/// Reads and discards until a read would block.
fn readAndDiscard(reader: anytype) !void
{
	var buffer = std.mem.zeroes([4096]u8);
	while (true) {
		_ = reader.read(&buffer) catch |e| switch (e) {
			error.WouldBlock => return,
			else => return e,
		};
	}
}

pub fn childProcess(prog: CString, argv: [*:null]const ?CString, our_pty: std.posix.fd_t) !u8
{
	// Become a session leader...
	_ = try setsid();

	// ...and take our terminal as this session's terminal.
	try csctty(our_pty);

	// Set stdio file descriptors for this child process to the pty.
	// TODO: should this also set stdin?
	inline for (.{ STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO }) |fileno| {
		try std.posix.dup2(our_pty, fileno);
	}

	// I totally don't get why this is here but all PTY code we've found does this.
	std.posix.close(our_pty);

	const envp: [*:null]const ?CString = std.c.environ;
	return std.posix.execvpeZ(prog, argv, envp);
}


/// Caller owns ReflowData.
pub fn countForReflow(allocator: std.mem.Allocator, hist: []const u21, winsize: std.posix.winsize) !ReflowData
{
	const newline: u21 = '\n';
	const carriage_return: u21 = '\r';
	const escape: u21 = '\x1b';

	const winwidth: f64 = @floatFromInt(winsize.ws_col);

	var cur = Cursor{};
	// The right-most column that has text in it.
	var textcol: u32 = 0;

	// TODO: reuse allocation between reflows?
	var term_rows = std.ArrayList(TermRow).init(allocator);

	var row_start: usize = 0;
	for (hist, 0..) |codepoint, idx| {
		if (codepoint == newline) {
			// We don't explicitly need to include the newline here (?),
			// otherwise we would do idx + 1.
			const line_data: []const u21 = hist[row_start..idx];
			try term_rows.append(.{
				.columns = textcol,
				.text = line_data,
			});

			cur.row += 1;
			cur.col = 1;
			textcol = 0;
			row_start = idx + 1;
		} else if (codepoint == carriage_return) {
			// \r doesn't change any existing output, but it does affect how future
			// characters affect our lines.
			cur.col = 1;
		} else if (codepoint == escape) {
			std.debug.panic("todo!", .{});
		} else {
			cur.col += 1;
			// The cursor's column is 1-indexed, but what column actually has output
			// is 0-indexed.
			textcol = @max(cur.col - 1, textcol);
		}
	}

	// Take care of anything left in the last line processed
	if (textcol != 0) {
		try term_rows.append(.{
			.columns = textcol,
			.text = hist[row_start..],
		});
	}

	// Figure out how many lines we're gonna need to reflow.
	var total_lines: u32 = 0;
	for (term_rows.items) |row| {
		// @floatFromInt() needs a type annotation to work.
		const line_width: f64 = @floatFromInt(row.columns);
		const visual_lines = line_width / winwidth;
		total_lines += @intFromFloat(@ceil(visual_lines));
	}

	return .{
		.total_lines = total_lines,
		.term_rows = term_rows,
	};
}

pub fn reflow(allocator: std.mem.Allocator, hist: []const u21, winsize: std.posix.winsize) !void
{
	const newline: u21 = '\n';
	const carriage_return: u21 = '\r';
	const escape: u21 = '\x1b';

	const stdout = std.io.getStdOut();
	var cur = Cursor{};
	// The right-most column that has text in it.
	var textcol: u32 = 0;

	var reflow_data = try countForReflow(allocator, hist, winsize);
	defer reflow_data.deinit();
	const total_lines = reflow_data.total_lines;
	const term_rows = reflow_data.term_rows;
	// Move up that many lines.
	try stdout.writer().print("\r\x1b[{}F", .{total_lines});

	// FIXME: choose a better threshold.
	const threshold: comptime_int = 10;

	// I'd prefer not to make a syscall for every codepoint we want to write.
	// TODO: reuse allocation across reflows or something
	var line_buffer = std.ArrayList(u8).init(allocator);
	defer line_buffer.deinit();

	// Reset our state; we have some cursor tracking to do again!
	cur.col = 1;
	textcol = 0;

	// And finally, replay, with some modifications.
	for (term_rows.items) |row| {
		// Clear line.
		try line_buffer.appendSlice("\r\x1b[0K");

		// If this row doesn't overflow, then we can just output it verbatim!
		// TODO: reflow-expand too, not just reflow-shrink.
		if (row.columns <= winsize.ws_col) {
			// But we do have to encode it back to UTF-8 first.
			for (row.text) |codepoint| {
				var buffer = std.mem.zeroes([8]u8);
				const len = try std.unicode.utf8Encode(codepoint, &buffer);
				try line_buffer.appendSlice(buffer[0..len]);
			}
			try line_buffer.append('\n');
			_ = try stdout.writer().write(line_buffer.items);

			continue;
		}

		// Otherwise, we have work to do.
		var last_char: u21 = 0;
		var last_count: u32 = 0;
		// Amount of columns in this line we've already taken care of.
		var cols_advanced: u32 = 0;
		for (row.text) |codepoint| {
			if (codepoint == newline) {
				std.debug.panic("bruh this shouldn't happen", .{});
			}

			if (codepoint == carriage_return) {
				// Reset state.
				try line_buffer.append('\r');
				cur.col = 1;
				last_char = 0;
				last_count = 0;
				cols_advanced = 0;

				continue;
			} else if (codepoint == escape) {
				std.debug.panic("what", .{});
			}

			defer last_char = codepoint;
			defer cols_advanced += 1;

			const left: i64 = (row.columns + 1) - cols_advanced;
			const available_cols: i64 = winsize.ws_col - cur.col;

			if (codepoint == last_char) {
				last_count += 1;
			} else {
				last_count = 0;
			}

			// Hueristic: if we see a bunch of the same characters in a row, that segment
			// can *probably* be lengthed or shortened as needed.
			// FIXME: this does not lengthen past the original width.
			if (left > available_cols and last_count >= threshold) {
				// Don't output anything.
				continue;
			}

			// Otherwise output normally.
			var buffer: [8]u8 = std.mem.zeroes([8]u8);
			const len = try std.unicode.utf8Encode(codepoint, &buffer);
			try line_buffer.appendSlice(buffer[0..len]);
			cur.col += 1;
		}

		try line_buffer.appendSlice("\n\x1b[0K");
		_ = try stdout.writer().write(line_buffer.items);
		line_buffer.clearAndFree();
	}
}

pub fn parentLoop(allocator: std.mem.Allocator, pty_fd: fd_t) !void
{
	const File = std.fs.File;

	const pty_file = File{ .handle = pty_fd };

	// Switch to file descriptor based handling for SIGCHLD and SIGWINCH,
	// so we can multiplex them and PTY output.
	const sigchld_fd = try handleSignalAsFile(&.{std.posix.SIG.CHLD});
	defer std.posix.close(sigchld_fd);
	const sigchld = File{ .handle = sigchld_fd };
	const sigwinch_fd = try handleSignalAsFile(&.{std.posix.SIG.WINCH});
	defer std.posix.close(sigwinch_fd);
	const sigwinch = File{ .handle = sigwinch_fd };

	// Now setup polling for them.
	const poller = try BasicPoller.init(
		allocator,
		&.{ pty_fd, sigchld_fd, sigwinch_fd },
	);
	defer poller.deinit();

	var known_history = std.ArrayList(u21).init(allocator);
	defer known_history.deinit();

	var current_size = try getwinsz(STDIN_FILENO);
	try setwinsz(pty_fd, current_size);

	var historyBuffer = std.ArrayList(u8).init(allocator);
	defer historyBuffer.deinit();
	try historyBuffer.ensureTotalCapacity(8 * 1024);

	var keep_going = true;
	while (keep_going) {
		const fd_list: std.ArrayList(fd_t) = try poller.next(-1) orelse break;
		defer fd_list.deinit();

		for (fd_list.items) |fd| {
			if (fd == pty_fd) {
				var buffer = std.mem.zeroes([4096]u8);
				var count: usize = 1;
				inner: while (count > 0) {
					if (pty_file.read(&buffer)) |amount_read| {
						count = amount_read;
					} else |err| switch (err) {
						error.WouldBlock => break :inner,
						else => return err,
					}
					try std.io.getStdOut().writeAll(buffer[0..count]);
					var iterator = std.unicode.Utf8Iterator{
						.bytes = buffer[0..count],
						.i = 0,
					};
					while (iterator.nextCodepoint()) |codepoint| {
						try known_history.append(codepoint);
					}
				}
			} else if (fd == sigwinch_fd) {
				// Read and discard to clear the "event" from our poller.
				try readAndDiscard(sigwinch.reader());

				// Get the new size, and forward it to the child.
				current_size = try getwinsz(STDIN_FILENO);
				try setwinsz(pty_fd, current_size);

				// Clear and redraw known lines.
				try reflow(allocator, known_history.items, current_size);

			} else if (fd == sigchld_fd) {
				// We don't want to break immediately, because we could still have non-signal
				// events left to handle.
				keep_going = false;

				// Read and discard to clear the "event" from our poller.
				try readAndDiscard(sigchld.reader());
			} else unreachable;
		}
	}
}

const CmdlineArgsResult = union(enum) {
	exit_code: u8,
	/// Caller owned.
	subproc: struct{
		argc: usize,
		argv: [*:null]?CString,
	},
};

// Shitty, shotgun arg parser.
fn handleArgs(allocator: Allocator) !CmdlineArgsResult
{
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
		eprintln(
			\\floatty: error: the following required arguments were not provided:
			\\  <program>
			++ "\n",
			.{},
		);
		printUsage();
		return .{ .exit_code = 255 };
	};

	if (first[0] == '-') {
		// No outlet.

		if (streql(first, "--help")) {
			printUsage();
			return .{ .exit_code = 0 };
		}

		if (std.mem.eql(u8, first, "--version")) {
			println("floatty 0.0.1", .{});
			return .{ .exit_code = 0 };
		}

		eprintln(
			"floatty: unrecognized option '{s}'\nTry 'floatty --help' for more information",
			.{first},
		);
		return .{ .exit_code = 255 };
	}

	// - 1 as we do not include the `executed_as` argument.
	const child_argc = args.inner.count - 1;

	// Note: no defer free. Caller takes ownership.
	var child_args: [*:null]?CString = try allocator.allocSentinel(?CString, child_argc, null);
	var first_copied: [*:NUL]u8 = try allocator.allocSentinel(u8, first.len, NUL);
	@memcpy(first_copied, first);
	first_copied[first.len] = NUL;
	child_args[0] = first_copied[0..first.len :NUL];

	var arg_pos: usize = 1;
	while (args.next()) |arg| : (arg_pos += 1) {
		var copied: [*:NUL]u8 = try allocator.allocSentinel(u8, arg.len, NUL);
		@memcpy(copied, arg);
		copied[arg.len] = NUL;
		child_args[arg_pos] = copied[0..arg.len :NUL];
	}

	std.debug.assert(child_argc == arg_pos);

	return .{ .subproc = .{
		.argc = arg_pos,
		.argv = child_args,
	} };
}

pub fn main() !u8
{
	const allocator = std.heap.c_allocator;

	try openLogFile(allocator);
	defer log_file.close();

	const child_args = switch(try handleArgs(allocator)) {
		.exit_code => |code| return code,
		.subproc => |args| args,
	};


	// Note: this does not get run in the child code
	// since execve() replaces the process first.
	defer {
		const argv_slice = child_args.argv[0..child_args.argc];
		for (argv_slice) |maybe_arg| {
			// The only null here should be the terminator, which wont be included in argc.
			const arg = maybe_arg orelse unreachable;
			const slice = arg[0..std.mem.len(arg)];
			allocator.free(slice);
		}
		allocator.free(argv_slice);
	}

	const pty_fd: c_int = try openpt(.BecomeNonControllingTerminal);
	defer std.posix.close(pty_fd);
	_ = try std.posix.fcntl(pty_fd, std.c.F.SETFL, std.os.linux.IN.NONBLOCK);

	// ioctl TIOCSPTLCK
	try unlockpt(pty_fd);

	// ioctl TIOCGPTN "get pty number"
	// FIXME: use TIOCGPTPEER instead
	const term_name = try ptsname(allocator, pty_fd);
	defer allocator.free(term_name);
	log.debug("Our terminal is {s}", .{term_name});

	const other_side = try std.posix.open(term_name, .{ .NOCTTY = false, .ACCMODE = .RDWR }, 0);
	defer std.posix.close(other_side);

	log.debug("Got file descriptors {} and {}", .{ pty_fd, other_side });

	// TODO: technically there's a minor race condition here.
	// If the user changes the parent terminal size after here, but before we setup
	// the epoll() event loop, the size won't be propagated to the float-pty until
	// the parent terminal size changes again.
	const parent_winsize = try getwinsz(std.posix.STDIN_FILENO);
	log.debug("our win size: {}", .{parent_winsize});
	try setwinsz(other_side, parent_winsize);

	const child_winsize = try getwinsz(other_side);
	log.debug("winsize: {}", .{child_winsize});

	// Spawn a new process, and then use setsid() and TIOCSCTTY to make this terminal
	// the controlling terminal for that process, and then spawn the requested command.
	const pid = try std.posix.fork();
	if (pid == 0) {
		// Child code...
		std.posix.close(pty_fd);
		log_file.close();
		const first = child_args.argv[0] orelse unreachable;
		return childProcess(first, child_args.argv, other_side);
	}

	defer {
		// Gotta reap those children!
		const status = std.posix.waitpid(pid, 0);
		log.debug("waitpid() returned {}", .{status});
		const wstatus: u32 = status.status;
		if (std.c.W.IFEXITED(wstatus)) {
			const exit_code = std.c.W.EXITSTATUS(wstatus);
			if (exit_code != 0) {
				eprintln("floatty: child exited with non-zero exit code {}", .{exit_code});
			}
		} else if (std.c.W.IFSIGNALED(wstatus)) {
			const signum = std.c.W.TERMSIG(wstatus);
			eprintln("floatty: child killed by SIG{s} (signal {})", .{signalName(signum), signum});
		} else if (std.c.W.IFSTOPPED(wstatus)) {
			const signum = std.c.W.STOPSIG(wstatus);
			eprintln("floatty: child stopped by SIG{s} (signal {})", .{signalName(signum), signum});
		} else {
			eprintln("floatty: unknown waitpid() status {} (floatty bug)", .{status});
		}
	}

	// Meanwhile here in the parent we'll be monitoring the PTY we connected the child
	// to for output to forward to the non-float-pty, as well as SIGCHLD for when the
	// command ends, and SIGWINCH to forward terminal size changes to the float-pty.

	log.debug("forked to process {}", .{pid});
	try parentLoop(allocator, pty_fd);

	return 0;
}
