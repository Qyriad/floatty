use std::ffi::{OsStr, c_char};
use std::path::Path;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::sync::LazyLock;

use bstr::ByteSlice;
use bytes::{Bytes, BytesMut};
use nix::errno::Errno;
use tap::Pipe;

mod openpt_error;
pub use openpt_error::OpenptError;
mod unlockpt_error;
pub use unlockpt_error::UnlockptError;
mod ptsname_error;
pub use ptsname_error::PtsnameError;

pub const NUL_CHAR: c_char = 0;
pub const NUL_BYTE: u8 = 0;

/// Access will panic on the few error conditions that *should* be unreachable.
static TTY_NAME_MAX: LazyLock<usize> = LazyLock::new(|| {
	use nix::unistd::SysconfVar;

	let limit: i64 = nix::unistd::sysconf(SysconfVar::TTY_NAME_MAX)
		.unwrap_or_else(|errno| {
			panic!("sysconf(TTY_NAME_MAX) gave supposedly impossible errno {}", errno);
		})
		.unwrap_or_else(|| {
			panic!("sysconf(TTY_NAME_MAX) has no defined limit?");
		});

	usize::try_from(limit)
		.unwrap_or_else(|err| {
			panic!("sysconf(TTY_NAME_MAX) returned {}, which does not fit in a usize: {}", limit, err);
		})
});


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
	debug_assert!(code == 0, "unlockpt() returned invalid code {code}");

	Ok(())
}

/// Rust wrapper for `ptsname_r(3p)`, implemented with [`libc::ptsname_r()`].
pub fn ptsname(pty_fd: BorrowedFd) -> Result<Box<Path>, PtsnameError>
{
	// + 1 for the NUL terminator.
	let buf_len = *TTY_NAME_MAX + 1;
	let mut buffer = BytesMut::zeroed(buf_len);
	debug_assert_eq!(buf_len, buffer.len());
	let buf_ptr: *mut c_char = buffer.as_mut_ptr().cast();

	let fd = pty_fd.as_raw_fd();
	// SAFETY: `buf_ptr` is non-null, and has already been zeroed with `buffer.len()` characters.
	let code = unsafe { libc::ptsname_r(fd, buf_ptr, buffer.len()) };
	if code < 0 {
		let errno = Errno::last();
		let ptsname_err = PtsnameError::from_errno(errno);

		return Err(ptsname_err);
	}
	// Per POSIX, `ptsname_r` may only return `0` or `-1`.
	debug_assert!(code == 0, "ptsname_r() returned invalid code {code}");

	let nul_pos = match buffer.find_byte(NUL_BYTE) {
		Some(pos) => pos,
		None => {
			panic!("`ptsname_r()` filled our string with garbage (no NUL): {:?}", buffer);
		},
	};

	buffer.truncate(nul_pos);
	let bytes: Bytes = buffer.freeze();

	let path: Box<Path> = bytes
		.pipe_deref(OsStr::from_bytes)
		.pipe(Path::new)
		.pipe(Box::from);

	Ok(path)
}
