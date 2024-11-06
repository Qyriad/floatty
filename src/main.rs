use std::fs::File;
use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::io::{self, IsTerminal};

#[allow(unused_imports)]
use {
	bstr::{BStr, BString, ByteSlice, ByteVec},
	bytes::{BufMut, Bytes},
	log::{trace, debug, info, warn, error},
	miette::{Context as _, Diagnostic, Error, IntoDiagnostic},
	nix::errno::Errno,
	tap::prelude::*,
};

use floatty::pty::{openpt, unlockpt, ptsname, getwinsz, setwinsz, OpenptControl};
use floatty::fdops::FdOps;

fn main() -> miette::Result<()>
{
	env_logger::init();

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

	Ok(())
}
