use std::io::{self, Write};
use std::ffi::c_int;
use std::fs::File;
use std::ptr;
use std::ops::ControlFlow;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

#[allow(unused_imports)]
use {
	bstr::{BStr, BString, ByteSlice, ByteVec},
	bytes::{BufMut, Bytes},
	log::{trace, debug, info, warn, error},
	miette::{Context as _, Diagnostic, Error, IntoDiagnostic},
	nix::errno::Errno,
	tap::prelude::*,
};
use nix::unistd::Pid;
use nix::sys::{
	signal::{Signal, SigmaskHow, sigprocmask},
	signalfd::{SfdFlags, SigSet},
};

use crate::poller::{Poller, PollInterest};

mod signalfd_error;
pub use signalfd_error::SignalfdError;

/// Caller is responsible for closing the file descriptor.
pub fn signalfd(fd: RawFd, mask: &SigSet, flags: SfdFlags) -> Result<RawFd, SignalfdError>
{
	let mask: *const libc::sigset_t = ptr::from_ref(mask.as_ref());
	let flags: c_int = flags.bits();
	let signal_fd: RawFd = unsafe { libc::signalfd(fd, mask, flags) };
	if signal_fd < 0 {
		let errno = Errno::last();
		let err = SignalfdError::from_errno(errno);
		return Err(err);
	}

	Ok(signal_fd)
}

/// Block a signal and convert it to a [File].
fn handle_signals_as_file(signals: &[Signal]) -> miette::Result<File>
{
	let mut set = SigSet::empty();
	for &sig in signals {
		set.add(sig);
	}

	sigprocmask(SigmaskHow::SIG_BLOCK, Some(&set), None)
		.into_diagnostic()
		.with_context(|| format!("blocking the following signals: {set:?}"))?;

	// Per `signalfd(2)`, `-1` creates a new file descriptor for us.
	const NEW_FD: RawFd = -1;
	let signal_fd: RawFd = signalfd(NEW_FD, &set, SfdFlags::SFD_NONBLOCK)
		.into_diagnostic()
		.with_context(|| format!("calling signalfd() on the following signals: {set:?}"))?;

	let signal_file = unsafe { File::from_raw_fd(signal_fd) };

	Ok(signal_file)
}

fn parent_loop(pty: File) -> miette::Result<()>
{
	let pty_key = pty.as_raw_fd() as u64;
	// Switch to file descriptor based handling for SIGCHLD and SIGWINCH,
	// so we can multiplex them and PTY output.
	let sigchld: File = handle_signals_as_file(&[Signal::SIGCHLD])
		.context("turning SIGCHLD into a file descriptor")?;
	let sigchld_key = sigchld.as_raw_fd() as u64;
	trace!("turned SIGCHLD into file descriptor {}", sigchld.as_raw_fd());

	let sigwinch: File = handle_signals_as_file(&[Signal::SIGWINCH])
		.context("turning SIGWINCH into a file descriptor")?;
	let sigwinch_key = sigwinch.as_raw_fd() as u64;
	trace!("turned SIGWINCH into file descriptor {}", sigwinch.as_raw_fd());

	let poll_sigchld = PollInterest::read(sigchld);
	let poll_sigwinch = PollInterest::read(sigwinch);
	let poll_pty = PollInterest::read(pty);

	let sources = [poll_sigchld, poll_sigwinch, poll_pty];
	let mut poller = Poller::with_sources(sources)
		.context("initializing pollers for SIGCHLD, SIGWINCH, and child PTY")?;

	let mut stdout = io::stdout();
	poller.each_with(&mut stdout, |stdout, event, data| {
		debug!("got event: {event:?}");

		if event.key as u64 == pty_key {
			stdout.write_all(&data).unwrap();
		} else if event.key as u64 == sigwinch_key {
			trace!("got sigwinch!");
		} else if event.key as u64 == sigchld_key {
			trace!("got sigchld");
			return ControlFlow::Break(());
		}

		ControlFlow::Continue(())
	})?;

	info!("exited poll loop");

	Ok(())
}

pub fn parent_process(child: Pid, pty_fd: OwnedFd) -> miette::Result<()>
{
	info!("forked to process {child}");

	// We must not close this file before we waitpid().
	let pty_file = File::from(pty_fd);

	let result = parent_loop(pty_file);

	// Gotta reap those children!
	let status = nix::sys::wait::waitpid(child, None)
		.into_diagnostic()
		.with_context(|| format!("waitpid() on child {child}"))?;
	debug!("waitpid() returned {status:?}");

	use nix::sys::wait::WaitStatus::*;
	match status {
		Exited(_pid, exit_code) if exit_code != 0 => {
			eprintln!("floatty: child exited with non-zero exit code {exit_code}");
		},
		Exited(_pid, _exit_code) => (),
		Signaled(_pid, signal, _dumped) => {
			let name = signal.as_str();
			let number = signal as i32;
			eprintln!("floatty: child killed by {} (signal {})", name, number);
		},
		Stopped(_pid, signal) => {
			let name = signal.as_str();
			let number = signal as i32;
			eprintln!("floatty: child stopped by {} (signal {})", name, number);
		},
		other => {
			eprintln!("floatty: unknown waitpid() status {other:?} (floatty bug)")
		}
	}

	result
}
