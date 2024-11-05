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

/// The error type for [`openpt()`], which contains variants for all error codes that can be
/// returned by `posix_openpt(3p)`.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash, Diagnostic)]
// We're not repeating the enum name;
// it just so happens that all possible errors are an "exhausted" variant.
#[allow(clippy::enum_variant_names)]
pub enum PtsnameError
{
	/// The file descriptor is not a pseudo-terminal "master".
	NotAPty,
}

impl PtsnameError
{
	pub const fn try_from_raw(raw: Errno) -> Option<Self>
	{
		use Errno::*;
		use PtsnameError::*;
		let ptsname_error = match raw {
			EINVAL => NotAPty,
			_ => {
				return None;
			}
		};

		Some(ptsname_error)
	}

	pub fn from_errno(raw: Errno) -> Self
	{
		match Self::try_from_raw(raw) {
			Some(err) => err,
			None => {
				panic!("ptsname() gave supposedly impossible error code {raw}");
			},
		}
	}

	pub const fn to_errno(self) -> Errno
	{
		use Errno::*;
		use PtsnameError::*;
		match self {
			NotAPty => ENOTTY,
		}
	}

	pub const fn as_errno(self) -> &'static Errno
	{
		use Errno::*;
		use PtsnameError::*;
		match self {
			NotAPty => &ENOTTY,
		}
	}

	/// Not to be confused with [`std::error::Error::description()`].
	pub const fn desc(self) -> &'static str
	{
		// Descriptions from `posix_openpt(3p)`.
		use PtsnameError::*;
		match self {
			NotAPty => "The filedes argument is not associated with a master pseudo-terminal device",
		}
	}
}

impl Display for PtsnameError
{
	fn fmt(&self, f: &mut Formatter) -> FmtResult
	{
		let description: &'static str = self.desc();
		f.write_str(description)?;

		Ok(())
	}
}

/// [`std::error::Error::source()`] returns the [`nix::Error`] that caused this error.
impl StdError for PtsnameError
{
	fn source(&self) -> Option<&(dyn StdError + 'static)>
	{
		// We can actually reconstruct the source error trivially,
		// so we don't even need to store it.
		let nix_error: &'static Errno = self.as_errno();

		Some(nix_error)
	}
}

impl From<Errno> for PtsnameError
{
	fn from(other: Errno) -> PtsnameError
	{
		PtsnameError::from_errno(other)
	}
}

impl From<PtsnameError> for Errno
{
	fn from(other: PtsnameError) -> Errno
	{
		PtsnameError::to_errno(other)
	}
}
