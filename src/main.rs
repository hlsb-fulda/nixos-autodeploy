use crate::cli::{Args, RebootMode, SwitchMode};
use crate::exec::CommandExt;
use crate::metrics::State;
use clap::Parser;
use color_eyre::Result;
use color_eyre::eyre::{Context, ContextCompat, eyre};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;

mod cli;
mod exec;
mod metrics;

const RUN_UPSTREAM_SYSTEM: &'static str = "/run/upstream-system";
const RUN_DEPLOYED_SYSTEM: &'static str = "/run/deployed-system";
const RUN_CURRENT_SYSTEM: &'static str = "/run/current-system";
const RUN_BOOTED_SYSTEM: &'static str = "/run/booted-system";

fn main() -> Result<()> {
    color_eyre::install()?;

    let args = Args::parse();

    println!("Fetching upstream derivation path from {}", args.url);

    // Fetch derivation from provided URL and get response string
    let upstream_drv = reqwest::blocking::get(args.url.clone())
        .and_then(|r| r.error_for_status())
        .and_then(|r| r.text())
        .map(|s| PathBuf::from(s.trim_ascii()))
        .with_context(|| format!("Failed to fetch URL: {url}", url = args.url))?;

    println!(
        "Realizing upstream closure: {upstream}",
        upstream = upstream_drv.display()
    );

    // Realize the upstream derivation and register it GC root
    let upstream_drv = resolve({
        let mut cmd = Command::new("nix-store");
        cmd.arg("--realize");
        cmd.arg(&upstream_drv);
        cmd.arg("--add-root");
        cmd.arg(RUN_UPSTREAM_SYSTEM);
        cmd.capture_path()
            .context("Failed to realize upstream derivation")?
    })?
    .expect("symlink of realized upstream must exist");

    println!(
        "Realized upstream closure: {upstream}",
        upstream = upstream_drv.display()
    );

    // Read in current state
    // The deployed state is not expected to exist as it will be created by the first run
    let deployed_drv = resolve(RUN_DEPLOYED_SYSTEM)?;
    let current_drv =
        resolve(RUN_CURRENT_SYSTEM)?.wrap_err_with(|| eyre!("Can not determine current system"))?;

    println!("Upstream: {upstream}", upstream = upstream_drv.display());
    println!("Current : {current}", current = current_drv.display());

    if let Some(ref deployed_drv) = deployed_drv {
        println!("Deployed: {deployed}", deployed = deployed_drv.display());
    } else {
        println!("Deployed: unknown");
    }

    // Track the state of the process
    let mut state = State::default();

    // Do the automatic deployment
    // There are four states depending on the comparison of current, deployed and upstream derivations
    // | current == deployed | current == upstream | action             |
    // |---------------------|---------------------|--------------------|
    // |         ❌          |         ❌          | suspend            |
    // |         ❌          |         ✅          | start tracking     |
    // |         ✅          |         ❌          | perform deployment |
    // |         ✅          |         ✅          | nothing to do      |
    if Some(&current_drv) == deployed_drv.as_ref() || args.force {
        if current_drv == upstream_drv {
            println!("System is up to date");
        } else {
            println!("Current system differs from upstream - deploying upstream");

            // The system needs a reboot, if initrd, kernel or module has changed between current
            // derivation and upstream derivation
            state.reboot_pending = ["initrd", "kernel", "kernel-modules"]
                .into_iter()
                .try_fold(false, |prev, part| -> Result<bool> {
                    let current = resolve(current_drv.join(part))?;
                    let upstream = resolve(upstream_drv.join(part))?;
                    Ok(prev || current != upstream)
                })?;

            // Determine if apply config by switching or booting
            let boot = match (args.switch_mode, state.reboot_pending) {
                (SwitchMode::Boot, _) => true,
                (SwitchMode::Switch, _) => false,
                (SwitchMode::Smart, reboot) => reboot,
            };

            // Update system profile
            {
                let mut cmd = Command::new("nix-env");
                cmd.arg("--profile");
                cmd.arg("/nix/var/nix/profiles/system");
                cmd.arg("--set");
                cmd.arg(&upstream_drv);
                cmd.capture_stdout()?
            };

            // Switch to configuration
            {
                let mut cmd = Command::new("systemd-run");
                cmd.arg("--setenv=NIXOS_INSTALL_BOOTLOADER=1");
                cmd.arg("--collect");
                cmd.arg("--no-ask-password");
                cmd.arg("--pipe");
                cmd.arg("--quiet");
                cmd.arg("--service-type=exec");
                cmd.arg("--unit=nixos-autodeploy-switch-to-configuration");
                cmd.arg("--wait");
                cmd.arg(upstream_drv.join("bin/switch-to-configuration"));
                cmd.arg(match boot {
                    true => "boot",
                    false => "switch",
                });
                cmd.capture_stdout()?
            };

            // Record upstream as deployed
            symlink(RUN_DEPLOYED_SYSTEM, &upstream_drv)?;

            // Reboot the system if auto reboot is configured and a reboot is required
            if boot && let Some(reboot_mode) = args.reboot_mode {
                let mut cmd = Command::new("systemctl");
                cmd.arg(match reboot_mode {
                    RebootMode::KExec => "kexec",
                    RebootMode::Reboot => "reboot",
                });
                cmd.capture_stdout()?;
            }
        }
    } else {
        if current_drv == upstream_drv {
            println!(
                "Current system matches upstream - start tracking upstream by syncing deployed state"
            );
            symlink(RUN_DEPLOYED_SYSTEM, &current_drv)?;
        } else {
            println!("Current system has been deployed manually - skipping deployment");
            state.dirty = true;
        }
    }

    if state.reboot_pending {
        println!("Reboot required for full update");
    }

    // Expose deployment status to prometheus node exporter
    if let Some(prometheus_path) = args.prometheus_path {
        state.write_metrics(&prometheus_path)?;
    }

    Ok(())
}

fn resolve(path: impl AsRef<Path>) -> Result<Option<PathBuf>> {
    let path = path.as_ref();

    if !std::fs::exists(path)? {
        return Ok(None);
    }

    let path = path
        .canonicalize()
        .with_context(|| format!("Fail to resolve symlink: {}", path.display()))?;

    Ok(Some(path))
}

fn symlink(path: impl AsRef<Path>, target: impl AsRef<Path>) -> Result<()> {
    let path = path.as_ref();
    let target = target.as_ref();

    // Hash the target to create a unique temporary path
    let mut hash = DefaultHasher::new();
    target.hash(&mut hash);
    let hash = hash.finish();

    let tmp = path.with_added_extension(format!("tmp.{hash:08x}"));

    // Create symlink to temporary
    std::os::unix::fs::symlink(target, &tmp)
        .with_context(|| format!("Failed to create symlink: {}", tmp.display()))?;

    // Move temporary to final path
    std::fs::rename(&tmp, &path).with_context(|| {
        format!(
            "Failed to rename symlink: {} -> {}",
            tmp.display(),
            path.display()
        )
    })?;

    Ok(())
}
