# TODO / FIX

## 1. InvokeAI can't update: containerd 2.2.4 can't unpack the new release's big layer

The InvokeAI release published 2026-10-24 (`ghcr.io/invoke-ai/invokeai:latest`, manifest
`sha256:fedfb19d…`) fails to unpack on this host: `failed to extract layer sha256:3737eece…:
archive/tar: invalid tar header` (compressed layer `sha256:142c6c9a…`, 3.4 GB → 6.8 GB tar). Until
fixed, the weekly update reports `invokeai (build failed)` and keeps the working image (InvokeAI
6.10.0rc2 with Pascal-capable torch 2.7.1+cu126).

Ruled out on 2026-10-24: the registry/CDN and network (single and parallel-range downloads both
match the digest), the layer itself (plain USTAR, one gzip member, read cleanly by GNU tar, Go 1.25
`archive/tar` and `unpigz` from file and stdin), stale partial downloads (cleared `ingest/`),
RAM/CPU stability (12 parallel decompress+hash runs, identical). It also fails via `docker load` of a
hand-assembled, verified OCI archive, so it's containerd's unpack path, not the download.
- Most likely fixes itself: the next InvokeAI release (new layers) or a containerd update (comes with
  the weekly system update from Docker's apt repo). The weekly docker update retries automatically.
- If not: report to containerd with the digests above, or try with containerd's `unpigz` out of the
  way (`sudo mv /usr/bin/unpigz /usr/bin/unpigz.off`, restart containerd, retry the pull, move it
  back) to tell its Go and pigz decompression paths apart.

## 2. Containers still to set up: Home Assistant and Open WebUI

Already listed in Glance's Services monitor as reminders (they show as errors until they exist):
`home.leonardonels.com` (Home Assistant) and `openai.leonardonels.com` (Open WebUI, presumably for
the `ollama` container). For each: add `compose/<name>/`, a route in the Cloudflare tunnel (which
also creates the DNS record), and a Glance docker-containers entry.

## 3. Put the remaining public hostnames behind Cloudflare Access

Tested on 2026-10-25 by requesting each public hostname from outside the tunnel: only `invoke-ai`
and `sam3` redirected to the Cloudflare Access login. Still to put behind Access: `portainer`,
`pi-hole`, `n8n`, `crafty` (admin tools, so far protected only by their own login).

Intentionally open (see README, Cloudflared): `nextcloud`, `immich`, `vaultwarden` (apps can't pass
Access), `floratech` (public demo), `glance`, `hot`, `scrutiny` (read-only dashboards). Recheck after
adding the Access applications:

```bash
for h in portainer pi-hole n8n crafty; do
  curl -s -o /dev/null -w "$h %{redirect_url}\n" https://$h.leonardonels.com/
done   # protected ones redirect to <team>.cloudflareaccess.com
```

