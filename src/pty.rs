use std::os::fd::{AsRawFd, RawFd};

mod openpt_error;
pub use openpt_error::OpenptError;

/// Argument for [`openpt()`].
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub enum OpenptControl
{
	BecomeControllingTerminal,
	BecomeNonControllingTerminal,
}

/// Rust wrapper for `posix_openpt(3p)`, implemented with [`nix::pty::posix_openpt()`].
pub fn openpt(control_type: OpenptControl) -> Result<RawFd, OpenptError>
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

	let fd: RawFd = pty_controller.as_raw_fd();

	Ok(fd)
}
