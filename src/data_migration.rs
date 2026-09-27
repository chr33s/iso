//! Migration of the former Apple-only application directory.
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};

/// Called before default-config dispatch, including init and uninstall. Custom
/// config paths are intentionally untouched.
pub(crate) fn prepare(config: &Path) -> Result<fs::File> {
    let home = dirs::home_dir().context("Cannot determine home directory")?;
    let mut guard = command_lock(&home, libc::LOCK_SH)?;
    if config == crate::config::CoopConfig::default_path() {
        let old = home.join(".coop-apple");
        let needs_migration = fs::symlink_metadata(&old).is_ok_and(|m| !m.file_type().is_symlink())
            || home.join(".coop/.apple-directory-migration").exists();
        if needs_migration {
            drop(guard);
            migrate(&home)?;
            guard = command_lock(&home, libc::LOCK_SH)?;
        } else {
            check_root(&home.join(".coop"))?;
            if old.is_symlink() && fs::read_link(&old)? != home.join(".coop") {
                bail!(
                    "{} is an unexpected symlink; refusing migration",
                    old.display()
                );
            }
        }
    }
    Ok(guard)
}

fn command_lock(home: &Path, mode: libc::c_int) -> Result<fs::File> {
    use std::os::fd::AsRawFd as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(home.join(".coop-migration.lock"))?;
    // SAFETY: file owns the descriptor throughout flock and the guard lifetime.
    if unsafe { libc::flock(file.as_raw_fd(), mode) } != 0 {
        return Err(std::io::Error::last_os_error())
            .context("Cannot lock application state migration");
    }
    Ok(file)
}

fn migrate(home: &Path) -> Result<()> {
    let old = home.join(".coop-apple");
    let new = home.join(".coop");
    let marker = ".apple-directory-migration";
    let _lock = command_lock(home, libc::LOCK_EX | libc::LOCK_NB)?;
    let old_meta = match fs::symlink_metadata(&old) {
        Ok(meta) => Some(meta),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(e.into()),
    };
    if let Some(meta) = old_meta {
        if meta.file_type().is_symlink() {
            if fs::read_link(&old)? != new {
                bail!(
                    "{} is an unexpected symlink; refusing migration",
                    old.display()
                );
            }
        } else {
            if !meta.is_dir() {
                bail!("{} is not a directory", old.display());
            }
            if fs::symlink_metadata(&new).is_ok() {
                bail!(
                    "Both {} and {} exist; refusing to merge state. Use --config to select an installation explicitly.",
                    old.display(),
                    new.display()
                );
            }
            check_root(&old)?;
            let _runtime_locks = quiescent_runtime(&old)?;
            crate::fs_util::atomic_write_with_mode(&old.join(marker), "1\n", 0o600)?;
            rename_exclusive(&old, &new)?;
            // Preserve absolute paths in existing SSH entries and explicit
            // data_dir values. No second copy of state is created.
            std::os::unix::fs::symlink(&new, &old).with_context(|| {
                format!(
                    "State moved to {}; could not create compatibility link {}",
                    new.display(),
                    old.display()
                )
            })?;
        }
    }
    check_root(&new)?;
    // The marker moves atomically with the directory, allowing retry after a
    // crash between rename and compatibility-link publication.
    if new.join(marker).exists() {
        if fs::symlink_metadata(&old).is_err() {
            std::os::unix::fs::symlink(&new, &old)?;
        }
        fs::remove_file(new.join(marker))?;
    }
    Ok(())
}

fn quiescent_runtime(root: &Path) -> Result<Vec<fs::File>> {
    use std::os::fd::AsRawFd as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let runtime = root.join("backends/apple-container-v1/runtime");
    if !runtime.exists() {
        return Ok(Vec::new());
    }
    let acquire = |path: &Path| -> Result<fs::File> {
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        // SAFETY: the descriptor remains valid until the returned file is dropped.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            bail!(
                "Apple runtime is busy; stop VMs and finish other coop commands before migration"
            );
        }
        Ok(file)
    };
    let mut locks = vec![acquire(&runtime.join("operations.lock"))?];
    let sandboxes = runtime.join("sandboxes");
    if sandboxes.exists() {
        for entry in fs::read_dir(sandboxes)? {
            let path = entry?.path();
            locks.push(acquire(&path.join("owner.lock"))?);
            reject_registered_owner(&path)?;
            if path.join("live.json").exists() {
                bail!(
                    "Stop all Apple VMs using --config ~/.coop-apple/config.toml before migration; {} still has live state",
                    path.display()
                );
            }
        }
    }
    Ok(locks)
}

fn reject_registered_owner(path: &Path) -> Result<()> {
    use std::os::unix::ffi::OsStrExt as _;
    let canonical = fs::canonicalize(path)?;
    // Must match SandboxPaths.stableHash in CoopSandboxCore/Layout.swift.
    let hash = canonical
        .as_os_str()
        .as_bytes()
        .iter()
        .fold(14_695_981_039_346_656_037_u64, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(1_099_511_628_211)
        });
    let label = format!("dev.coop.sandbox.{hash:x}");
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    for domain in ["gui", "user"] {
        let output = crate::cmd::Cmd::new("/bin/launchctl")
            .args(["print", &format!("{domain}/{uid}/{label}")])
            .output()?;
        if output.status.success() {
            bail!("Stop the registered Apple VM owner {label} before migration");
        }
        // launchctl reports an absent service/domain with exit 113. All other
        // failures are ambiguous and must not authorize a directory move.
        if output.status.code() != Some(113) {
            bail!(
                "Could not establish whether Apple VM owner {label} is registered; refusing migration"
            );
        }
    }
    Ok(())
}

