use std::io::{ErrorKind as IoErrorKind, Read, Result as IoResult};
use std::fs::File;
use std::mem;
use std::ops::ControlFlow;
use std::os::fd::{AsRawFd, RawFd};

#[allow(unused_imports)]
use {
	bstr::{BStr, BString, ByteSlice, ByteVec},
	log::{trace, debug, info, warn, error},
	miette::{Context as _, Diagnostic, Error, IntoDiagnostic},
	nix::errno::Errno,
	tap::prelude::*,
};

use crate::{DataBuf, DataBufExt};

// FIXME: what buffer size?
const BUFFER_SIZE: usize = 4096;

#[derive(Debug)]
pub struct PollInterest
{
	pub file: File,
	pub read: bool,
	pub write: bool,
}

impl PollInterest
{
	pub fn read(file: File) -> Self
	{
		Self {
			file,
			read: true,
			write: false,
		}
	}
}

/// Extension trait for [Read] which allows continually reading until a read would block.
/// Meant to be used with `O_NONBLOCK`.
pub trait NonblockingRead: Read
{
	fn read_until_block(&mut self) -> IoResult<DataBuf>;
}

impl NonblockingRead for File
{
	/// Read until `std::io::ErrorKind::WouldBlock` is returned, and return all data read,
	/// unless some other error occured.
	fn read_until_block(&mut self) -> IoResult<DataBuf>
	{
		let mut data = DataBuf::new();

		let mut buffer = DataBuf::zeroed(BUFFER_SIZE);
		loop {
			match self.read(&mut buffer) {
				Ok(0) => {
					// No more data at all I guess? Is this necessary?
					warn!("Nonblocking reader returned 0 bytes; I guess this is possible after all!");
					break;
				},
				Ok(count) => {
					let read_data = &buffer[0..count];
					data.extend_from_slice(read_data);
				},
				Err(e) => {
					if e.kind() == IoErrorKind::WouldBlock {
						// No more data ready right now. We're done here.
						break;
					}
					error!("error while doing non-blocking read: {e:?}");
					return Err(e);
				}
			}
		}

		Ok(data)
	}
}

#[derive(Debug)]
pub struct Poller
{
	inner: polling::Poller,
	sources: Vec<File>,
}

/// API
impl Poller
{
	pub fn with_sources<I>(sources: I) -> miette::Result<Self>
	where
		I: IntoIterator<Item = PollInterest, IntoIter: ExactSizeIterator>,
	{
		let mut poller = polling::Poller::new()
			.into_diagnostic()
			.context("registering base file poller with operating system")?;
		let sources = sources.into_iter();
		let mut fds: Vec<File> = Vec::with_capacity(sources.len());

		for PollInterest { file, read, write } in sources {
			let raw_fd: RawFd = file.as_raw_fd();
			fds.push(file);

			let key: usize = raw_fd.try_into().unwrap_or_else(|e| {
				panic!("file descriptor {raw_fd} does not fit in a usize? {e}");
			});

			let interest = polling::Event::new(key, read, write);
			// SAFETY: `raw_fd` comes from an `std::io::File`. It can only be invalid if some other
			// unsafe code has made it so.
			unsafe { poller.add(raw_fd, interest) }.unwrap_or_else(|e| {
				// Deleting already added sources is apparently a safety issue? Weird.
				Self::cleanup(&mut poller, mem::take(&mut fds));
				panic!("error adding file descriptor {raw_fd} to poller: {e}");
			});
		}

		Ok(Self {
			inner: poller,
			sources: fds,
		})
	}

	pub fn each<F>(&mut self, f: F) -> miette::Result<()>
	where
		F: Fn(polling::Event, DataBuf) -> ControlFlow<()>
	{
		let mut unit = ();
		self.each_with(&mut unit, |_, event, data| f(event, data))
	}

	pub fn each_with<T, F>(&mut self, user_data: &mut T, f: F) -> miette::Result<()>
	where
		T: ?Sized,
		F: Fn(&mut T, polling::Event, DataBuf) -> ControlFlow<()>,
	{
		let mut events = polling::Events::new();
		'outer: loop {
			events.clear();
			self.inner.wait(&mut events, None).expect("todo");

			for event in events.iter() {

				let raw_fd = event.key as RawFd;
				let matching_file = self.sources
					.iter_mut()
					.find(|source| source.as_raw_fd() == raw_fd)
					.unwrap_or_else(|| unreachable!());

				let data = matching_file.read_until_block()
					.into_diagnostic()
					.with_context(|| format!("attempting non-blocking reads from fd {raw_fd}"))?;
				let flow = f(user_data, event, data);
				if flow.is_break() {
					break 'outer;
				}

				// Re-establish interest in this file.
				self.inner.modify(matching_file, event)
					.into_diagnostic()
					.with_context(|| format!("re-adding poller for fd {}", raw_fd))?;
			}
		}

		Self::cleanup(&mut self.inner, mem::take(&mut self.sources));

		Ok(())
	}
}

/// Implementation details.
impl Poller
{
	fn cleanup(poller: &mut polling::Poller, sources: Vec<File>)
	{
		for source in sources {
			let raw_fd: RawFd = source.as_raw_fd();
			trace!("deleting file descriptor {raw_fd} for inner poller");
			poller.delete(source).unwrap_or_else(|e| {
				// FIXME: return actual errors?
				error!("error dropping poller for file descriptor {raw_fd}: {e}");
			});
		}
	}
}
