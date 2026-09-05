# omarchy-resolve

A working prototype of one idea: **`omarchy install <thing>` should not care
which package manager ends up doing the work.**

The server knows the paths to success. The client picks the first one the
machine can actually execute. Same command on Omarchy, Debian, Fedora or a Mac,
different mechanism underneath, and the user never learns which.

```
omarchy install {thing} -> orchestrator -> server ("this is what you need") -> installs and runs
```

## What is here

```
server/
  resolve.py            Route resolver. Answers, never installs.
  routes/*.json         One file per package: every known way to get it.
client/
  omarchy-install       Orchestrator. Runs the first route it has a plugin for.
  omarchy-remove        Asks whichever backend installed it to take it away.
  omarchy-list          What is installed, who owns it, is it still there.
  lib.sh                Platform detection and the state file.
  plugins/<backend>     One file per backend. Four verbs, nothing else.
test/
  run                   End-to-end suite against a stub backend.
```

A plugin implements exactly four verbs:

| Verb | Answers |
|---|---|
| `probe` | Can you run on this machine at all? |
| `installed <pkg>` | Is this package present right now? |
| `install <pkg>...` | Put it there. |
| `remove <pkg>...` | Take it away. |

Adding a backend means adding one executable to `client/plugins/`. Nothing else
in the system changes. That is the whole point of the shape, and the files are
about seven lines each.

## Try it

```bash
python3 server/resolve.py &          # listens on :8080

./client/omarchy-install mise        # prints the plan, installs nothing
./client/omarchy-install --apply mise
./client/omarchy-install --variant cli wireshark
./client/omarchy-install --backend flatpak wireshark

./client/omarchy-list                # what is installed and who owns it
./client/omarchy-remove --apply mise
```

Nothing is installed or removed without `--apply`.

## What the two example packages demonstrate

**`mise`** has a route we own. It is genuinely in OPR as `mise-bin`, so on
Omarchy the resolver returns the `built-here` tier first and the install is
ours to support.

**`wireshark`** has no route we own, and is a good stress test because every
ecosystem names it differently:

| Ecosystem | Package | Version seen |
|---|---|---|
| Arch / Omarchy | `wireshark-qt`, `wireshark-cli` | 4.7.3 |
| Debian, Ubuntu | `wireshark` | 4.6.6 / 4.2.2 |
| Fedora 43 | `wireshark` | 4.6.8 |
| Homebrew | `wireshark` | 4.6.8 |
| Flathub | `org.wireshark.Wireshark` | hand-curated |
| winget | `WiresharkFoundation.Wireshark` | hand-curated |

There is no package called `wireshark` on Arch at all. That single fact is the
argument for a routing table: the client cannot guess the name, and the user
should not have to.

## Trust is a support boundary

Every route carries a `trust` tier, ordered best first:

| Tier | Meaning |
|---|---|
| `built-here` | We built it, signed it, serve it. Failures are ours. |
| `distro` | Packaged by the distribution. Failures go to them. |
| `flathub` | Flathub's build. Failures go to them. |
| `upstream` | Upstream's own release or a third-party tap. |
| `unverified` | Nobody reviewed what this produces. Last resort. |

This is not a quality score. It answers "who owns it when this breaks", which
is the objection that sinks a router like this if it goes unanswered: promise
that every backend works and every backend's edge cases become your bug
tracker. The tier decides where a failure is *routed*, not just what gets
printed.

Sandboxed builds and source scanning only apply to `built-here`. They are
meaningless for a route that shells out to `brew`.

## Where the route data comes from

`origin` on each route records how the entry was obtained.

