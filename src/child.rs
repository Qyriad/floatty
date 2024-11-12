use std::ffi::OsStr;
use std::path::Path;
use std::process::Command;
use std::io;
use std::os::fd::{AsFd, AsRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;

#[allow(unused_imports)]
use {
	bstr::{BStr, BString, ByteSlice, ByteVec},
	bytes::{BufMut, Bytes},
	log::{trace, debug, info, warn, error},
	miette::{Context as _, Diagnostic, Error, IntoDiagnostic},
	nix::errno::Errno,
	tap::prelude::*,
};

use crate::pty::csctty;

pub fn child_process(prog: Box<Path>, args: Box<[Box<OsStr>]>, our_pty: OwnedFd) -> miette::Result<()>
{
	// Become a session leader...
	let pgid = nix::unistd::setsid().into_diagnostic()?;
	debug!("became session leader of new session {pgid}");

	// ...and take our terminal as this session's terminal.
	csctty(our_pty.as_fd())?;

	// Set stdio file descrptors for this child process to the pty.
	// TODO: should this also set stdin?
	let stdin_fileno = io::stdin().as_raw_fd();
	let stdout_fileno = io::stdout().as_raw_fd();
	let stderr_fileno = io::stderr().as_raw_fd();

	let pty_raw: RawFd = our_pty.as_raw_fd();

	for fileno in [stdin_fileno, stdout_fileno, stderr_fileno] {
		nix::unistd::dup2(pty_raw, fileno)
			.into_diagnostic()
			.with_context(|| format!("setting stdio fd {fileno} to pty fd {pty_raw}"))?;
	}

	// I totally don't get why this is here but all the PTY code we've found does this.
	drop(our_pty);

	let err = Command::new(prog.as_ref())
		.args(args)
		.exec();

	Err(err)
		.into_diagnostic()
		.with_context(|| format!("exec()-ing target process {}", prog.display()))
}
