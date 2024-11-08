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

/// The error type for [`csctty()`], which contains variants for all error codes that can
/// be returned by `ioctl(CSCTTY)`.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, Diagnostic)]
pub enum CscttyError
{
	/// Insufficient permissions to become the controlling terminal.
	PermissionDenied,
}

impl CscttyError
{
	pub const fn try_from_raw(raw: Errno) -> Option<Self>
	{
		use Errno::*;
		use CscttyError::*;
		let csctty_error = match raw {
			EPERM => PermissionDenied,
			_ => {
				return None;
			},
		};

		Some(csctty_error)
	}

	pub fn from_errno(raw: Errno) -> Self
	{
		match Self::try_from_raw(raw) {
			Some(err) => err,
			None => {
				panic!("ioctl(TIOCSCTTY) gave supposedly impossible error code {raw}");
			},
		}
	}

	pub const fn to_errno(self) -> Errno
	{
		use Errno::*;
		use CscttyError::*;
		match self {
			PermissionDenied => EPERM,
		}
	}

	pub const fn as_errno(self) -> &'static Errno
	{
		use Errno::*;
		use CscttyError::*;
		match self {
			PermissionDenied => &EPERM,
		}
	}

	/// Not to be confused with [`std::error::Error::description()`].
	pub const fn desc(self) -> &'static str
	{
		// Descriptions from `TIOCSCTTY(2const)`.
		use CscttyError::*;
		match self {
			PermissionDenied => "Insufficient permissions",
		}
	}
}

impl Display for CscttyError
{
	fn fmt(&self, f: &mut Formatter) -> FmtResult
	{
		let description: &'static str = self.desc();
		f.write_str(description)?;

		Ok(())
	}
}

/// [`std::error::Error::source()`] returns the [`nix::Error`] that caused this error.
impl StdError for CscttyError
{
	fn source(&self) -> Option<&(dyn StdError + 'static)>
	{
		// We can actually reconstruct the source error trivially,
		// so we don't even need to store it.
		let nix_error: &'static Errno = self.as_errno();

		Some(nix_error)
	}
}

impl From<Errno> for CscttyError
{
	fn from(other: Errno) -> Self
	{
		Self::from_errno(other)
	}
}

impl From<CscttyError> for Errno
{
	fn from(other: CscttyError) -> Self
	{
		CscttyError::to_errno(other)
	}
}
