# syntax=docker/dockerfile:1
#
# Multi-arch image for `condukt-egress`. Used as both the init container
# (in `netfilter-setup` mode) and the sidecar (in `proxy` mode) for
# `Condukt.Sandbox.Net`-enabled `Condukt.Sandbox.Kubernetes` pods.
#
# We use `debian:bookworm-slim` as the runtime base rather than
# `gcr.io/distroless/cc-debian12` for v1. The init mode needs the
# `iptables` binary (and its shared-library dependency closure:
# libnftnl, libmnl, libxtables, libnetfilter-conntrack, libnfnetlink),
# which distroless does not provide. Multi-stage copy of the iptables
# dep closure into distroless is fragile across Debian versions; we
# accept a slightly larger image (~85MB) for v1 to keep this Dockerfile
# stable. Future revision: switch to distroless+manual lib copy once
# we have CI coverage that catches missing-lib regressions.

FROM rust:1.94-bookworm AS builder

WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY src ./src

# Pre-fetch deps in a separate layer so source-only edits skip the
# dependency build.
RUN cargo fetch --locked

RUN cargo build --release --frozen \
 && strip target/release/condukt-egress

# ----------------------------------------------------------------------------

FROM debian:bookworm-slim AS runtime

# `iptables-nft` is the default backend on modern Debian and what we
# rely on at runtime. `ca-certificates` is needed for the Tier 2 path:
# the sidecar dials upstream TLS and verifies the real server's cert
# against the system trust store.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      iptables \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Sidecar runs as a fixed uid so the init container's netfilter rule
# can exempt it by `--uid-owner`.
RUN groupadd --system --gid 1337 condukt-egress \
 && useradd --system --uid 1337 --gid 1337 --no-create-home --shell /sbin/nologin condukt-egress

COPY --from=builder /src/target/release/condukt-egress /usr/local/bin/condukt-egress

# Default to the proxy subcommand so the sidecar usage path is the
# zero-config one. The K8s init container overrides `command:` to run
# `condukt-egress netfilter-setup`.
USER 1337
ENTRYPOINT ["/usr/local/bin/condukt-egress"]
CMD ["proxy"]
