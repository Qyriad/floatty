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
pub enum OpenptError
{
    /// All file descriptors available to the process are currently open.
	ExhaustedFileDescriptors,
    /// The maximum allowable number of file sis openly open in the system.
	ExhaustedFiles,
    /// Out of pseudo-terminal resources.
	ExhaustedPtys,
    /// Out of STREAMS resources.
	ExhaustedStreams,
}

impl OpenptError
{
	pub const fn try_from_raw(raw: Errno) -> Option<Self>
	{
		use Errno::*;
		use OpenptError::*;
		let openpt_error: OpenptError = match raw {
			EMFILE => ExhaustedFileDescriptors,
			ENFILE => ExhaustedFiles,
			EAGAIN => ExhaustedPtys,
			ENOSR => ExhaustedStreams,
			EINVAL => {
				// Only reachable if `oflag` is invalid. Should be impossible in our code.
				unreachable!();
			},

			_ => {
				return None;
			}
		};

		Some(openpt_error)
	}

	pub fn from_errno(raw: Errno) -> Self
	{
		match Self::try_from_raw(raw) {
			Some(err) => err,
			None => {
				panic!("posix_openpt() gave supposedly impossible error code {raw}");
			},
		}
	}

	pub const fn to_errno(self) -> Errno
	{
		use Errno::*;
		use OpenptError::*;
		match self {
			ExhaustedFileDescriptors => EMFILE,
			ExhaustedFiles => ENFILE,
			ExhaustedPtys => EAGAIN,
			ExhaustedStreams => ENOSR,
		}
	}

	pub const fn as_errno(self) -> &'static Errno
	{
		use Errno::*;
		use OpenptError::*;
		match self {
			ExhaustedFileDescriptors => &EMFILE,
			ExhaustedFiles => &ENFILE,
			ExhaustedPtys => &EAGAIN,
			ExhaustedStreams => &ENOSR,
		}
	}

	/// Not to be confused with [`std::error::Error::description()`].
	pub const fn desc(self) -> &'static str
	{
		// Descriptions from `posix_openpt(3p)`.
		use OpenptError::*;
		match self {
			ExhaustedFileDescriptors => {
				"All file descriptors available to the process are currently open"
			},
			ExhaustedFiles => {
				"The maximum allowable number of file sis openly open in the system"
			},
			ExhaustedPtys => {
				"Out of pseudo-terminal resources"
			},
			ExhaustedStreams => {
				"Out of STREAMS resources"
			},
		}
	}
}

impl Display for OpenptError
{
	fn fmt(&self, f: &mut Formatter) -> FmtResult
	{
		let description: &'static str = self.desc();
		f.write_str(description)?;

		Ok(())
	}
}

/// [`std::error::Error::source()`] returns the [`nix::Error`] that caused this error.
impl StdError for OpenptError
{
	fn source(&self) -> Option<&(dyn StdError + 'static)>
	{
		// We can actually reconstruct the source error trivially,
		// so we don't even need to store it.
		let nix_error: &'static Errno = self.as_errno();

		Some(nix_error)
	}
}

impl From<Errno> for OpenptError
{
	fn from(other: Errno) -> OpenptError
	{
		OpenptError::from_errno(other)
	}
}

impl From<OpenptError> for Errno
{
	fn from(other: OpenptError) -> Errno
	{
		OpenptError::to_errno(other)
	}
}
