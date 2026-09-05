# Security model

This tool decides what a privileged package manager installs. That makes it a
supply-chain component, and it is worth being explicit about what it defends
against, what it does not, and where the sharp edges are.

## The core problem

```
resolver  ->  "install these packages"  ->  client  ->  sudo pacman -S ...
```

Anything that can influence the middle arrow can name any package on the
system. There is no clever way around that: it is the nature of a service whose
job is to answer "what should I install". So the resolver has to be treated
with the same seriousness as a package signing key, and the client has to treat
every answer as input rather than as instruction.

## Trust boundaries

| Component | Trusted? | Why |
|---|---|---|
| The resolver's answer | Only when signed by a pinned key | It names packages a privileged tool installs |
| The route table on the server | Yes, by the operator | Whoever writes routes decides what people get |
| The state file on disk | No | Local file, could be tampered with; re-validated on read |
| Plugin scripts | Yes | They ship with the client and are part of it |
| The backend package manager | Yes | It does its own signature verification |

## What is defended against

**A spoofed or man-in-the-middled resolver.** Every answer is signed with an
ed25519 key. Clients pin the public key and refuse anything that does not
verify. This holds even over plain HTTP, through a terminating proxy, or via a
compromised CDN, because the signature covers the response body rather than the
transport. A client with no pinned key refuses to act at all unless
`OMARCHY_INSECURE=1` is set explicitly.

**A malicious backend name.** The backend field becomes a path that gets
executed. A resolver answering `../../../tmp/payload` would otherwise get
arbitrary code run as the user, and that user can drive a package manager as
root. Backend names must match `^[a-z][a-z0-9-]{0,31}$`, and the resolved
plugin path is separately confirmed to sit inside the plugin directory. Both
checks exist because this is the failure that ends with somebody's machine
owned.

**Option injection through package names.** Names are passed as argv elements,
so quoting is not the exposure, but a name like `--config` becomes a flag to
whatever privileged tool receives it. Leading dashes and control characters are
refused, and plugins pass `--` where the underlying tool supports it.

**A tampered state file.** `omarchy-remove` reads a backend name out of local
state and executes it, so state gets the same validation as a network answer.

**A hung or hostile resolver.** Requests time out (default 10s), redirects are
not followed, and the protocol is restricted to http/https.

**A resolver that cannot sign.** The server fails closed. If a signing key is
configured and signing fails, it returns 500 rather than an unsigned answer,
because an unsigned response is indistinguishable from an attacker stripping
the header.

## What is not defended against, and cannot be

**A compromised resolver operator.** If the signing key is stolen or the person
holding it is malicious, they can name any package and every client will
believe it. This is the same exposure any distribution has with its signing
key. Mitigation is operational: key custody, hardware tokens, audit logs on
route changes. Not code.

**A malicious upstream package.** If Debian ships a backdoored `wireshark`,
routing you to Debian's `wireshark` faithfully delivers the backdoor. The
`trust` tier tells you whose judgement you are relying on; it does not
substitute for that judgement.

**A lying trust label.** The tier is server-controlled. A compromised resolver
can mark an `unverified` route as `built-here` and the client will print a
green tick. The label is advisory. The actual integrity guarantee comes from
the backend: pacman verifies package signatures against its own keyring
regardless of what the resolver claimed, and the `opr` plugin qualifies package
names with the repository so a same-named package elsewhere cannot shadow it.

**Route data that is simply wrong.** A route pointing at the wrong package
installs the wrong thing. Nothing here validates that a route is *correct*,
only that it is authentic and well-formed.

## Running it safely

The resolver binds `127.0.0.1` by default. Exposing it is deliberate:

```bash
tools/keygen ./resolver-key
SIGNING_KEY=./resolver-key LISTEN_ADDR=0.0.0.0 python3 server/resolve.py
```

The private key never leaves the server. Distribute only the `.pub`:

```bash
install -Dm644 resolver-key.pub ~/.config/omarchy/resolver.pub
```

Rotating the signing key invalidates every pinned client at once. There is no
key rotation story yet, which is a real gap for anything beyond a prototype.

## Known gaps

- **No key rotation.** Pinning is single-key with no overlap period.
- **No TLS by default.** Signing makes transport interception useless for
  tampering, but request contents are still visible, which leaks what a machine
  is installing.
- **No replay protection.** A signed answer stays valid forever, so an attacker
  who can intercept traffic could serve a stale answer to pin someone to an old
  route. Responses need a timestamp and clients need a freshness window.
- **No rate limiting or authentication on the resolver.** Anyone who can reach
  it can enumerate the route table.
- **Plugins run with the user's privileges** and invoke `sudo`. There is no
  sandboxing of a plugin itself.

## Reporting

This is a prototype. If you find something, open an issue.
