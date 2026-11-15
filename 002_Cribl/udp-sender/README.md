# udp-sender

This repo has one script, `udp-sender.sh`, that installs
[`criblio/udp-sender`](https://github.com/criblio/udp-sender) and sends UDP
packets with a spoofed source IP. The install step takes care of everything
in a single pass, including the permission fixes a sandboxed service such as
Cribl Stream would otherwise need the first time it tries to spawn the
binary. You run it once and there's nothing left to patch up afterward.

`udp-sender` builds its own raw IP and UDP headers, which is how it's able to
spoof the source IP and port on each packet it sends. Raw sockets need
`CAP_NET_RAW`, or root if you'd rather not bother with capabilities.

## Commands

```
sudo ./udp-sender.sh install      # install, online or air gapped, with full setup
     ./udp-sender.sh send ...      # send packets with a spoofed source IP
     ./udp-sender.sh help          # usage
```

Each command takes `-h` if you want to see its own options.

## Requirements

You'll need Linux on x86_64 (`x64`) or aarch64 (`arm64`), root for the
install step, and the `libcap` tools (`setcap`, `getcap`) which come from
`libcap2-bin` on Debian/Ubuntu or `libcap` on RHEL. Go 1.24 or newer is only
needed if you're building from source, or if `send` has to build the packet
generator itself.

---

## 1. Download the artifact

Grab whichever file matches your target host from the
[releases page](https://github.com/criblio/udp-sender/releases). Replace
`X.Y.Z` with the version you want and `<arch>` with `x64` or `arm64`.

| Host | Files |
|------|-------|
| Debian / Ubuntu | `udp-sender-X.Y.Z-<arch>.deb` and its `.sha256` |
| RHEL / CentOS / Fedora | `udp-sender-X.Y.Z-<arch>.rpm` and its `.sha256` |
| Any Linux | `udp-sender-vX.Y.Z-linux-<arch>.tar.gz` and its `.sha256` |

The `.sha256` file is optional, but worth keeping; the installer checks it
automatically when it's there. If the target host is air gapped, download on
a machine that does have internet access and copy the file over.

---

## 2. Install

```bash
sudo ./udp-sender.sh install
```

That's the whole command, whether the host is online or air gapped. Just
place the downloaded artifact in the same folder as the script and run it.
No flag for network state, no extra steps.

Here's how it decides what to do:

1. It checks its own folder first. If a `.deb`, `.rpm`, binary tarball, or a
   source checkout is sitting there, it installs from that. This is the
   air-gapped path, and it works fine online too.
2. If nothing's staged and GitHub is reachable, it downloads the release
   itself.

If you'd rather keep the artifact somewhere else, point the script at it:

```bash
sudo ./udp-sender.sh install -d /path/to/artifacts
```

### What one install run actually does

First, the basics:
- installs the binary to `/usr/bin/udp-sender`
- creates the `udp-senders` group, sets ownership to `root:udp-senders`, mode 750
- grants `CAP_NET_RAW` with `setcap cap_net_raw+ep`, so the binary doesn't need root at runtime
- adds whoever's running the install to that group

Then, if a systemd service is already running on the host (it looks for a
unit name containing "cribl", or you can name one with `--service`), it goes
further and fixes the two errors that service would otherwise hit the first
time it tries to run `udp-sender`:

| Error you'd otherwise see | Why it happens | What the install does about it |
|---|---|---|
| `spawn EACCES` | the service's account isn't in `udp-senders`, and the binary is mode 750 | adds that account to the group |
| `spawn EPERM` | the service's `CapabilityBoundingSet` doesn't include `CAP_NET_RAW`, so the kernel won't let it exec a binary carrying that capability | writes a drop-in adding `CAP_NET_RAW` to the bounding set and ambient capabilities |

It then reloads systemd and restarts the service once, so both fixes take
effect right away. On a host with nothing matching, this whole section is
skipped quietly. Running `install` again later doesn't redo work that's
already correct, so it's safe to run more than once.

**Options:** `-d DIR` for the artifact folder, `-V vX.Y.Z` for a specific
version, `-m auto|package|binary|source`, `-b DIR` for the install path,
`-u USER`, `--service NAME` if auto-detection doesn't find your unit, and
`--no-restart` if you'd rather apply the service fix without bouncing it
right away.

---

## 3. Send with a spoofed source IP

```bash
./udp-sender.sh send --src-ip 203.0.113.55 --src-port 5514 \
                     --dest-ip 10.20.30.40 --dest-port 514 --count 100
```

This checks that `CAP_NET_RAW` is set (granting it once, if needed, which
does require root), finds or builds the packet generator, and sends the
packets without needing sudo. `--src-ip` is the address being spoofed. Across
multiple packets, the generator increments the last octet of that address
and the source port for each one.

| Option | What it does |
|---|---|
| `-s, --src-ip IP` | the spoofed source IP (required) |
| `-D, --dest-ip IP` | destination IP (required) |
| `-P, --dest-port N` | destination port (required) |
| `-p, --src-port N` | source port, defaults to 5000 |
| `-c, --count N` | how many packets, defaults to 1 |
| `-6, --ipv6` | send IPv6 instead |
| `-m, --mtu N` | MTU between 576 and 9000, defaults to 1500 |
| `-v, --verbose` | turn on debug logging |

You can watch the packets land with:

```bash
sudo tcpdump -i any -n udp port 514 -v
```

If you'd rather run the binary yourself, add your user to the group once
(`sudo usermod -aG udp-senders $USER`, then `newgrp udp-senders`) and pipe
the generator straight into it:

```bash
packet-generator -count 100 -base-ip 203.0.113.55 -base-port 5514 \
                 -dest-ip 10.20.30.40 -dest-port 514 | udp-sender -m 1500
```

---

## Notes

Only members of the `udp-senders` group can run the binary, since it's mode
750. Install adds whoever ran it, and the detected service's account if
there is one. Anyone else needs `usermod -aG udp-senders <user>` and either
a fresh login or a service restart. A group change doesn't reach a process
that's already running.

If the binary ever gets copied, rebuilt, or repackaged, it loses its file
capability. Run `install` again, or just `setcap cap_net_raw+ep` on it
directly, to put it back.

`CAP_NET_RAW` only grants raw socket access, nothing more. macOS doesn't
support Linux capabilities, so it needs `sudo` there instead.

Worth knowing: the upstream `packet-generator.go` carries a build tag that
excludes it from a normal build, and it also depends on a constant defined
elsewhere in the package. Running it the way the upstream README describes
(`go run packet-generator.go`) doesn't actually work on its own. The `send`
command works around this by stripping that tag and supplying the missing
constant itself when it builds the generator.

And finally, a word on using this responsibly. Spoofing is meant for testing,
load generation, and security research on networks you're authorized to
test. It can be illegal depending on where you are, and most networks filter
spoofed traffic anyway, so don't expect it to just work everywhere.