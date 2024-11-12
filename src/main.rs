#![feature(os_str_display)]

use std::env;
use std::ffi::{OsString, OsStr};
use std::fs::File;
use std::io::{self, IsTerminal, Write};
use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

#[allow(unused_imports)]
use {
	bstr::{BStr, BString, ByteSlice, ByteVec},
	bytes::{BufMut, Bytes},
	log::{trace, debug, info, warn, error},
	miette::{Context as _, Diagnostic, Error, IntoDiagnostic},
	nix::{errno::Errno, unistd::ForkResult},
	tap::prelude::*,
};

use floatty::pty::{openpt, unlockpt, ptsname, getwinsz, setwinsz, OpenptControl};
use floatty::fdops::FdOps;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct HandledArgs
{
	/// The program to execute.
	prog: Box<Path>,
	/// Arguments to that program.
	args: Box<[Box<OsStr>]>,
}

fn print_usage()
{
	let mut stdout = io::stdout();
	writeln!(
		stdout,
		"Usage: floatty <program> <args...>\
		\n\
		\nOPTIONS:\
		\n  --help     display this help message and exit
		\n  --version  display version information and exit\
		\n",
	).unwrap_or_else(|e| {
		// If we can't write to stdout for even the help message, then we might as well
		// at least let the caller process know *something* went wrong.
		// Writing to stderr probably won't work either, but we'll throw an attempt in anyway.
		let _ = writeln!(io::stderr(), "floatty: error writing help message to stdout: {e}");
		std::process::exit(254);
	});
}

/// Pretty raw port of the Zig argument parsing we had.
fn handle_args() -> Result<HandledArgs, ExitCode>
{
	let mut args = env::args_os();
	// Should be impossible.
	// If we don't even have argv[0] then we were exeecuted incorrectly in the first place.
	// On the other hand, we don't care about the actual value of argv[0].
	let Some(_executed_as) = args.next() else { unreachable!(); };

	// The first argument is special.
	// We can't take any --options after accepting positional arguments, so that we don't
	// interpret things like `floatty ls --help` as `--help` for us.
	// Also we don't have any cases where --multiple --options make sense at a time, yet,
	// since we only have `--version` and `--help`.
	let Some(first) = args.next() else {
		// No arguments provided.
		eprintln!(
			"floatty: error: the following required arguments were not provided:\
			\n  <program>\
			",
		);

		print_usage();

		return Err(ExitCode::from(255));
	};

	// Jesus christ Rust. Get your shit together with OS strings...
	let hyphen_minus = OsStr::new("-").as_encoded_bytes();
	let encoded_len = hyphen_minus.len();
	if &first.as_encoded_bytes()[0..encoded_len] == hyphen_minus {
		if first == OsStr::new("--help") {
			print_usage();
			return Err(ExitCode::SUCCESS);
		}

		if first == OsStr::new("--version") {
			println!("floatty 0.0.1");
			return Err(ExitCode::SUCCESS);
		}

		eprintln!(
			"floatty: unrecognized option '{}'\
			\nTry 'floatty --help' for more information",
			first.display(),
		);
	}

	// If we got here, then we weren't passed any options.
	// Which means `first` is the command we want to execute.
	let prog: Box<Path> = which::which(&first)
		.unwrap_or_else(|_| PathBuf::from(first))
		.into_boxed_path();

	let args: Box<[Box<OsStr>]> = args
		.map(OsString::into_boxed_os_str)
		.collect::<Vec<_>>()
		.into_boxed_slice();

	Ok(HandledArgs { prog, args })
}

fn main() -> miette::Result<ExitCode>
{
	env_logger::init();

	let HandledArgs { prog, args } = match handle_args() {
		Ok(handled) => handled,
		// Feels slightly weird to use Ok() to return a potential error code...
		// ...but whatever.
		Err(code) => return Ok(code),
	};

	let pty_fd: OwnedFd = openpt(OpenptControl::BecomeControllingTerminal)?;

	pty_fd.as_fd().set_nonblocking();

	unlockpt(pty_fd.as_fd())?;

	// ioctl TIOCGPTN "get pty number"
	// FIXME: use TIOCPTPEER instead
	let term_name = ptsname(pty_fd.as_fd())?;
	info!("Our terminal is {}", term_name.display());

	let other_side = File::options()
		.read(true)
		.write(true)
		.custom_flags(libc::O_NONBLOCK | libc::O_NOCTTY)
		.open(&term_name)
		.into_diagnostic()
		.with_context(|| format!("opening terminal child {}", term_name.display()))?;

	// Surprisingly, `pty_fd` is NOT a terminal, but this definitely should be.
	debug_assert!(other_side.is_terminal());

	debug!("Got file descriptors {} and {}", pty_fd.as_raw_fd(), other_side.as_raw_fd());

	let current_size = getwinsz(io::stdin().as_fd());
	setwinsz(pty_fd.as_fd(), current_size);

	// Spawn a new process, and then use setsid() and TIOCSCTTY to make this terminal
	// the controlling terminal for that process, and then spawn the requested command.
	use ForkResult::*;
	match unsafe { nix::unistd::fork() } {
		Ok(Child) => {
			drop(pty_fd);

			info!("prog: {prog:?}, args: {args:?}");
			floatty::child::child_process(prog, args, OwnedFd::from(other_side))?;
		},
		Ok(Parent { child }) => {
			floatty::parent::parent_process(child, pty_fd)?;
		},
		Err(e) => {
			panic!("fork() failed: {e}");
		},
	}

	Ok(ExitCode::SUCCESS)
}
