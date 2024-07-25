const std: type = @import("std");
const print: fn (comptime []const u8, anytype) void = std.debug.print;
const panic: fn (comptime []const u8, anytype) noreturn = std.debug.panic;
const log = std.log;

const STDIN_FILENO = std.posix.STDIN_FILENO;
const STDOUT_FILENO = std.posix.STDOUT_FILENO;
const STDERR_FILENO = std.posix.STDERR_FILENO;

pub const std_options = .{
	.log_level = .info,
};

/// Not to be confused with null.
const NUL: u8 = 0;

fn println(comptime fmt: []const u8, args: anytype) void
{
	std.debug.print(fmt, args);
	std.debug.print("\n", .{});
}

const Type = std.builtin.Type;

fn typeInfoOf(comptime value: anytype) Type
{
	return @typeInfo(@TypeOf(value));
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
			println("posix_openpt() gave supposedly impossible error code {}", .{ e });
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
			println("unlockpt() gave supposedly impossible error code {}", .{ e });
			return error.Unexpected;
		}
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

fn TerminatedArrayList(comptime T: type, comptime sentinel_value: ?T) type
{
	return struct{
		const Self = @This();
		const Item = T;
		const sentinel = sentinel_value;

		inner: std.ArrayList(?Item),

		pub fn init(allocator: std.mem.Allocator) !Self
		{
			var list = std.ArrayList(?Item).init(allocator);
			try list.append(null);
			return Self{
				.inner = list,
			};
		}

		pub fn deinit(self: Self) void
		{
			for (self.inner.items) |item| {
				if (item) |ptr| {
					switch (@typeInfo(@TypeOf(ptr))) {
						.Pointer => {
							const slice = ptr[0..std.mem.len(ptr)];
							self.inner.allocator.free(slice);
						},
						.Array => {
							self.inner.allocator.free(ptr);
						},
						else => comptime unreachable,
					}
				}
			}
			self.inner.deinit();
		}

		pub fn append(self: *Self, item: Item) !void
		{
			const last: *?Item = &self.inner.items[self.inner.items.len - 1];
			std.debug.assert(last.* == null);
			// These two operations must be in this order.
			// If we set the last item before doing the append, and the append failed, then
			// we'd have an arraylist where the last element isn't the sentinel terminator.
			try self.inner.append(null);
			last.* = item;
		}

		/// The number of *items* in this arraylist -- so not including the sentinel.
		pub fn count(self: Self) usize
		{
			return self.inner.items.len - 1;
		}

		/// The number of slots this arraylist is using -- so including the sentinel.
		pub fn totalLen(self: Self) usize
		{
			return self.inner.items.len;
		}

		pub fn asSlice(self: Self) []Item
		{
			return @ptrCast(self.inner.items[0..self.count()]);
		}

		pub fn asTerminatedSlice(self: Self) [:null]?Item
		{
			return @ptrCast(self.inner.items[0..self.inner.items.len]);
		}

		pub fn format(self: Self, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void
		{
			if (fmt.len != 0) std.fmt.invalidFmtError(fmt, self);
			if (self.count() < 1) {
				return;
			}

			try std.fmt.format(writer, "{s}", .{ "{ " });

			const slice: []Item = self.asSlice();
			std.debug.assert(slice.len == self.count());

			for (slice, 0..) |arg, idx| {
				try std.fmt.format(writer, if (Item == [:NUL]const u8) "\"{s}\"" else "{any}", .{ arg });
				if (idx < slice.len - 1) {
					try std.fmt.format(writer, "{s}", .{ ", "});
				}
			}
			try std.fmt.format(writer, "{s}", .{ " }" });
		}
	};
}

const CStringCArray = TerminatedArrayList([*:NUL]const u8, null);

pub fn main() !void
{
	const allocator = std.heap.c_allocator;

	var arglist = try CStringCArray.init(allocator);
	defer arglist.deinit();
	var args = try std.process.ArgIterator.initWithAllocator(allocator);
	defer args.deinit();
	while (args.next()) |arg| {
		var copied: [*:NUL]u8 = try allocator.allocSentinel(u8, arg.len, NUL);
		copied[arg.len] = 0;
		@memcpy(copied, arg);
		try arglist.append(copied);
	}

	if (arglist.count() < 2) {
		println("i need some args bro.", .{});
		return;
	}

	log.debug("args: {}", .{ arglist });

	const pty_fd: c_int = try openpt(.BecomeNonControllingTerminal);
	defer std.posix.close(pty_fd);
	_ = try std.posix.fcntl(pty_fd, std.c.F.SETFL, std.os.linux.IN.NONBLOCK);

	// ioctl TIOCSPTLCK
	try unlockpt(pty_fd);

	// ioctl TIOCGPTN "get pty number"
	// FIXME: use TIOCGPTPEER instead
	const term_name = try ptsname(allocator, pty_fd);
	defer allocator.free(term_name);
	log.debug("Our terminal is {s}", .{ term_name });

	const other_side = try std.posix.open(term_name, .{ .NOCTTY = false, .ACCMODE = .RDWR }, 0);
	defer std.posix.close(other_side);

	log.debug("Got file descriptors {} and {}", .{ pty_fd, other_side });

	const parent_winsize = try getwinsz(std.posix.STDIN_FILENO);
	log.debug("our win size: {}", .{ parent_winsize });

	const child_winsize = try getwinsz(other_side);
	log.debug("winsize: {}", .{ child_winsize });

	// Spawn a new process, and then use setsid() and TIOCSCTTY to make this terminal
	// the controlling terminal for that process.
	const pid = try std.posix.fork();
	if (pid == 0) {
		// Child code...

		std.posix.close(pty_fd);

		// Become a session leader...
		_ = try setsid();

		// ...and take our terminal as this session's terminal.
		try csctty(other_side);

		// Set stdout, and stderr for this child process to the pty.
		// TODO: should this also set stdin?
		inline for (.{ STDOUT_FILENO, STDERR_FILENO }) |fileno| {
			try std.posix.dup2(other_side, fileno);
		}

		// I totally don't get why this is here but all PTY code we've found does this.
		std.posix.close(other_side);

		const argsSlice: [:null]const ?[*:NUL]const u8 = arglist.asTerminatedSlice();
		const first = argsSlice[1] orelse unreachable;
		const argv: [*:null]const ?[*:NUL]const u8 = argsSlice[1..];
		const envp: [*:null]const ?[*:NUL]const u8 = std.c.environ;
		return std.posix.execvpeZ(first, argv, envp);
	} else {
		log.debug("forked to process {}", .{ pid });

		const pty_file = std.fs.File{ .handle = pty_fd };
		const pty_reader = pty_file.reader();

		// Switch to file descriptor based handling for SIGCHLD.
		var sigchld_set: std.posix.sigset_t = sigset: {
			var set = std.posix.empty_sigset;
			std.os.linux.sigaddset(&set, std.posix.SIG.CHLD);
			break :sigset set;
		};
		std.posix.sigprocmask(std.os.linux.SIG.BLOCK, &sigchld_set, null);
		const sigchld_fd = try std.posix.signalfd(-1, &sigchld_set, 0);
		defer std.posix.close(sigchld_fd);

		// Now setup polling for both the pty and the sigchld file descriptors.
		const poller = try std.posix.epoll_create1(0);
		defer std.posix.close(poller);
		var pty_poll_event = std.os.linux.epoll_event{
			.events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP,
			.data = std.os.linux.epoll_data{
				.fd = pty_fd,
			},
		};
		try std.posix.epoll_ctl(poller, std.os.linux.EPOLL.CTL_ADD, pty_fd, &pty_poll_event);
		var sigchld_poll_event = std.os.linux.epoll_event{
			.events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP,
			.data = std.os.linux.epoll_data{
				.fd = sigchld_fd,
			},
		};
		try std.posix.epoll_ctl(poller, std.os.linux.EPOLL.CTL_ADD, sigchld_fd, &sigchld_poll_event);

		var poll_events: [2]std.os.linux.epoll_event = .{ pty_poll_event, sigchld_poll_event };

		// And startup our poll-based event loop.
		var keep_going = true;
		while (keep_going) {
			// -1 means block forever.
			const nfds = std.posix.epoll_wait(poller, &poll_events, -1);
			if (nfds < 1) {
				unreachable;
			}

			for (0..nfds) |fd_idx| {
				const event = poll_events[fd_idx];
				if (event.data.fd == pty_fd) {

					var buffer = std.mem.zeroes([4096]u8);
					// lol, mini hack because zig doesn't have do { } while
					var count: usize = 1;
					while (count > 0) {
						if (pty_reader.read(&buffer)) |amount_read| {
							count = amount_read;
						} else |err| switch (err) {
							error.WouldBlock => break,
							else => |e| return e,
						}
						try std.io.getStdOut().writeAll(buffer[0..count]);
					}
				} else if (event.data.fd == sigchld_fd) {
					keep_going = false;
				} else {
					unreachable;
				}
			}
		}

		defer {
			const status = std.posix.waitpid(pid, 0);
			log.info("waitpid() returned {}", .{ status });
		}
	}
}
