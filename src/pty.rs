use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};

use nix::errno::Errno;

mod openpt_error;
pub use openpt_error::OpenptError;
mod unlockpt_error;
pub use unlockpt_error::UnlockptError;

/// Argument for [`openpt()`].
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub enum OpenptControl
{
	BecomeControllingTerminal,
	BecomeNonControllingTerminal,
}

/// Rust wrapper for `posix_openpt(3p)`, implemented with [`nix::pty::posix_openpt()`].
pub fn openpt(control_type: OpenptControl) -> Result<OwnedFd, OpenptError>
{
	use nix::fcntl::OFlag;

	use OpenptControl::*;
	let flags = match control_type {
		BecomeControllingTerminal => OFlag::O_RDWR,
		BecomeNonControllingTerminal => OFlag::O_RDWR | OFlag::O_NOCTTY,
	};

	let pty_controller = match nix::pty::posix_openpt(flags) {
		Ok(fd) => fd,
		Err(errno) => {
			return Err(OpenptError::from(errno));
		},
	};

	// *sigh*...
	// nix::pty::PtyMaster is a wrapper around `OwnedFd` that doesn't allow unwrapping
	// into the inner type...
	let fd: RawFd = pty_controller.into_raw_fd();
	// SAFETY: this file descriptor is already an OwnedFd at heart and requires no
	// other special handling.
	let fd = unsafe { OwnedFd::from_raw_fd(fd) };

	Ok(fd)
}

/// Rust wrapper for `unlockpt(3p)`, implemented with [`libc::unlockpt()`].
pub fn unlockpt(pty_fd: BorrowedFd) -> Result<(), UnlockptError>
{
	let fd = pty_fd.as_raw_fd();
	// SAFETY: no memory shenanigans here!
	let code = unsafe { libc::unlockpt(fd) };
	if code < 0 {
		let errno = Errno::last();
		let unlockpt_err = UnlockptError::from_errno(errno);

		return Err(unlockpt_err);
	}
	// Per POSIX, `unlockpt()` may only return `0`, or `-1`.
	debug_assert!(code > 0);

	Ok(())
}
