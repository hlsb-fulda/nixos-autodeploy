use color_eyre::eyre::eyre;
use color_eyre::Result;
use itertools::Itertools;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

pub trait CommandExt: Sized {
    fn capture_stdout(self) -> Result<Vec<u8>>;

    fn capture_path(self) -> Result<PathBuf> {
        let out = self.capture_stdout()?;
        let out = OsStr::from_bytes(out.trim_ascii());
        let out = PathBuf::from(out);
        Ok(out)
    }
}

impl CommandExt for Command {
    fn capture_stdout(mut self) -> Result<Vec<u8>> {
        self.stdin(Stdio::null());
        self.stdout(Stdio::piped());
        self.stderr(Stdio::piped());

        let cmd = format!(
            "{} {}",
            self.get_program().display(),
            self.get_args().map(|arg| arg.display()).join(" ")
        );

        let child = self.output()?;

        if !child.status.success() {
            // We assume a human-readable error message here
            let out = String::from_utf8_lossy(&child.stdout);
            let err = String::from_utf8_lossy(&child.stderr);
            return Err(eyre!("Executing command '{cmd}' ({status}):\n{out}\n{err}", status = child.status));
        }

        Ok(child.stdout)
    }
}
