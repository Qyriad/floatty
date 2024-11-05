use std::os::fd::{AsFd, OwnedFd};

#[allow(unused_imports)]
use {
	bstr::{BStr, BString, ByteSlice, ByteVec},
	bytes::{BufMut, Bytes},
	log::{trace, debug, info, warn, error},
	miette::{Diagnostic, Error, IntoDiagnostic},
	nix::errno::Errno,
	tap::prelude::*,
};

use floatty::pty::{openpt, OpenptControl};
use floatty::fdops::FdOps;

fn main() -> miette::Result<()>
{
	env_logger::init();

	let pty_fd: OwnedFd = openpt(OpenptControl::BecomeControllingTerminal)?;

	pty_fd.as_fd().set_nonblocking();
	dbg!(&pty_fd);

	floatty::pty::unlockpt(pty_fd.as_fd())?;

	Ok(())
}
