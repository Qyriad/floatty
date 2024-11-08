use std::mem;
use std::ops::ControlFlow;
use std::os::fd::{AsRawFd, BorrowedFd, RawFd};

use log::error;

#[derive(Debug)]
pub struct Poller<'f>
{
	inner: polling::Poller,
	sources: Vec<BorrowedFd<'f>>,
}

impl<'f> Poller<'f>
{
	pub fn with_sources(sources: &[BorrowedFd<'f>]) -> Self
	{
		let poller = polling::Poller::new().unwrap();
		let sources: Vec<BorrowedFd> = sources.to_vec();
		for source in sources.iter() {
			let raw: RawFd = source.as_raw_fd();
			let key: usize = raw.try_into().unwrap_or_else(|e| {
				panic!("file descriptor {raw} does not fit in a usize? {e}");
			});
			let interest = polling::Event::all(key);
			unsafe { poller.add(source, interest) }.unwrap_or_else(|e| {
				panic!("error adding file descriptor {raw} to poller: {e}");
			});
		}

		Self {
			inner: poller,
			sources,
		}
	}

	pub fn each<F>(&mut self, f: F)
	where
		F: Fn(polling::Event) -> ControlFlow<()>,
	{
		let mut events = polling::Events::new();
		'outer: loop {
			events.clear();
			self.inner.wait(&mut events, None).expect("todo");

			for event in events.iter() {
				let flow = f(event);
				if flow.is_break() {
					break 'outer;
				}
			}
		}

		// Cleanup.
		for source in mem::take(&mut self.sources) {
			let raw_fd: RawFd = source.as_raw_fd();
			self.inner.delete(source).unwrap_or_else(|e| {
				// FIXME: return actual errors?
				error!("error dropping poller for file descriptor {raw_fd}: {e}");
			});
		}
	}
}
