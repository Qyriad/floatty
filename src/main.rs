#[allow(unused_imports)]
use {
	bstr::{BStr, BString, ByteSlice, ByteVec},
	bytes::{BufMut, Bytes},
	log::{trace, debug, info, warn, error},
	miette::{Diagnostic, Error, IntoDiagnostic},
	nix::errno::Errno,
	tap::prelude::*,
};

use floatty::pty::{openpt, OpenptControl};

fn main() -> miette::Result<()>
{
	env_logger::init();

	let pty_fd = openpt(OpenptControl::BecomeControllingTerminal)
		.into_diagnostic()?;

	dbg!(&pty_fd);

	Ok(())
}
