# Shared coding-agent instructions

- Main branch is `master`, never `main`.
- Read `STATUS.md`, `DECISIONS.md` and `TODO.md` before substantial work and update them after.
- Keep shell code ShellCheck-clean (`bash tests/lint.sh`) and run `bash tests/run.sh` on Linux (the sandbox suites
  use GNU `stat`/`install` and do not run on Windows Git Bash). A Debian 13 lab VM is described in the global
  `localnet` skill; never commit its credentials.
- Do not print or commit client passwords, obfuscation passwords or certificates.
