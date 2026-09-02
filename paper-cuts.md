# Paper cuts

Friction in Captain itself. These are harness quirks, broken scripts, and skills that
misfire. They are not project bugs.

- [ ] 2026-08-30 https://github.com/anthropics/claude-code/issues/82563: prompt cache behavior changes between adjacent turns. Captain cannot correct the client behavior. Recheck after a CLI release.
- [ ] 2026-08-30 https://github.com/anthropics/claude-code/issues/89327: the skill catalog is sent twice per session. Keep installed skill snapshots small until the client changes.
- [ ] 2026-09-01 - comparing two captain hosts (local vs a remote instance) required a dozen manual ssh probes (tool PATH, herdr env vars, gh auth status, bin/ checksums) - there is no single command to audit or diff a host's captain environment