fn check_root(root: &Path) -> Result<()> {
    match fs::symlink_metadata(root) {
        Ok(meta) if !meta.is_dir() => bail!("{} must be a real directory", root.display()),
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.into()),
    }
    for name in [
        "images",
        "instances",
        "vm_key",
        "lima-builder.yaml",
        "vmlinux",
        "firecracker",
    ] {
        if fs::symlink_metadata(root.join(name)).is_ok() {
            bail!(
                "{} contains legacy upstream state ({name}); refusing to share it. Select a separate data_dir and --config.",
                root.display()
            );
        }
    }
    Ok(())
}

fn rename_exclusive(from: &Path, to: &Path) -> Result<()> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt as _;
    let source = CString::new(from.as_os_str().as_bytes())?;
    let target = CString::new(to.as_os_str().as_bytes())?;
    // SAFETY: both C strings remain alive through the syscall. RENAME_EXCL
    // ensures a concurrently created destination is never replaced.
    let result = unsafe { libc::renamex_np(source.as_ptr(), target.as_ptr(), libc::RENAME_EXCL) };
    if result != 0 {
        return Err(std::io::Error::last_os_error()).context("Could not migrate application state");
    }
    Ok(())
}

#[cfg(test)]
#[expect(clippy::unwrap_used, reason = "tests")]
mod tests {
    use super::*;

    #[test]
    fn moves_state_and_preserves_old_absolute_paths() {
        let home = tempfile::tempdir().unwrap();
        let old = home.path().join(".coop-apple");
        fs::create_dir_all(old.join("backends/apple-container-v1")).unwrap();
        fs::write(old.join("config.toml"), "data_dir = '/custom/state'\n").unwrap();
        migrate(home.path()).unwrap();
        let new = home.path().join(".coop");
        assert_eq!(fs::read_link(&old).unwrap(), new);
        assert_eq!(
            fs::read_to_string(new.join("config.toml")).unwrap(),
            "data_dir = '/custom/state'\n"
        );
        assert!(old.join("backends/apple-container-v1").is_dir());
        migrate(home.path()).unwrap();
    }

    #[test]
    fn refuses_even_empty_destination_without_changing_either_root() {
        let home = tempfile::tempdir().unwrap();
        for name in [".coop", ".coop-apple"] {
            fs::create_dir(home.path().join(name)).unwrap();
        }
        assert!(migrate(home.path()).is_err());
        assert!(!home.path().join(".coop-apple").is_symlink());
    }

    #[test]
    fn refuses_foreign_state_and_unexpected_symlinks() {
        let home = tempfile::tempdir().unwrap();
        fs::create_dir_all(home.path().join(".coop/instances")).unwrap();
        assert!(migrate(home.path()).is_err());
        fs::remove_dir_all(home.path().join(".coop")).unwrap();
        std::os::unix::fs::symlink("elsewhere", home.path().join(".coop-apple")).unwrap();
        assert!(migrate(home.path()).is_err());
    }

    #[test]
    fn repairs_interrupted_link_publication() {
        let home = tempfile::tempdir().unwrap();
        let new = home.path().join(".coop");
        fs::create_dir(&new).unwrap();
        fs::write(new.join(".apple-directory-migration"), "1\n").unwrap();
        migrate(home.path()).unwrap();
        assert_eq!(fs::read_link(home.path().join(".coop-apple")).unwrap(), new);
        assert!(!new.join(".apple-directory-migration").exists());
    }

    #[test]
    fn refuses_live_runtime_without_moving_state() {
        let home = tempfile::tempdir().unwrap();
        let old = home.path().join(".coop-apple");
        let sandbox = old.join("backends/apple-container-v1/runtime/sandboxes/test");
        fs::create_dir_all(&sandbox).unwrap();
        fs::write(sandbox.join("live.json"), "{}").unwrap();
        assert!(migrate(home.path()).is_err());
        assert!(old.is_dir());
        assert!(!home.path().join(".coop").exists());
    }

    #[test]
    fn refuses_migration_while_another_command_is_active() {
        let home = tempfile::tempdir().unwrap();
        fs::create_dir(home.path().join(".coop-apple")).unwrap();
        let _command = command_lock(home.path(), libc::LOCK_SH).unwrap();
        assert!(migrate(home.path()).is_err());
        assert!(!home.path().join(".coop").exists());
    }

    #[test]
    fn exclusive_rename_never_replaces_a_destination() {
        let home = tempfile::tempdir().unwrap();
        let from = home.path().join("old");
        let to = home.path().join("new");
        fs::create_dir(&from).unwrap();
        fs::create_dir(&to).unwrap();
        fs::write(to.join("sentinel"), "preserved").unwrap();
        assert!(rename_exclusive(&from, &to).is_err());
        assert!(from.is_dir());
        assert_eq!(
            fs::read_to_string(to.join("sentinel")).unwrap(),
            "preserved"
        );
    }

    #[test]
    fn custom_config_does_not_migrate() {
        let home = tempfile::tempdir().unwrap();
        fs::create_dir(home.path().join(".coop-apple")).unwrap();
        prepare(&home.path().join("custom.toml")).unwrap();
        assert!(!home.path().join(".coop").exists());
    }
}
