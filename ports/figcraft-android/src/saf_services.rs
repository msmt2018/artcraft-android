#![cfg(target_os = "android")]

//! FigCraft's `Services` implemented on top of the Storage Access Framework.
//!
//! FigCraft is the one Craft app whose `Services` is a trait *and* whose pickers return
//! `DialogFuture = Pin<Box<dyn Future<Output = Option<PathBuf>>>>`, polled across frames by the UI
//! (see `DialogFuture` and the `future` field in `figcraft_ui_egui`). That suits SAF far better
//! than the synchronous `FnMut(&str) -> Option<String>` the other apps use: nothing has to block
//! the frame.
//!
//! The future this module returns works like this. On its first poll it spawns a thread that runs
//! [`saf::pick_media`] -- which itself blocks for as long as the picker is up, so it must not be on
//! the render thread -- and sends the chosen path back over a oneshot channel. It then asks egui to
//! repaint once the result has arrived, because a cancelled dialog produces no input event of its
//! own and an idle app would otherwise not poll again. Every later poll takes the value if it is
//! there, and `Pending` until then.

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use figcraft_ui_egui::{DialogFuture, Services};

use crate::saf;

/// `Services` for Android: the SAF picker for open, and FigCraft's own directory for save.
pub struct SafServices {
    /// The activity pointer (`AndroidApp::activity_as_ptr()`), which is what
    /// `startActivityForResult` has to be called on; `ndk_context` hands out the Application, which
    /// has no such method.
    activity: usize,
    /// `AndroidApp::internal_data_path()`: the same `filesDir` the Java side writes its manifest to.
    data_dir: Option<PathBuf>,
    /// Filled in once eframe has built its `egui::Context`, so a completed pick can wake the app.
    ctx: Arc<Mutex<Option<egui::Context>>>,
}

impl SafServices {
    pub fn new(
        activity: usize,
        data_dir: Option<PathBuf>,
        ctx: Arc<Mutex<Option<egui::Context>>>,
    ) -> Self {
        Self { activity, data_dir, ctx }
    }

    /// Start the picker on a thread and return a future that resolves once it has an answer.
    fn spawn_pick(&self) -> DialogFuture {
        let Some(dir) = self.data_dir.clone() else {
            log::warn!("SAF: no data dir; cannot open the picker");
            return Box::pin(std::future::ready(None));
        };
        let (tx, rx) = mpsc::channel::<Option<PathBuf>>();
        let activity = self.activity;
        let ctx = Arc::clone(&self.ctx);
        std::thread::spawn(move || {
            let picked = saf::pick_media(activity, &dir, std::time::Duration::from_secs(300))
                .into_iter()
                .next()
                .map(PathBuf::from);
            match &picked {
                Some(path) => log::info!("SAF: picked {}", path.display()),
                None => log::info!("SAF: nothing picked"),
            }
            let _ = tx.send(picked);
            // A cancelled picker delivers no input event, so an idle app would never poll again.
            if let Ok(guard) = ctx.lock() {
                if let Some(ctx) = guard.as_ref() {
                    ctx.request_repaint();
                }
            }
        });
        Box::pin(PickFuture { rx })
    }
}

/// Polls a channel; `Pending` until the picker thread sends its answer.
struct PickFuture {
    rx: Receiver<Option<PathBuf>>,
}

impl Future for PickFuture {
    type Output = Option<PathBuf>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match self.rx.try_recv() {
            Ok(answer) => Poll::Ready(answer),
            Err(TryRecvError::Empty) => {
                // The picker thread wakes us on completion, but a poll landing between the send and
                // the wakeup would otherwise spin; yielding is enough because the wakeup follows.
                cx.waker().wake_by_ref();
                Poll::Pending
            }
            Err(TryRecvError::Disconnected) => Poll::Ready(None),
        }
    }
}

impl Services for SafServices {
    fn pick_open(&mut self, _title: &str, _exts: &[&str]) -> DialogFuture {
        self.spawn_pick()
    }

    fn pick_save(&mut self, _title: &str, _name: &str, _exts: &[&str]) -> DialogFuture {
        // Saving goes through "write a scratch file, then publish it" the way FilmCraft does, and
        // FigCraft's export flow has not been traced yet. Answering `None` is honest: the UI treats
        // it as "no destination chosen" and keeps the file where it was. Faking a path here would
        // put back the silent failure this whole exercise is removing.
        log::info!("SAF: save is not wired for FigCraft yet; the file stays in the app directory");
        Box::pin(std::future::ready(None))
    }
}