- `repology:<repo>` — from a [Repology](https://repology.org) dump, which maps
  a project to its package name and version across ~400 repositories. That is
  most of the tedious work done for free.
- `curated` — by hand. Repology does not index Flathub, winget or Steam, so
  the long tail stays manual.

Repology's API is capped at 1 request/second and asks bulk consumers to use
database dumps with an identifying User-Agent, so a real deployment ingests
dumps periodically rather than calling it per install.

Version fields in the route table are advisory. The backend is the authority
on what actually gets installed; the table only uses them to rank freshness.

## One native manager per root

The obvious objection to a router like this is that you end up merging package
managers: dnf's `somelib.so` and pacman's `somelib.so` in one LD path, symlinked
dependency trees, a worse Nix.

The model refuses that outright. Routes are scoped to the platform the backend
is native to, so `dnf` is never offered on Omarchy:

```
omarchy   -> opr, pacman, flatpak, source
fedora    -> dnf, flatpak, source
debian    -> apt, flatpak, source
alpine    -> apk, flatpak, source
macos     -> flatpak, brew, source
```

One native manager per root. Anything else has to own a separate store, which
is why flatpak and brew appear alongside a native manager and `apt` never does.
Nothing merges trees, because merging trees is the part that goes wrong.

The cost is real: something packaged only for Debian does not become installable
on Arch. The router picks the best existing path, it does not create one.

## The state store is a hint, not a database

It records one thing per install: what was asked for, and which backend answered.

It deliberately does not mirror the transitive dependencies a backend pulled in.
dnf already knows what it installed; a second copy of that only drifts. If a user
removes something out of band with `dnf remove`, the entry goes stale and is
dropped the next time it is consulted. **The backend is always the source of
truth. State only remembers who to ask.**

## Security

The resolver decides what a privileged package manager installs, which makes it
a supply-chain component. [SECURITY.md](SECURITY.md) has the full model. The
short version:

**Answers are signed and clients pin the key.** Every response carries an
ed25519 signature over the body. A client with no pinned key refuses to act; a
client with the wrong key refuses to act. This holds over plain HTTP and
through a terminating proxy, because the signature covers the payload rather
than the transport.

**The resolver is not trusted, only authenticated.** Backend names become paths
that get executed, so they are validated against a strict identifier pattern
and the resolved path is confirmed to be inside the plugin directory. Package
names cannot begin with a dash or contain control characters. A route that
fails validation is dropped rather than shown, and the same checks apply to the
state file, because it is a local file that could have been tampered with.

**It fails closed.** A resolver configured to sign that cannot sign returns 500
rather than an unsigned answer, since an unsigned response looks exactly like
an attacker stripping the header.

The suite includes a fixture that answers the way a compromised resolver would,
with a traversing backend name and an option-injecting package name, and
asserts that nothing executes.

What this does not defend against, in short: a compromised resolver operator, a
malicious upstream package, or a lying `trust` label. The real integrity
guarantee still comes from the backend, which verifies package signatures
against its own keyring no matter what the resolver claimed.

### Running it with signing

```bash
tools/keygen ./resolver-key
SIGNING_KEY=./resolver-key python3 server/resolve.py

install -Dm644 resolver-key.pub ~/.config/omarchy/resolver.pub
```

The resolver binds `127.0.0.1` unless `LISTEN_ADDR` says otherwise. Exposing a
service that names packages for other machines should be a deliberate act.

## Tests

```bash
./test/run
```

47 tests covering the full lifecycle plus the security properties: resolve,
install, record, reconcile, remove, prune, signature verification, and a
hostile-resolver fixture. They run against a stub backend that records what it was told
instead of installing anything, so the suite needs no root and no real package
manager. The interesting bugs here are in the orchestration, not in whether
pacman works.

The plugin verbs have also been exercised against real pacman on an Omarchy
machine, install through detect through remove.

## Status

Working and tested: resolution, platform and variant matching, trust ordering,
plugin probe and dispatch, install, remove, list, reconciliation against the
backend, stale-record pruning, dry-run on every mutating command.

Not built yet:

- **The receiver half.** Submitting a package and having a signed artifact come
  out the other side. The gate for that exists separately as an offline build
  verifier, but it is not wired in here.
- **`update`.** The state file has what it needs, the command is not written.
- **Key rotation.** Pinning is single-key with no overlap period.
- **Replay protection.** A signed answer stays valid forever; responses need a
  timestamp and clients a freshness window.
- **Route data at scale.** Two packages are curated by hand. Ingesting Repology
  dumps to seed thousands is a tool that does not exist yet.
