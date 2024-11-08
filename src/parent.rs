use std::ffi::c_int;
use std::fs::File;
use std::ptr;
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

/// Block a signal and convert it to a file descriptor.
pub fn handle_signals_as_file(signals: &[Signal]) -> miette::Result<File>
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

fn parent_loop(child: Pid, pty: &mut File) -> miette::Result<()>
{
	// Switch to file descriptor based handling for SIGCHLD and SIGWINCH,
	// so we can multiplex them and PTY output.
	let sigchld: File = handle_signals_as_file(&[Signal::SIGCHLD])
		.context("turning SIGCHLD into a file descriptor")?;
	trace!("turned SIGCHLD into file descriptor {}", sigchld.as_raw_fd());
	let sigwinch: File = handle_signals_as_file(&[Signal::SIGWINCH])
		.context("turning SIGWINCH into a file descriptor")?;
	trace!("turned SIGWINCH into file descriptor {}", sigwinch.as_raw_fd());

	use polling::Event;
	let poller = polling::Poller::new().into_diagnostic()?;
	unsafe { poller.add(&sigchld, Event::readable(0)) }.into_diagnostic()?;
	unsafe { poller.add(&sigwinch, Event::readable(0)) }.into_diagnostic()?;
	unsafe { poller.add(&*pty, Event::readable(0)) }.into_diagnostic()?;

	poller.delete(&sigchld).into_diagnostic()?;
	poller.delete(&sigwinch).into_diagnostic()?;
	poller.delete(&*pty).into_diagnostic()?;

	Ok(())
}

pub fn parent_process(child: Pid, pty_fd: OwnedFd) -> miette::Result<()>
{
	info!("forked to process {child}");

	// We must not close this file before we waitpid().
	let mut pty_file = File::from(pty_fd);

	let result = parent_loop(child, &mut pty_file);

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
