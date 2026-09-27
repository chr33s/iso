//! Bound the credential pipe and disable core files before reading secrets.
use std::fs::File;
use std::io::Read;
use std::os::fd::FromRawFd;

use anyhow::{Context, Result, ensure};

use crate::config::ProxyConfig;

const CONFIG_BYTES: usize = 64 * 1024;

pub fn disable_core_dumps() -> std::io::Result<()> {
    let limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: setrlimit reads a valid rlimit pointer and retains no reference.
    if unsafe { libc::setrlimit(libc::RLIMIT_CORE, &raw const limit) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

pub fn read_config() -> Result<ProxyConfig> {
    // SAFETY: main is single-threaded, has never accessed std::io::stdin, and
    // transfers sole ownership of its inherited descriptor here. File closes
    // it on every return path, before any runtime threads or sockets exist.
    let input = unsafe { File::from_raw_fd(libc::STDIN_FILENO) };
    decode(input)
}

fn decode(input: impl Read) -> Result<ProxyConfig> {
    let mut bytes = Vec::new();
    input
        .take((CONFIG_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .context("reading startup pipe")?;
    ensure!(
        bytes.len() <= CONFIG_BYTES,
        "startup configuration exceeds 64 KiB"
    );
    let json = std::str::from_utf8(&bytes).context("startup configuration is not UTF-8")?;
    ProxyConfig::from_json(json)
}

#[cfg(test)]
mod tests {
    use crate::startup::decode;

    #[test]
    #[expect(
        clippy::unwrap_used,
        reason = "isolated test process and resource-limit assertions"
    )]
    fn core_limits_are_zero_in_an_isolated_process() {
        const CHILD: &str = "COOP_TEST_CORE_LIMIT_CHILD";
        if std::env::var_os(CHILD).is_none() {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "startup::tests::core_limits_are_zero_in_an_isolated_process",
                ])
                .env(CHILD, "1")
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            return;
        }
        let mut limit = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        // SAFETY: getrlimit writes only to this valid stack allocation.
        assert_eq!(
            unsafe { libc::getrlimit(libc::RLIMIT_CORE, &raw mut limit) },
            0
        );
        if limit.rlim_max > 0 {
            // Start nonzero when the inherited hard limit permits it, so a
            // no-op cannot pass merely because the shell's soft limit is zero.
            limit.rlim_cur = 1;
            // SAFETY: setrlimit reads the valid allocation and retains no pointer.
            assert_eq!(
                unsafe { libc::setrlimit(libc::RLIMIT_CORE, &raw const limit) },
                0
            );
        }
        crate::startup::disable_core_dumps().unwrap();
        // SAFETY: getrlimit writes only to this valid stack allocation.
        assert_eq!(
            unsafe { libc::getrlimit(libc::RLIMIT_CORE, &raw mut limit) },
            0
        );
        assert_eq!(limit.rlim_cur, 0);
        assert_eq!(limit.rlim_max, 0);
    }

    #[test]
    fn bounded_reader_rejects_without_reading_to_eof() {
        let input = std::io::repeat(b'a');
        let error = decode(input).err().map(|e| e.to_string());
        assert_eq!(
            error.as_deref(),
            Some("startup configuration exceeds 64 KiB")
        );
    }

    #[test]
    fn exact_limit_is_parsed_but_excess_is_rejected() {
        let json = r#"{"version":1,"listen":"127.0.0.1:0","provider":"anthropic","capability_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","injection":{"scheme":"x_api_key","credential":"fake"}}"#;
        let mut bytes = json.as_bytes().to_vec();
        bytes.resize(65_536, b' ');
        assert!(decode(bytes.as_slice()).is_ok());
        bytes.push(b' ');
        assert!(decode(bytes.as_slice()).is_err());
    }
}
