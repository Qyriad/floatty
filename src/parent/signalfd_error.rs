use std::error::Error as StdError;
use std::fmt::{Display, Result as FmtResult, Formatter};

#[allow(unused_imports)]
use {
    log::{trace, debug, info, warn, error},
	tap::prelude::*,
};
use {
	miette::Diagnostic,
	nix::errno::Errno,
};

/// The error type for [`handle_signals_as_file()`], which contains variants for all error codes
/// that can be returned by `signalfd(2)`.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, Diagnostic)]
pub enum SignalfdError
{
	/// `flags` is invalid.
	InvalidFlags,
	/// The per-process limit on the number of open file descriptors has been reached.
	ExhaustedFileDescriptors,
	/// The system-wide limit on the total number of open files has been reached.
	ExhaustedFiles,
	/// Could not mount (internal) anonymous inode device.
	FailedToMountInode,
	/// There was insufficient memory to create a new signalfd file descriptor.
	ExhaustedMemory,
}

impl SignalfdError
{
	pub const fn try_from_raw(raw: Errno) -> Option<Self>
	{
		use Errno::*;
		use SignalfdError::*;
		let signalfd_error: SignalfdError = match raw {
			EINVAL => InvalidFlags,
			EMFILE => ExhaustedFileDescriptors,
			ENFILE => ExhaustedFiles,
			ENODEV => FailedToMountInode,
			ENOMEM => ExhaustedMemory,
			_ => {
				return None;
			},
		};

		Some(signalfd_error)
	}

	pub fn from_errno(raw: Errno) -> Self
	{
		match Self::try_from_raw(raw) {
			Some(err) => err,
			None => {
				panic!("signalfd() gave supposedly impossible error code {raw}");
			},
		}
	}

	pub const fn to_errno(self) -> Errno
	{
		use Errno::*;
		use SignalfdError::*;
		match self {
			InvalidFlags => EINVAL,
			ExhaustedFileDescriptors => EMFILE,
			ExhaustedFiles => ENFILE,
			FailedToMountInode => ENODEV,
			ExhaustedMemory => ENOMEM,
		}
	}

	pub const fn as_errno(self) -> &'static Errno
	{
		use Errno::*;
		use SignalfdError::*;
		match self {
			InvalidFlags => &EINVAL,
			ExhaustedFileDescriptors => &EMFILE,
			ExhaustedFiles => &ENFILE,
			FailedToMountInode => &ENODEV,
			ExhaustedMemory => &ENOMEM,
		}
	}

	/// Not to be confused with [`std::error::Error::description()`].
	pub const fn desc(self) -> &'static str
	{
		// Descriptions from `signalfd(2)`.
		use SignalfdError::*;
		match self {
			InvalidFlags => {
				"`flags` is invalid"
			},
			ExhaustedFileDescriptors => {
				"The per-process limit on the number of open file descriptors has been reached"
			},
			ExhaustedFiles => {
				"The system-wide limit on the total number of open files has been reached"
			},
			FailedToMountInode => {
				"Could not mount (internal) anonymous inode device"
			},
			ExhaustedMemory => {
				"There was insufficient memory to create a new signalfd file descriptor"
			},
		}
	}
}

impl Display for SignalfdError
{
	fn fmt(&self, f: &mut Formatter) -> FmtResult
	{
		let description: &'static str = self.desc();
		f.write_str(description)?;

		Ok(())
	}
}

/// [`std::error::Error::source()`] returns the [`nix::Error`] that caused this error.
impl StdError for SignalfdError
{
	fn source(&self) -> Option<&(dyn StdError + 'static)>
	{
		// We can actually reconstruct the source error trivially,
		// so we don't even need to store it.
		let nix_error: &'static Errno = self.as_errno();

		Some(nix_error)
	}
}

impl From<Errno> for SignalfdError
{
	fn from(other: Errno) -> Self
	{
		Self::from_errno(other)
	}
}

impl From<SignalfdError> for Errno
{
	fn from(other: SignalfdError) -> Self
	{
		SignalfdError::to_errno(other)
	}
}
