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
  plugins/<backend>     One file per backend. probe + install, nothing else.
```

Adding a backend means adding one executable to `client/plugins/`. Nothing
else in the system changes. That is the whole point of the shape.

## Try it

```bash
python3 server/resolve.py &          # listens on :8080

./client/omarchy-install mise        # prints the plan, installs nothing
./client/omarchy-install --apply mise
./client/omarchy-install --variant cli wireshark
./client/omarchy-install --backend flatpak wireshark
```

Nothing installs without `--apply`.

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

## Status

Prototype. Working: resolution, platform and variant matching, trust ordering,
plugin probe/dispatch, state recording, dry-run.

Not built yet: the receiver half (submitting a package and having it come out
signed on the other side), `remove` and `update` reading back the state file,
and any authentication on the resolver.
