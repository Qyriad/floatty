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

/// The error type returned for [`unlockpt()`], which contains variants for all error codes that
/// can be returned by `unlockpt(3p)`.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, Diagnostic)]
pub enum UnlockptError
{
	/// The file descriptor is not a pseudo-terminal "master".
	NotAPty,
}

impl UnlockptError
{
	pub const fn try_from_raw(raw: Errno) -> Option<Self>
	{
		use Errno::*;
		use UnlockptError::*;
		let unlockpt_error = match raw {
			EINVAL => NotAPty,
			_ => {
				return None;
			}
		};

		Some(unlockpt_error)
	}

	pub fn from_errno(raw: Errno) -> Self
	{
		match Self::try_from_raw(raw) {
			Some(err) => err,
			None => {
				panic!("unlockpt() gave supposedly impossible error code {raw}");
			}
		}
	}

	pub const fn to_errno(self) -> Errno
	{
		use Errno::*;
		use UnlockptError::*;
		match self {
			NotAPty => EINVAL,
		}
	}

	pub const fn as_errno(self) -> &'static Errno
	{
		use Errno::*;
		use UnlockptError::*;
		match self {
			NotAPty => &EINVAL,
		}
	}

	/// Not to be confused with [`std::error::Error::description()`].
	pub const fn desc(self) -> &'static str
	{
		// Descriptions from `unlockpt(3p)`.
		use UnlockptError::*;
		match self {
			NotAPty => "The filedes argument is not associated with a master pseudo-terminal device",
		}
	}
}

impl Display for UnlockptError
{
	fn fmt(&self, f: &mut Formatter) -> FmtResult
	{
		let description: &'static str = self.desc();
		f.write_str(description)?;

		Ok(())
	}
}

impl StdError for UnlockptError
{
	fn source(&self) -> Option<&(dyn StdError + 'static)>
	{
		// We can actually reconstruct the source error trivially,
		// so we don't even need to store it.
		let nix_error: &'static Errno = self.as_errno();

		Some(nix_error)
	}
}

impl From<Errno> for UnlockptError
{
	fn from(other: Errno) -> UnlockptError
	{
		UnlockptError::from_errno(other)
	}
}

impl From<UnlockptError> for Errno
{
	fn from(other: UnlockptError) -> Errno
	{
		UnlockptError::to_errno(other)
	}
}
