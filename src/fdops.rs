//! Operations on file descriptors.

use std::os::fd::{AsRawFd, BorrowedFd, RawFd};

#[allow(unused_imports)]
use {
    log::{trace, debug, info, warn, error},
	tap::prelude::*,
};
use nix::fcntl::{FcntlArg, OFlag};

/// Set file descriptor status flags.
///
/// Per POSIX, this cannot fail if used on a valid file descriptor.
pub fn set_fl(fd: &BorrowedFd, flags: OFlag)
{
	let raw_fd: RawFd = fd.as_raw_fd();

	match nix::fcntl::fcntl(raw_fd, FcntlArg::F_SETFL(flags)) {
		Ok(ret) => {
			trace!("fcntl(F_SETFL, O_NONBLOCK) returned {ret}");
		},
		Err(errno) => {
			// Either the kernel violated POSIX, or someone used unsafe code to give us
			// an invalid file descriptor.
			unreachable!("POSIX fcntl F_SETFL cannot fail, but got errno: {}", errno);
		},
	}
}

pub trait FdOps
{
	/// Set file descriptor status flags.
	///
	/// Per POSIX, this cannot fail if used on a valid file descriptor.
	fn set_fl(&mut self, flags: OFlag);

	/// Set the `O_NONBLOCK` file descriptor flag.
	///
	/// Per POSIX, this cannot fail if used on a valid file descriptor.
	fn set_nonblocking(&mut self)
	{
		self.set_fl(OFlag::O_NONBLOCK)
	}
}

impl FdOps for BorrowedFd<'_>
{
	fn set_fl(&mut self, flags: OFlag)
	{
		set_fl(&*self, flags)
	}
}
