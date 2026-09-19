# vps-setup: tailnet-only setup

Date: 2026-09-19. Mode: auto-shape. The captain owned nothing here yet, so the calls under
"Decisions made on your behalf" are mine. The spikes ran on a real box.

Repo: `github.com/totallynotdavid/vps-setup` (public), `~/git/vps-setup`, registered in
`local` mode.

## Why shape

Four mechanisms could work: adopt a script, write one, drive it with Ansible, or use
cloud-init. One step cannot be undone. Removing the public login leaves no console
recovery.

## Requirements

| # | Requirement | Status |
|---|---|---|
| R1 | Each step is its own file. `./build` generates `dist/install.sh`. Nothing generated is committed. CI builds the artifact from a tag. | known (captain's ask) |
| R2 | On a fresh box with only root+password, one command as root creates the admin user (locked password, NOPASSWD sudo) and joins the tailnet with `--ssh`. | spiked |
| R3 | After that command, tailnet SSH works and root+password still works. | spiked |
| R4 | A second command, run inside a Tailscale SSH session, closes public SSH. A new tailnet session works afterwards and after a reboot. | spiked |
| R5 | The close keeps the SSH host key, so the operator sees no host-key warning. | spiked |
| R6 | The script refuses an OS version it has not been run on. | known |
| R7 | The auth key never appears in argv. With no key, the script prints the login URL and waits. | URL spiked, key open |
| R8 | Running `install` twice changes nothing. | known |
| R9 | The artifact does nothing unless fully downloaded, and ships with a checksum. | known |
| R10 | After install: ufw active with default-deny incoming, unattended-upgrades active, only 22 open publicly until the close. | spiked |

## Spikes

Box: Contabo, Ubuntu 26.04.1 ("resolute"), fresh, root+password. Node `vps-spike`.

| Question | Answer, with handle |
|---|---|
| S1. Does `tailscale up --ssh --advertise-tags=tag:prod,tag:worker-fleet` join clean on 26.04? | Yes. Joined about 115 s after the login URL was approved. `tailscale status --json`: `Health: []`, `Tags: [tag:prod, tag:worker-fleet]`. |
| S2. Does Tailscale SSH answer while OpenSSH still holds :22? | Yes. `ssh -v`: remote software "Tailscale", auth "none". On the box `SSH_CONNECTION=100.76.195.109 … 100.119.96.74 22`, parent process `tailscaled`. |
| S3. Does ufw default-deny break either path? | No. Rules: `default deny incoming`, `allow in on tailscale0`, `limit 22/tcp`. A new tailnet session and root+password both worked. `tailscale ping`: direct via `:41641`, so no extra UDP rule is needed. |
| S4. Does a sshd drop-in beat cloud-init? | It must sort first. `50-cloud-init.conf` (`PasswordAuthentication yes`) beats `60-cloudimg-settings.conf` (`no`). `00-hardening.conf` flipped `sshd -T` from `yes` to `no`. v1 writes no drop-in, see decision 7. |
| S5. What does removing OpenSSH break? | `apt-get -s purge` lists only `openssh-server` and `openssh-sftp-server`. But `purge` deletes `/etc/ssh/ssh_host_*`, and Tailscale SSH serves those keys. After the purge the host key changed (`6/M7ej…` to `Vzh1Fo…`) and clients printed "REMOTE HOST IDENTIFICATION HAS CHANGED". `apt-get remove` keeps the key files. I reinstalled, then ran `remove`: the served fingerprint stayed `f+Af45…`. |
| S6. Does the closed state survive a reboot? | Yes. Back on the tailnet in about 35 s. Listeners: loopback DNS and tailscaled on tailnet IPs only. ssh units inactive, root locked (`passwd -S root` = `L`), `Health: []`, host key unchanged, public :22 closed/filtered from outside. |
| S7. Does sudo work as expected on 26.04? | It is `sudo-rs 0.2.13`. `visudo -cf /etc/sudoers.d/dubu` parses. `sudo -n true` works over Tailscale SSH. |
| S8. Can the key stay out of argv? | `tailscale up --help` (1.102.4): `--auth-key` accepts `file:<path>`. Not run end to end. See "Not verified". |
| S9. Is Tailscale's apt repo published for 26.04? | Yes. `resolute.noarmor.gpg` and `resolute.tailscale-keyring.list` under `https://pkgs.tailscale.com/stable/ubuntu/` both fetch. |

Other observed traps: `apt` prints `needrestart` noise (`NEEDRESTART_MODE=a`);
`unattended-upgrades` can hold the dpkg lock (`-o DPkg::Lock::Timeout=120`); systemd's ssh
generator leaves `sshd-unix-local.socket` listening on a Unix socket after OpenSSH is gone.
It is harmless.

## Shapes

- **A. Adopt `buildplan/du_setup`.** Fork the 798-star script and add a tailnet close.
  Costs little to start. Keeps its 6,382-line single file.
- **B. Modular sources, generated artifact.** Small step files. A build writes
  `dist/install.sh`, and CI attaches it to a release on a tag. Two subcommands:
  `install` and `close-ssh`.
- **C. Ansible from the laptop.** Roles per step. Needs Ansible and root+password SSH from
  the laptop. Forecloses the one-command run on the box.
- **D. cloud-init user data only.** Contabo takes it at order or reinstall. Nobody is on
  the box, so nothing verifies the tailnet before the close.

## The cross

| | A | B | C | D |
|---|---|---|---|---|
| R1 | ✗ one 6,382-line file | ✓ | ✓ | ✓ |
| R2 | ✗ no `--advertise-tags` in the file; `--ssh` optional (`du_setup.sh:4952`) | ✓ | ✗ not one command on the box | ✗ only at order or reinstall |
| R3 | ✗ its gate proves an OpenSSH key login, not the tailnet | ✓ | ✓ | ✗ no operator, no fallback window |
| R4 | ✗ never closes or removes :22 | ✓ | ✓ two plays, the second targets the tailnet name | ✗ the close cannot run inside a tailnet session |
| R5 | ✓ never removes OpenSSH | ✓ `remove`, not `purge` | ✓ | ✓ |
| R6 | ✓ has a 26.04 verification doc | ✓ | ✓ | ✓ |
| R7 | ✗ key on argv (`du_setup.sh:4898`) | ✓ | ✓ | ✗ key travels inside provider-held user data |
| R8 | ✓ | ✓ | ✓ | ✓ cloud-init runs once per instance |
| R9 | ✓ | ✓ | ✓ nothing is downloaded | ✓ |
| R10 | ✓ | ✓ | ✓ | ✓ |

**Pick: B.** R2 decided it (the flow you described: one command on a box that only has
root+password), with R4 behind it (the close must run inside the tailnet session). A fails
R1, your explicit ask.

**Gives up:** a change reaches a server only after a tagged release. v1 covers 26.04 only.
The checksum is published next to the script, so it catches a truncated or corrupted
download, not a compromised repo or release.

**Keep D as a later output.** A cloud-init file generated from the same steps fits a box that
is reinstalled with an auth key. Not v1.

## Layout of B

    build                        generates dist/install.sh and dist/install.sh.sha256 (gitignored)
    lib/*.sh                     helpers and the dispatcher
    steps/install/NN-name.sh     00-config 10-user 20-tailscale 30-firewall 40-updates 90-next-steps
    steps/close-ssh/NN-name.sh   10-session 20-firewall 30-openssh 40-root
    tests/                       guards.sh, config.sh, e2e/verify.sh
    .github/workflows/           check.yml (mise run check), release.yml (on a v* tag)

Nothing generated is committed. `cap commit` gives each path to one commit, and a committed
`dist/` would be stale in every commit but the last. `main` is called on the last line, so a
truncated download runs nothing. `close-ssh` is the same file with a subcommand, run inside the
Tailscale session.

The close, in order: the session must be served by Tailscale SSH (a `tailscaled` ancestor,
as in S2; a 100.x source address would also match OpenSSH over the tailnet); delete the ufw
22 rule; `apt-get remove` (not purge) `openssh-server` and `openssh-sftp-server`;
`passwd -l root`.

## Decisions made on your behalf

1. Repo `vps-setup` (your name), public on GitHub. The curl target must be public, and no
   secret lives in it.
2. v1 supports Ubuntu 26.04 only. It refuses other versions until they are run on a real box.
   24.04 is next.
3. Neutral defaults, so the public tool carries no personal config: admin user `admin`, no
   tags, node name from the host's name. The fleet passes `ADMIN_USER=dubu` and
   `TS_TAGS=tag:prod,tag:worker-fleet` per run. No `~/git` folder is created.
4. The admin user gets NOPASSWD sudo and a locked password, as on the fleet. Tailscale identity
   is the only gate.
5. The close locks root's password. Recovery is a reinstall from the provider's panel. A
   fleet treats servers as rebuildable and never keeps a standing root password.
6. No fail2ban: after the close there is no public SSH to guard.
7. No custom sysctl and no sshd drop-in in v1. Ubuntu already ships kernel and network
   hardening (`10-kernel-hardening.conf`, `10-network-security.conf`, seen on `master`).
   Removing sshd beats configuring it, and root+password stays as the fallback until the
   close.
8. The auth key is passed as `TS_AUTHKEY_FILE`, a path. The script forwards it as
   `--auth-key=file:<path>` and never handles the secret.
9. Delivery mode is `local`. You sign commits, and GitHub's rebase merge in `pr` mode strips
   signatures. Captain merges the task branch with `--no-ff`, and I push the result.

## Verified end to end (2026-09-19, v0.1.0)

A fresh Contabo box (Ubuntu 26.04.1, root+password). The delivered build was streamed in as
`curl | bash -s install`. Its sha256 (`66de7be6…`) equals the release asset.

| Step | Result |
|---|---|
| `install` with `TS_AUTHKEY_FILE` (one-use, tagged key, trailing newline in the file) | joined the tailnet, exit 0 |
| `verify.sh installed` | 8 of 8 |
| `install` again after the key was spent | exit 0 in 14 s, no re-authentication |
| `close-ssh` inside the Tailscale session, strict host-key checking | exit 0, host key `eHMqo7…` unchanged (R5) |
| `verify.sh closed` | 9 of 9 |
| reboot, then `verify.sh closed` | back on the tailnet in about 38 s, 9 of 9 |
| release `v0.1.0` | CI built it. The asset equals the tested build and `sha256sum -c` passes. |

Findings from the run:

- **Device approval.** This tailnet holds a new node until an admin approves it, and the key
  was not pre-approved. `tailscale up` printed "To approve your machine" and waited, and
  `tailscale status` said "Machine is not yet approved by tailnet admin." While it waited,
  steps 30 to 90 had not run, so the firewall was untouched. The captain approved with about
  ten seconds left of the 10-minute timeout. The timeout path itself was not run. The README
  did not say any of this. A follow-up task documents it.
- **Transient connect timeout.** The first tailnet connection after the re-run's ufw reload
  timed out at 15 s. `tailscale ping` showed a direct path. A retry with a 45 s connect
  timeout worked, and the close had not run.
- On the closed spike box earlier: `install` and `close-ssh` re-runs converged, and a detached
  process chain (parent PID 1) made `close-ssh` refuse.

## Not verified

- Ubuntu 24.04. The OS gate refuses it.
- The cloud-init path. That Contabo accepts user data (API at order time, or Reinstall in the
  panel) comes from Contabo's docs via a web search. I did not run it.
- The script's own login-URL mode. The spike ran `tailscale up` by hand.
- The 10-minute join timeout path, and a pre-approved key.

## State left behind

`vps-e2e` is on the tailnet as `tag:prod`, on the closed-down box. Its root password is locked
and the one-use auth key is spent. Delete the node in the admin console when done.
