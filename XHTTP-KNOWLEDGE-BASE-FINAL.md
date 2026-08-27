# XHTTP / xui-lite Deployment — Complete Knowledge Base

_Generated 2026-08-25 on the main VPS (38.45.80.233). Merged from: `xhttp-final-report.md`, `xhttp-nginx-uds-analysis.md`, `xray-fronted-architecture.md` (all three now consolidated here), live server audits, XTLS/Xray-core GitHub research, Cloudflare API DNS dumps (both accounts), and the four production client configs._

---

## Table of Contents
1. Architecture overview
2. Server-side configuration (as deployed)
3. UDS → TCP migration history
4. XHTTP protocol deep-dive & settings reference
5. Stability findings & root-cause attribution
6. DNS inventory (domains → IPs → owners; full Cloudflare dump)
7. Client configurations (verbatim ×4) + per-config evaluation
8. Cross-evaluation: DNS × nginx × xray × clients
9. Uplink/downlink semantics
10. Operational playbook
11. Alternative architecture: xray-fronted
12. References

---

## 1. Architecture Overview

```
Iran client ──► [choice of entry paths]
   A) DE VPS 94.159.109.54 (H2.NEXUS Frankfurt) ──forwards :443 + :80──► CZ main VPS
   B) ArvanCloud edge (185.143.233/234.238 anycast)      ──origin pull──► origin per panel
   C) Cloudflare edge (104.21.x / 172.67.x)              ──origin pull──► CZ:443
   D) Bitcommand edge 185.239.1.100 (ParsPack NS)        ──origin pull──► DE or CZ per name
        │
        ▼
CZ MAIN VPS 38.45.80.233 (Cogent/Euronodes) — nginx (TLS term, :80+:443) ──TCP 127.0.0.1:29117──► xray v26.7.28 (x-ui managed)
```

- Split-path design goal: upload and download legs traverse **different, unrelated IPs** so DPI never sees one bidirectional correlated flow.
- Entry selection is per-config: direct IP (no CDN), ArvanCloud, Cloudflare, or Bitcommand/ParsPack CDN.

## 2. Server-Side Configuration (as deployed)

### 2.1 nginx — six identical-pattern vhosts (`/etc/nginx/sites-available/xui-lite-*.conf`)
Domains: `avistel.ir`, `elahe-rad.ir`, `rprx.ir`, `southpark.ir`, `wille.ir`, `zyklon.ir`.

```nginx
server {
    server_name DOMAIN *.DOMAIN;
    listen 80;
    listen [::]:80;
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    # TLS 1.2/1.3, LE wildcard cert:
    ssl_certificate     /etc/letsencrypt/live/DOMAIN/fullchain.pem;   # SANs: *.DOMAIN + DOMAIN
    # host gate:
    if ($host !~* ^(.+\.)?DOMAIN$ ) { return 444; }
    # SNI gate ($ssl_server_name) sets $safe; if both fail -> 444
    # hack regex -> 404
    error_page 400 402 403 404 500 501 502 503 504 =200 /;   # all errors masked as fake-site 200
    proxy_intercept_errors on;

    location /5udEeljFo0biF2AGXz/ { proxy_pass http://127.0.0.1:35513; ... }   # panel (random path+port)
    location ~ ^/(?<fwdport>\d+)/sub/(?<fwdpath>.*)$  { ... proxy_pass http://127.0.0.1:$fwdport/sub/$fwdpath$is_args$args; }
    location ~ ^/(?<fwdport>\d+)/json/(?<fwdpath>.*)$ { ... proxy_pass http://127.0.0.1:$fwdport/json/$fwdpath$is_args$args; }

    # Main Xray traffic — traditional local TCP port (v6.1.0):
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)$ {
        client_max_body_size 0;
        client_body_timeout 1d;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:$fwdport;
        break;
    }
    location / { try_files $uri $uri/ =404; }
}
```

Certificates (LE wildcard, all valid until Oct 2026): `*.avistel.ir`, `*.elahe-rad.ir`, `*.rprx.ir`, `*.southpark.ir`, `*.wille.ir`, `*.zyklon.ir` (+ apex each).

**Rules that must never be violated:**
- Use `proxy_pass` for the generic `/<port>/<path>` location — it also carries ws/httpupgrade. `grpc_pass` works in front of xray xhttp too, but is HTTP/2-only upstream (see §5.1, corrected 2026-08-27).
- Keep `proxy_buffering off` + `proxy_request_buffering off` + long read timeout for streaming halves.
- The `/​<digits>/…` location serves on BOTH :80 and :443 (same server block).

### 2.2 xray inbound (`zeiss`) — from `/etc/x-ui/x-ui.db`
```json
{
  "id": 1, "remark": "zeiss", "port": 29117, "listen": "127.0.0.1", "enable": 1,
  "settings": {
    "clients": [
      {"id":"ec456111-79b2-411f-a34d-e50be2a54e76","email":"administrator","enable":true},
      {"id":"6935bbee-cc60-4a51-ad60-f8fbf98b67dd","email":"reza"},
      {"id":"898e482b-6aad-44af-8c46-8a5ad73da81e","email":"zikno"},
      {"id":"76eb7dde-6cf7-4cd8-b70a-fd4e5d8ccc91","email":"carvex"}
    ],
    "decryption": "mlkem768x25519plus.native.600s.OGhOGZBNNwtYeiTy83yRj8BO1ymzLSDJ-4VcAfB_CnQ",
    "encryption": "mlkem768x25519plus.native.0rtt.QWoXJO-Jw_tShsUrQbB37bv46eSn99D8ky1_I42Cfh8"
  },
  "streamSettings": {
    "network": "xhttp", "security": "none",
    "xhttpSettings": {
      "path": "/29117/zigen", "host": "", "mode": "auto",
      "xPaddingBytes": "100-1000", "scMaxBufferedPosts": 30,
      "scStreamUpServerSecs": "20-80"
    }
  }
}
```
Client-side `encryption` string = the published public form matching the server's private `decryption` (VLESS post-quantum encryption; verified working end-to-end).

### 2.3 Daily restart cron
`/etc/cron.d/xui-lite`: `0 0 * * * root /usr/bin/x-ui restart` (+01:00 nginx reload, 03:00 certbot renew, 10:30 apt). With TCP loopback the historic socket-deletion race no longer severs nginx→xray, but active sessions still drop briefly at 00:00.

## 3. UDS → TCP Migration History (2026-08-25, applied)

Installer `/home/dev/mimo/xui-lite.sh` bumped to **v6.1.0**: reverted nginx→xray forwarding from UDS (`unix:/dev/shm/port-$fwdport.sock`) to `proxy_pass http://127.0.0.1:$fwdport;` (as in GFW4Fun base). Reasons documented: socket files deleted out-of-band during x-ui restart cron → `[crit] connect() ... failed (2: No such file or directory)` at exactly 00:00:01 daily; hand-tuned `,0666` perms needed; TCP loopback needs none of that. Inbound must be `Listen=127.0.0.1, Port=<port segment of public URL>`.

Applied via `/home/dev/mimo/apply-tcp-revert.sh` (root, backups `*.pre-tcp.20260825-042026`, nginx -t + rollback safety, DB backup `x-ui.db.pre-tcp.*`, converts any `listen=/dev/shm/port-N.sock…` row to `listen='127.0.0.1', port=N`). Verified post-run: all six confs migrated, `nginx -t` OK, reloaded, `ss` shows xray on `127.0.0.1:29117`. Old UDS sockets removed.


---

## 4. XHTTP Protocol Deep-Dive & Settings Reference

### 4.1 Modes and wire mechanics

| Mode | Uplink (client to server) | Downlink (server to client) |
|---|---|---|
| **packet-up** | many small `POST /path/UUID/seq` (seq from 0; next POST body only after previous sent; server reassembles in seq order, buffers max 30 out-of-order then drops) | ONE long-lived `GET /path/UUID`, response body is the data stream |
| **stream-up** | ONE streaming `POST /path/UUID` (body streams up) | same GET as packet-up |
| **stream-one** | single bidirectional `POST /path/` (trailing slash auto-added); response IS the downlink | inside the POST response |

- UUID: random per session, correlates up/down halves; server kills session if correlation fails within **30 s**. UUID+seq deliberately in path, not query string.
- Download GET response headers: `X-Accel-Buffering: no`, `Cache-Control: no-store`, `Content-Type: text/event-stream` (SSE masquerade; `noSSEHeader` disables), chunked on H1.1.
- CORS everywhere: `Access-Control-Allow-Origin: *`, methods GET/POST (Browser Dialer).
- Header padding (`xPaddingBytes`, default `"100-1000"` random per request/response): client side in `Referer: ...?x_padding=XXX`; server replies `X-Padding:`. Server validates range.
- Upload masquerade: `Content-Type: application/grpc` — **camouflage only**, plain HTTP framing. Disable via `noGRPCHeader`.
- Server honors `X-Forwarded-For` and can enforce host match.
- `auto` resolution — client: TLS H2 -> stream-up; REALITY -> stream-one (stream-up if downloadSettings present); else packet-up. Server accepts all; pinned = accept only that mode (stream-up also accepts stream-one).
- HTTP version rules: TLS -> H2 default; ALPN only http/1.1 -> H1.1; ALPN only h3 -> quic-go H3 (server normally TCP H1/H2 only; CDNs convert H3 anyway). No TLS -> H1.1. Browser Dialer: browser decides.

### 4.2 Settings field-by-field

| Field | Side | Meaning / default |
|---|---|---|
| `host` | both | Host/SNI check value; leave unset unless needed |
| `path` | both | URL prefix, must match server |
| `mode` | both | auto / packet-up / stream-up / stream-one |
| `xPaddingBytes` | both | Header padding range, default "100-1000" |
| `noGRPCHeader` | client, stream-up/one | Removes fake gRPC Content-Type; helps only when a CDN *rejects* grpc-looking requests while feature is off; does NOT add gRPC support where absent |
| `noSSEHeader` | server | Removes SSE Content-Type on download responses |
| `scMaxEachPostBytes` | packet-up | Max bytes per POST, default 1,000,000; server rejects larger; ranges allowed; keep below CDN limits |
| `scMinPostsIntervalMs` | client, packet-up | Min gap between POSTs per session, default 30 ms |
| `scMaxBufferedPosts` | server, packet-up | Out-of-order reassembly buffer, default 30 per proxy request; overflow drops conn |
| `scStreamUpServerSecs` | server, stream-up | Periodic X-padding into upload-POST response defeating ~100 s CDN idle close; default "20-80"; -1 disables (also delays response headers). Does NOT protect download GET (#6554) |
| `extra` | server->client | Server pushes all params to clients automatically |

XMUX (H2/H3 multiplexing, client). Defaults apply ONLY when every field is zero; set one -> set them all:

| Field | Default (all-zero) | Meaning |
|---|---|---|
| `maxConcurrency` | "16-32" rand | Max concurrent proxy sessions per TCP/QUIC conn before new conn |
| `maxConnections` | unlimited | Cap total conns (conflicts with maxConcurrency; pick one) |
| `cMaxReuseTimes` | unlimited | Reuse budget per conn |
| `hMaxRequestTimes` | "600-900" rand | HTTP reqs per conn (nginx caps ~1000); stream-one=1, stream-up=2, packet-up=N reqs |
| `hMaxReusableSecs` | "1800-3000" rand | Conn lifetime cap (nginx ~1 h) |
| `hKeepAlivePeriod` | 0 (Chrome H2 45 s / quic-go H3 10 s) | Idle H2/H3 keepalive period; no ranges allowed; negatives disable |

Rotation defeats the eternal-connection fingerprint. Do NOT enable mux.cool with XHTTP (server accepts pure XUDP only).

### 4.3 `downloadSettings` (client only)

A complete second `streamSettings` plus `address`/`port` for the downlink GET. Uplink/downlink may use different IPs/domains/transports (e.g., IPv4/TCP up, IPv6/UDP down), correlated solely by path UUID. `network` must be `"xhttp"`; `security` tls or reality. `sockopt` shared unless the receiver sets `penetrate:true`.

### 4.4 Uplink/downlink semantics — CLIENT-relative

Uplink = your outgoing requests (POSTs). Downlink = everything arriving to you (GET response). Typical browsing ~90% download -> put the strongest path on `downloadSettings`. The #6554 exposure lives on the DOWNLINK leg (GET idles during heavy uploads); upload POSTs never idle.

---

## 5. Stability Findings & Root-Cause Attribution

### 5.1 `grpc_pass` vs `proxy_pass` in front of xray xhttp (corrected 2026-08-27)

**Correction:** the previous version of this section claimed "grpc_pass never works in front of xray xhttp — nginx waits for grpc-status trailers that never arrive". That mechanism was WRONG: nginx's grpc module is a transparent HTTP/2 passthrough; it never parses or requires gRPC trailers. Verified facts:

- xray's xhttp listener explicitly handles plaintext HTTP/1.1 AND h2c on both TCP and UDS (hub.go: `SetHTTP1(true)` + `SetUnencryptedHTTP2(true)`, "server can handle both plaintext HTTP/1.1 and h2c"). h2c prior-knowledge is exactly what `grpc_pass grpc://` speaks, so the two interoperate.
- The upstream XHTTP doc (RPRX, discussion #4113) itself recommends grpc_pass for nginx: Quick Start #5 "If you cannot penetrate Nginx, change Nginx's proxy_pass to grpc_pass"; STREAM-UP section "Nginx recommends grpc_pass – simple and easy". That advice targets exactly the nginx-fronted architecture (nginx terminates TLS, forwards to xray). The hint fixes nginx's DEFAULT request buffering stalling stream-up's streaming POST, which `proxy_request_buffering off` also fixes.
- XTLS/Xray-core#6444 ran `grpc_pass grpc://127.0.0.1:PORT` → xray xhttp (security:none) successfully; its instability was Fastly + XMUX `maxConnections` defaults, not grpc_pass. The reporter confirmed stream-up through Fastly only worked WITH nginx in front of xray.

Unresolved observation (2026-08-04, kept for the record): `upstream timed out (110) ... upstream: "grpc://unix:/dev/shm/port-29117.sock:"` on avistel.ir, client 94.159.109.54, POST /29117/zigen; grpc_pass tests timed out while proxy_pass worked:

| Setup | grpc_pass | proxy_pass |
|---|---|---|
| nginx-fronted + UDS + security:none | TIMEOUT (unroot-caused) | works |
| nginx-fronted + TCP + security:none/tls | TIMEOUT (unroot-caused) | works |

The timeouts were real, but the trailer-waiting explanation was wrong. Plausible causes never verified at the time: UDS lifecycle race (§5.3), connect timeout to a dead/recreated listener, or the Go >=1.26.6 build bug (#6630). Regardless, proxy_pass remains the design choice for the generic `/<port>/<path>` location because it also carries WebSocket/HTTPUpgrade inbounds, which grpc_pass (HTTP/2-only upstream) cannot. The gRPC Content-Type in stream-up is just camouflage — xray recognizes the protocol from the path pattern (seq presence), not Content-Type. A real gRPC-transport inbound would need a dedicated grpc_pass location.

### 5.2 Packet-up CDN idle-close — issue #6554

Mechanism: packet-up downlink = one long GET; its hub.go handler sets anti-buffer headers, flushes, blocks — **no keepalive padding goroutine** (unlike stream-up's upload-response padding from #4306). During sustained uploads the GET goes silent; CDN edges (nginx 60 s default; Cloudflare ~100 s; Arvan similar) close it. Symptoms: `RST_STREAM INTERNAL_ERROR received from peer` (~60 s, self-heals by redial) or **silent wedge** (session half-alive, POSTs trickle kbit/s, no logs).

Measured: 15 min through CDN = 8+ INTERNAL_ERROR, 7+ 502, 6+ 504 with server logs clean; direct-IP 2.5 h test = zero errors anywhere.

RPRX closed #6554 as *not planned*. His reply decoded: framing aside, he judges pure-upload phases rare; the proper mechanism would be Mux.Cool-level SessionStatusKeepAlive frames (community PR #6561), which he also deems unnecessary now. Related unmerged community work: #6562 ("keep stream-down response alive", completes #4306 for the download side), #6632 (Request.GetBody so packet-up h2 replays after GOAWAY), #4846 (packet-down feature request).

Mitigations: direct-IP endpoints (zero exposure); stream-up + scStreamUpServerSecs through CDNs that pass long H2 bodies (both halves padded); self-patch core with PR #6562 building with Go <=1.26.5 (#6630); wait for upstream.

### 5.3 Historic UDS restart race (FIXED 2026-08-25)

Timeline at 00:00 UTC daily: cron restarts x-ui -> socket deleted -> `[crit] connect() to unix:/dev/shm/port-29117.sock failed (2)` + `upstream prematurely closed` -> recreated ~1 s later. Eliminated by TCP loopback revert (section 3). Sessions still drop briefly at 00:00 restart itself.

### 5.4 Other Xray-core issues (status vs v26.7.28+)

| Issue | Status | Impact |
|---|---|---|
| #6663 | closed, no fix commit | Server SETTINGS_MAX_FRAME_SIZE=1MB -> up to 512KB per-stream client buffers -> iOS jetsam kills |
| #6630 | closed not_planned | Cores self-built with Go >=1.26.6/1.27rc3: severe disconnects; official binaries pinned safe |
| #6560 | open | packet-up H1 upload sockets pooled in sync.Pool never closed except GC |
| #6590 | fixed | stalled dial parked goroutine without timeout |
| #6268 | open | high client memory on xhttp/http2 |
| #4621 | open | noisy INTERNAL_ERROR h2 stream-error logs |
| #4501 | external | CloudFront strips x_padding query param -> "invalid x_padding length:0" -> 400 |
| #6444 | closed not_planned | NOT a grpc_pass bug: instability was Fastly + XMUX maxConnections defaults; reporter's nginx grpc_pass → xray xhttp worked, and stream-up through Fastly only worked with nginx in front |
| #6526,#6372,#6343,#6332,#6316,#6309,#6258,#6140,#6095 | shipped in v26.7.28 | localAddr accuracy, upload_queue refactor, scStreamUpServerSecs fix w/ xPaddingObfsMode, H3 client active close, panic fix, trustedXForwardedFor requirement, sessionIDTable rename, packet-up OpenUsage/H3 keepalive, memory leak fixes |


---

## 6. DNS Inventory

### 6.1 Domain -> IP -> Owner map (probed 2026-08-24/25 via 1.1.1.1 + authoritative)

| Domain | Resolves to | Owner / Network | Type | Used as |
|---|---|---|---|---|
| `avistel.ir`, `www.avistel.ir` | `94.159.109.54` | H2.NEXUS, Frankfurt, DE | DIRECT — DE front VPS | cfg1 upload (plain :80); nginx LE cert terminates |
| `southpark.ir`, `www.southpark.ir` | `38.45.80.233` | Cogent/Euronodes, CY/CZ | DIRECT — CZ main VPS (this box) | cfg1 download (plain :80) |
| `zyklon.ir`, `www.zyklon.ir`, `up.zyklon.ir`, `down.zyklon.ir` | `185.143.234.238`, `185.143.233.238` | AbrArvan BGP Anycast, IR | CDN — ArvanCloud | cfg3 upload (`up.`) |
| `down.elahe-rad.ir` | same Arvan pair | AbrArvan | CDN — ArvanCloud | cfg2 upload leg |
| `elahe-rad.ir`, `www.elahe-rad.ir` | no A record | — | dead names; only `down.` published | unused |
| `wille.ir`, `www.wille.ir`, `down.wille.ir` | `104.21.95.148`, `172.67.145.129` | CLOUDFLARENET | CDN — Cloudflare | cfg3 download leg |
| `upcdn.rprx.ir`, `downcdn.rprx.ir`, `rprx.ir` apex | `185.239.1.100` (all identical) | Bitcommand, Kerman IR (NS: parspack.net) | CDN — Iranian provider | cfg2 download, cfg4 both legs |
| `www.rprx.ir` | no A record | — | dead name | unused |

Non-CF zones: `rprx.ir` DNS at ParsPack (`rainbow/lightning.parspack.net`) with Bitcommand edge — authoritative answers confirm upcdn=downcdn=185.239.1.100 (no geo-DNS variance); origins configured in panel: upcdn->DE 94.159.109.54, downcdn->CZ 38.45.80.233. `zyklon.ir` / `elahe-rad.ir` managed at Arvan.

whois 185.239.1.100: netname Bitcommand, country IR, person Mansour Maddah, Ansar-al-Rasool BL, Vali Asr SQ., Kerman, Iran.
whois 94.159.109.54: H2NEXUS, DE. whois 38.45.80.233: COGENT-A / EURONODES-CGNT-NET-1, CY. whois 185.143.234.238: ANYCAST_185-143-234-0_24, AbrArvan, IR.

### 6.2 Cloudflare API dump — both accounts, complete

Pulled 2026-08-25 with read-only tokens (Zone:Read + DNS:Read). Account 1 = `cfat_…` token: zones `20030417.xyz`, `avistel.ir`, `knxv.ir`, `southpark.ir`, `wille.ir`. Account 2 = `cfut_…`: zones `anjomansut.ir`, `iran-liberation-army.eu.org`, `magi.anjomansut.ir`, `saleh-momtaz.ir`, `saleh-mumtaz.ir`. Tokens expire 2026-08-28 — revoke after use.

_Generated: 2026-08-25T06:24:36+00:00_
## Account 1 (`cfat_…`) — via dns-read token


## Account 2 (`cfut_…`)


### Zone `anjomansut.ir` — 13 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|
| dnrr.anjomansut.ir | A | 38.45.80.233 | off | auto |  |
| nsrr.anjomansut.ir | A | 94.159.109.54 | off | auto |  |
| anjomansut.ir | MX | mx2.zoho.eu | off | auto | 20 |
| anjomansut.ir | MX | mx.zoho.eu | off | auto | 10 |
| anjomansut.ir | MX | mx3.zoho.eu | off | auto | 50 |
| *.dnr.anjomansut.ir | NS | dnrr.anjomansut.ir | off | auto |  |
| *.nsr.anjomansut.ir | NS | nsrr.anjomansut.ir | off | auto |  |
| dnr.anjomansut.ir | NS | dnrr.anjomansut.ir | off | auto |  |
| magi.anjomansut.ir | NS | rachel.ns.cloudflare.com | off | auto |  |
| magi.anjomansut.ir | NS | aaden.ns.cloudflare.com | off | auto |  |
| nsr.anjomansut.ir | NS | nsrr.anjomansut.ir | off | auto |  |
| anjomansut.ir | TXT | "zoho-verification=zb66582253.zmverify.zoho.eu" | off | auto |  |
| anjomansut.ir | TXT | "v=spf1 include:zoho.eu ~all" | off | auto |  |

### Zone `iran-liberation-army.eu.org` — 3 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|
| awsup.iran-liberation-army.eu.org | A | 91.240.95.208 | off | auto |  |
| downstream.iran-liberation-army.eu.org | CNAME | cl-gl1a75bf0a.gcdn.co | off | auto |  |
| upstream.iran-liberation-army.eu.org | CNAME | cl-gl1a75bf0a.gcdn.co | off | auto |  |

### Zone `magi.anjomansut.ir` — 0 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|

### Zone `saleh-momtaz.ir` — 8 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|
| dnrr.saleh-momtaz.ir | A | 94.159.109.54 | off | auto |  |
| nsrr.saleh-momtaz.ir | A | 38.45.80.233 | off | auto |  |
| saleh-momtaz.ir | A | 149.56.201.253 | **ON** 🟠 | auto |  |
| saleh-momtaz.ir | A | 158.69.187.205 | **ON** 🟠 | auto |  |
| *.dnr.saleh-momtaz.ir | NS | dnrr.saleh-momtaz.ir | off | auto |  |
| *.nsr.saleh-momtaz.ir | NS | nsrr.saleh-momtaz.ir | off | auto |  |
| dnr.saleh-momtaz.ir | NS | dnrr.saleh-momtaz.ir | off | auto |  |
| nsr.saleh-momtaz.ir | NS | nsrr.saleh-momtaz.ir | off | auto |  |

### Zone `saleh-mumtaz.ir` — 15 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|
| dnrr.saleh-mumtaz.ir | A | 94.159.109.54 | off | auto |  |
| nsrr.saleh-mumtaz.ir | A | 38.45.80.233 | off | auto |  |
| saleh-mumtaz.ir | A | 149.56.201.253 | **ON** 🟠 | auto |  |
| saleh-mumtaz.ir | A | 158.69.187.205 | **ON** 🟠 | auto |  |
| saleh-mumtaz.ir | MX | mx3.zoho.eu | off | auto | 50 |
| saleh-mumtaz.ir | MX | mx2.zoho.eu | off | auto | 20 |
| saleh-mumtaz.ir | MX | mx.zoho.eu | off | auto | 10 |
| *.dnr.saleh-mumtaz.ir | NS | dnrr.saleh-mumtaz.ir | off | auto |  |
| *.nsr.saleh-mumtaz.ir | NS | nsrr.saleh-mumtaz.ir | off | auto |  |
| dnr.saleh-mumtaz.ir | NS | dnrr.saleh-mumtaz.ir | off | auto |  |
| nsr.saleh-mumtaz.ir | NS | nsrr.saleh-mumtaz.ir | off | auto |  |
| aggregator.saleh-mumtaz.ir | TXT | export default {  async fetch(req) {    try {      const url = new URL(req.url);      const splitted = url.pathname.replace(/^\/*/, '').split('/');      const address = splitted[0];      url.pathname = splitted.slice(1).join('/');      url.hostname = address;      url.protocol = 'https';      return fetch(new Request(url, req));    } catch (e) {      return new Response(e);    }  }}; | off | auto |  |
| saleh-mumtaz.ir | TXT | v=spf1 include:zoho.eu ~all | off | auto |  |
| saleh-mumtaz.ir | TXT | zoho-verification=zb45801592.zmverify.zoho.eu | off | auto |  |
| zmail._domainkey.saleh-mumtaz.ir | TXT | v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC3PClOpP7uwFlb807vIYjQi3tyguATFHR+3HgA9RaVwWAlkc9zesFAV/jAvHiBKwgLQ6b2yqjFuGsQf7Gwsyu37hg60imyxeJiHaCa648LDOstWyZL16QDhKWdmNCBsLQ3ihx/rDwHY1SZqiRlaAjFthXu2q/51+kTkBWZ42DNFwIDAQAB | off | auto |  |

### Zone `20030417.xyz` — 22 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|
| 20030417.xyz | A | 38.45.80.233 | off | auto |  |
| dnr.20030417.xyz | A | 38.45.80.233 | off | auto |  |
| dnrr.20030417.xyz | A | 38.45.80.233 | off | auto |  |
| downlink.20030417.xyz | A | 5.10.248.34 | **ON** 🟠 | auto |  |
| downstream.20030417.xyz | A | 5.10.248.34 | **ON** 🟠 | auto |  |
| nsr.20030417.xyz | A | 94.159.109.54 | off | auto |  |
| nsrr.20030417.xyz | A | 94.159.109.54 | off | auto |  |
| streamdown.20030417.xyz | A | 5.10.248.34 | **ON** 🟠 | auto |  |
| streamup.20030417.xyz | A | 5.10.248.34 | **ON** 🟠 | auto |  |
| uplink.20030417.xyz | A | 5.10.248.34 | **ON** 🟠 | auto |  |
| upstream.20030417.xyz | A | 5.10.248.34 | **ON** 🟠 | auto |  |
| www.20030417.xyz | A | 38.45.80.233 | off | auto |  |
| downlink6.20030417.xyz | AAAA | 2a07:4283:100:442:250:56ff:fead:d56a | **ON** 🟠 | auto |  |
| uplink6.20030417.xyz | AAAA | 2a07:4283:100:442:250:56ff:fead:d56a | **ON** 🟠 | auto |  |
| *.dnr.20030417.xyz | NS | dnr.20030417.xyz | off | auto |  |
| *.dnr.20030417.xyz | NS | dnrr.20030417.xyz | off | auto |  |
| *.nsr.20030417.xyz | NS | nsr.20030417.xyz | off | auto |  |
| *.nsr.20030417.xyz | NS | nsrr.20030417.xyz | off | auto |  |
| dnr.20030417.xyz | NS | dnr.20030417.xyz | off | auto |  |
| dnr.20030417.xyz | NS | dnrr.20030417.xyz | off | auto |  |
| nsr.20030417.xyz | NS | nsr.20030417.xyz | off | auto |  |
| nsr.20030417.xyz | NS | nsrr.20030417.xyz | off | auto |  |

### Zone `avistel.ir` — 23 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|
| *.avistel.ir | A | 94.159.109.54 | off | auto |  |
| arrow.avistel.ir | A | 85.198.11.7 | **ON** 🟠 | auto |  |
| avistel.ir | A | 94.159.109.54 | off | auto |  |
| dns.avistel.ir | A | 94.159.109.54 | off | auto |  |
| dnstt.avistel.ir | A | 94.159.109.54 | off | auto |  |
| downstream.avistel.ir | A | 188.212.99.71 | **ON** 🟠 | auto |  |
| nsr.avistel.ir | A | 38.45.80.233 | off | auto |  |
| nsrr.avistel.ir | A | 38.45.80.233 | off | auto |  |
| streamdown.avistel.ir | A | 5.10.248.167 | **ON** 🟠 | auto |  |
| streamup.avistel.ir | A | 5.10.248.167 | **ON** 🟠 | auto |  |
| upstream.avistel.ir | A | 188.212.99.71 | **ON** 🟠 | auto |  |
| www.avistel.ir | A | 94.159.109.54 | off | auto |  |
| argos.avistel.ir | CNAME | ef2ce531-a9d3-4d2b-bdba-6f1ccb4a7445.cfargotunnel.com | **ON** 🟠 | auto |  |
| relay.avistel.ir | CNAME | lminator-82ea83d9dc-313savior.apps.ir-northwest1.arvancaas.ir | **ON** 🟠 | auto |  |
| *.dns.avistel.ir | NS | dns.avistel.ir | off | auto |  |
| *.dns.avistel.ir | NS | dnstt.avistel.ir | off | auto |  |
| *.nsr.avistel.ir | NS | nsr.avistel.ir | off | auto |  |
| *.nsr.avistel.ir | NS | nsrr.avistel.ir | off | auto |  |
| dns.avistel.ir | NS | dns.avistel.ir | off | auto |  |
| dns.avistel.ir | NS | dnstt.avistel.ir | off | auto |  |
| nsr.avistel.ir | NS | nsr.avistel.ir | off | auto |  |
| nsr.avistel.ir | NS | nsrr.avistel.ir | off | auto |  |
| cdnverify.avistel.ir | TXT | "BnbqiC6GTVqNXt" | off | auto |  |

### Zone `knxv.ir` — 15 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|
| dns.knxv.ir | A | 38.45.80.233 | off | auto |  |
| dnstt.knxv.ir | A | 38.45.80.233 | off | auto |  |
| knxv.ir | A | 66.23.198.52 | off | auto |  |
| nsr.knxv.ir | A | 94.159.109.54 | off | auto |  |
| nsrr.knxv.ir | A | 94.159.109.54 | off | auto |  |
| www.knxv.ir | A | 66.23.198.52 | off | auto |  |
| ktz.knxv.ir | AAAA | 100:: | **ON** 🟠 | auto |  |
| *.dns.knxv.ir | NS | dns.knxv.ir | off | auto |  |
| *.dns.knxv.ir | NS | dnstt.knxv.ir | off | auto |  |
| *.nsr.knxv.ir | NS | nsr.knxv.ir | off | auto |  |
| *.nsr.knxv.ir | NS | nsrr.knxv.ir | off | auto |  |
| dns.knxv.ir | NS | dns.knxv.ir | off | auto |  |
| dns.knxv.ir | NS | dnstt.knxv.ir | off | auto |  |
| nsr.knxv.ir | NS | nsr.knxv.ir | off | auto |  |
| nsr.knxv.ir | NS | nsrr.knxv.ir | off | auto |  |

### Zone `southpark.ir` — 15 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|
| *.southpark.ir | A | 38.45.80.233 | off | auto |  |
| dnr.southpark.ir | A | 94.159.109.54 | off | auto |  |
| dnrr.southpark.ir | A | 94.159.109.54 | off | auto |  |
| nsr.southpark.ir | A | 38.45.80.233 | off | auto |  |
| nsrr.southpark.ir | A | 38.45.80.233 | off | auto |  |
| southpark.ir | A | 38.45.80.233 | off | auto |  |
| *.dnr.southpark.ir | NS | dnr.southpark.ir | off | auto |  |
| *.dnr.southpark.ir | NS | dnrr.southpark.ir | off | auto |  |
| *.nsr.southpark.ir | NS | nsr.southpark.ir | off | auto |  |
| *.nsr.southpark.ir | NS | nsrr.southpark.ir | off | auto |  |
| dnr.southpark.ir | NS | dnr.southpark.ir | off | auto |  |
| dnr.southpark.ir | NS | dnrr.southpark.ir | off | auto |  |
| nsr.southpark.ir | NS | nsr.southpark.ir | off | auto |  |
| nsr.southpark.ir | NS | nsrr.southpark.ir | off | auto |  |
| cdnverify.southpark.ir | TXT | "Yu3OAw7JBrpJPH" | off | auto |  |

### Zone `wille.ir` — 14 records
| Name | Type | Content | Proxied | TTL | Priority |
|---|---|---|---|---|---|
| *.wille.ir | A | 38.45.80.233 | **ON** 🟠 | auto |  |
| dns.wille.ir | A | 38.45.80.233 | off | auto |  |
| dnstt.wille.ir | A | 38.45.80.233 | off | auto |  |
| nsr.wille.ir | A | 94.159.109.54 | off | auto |  |
| nsrr.wille.ir | A | 94.159.109.54 | off | auto |  |
| wille.ir | A | 38.45.80.233 | **ON** 🟠 | auto |  |
| *.dns.wille.ir | NS | dns.wille.ir | off | auto |  |
| *.dns.wille.ir | NS | dnstt.wille.ir | off | auto |  |
| *.nsr.wille.ir | NS | nsr.wille.ir | off | auto |  |
| *.nsr.wille.ir | NS | nsrr.wille.ir | off | auto |  |
| dns.wille.ir | NS | dns.wille.ir | off | auto |  |
| dns.wille.ir | NS | dnstt.wille.ir | off | auto |  |
| nsr.wille.ir | NS | nsr.wille.ir | off | auto |  |
| nsr.wille.ir | NS | nsrr.wille.ir | off | auto |  |


---

## 7. Client Configurations (verbatim, 4 production configs)

All four: socks inbound 127.0.0.1:10808, VLESS outbound tag `proxy` with `mux.enabled=false`, freedom `direct`, blackhole `block`, dns-out; routing identical (IPOnDemand; UDP/443 block; private+IR direct; domestic-dns tags direct; dns-module->proxy); DNS = parallel query, Google/CF first (via proxy), TIC 217.218.127.127/.155 for ir/private with skipFallback; DoH hosts pinned; loglevel debug (recommend warning).

Shared VLESS identity: id `ec456111-79b2-411f-a34d-e50be2a54e76` (= inbound user `administrator`), encryption `mlkem768x25519plus.native.0rtt.QWoXJO-Jw_tShsUrQbB37bv46eSn99D8ky1_I42Cfh8`, path `/29117/zigen`, mode packet-up on the uplink leg.

### 7.1 cfg1 — `zeiss-administrator-venc` (plaintext split: DE up / CZ down)
Uplink: `94.159.109.54:80`, no TLS, H1.1, host www.avistel.ir. Downlink via downloadSettings: `38.45.80.233:80`, host www.southpark.ir.
Verdict: works (verified by live client log). Zero CDN exposure (#6554 immune). Least stealthy — plaintext HTTP to known VPS IPs, payload still VLESS-mlkem encrypted.

```json
{
  "dns": {
    "enableParallelQuery": true,
    "hosts": {
      "domain:googleapis.cn": "googleapis.com",
      "dns.alidns.com": ["223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1"],
      "dns.sse.cisco.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
      "dns.umbrella.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
      "one.one.one.one": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
      "1dot1dot1dot1.cloudflare-dns.com": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
      "dns.cloudflare.com": ["162.159.61.8", "172.64.41.8", "2a06:98c1:52::8", "2803:f800:53::8"],
      "cloudflare-dns.com": ["104.16.248.249", "104.16.249.249", "2606:4700::6810:f8f9", "2606:4700::6810:f9f9"],
      "engage.cloudflareclient.com": ["162.159.192.1", "2606:4700:d0::a29f:c001"],
      "doh.pub": ["1.12.12.12", "120.53.53.53"],
      "dot.pub": ["1.12.12.12", "120.53.53.53"],
      "dns.google": ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"],
      "dns.quad9.net": ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"],
      "dns.sb": ["45.11.45.11", "185.222.222.222", "2a09::", "2a11::"],
      "common.dot.dns.yandex.net": ["77.88.8.8", "77.88.8.1", "2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"]
    },
    "servers": [
      "8.8.8.8",
      "1.1.1.1",
      {"address": "217.218.127.127", "domains": ["geosite:private"], "skipFallback": true, "tag": "domestic-dns_0_0"},
      {"address": "217.218.155.155", "domains": ["geosite:private"], "skipFallback": true, "tag": "domestic-dns_0_1"},
      {"address": "217.218.127.127", "domains": ["domain:ir", "geosite:category-ir"], "skipFallback": true, "tag": "domestic-dns_1_0"},
      {"address": "217.218.155.155", "domains": ["domain:ir", "geosite:category-ir"], "skipFallback": true, "tag": "domestic-dns_1_1"}
    ],
    "tag": "dns-module"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true, "userLevel": 8},
      "sniffing": {"destOverride": [], "enabled": false, "routeOnly": false},
      "tag": "socks"
    }
  ],
  "log": {"loglevel": "debug"},
  "outbounds": [
    {
      "mux": {"concurrency": -1, "enabled": false},
      "protocol": "vless",
      "settings": {
        "address": "94.159.109.54",
        "encryption": "mlkem768x25519plus.native.0rtt.QWoXJO-Jw_tShsUrQbB37bv46eSn99D8ky1_I42Cfh8",
        "flow": "",
        "id": "ec456111-79b2-411f-a34d-e50be2a54e76",
        "level": 8,
        "port": 80
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "extra": {
            "xPaddingBytes": "100-1000",
            "downloadSettings": {
              "address": "38.45.80.233",
              "port": 80,
              "network": "xhttp",
              "xhttpSettings": {
                "path": "/29117/zigen",
                "host": "www.southpark.ir"
              }
            }
          },
          "host": "www.avistel.ir",
          "mode": "packet-up",
          "path": "/29117/zigen"
        }
      },
      "tag": "proxy"
    },
    {"protocol": "freedom", "streamSettings": {"network": "tcp", "sockopt": {"domainStrategy": "UseIP"}}, "tag": "direct"},
    {"protocol": "blackhole", "settings": {}, "tag": "block"},
    {"protocol": "dns", "tag": "dns-out"}
  ],
  "remarks": "zeiss-administrator-venc",
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {"inboundTag": ["socks"], "outboundTag": "dns-out", "port": "53", "type": "field"},
      {"ip": ["217.218.127.127", "217.218.155.155"], "outboundTag": "direct", "type": "field"},
      {"network": "udp", "outboundTag": "block", "port": "443", "type": "field"},
      {"ip": ["ext:geoip-only-cn-private.dat:private"], "outboundTag": "direct", "type": "field"},
      {"domain": ["geosite:private"], "outboundTag": "direct", "type": "field"},
      {"domain": ["domain:ir", "geosite:category-ir"], "outboundTag": "direct", "type": "field"},
      {"ip": ["geoip:ir"], "outboundTag": "direct", "type": "field"},
      {"inboundTag": ["domestic-dns_0_0", "domestic-dns_0_1", "domestic-dns_1_0", "domestic-dns_1_1"], "outboundTag": "direct", "type": "field"},
      {"inboundTag": ["dns-module"], "outboundTag": "proxy", "type": "field"}
    ]
  }
}
```

### 7.2 cfg2 — `zeiss-administrator-cdn-dw` (Arvan up / rprx-CDN down)
Uplink: down.elahe-rad.ir:443 TLS (Arvan; hosts-pinned to edge IPs; Arvan edge cert pinned via pinnedPeerCertSha256). Downlink: downcdn.rprx.ir:443 TLS (Bitcommand edge -> CZ origin).
Verdict: true cross-provider split; upload leg #6554-immune (short POSTs); exposure sits on rprx CDN idle timeout during heavy uploads. Cert pin brittle vs Arvan rotation.

```json
{
  "dns": {
    "enableParallelQuery": true,
    "hosts": {
      "domain:googleapis.cn": "googleapis.com",
      "dns.alidns.com": ["223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1"],
      "dns.sse.cisco.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
      "dns.umbrella.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
      "one.one.one.one": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
      "1dot1dot1dot1.cloudflare-dns.com": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
      "dns.cloudflare.com": ["162.159.61.8", "172.64.41.8", "2a06:98c1:52::8", "2803:f800:53::8"],
      "cloudflare-dns.com": ["104.16.248.249", "104.16.249.249", "2606:4700::6810:f8f9", "2606:4700::6810:f9f9"],
      "engage.cloudflareclient.com": ["162.159.192.1", "2606:4700:d0::a29f:c001"],
      "doh.pub": ["1.12.12.12", "120.53.53.53"],
      "dot.pub": ["1.12.12.12", "120.53.53.53"],
      "dns.google": ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"],
      "dns.quad9.net": ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"],
      "dns.sb": ["45.11.45.11", "185.222.222.222", "2a09::", "2a11::"],
      "common.dot.dns.yandex.net": ["77.88.8.8", "77.88.8.1", "2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"],
      "down.elahe-rad.ir": ["185.143.234.238", "185.143.233.238"]
    },
    "servers": [
      "8.8.8.8",
      "1.1.1.1",
      {"address": "217.218.127.127", "domains": ["geosite:private"], "skipFallback": true, "tag": "domestic-dns_0_0"},
      {"address": "217.218.155.155", "domains": ["geosite:private"], "skipFallback": true, "tag": "domestic-dns_0_1"},
      {"address": "217.218.127.127", "domains": ["domain:ir", "geosite:category-ir"], "skipFallback": true, "tag": "domestic-dns_1_0"},
      {"address": "217.218.155.155", "domains": ["domain:ir", "geosite:category-ir"], "skipFallback": true, "tag": "domestic-dns_1_1"}
    ],
    "tag": "dns-module"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true, "userLevel": 8},
      "sniffing": {"destOverride": [], "enabled": false, "routeOnly": false},
      "tag": "socks"
    }
  ],
  "log": {"loglevel": "debug"},
  "outbounds": [
    {
      "mux": {"concurrency": -1, "enabled": false},
      "protocol": "vless",
      "settings": {
        "address": "down.elahe-rad.ir",
        "encryption": "mlkem768x25519plus.native.0rtt.QWoXJO-Jw_tShsUrQbB37bv46eSn99D8ky1_I42Cfh8",
        "flow": "",
        "id": "ec456111-79b2-411f-a34d-e50be2a54e76",
        "level": 8,
        "port": 443
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "sockopt": {
          "domainStrategy": "UseIP",
          "happyEyeballs": {"interleave": 2, "maxConcurrentTry": 4, "prioritizeIPv6": false, "tryDelayMs": 250}
        },
        "tlsSettings": {
          "allowInsecure": false,
          "alpn": ["h2", "http/1.1"],
          "fingerprint": "chrome",
          "pinnedPeerCertSha256": "15e6c79437cbb2fc566f1d139c6a6b3b6b3c1a8d505ac3d411371cfb27423875",
          "serverName": "down.elahe-rad.ir"
        },
        "xhttpSettings": {
          "extra": {
            "xPaddingBytes": "100-1000",
            "downloadSettings": {
              "address": "downcdn.rprx.ir",
              "port": 443,
              "network": "xhttp",
              "security": "tls",
              "tlsSettings": {
                "serverName": "downcdn.rprx.ir",
                "alpn": ["h2", "http/1.1"],
                "fingerprint": "chrome"
              },
              "xhttpSettings": {
                "path": "/29117/zigen",
                "host": "downcdn.rprx.ir",
                "mode": "auto"
              }
            }
          },
          "host": "down.elahe-rad.ir",
          "mode": "packet-up",
          "path": "/29117/zigen"
        }
      },
      "tag": "proxy"
    },
    {"protocol": "freedom", "streamSettings": {"network": "tcp", "sockopt": {"domainStrategy": "UseIP"}}, "tag": "direct"},
    {"protocol": "blackhole", "settings": {}, "tag": "block"},
    {"protocol": "dns", "tag": "dns-out"}
  ],
  "remarks": "zeiss-administrator-cdn-dw",
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {"inboundTag": ["socks"], "outboundTag": "dns-out", "port": "53", "type": "field"},
      {"ip": ["217.218.127.127", "217.218.155.155"], "outboundTag": "direct", "type": "field"},
      {"network": "udp", "outboundTag": "block", "port": "443", "type": "field"},
      {"ip": ["ext:geoip-only-cn-private.dat:private"], "outboundTag": "direct", "type": "field"},
      {"domain": ["geosite:private"], "outboundTag": "direct", "type": "field"},
      {"domain": ["domain:ir", "geosite:category-ir"], "outboundTag": "direct", "type": "field"},
      {"ip": ["geoip:ir"], "outboundTag": "direct", "type": "field"},
      {"inboundTag": ["domestic-dns_0_0", "domestic-dns_0_1", "domestic-dns_1_0", "domestic-dns_1_1"], "outboundTag": "direct", "type": "field"},
      {"inboundTag": ["dns-module"], "outboundTag": "proxy", "type": "field"}
    ]
  }
}
```

### 7.3 cfg3 — `zeiss-administrator-upzyklon-downwille` (Arvan up / Cloudflare down)
Uplink: up.zyklon.ir:443 TLS (Arvan, pinned). Downlink: down.wille.ir:443 TLS — CF zone wille.ir has `*.wille.ir A 38.45.80.233` PROXIED ON, so CF pulls from CZ:443 directly (bypasses DE). No cert pin (correct — CF rotates edge certs).
Verdict: strongest public-side separation; CF ~100 s idle applies to download GET during heavy uploads.

```json
{
  "dns": {
    "enableParallelQuery": true,
    "hosts": {
      "domain:googleapis.cn": "googleapis.com",
      "dns.alidns.com": ["223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1"],
      "dns.sse.cisco.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
      "dns.umbrella.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
      "one.one.one.one": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
      "1dot1dot1dot1.cloudflare-dns.com": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
      "dns.cloudflare.com": ["162.159.61.8", "172.64.41.8", "2a06:98c1:52::8", "2803:f800:53::8"],
      "cloudflare-dns.com": ["104.16.248.249", "104.16.249.249", "2606:4700::6810:f8f9", "2606:4700::6810:f9f9"],
      "engage.cloudflareclient.com": ["162.159.192.1", "2606:4700:d0::a29f:c001"],
      "doh.pub": ["1.12.12.12", "120.53.53.53"],
      "dot.pub": ["1.12.12.12", "120.53.53.53"],
      "dns.google": ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"],
      "dns.quad9.net": ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"],
      "dns.sb": ["45.11.45.11", "185.222.222.222", "2a09::", "2a11::"],
      "common.dot.dns.yandex.net": ["77.88.8.8", "77.88.8.1", "2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"],
      "up.zyklon.ir": ["185.143.233.238", "185.143.234.238"]
    },
    "servers": [
      "8.8.8.8",
      "1.1.1.1",
      {"address": "217.218.127.127", "domains": ["geosite:private"], "skipFallback": true, "tag": "domestic-dns_0_0"},
      {"address": "217.218.155.155", "domains": ["geosite:private"], "skipFallback": true, "tag": "domestic-dns_0_1"},
      {"address": "217.218.127.127", "domains": ["domain:ir", "geosite:category-ir"], "skipFallback": true, "tag": "domestic-dns_1_0"},
      {"address": "217.218.155.155", "domains": ["domain:ir", "geosite:category-ir"], "skipFallback": true, "tag": "domestic-dns_1_1"}
    ],
    "tag": "dns-module"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true, "userLevel": 8},
      "sniffing": {"destOverride": [], "enabled": false, "routeOnly": false},
      "tag": "socks"
    }
  ],
  "log": {"loglevel": "debug"},
  "outbounds": [
    {
      "mux": {"concurrency": -1, "enabled": false},
      "protocol": "vless",
      "settings": {
        "address": "up.zyklon.ir",
        "encryption": "mlkem768x25519plus.native.0rtt.QWoXJO-Jw_tShsUrQbB37bv46eSn99D8ky1_I42Cfh8",
        "flow": "",
        "id": "ec456111-79b2-411f-a34d-e50be2a54e76",
        "level": 8,
        "port": 443
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "sockopt": {
          "domainStrategy": "UseIP",
          "happyEyeballs": {"interleave": 2, "maxConcurrentTry": 4, "prioritizeIPv6": false, "tryDelayMs": 250}
        },
        "tlsSettings": {
          "allowInsecure": false,
          "alpn": ["h2", "http/1.1"],
          "fingerprint": "chrome",
          "serverName": "up.zyklon.ir"
        },
        "xhttpSettings": {
          "extra": {
            "xPaddingBytes": "100-1000",
            "downloadSettings": {
              "address": "down.wille.ir",
              "port": 443,
              "network": "xhttp",
              "security": "tls",
              "tlsSettings": {
                "serverName": "down.wille.ir",
                "alpn": ["h2", "http/1.1"],
                "fingerprint": "chrome"
              },
              "xhttpSettings": {
                "path": "/29117/zigen",
                "host": "down.wille.ir",
                "mode": "auto"
              }
            }
          },
          "host": "up.zyklon.ir",
          "mode": "packet-up",
          "path": "/29117/zigen"
        }
      },
      "tag": "proxy"
    },
    {"protocol": "freedom", "streamSettings": {"network": "tcp", "sockopt": {"domainStrategy": "UseIP"}}, "tag": "direct"},
    {"protocol": "blackhole", "settings": {}, "tag": "block"},
    {"protocol": "dns", "tag": "dns-out"}
  ],
  "remarks": "zeiss-administrator-upzyklon-downwille",
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {"inboundTag": ["socks"], "outboundTag": "dns-out", "port": "53", "type": "field"},
      {"ip": ["217.218.127.127", "217.218.155.155"], "outboundTag": "direct", "type": "field"},
      {"network": "udp", "outboundTag": "block", "port": "443", "type": "field"},
      {"ip": ["ext:geoip-only-cn-private.dat:private"], "outboundTag": "direct", "type": "field"},
      {"domain": ["geosite:private"], "outboundTag": "direct", "type": "field"},
      {"domain": ["domain:ir", "geosite:category-ir"], "outboundTag": "direct", "type": "field"},
      {"ip": ["geoip:ir"], "outboundTag": "direct", "type": "field"},
      {"inboundTag": ["domestic-dns_0_0", "domestic-dns_0_1", "domestic-dns_1_0", "domestic-dns_1_1"], "outboundTag": "direct", "type": "field"},
      {"inboundTag": ["dns-module"], "outboundTag": "proxy", "type": "field"}
    ]
  }
}
```

### 7.4 cfg4 — `zeiss-administrator-cdn-rprx` (rprx up / rprx down)
Both legs pinned/unpinned to the same Bitcommand edge 185.239.1.100 (authoritative DNS confirms identical IP).
Verdict: functional but zero public-IP separation — DPI sees one correlated flow pair; only edge-to-origin differs (upcdn->DE, downcdn->CZ).

```json
{
  "dns": {
    "enableParallelQuery": true,
    "hosts": {
      "domain:googleapis.cn": "googleapis.com",
      "dns.alidns.com": ["223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1"],
      "dns.sse.cisco.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
      "dns.umbrella.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
      "one.one.one.one": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
      "1dot1dot1dot1.cloudflare-dns.com": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
      "dns.cloudflare.com": ["162.159.61.8", "172.64.41.8", "2a06:98c1:52::8", "2803:f800:53::8"],
      "cloudflare-dns.com": ["104.16.248.249", "104.16.249.249", "2606:4700::6810:f8f9", "2606:4700::6810:f9f9"],
      "engage.cloudflareclient.com": ["162.159.192.1", "2606:4700:d0::a29f:c001"],
      "doh.pub": ["1.12.12.12", "120.53.53.53"],
      "dot.pub": ["1.12.12.12", "120.53.53.53"],
      "dns.google": ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"],
      "dns.quad9.net": ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"],
      "dns.sb": ["45.11.45.11", "185.222.222.222", "2a09::", "2a11::"],
      "common.dot.dns.yandex.net": ["77.88.8.8", "77.88.8.1", "2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"],
      "upcdn.rprx.ir": "185.239.1.100"
    },
    "servers": [
      "8.8.8.8",
      "1.1.1.1",
      {"address": "217.218.127.127", "domains": ["geosite:private"], "skipFallback": true, "tag": "domestic-dns_0_0"},
      {"address": "217.218.155.155", "domains": ["geosite:private"], "skipFallback": true, "tag": "domestic-dns_0_1"},
      {"address": "217.218.127.127", "domains": ["domain:ir", "geosite:category-ir"], "skipFallback": true, "tag": "domestic-dns_1_0"},
      {"address": "217.218.155.155", "domains": ["domain:ir", "geosite:category-ir"], "skipFallback": true, "tag": "domestic-dns_1_1"}
    ],
    "tag": "dns-module"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true, "userLevel": 8},
      "sniffing": {"destOverride": [], "enabled": false, "routeOnly": false},
      "tag": "socks"
    }
  ],
  "log": {"loglevel": "debug"},
  "outbounds": [
    {
      "mux": {"concurrency": -1, "enabled": false},
      "protocol": "vless",
      "settings": {
        "address": "upcdn.rprx.ir",
        "encryption": "mlkem768x25519plus.native.0rtt.QWoXJO-Jw_tShsUrQbB37bv46eSn99D8ky1_I42Cfh8",
        "flow": "",
        "id": "ec456111-79b2-411f-a34d-e50be2a54e76",
        "level": 8,
        "port": 443
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "sockopt": {
          "domainStrategy": "UseIP",
          "happyEyeballs": {"interleave": 2, "maxConcurrentTry": 4, "prioritizeIPv6": false, "tryDelayMs": 250}
        },
        "tlsSettings": {
          "allowInsecure": false,
          "alpn": ["h2", "http/1.1"],
          "fingerprint": "chrome",
          "serverName": "upcdn.rprx.ir"
        },
        "xhttpSettings": {
          "extra": {
            "xPaddingBytes": "100-1000",
            "downloadSettings": {
              "address": "downcdn.rprx.ir",
              "port": 443,
              "network": "xhttp",
              "security": "tls",
              "tlsSettings": {
                "serverName": "downcdn.rprx.ir",
                "alpn": ["h2", "http/1.1"],
                "fingerprint": "chrome"
              },
              "xhttpSettings": {
                "path": "/29117/zigen",
                "host": "downcdn.rprx.ir",
                "mode": "auto"
              }
            }
          },
          "host": "upcdn.rprx.ir",
          "mode": "packet-up",
          "path": "/29117/zigen"
        }
      },
      "tag": "proxy"
    },
    {"protocol": "freedom", "streamSettings": {"network": "tcp", "sockopt": {"domainStrategy": "UseIP"}}, "tag": "direct"},
    {"protocol": "blackhole", "settings": {}, "tag": "block"},
    {"protocol": "dns", "tag": "dns-out"}
  ],
  "remarks": "zeiss-administrator-cdn-rprx",
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {"inboundTag": ["socks"], "outboundTag": "dns-out", "port": "53", "type": "field"},
      {"ip": ["217.218.127.127", "217.218.155.155"], "outboundTag": "direct", "type": "field"},
      {"network": "udp", "outboundTag": "block", "port": "443", "type": "field"},
      {"ip": ["ext:geoip-only-cn-private.dat:private"], "outboundTag": "direct", "type": "field"},
      {"domain": ["geosite:private"], "outboundTag": "direct", "type": "field"},
      {"domain": ["domain:ir", "geosite:category-ir"], "outboundTag": "direct", "type": "field"},
      {"ip": ["geoip:ir"], "outboundTag": "direct", "type": "field"},
      {"inboundTag": ["domestic-dns_0_0", "domestic-dns_0_1", "domestic-dns_1_0", "domestic-dns_1_1"], "outboundTag": "direct", "type": "field"},
      {"inboundTag": ["dns-module"], "outboundTag": "proxy", "type": "field"}
    ]
  }
}
```


---

## 8. Cross-Evaluation: DNS x nginx x xray x clients (2026-08-25 audit)

- Every hostname used by any client config has a matching vhost (`server_name DOMAIN *.DOMAIN`) with passing host/SNI gates.
- Wildcard LE certs cover every used subdomain; CF-proxied legs present CF edge certs to clients instead (expected).
- Path `/29117/zigen` matches the nginx regex location -> `proxy_pass http://127.0.0.1:29117` -> xray inbound (post-migration TCP, verified listening via ss).
- Mode auto on inbound accepts packet-up POSTs + stream-down GETs from every leg.
- Live probes: Arvan POST 200; rprx CDN both names 200; CZ:80 direct 200; DE:80 forward works for real clients (a self-probe from CZ fails only due to post-DNAT source==destination martian drop — hairpin artifact, not a fault).
- Real user traffic observed on multiple legs simultaneously (Iranian source IPs incl. TCI ranges).

Findings & recommendations:
1. Pin `downcdn.rprx.ir -> 185.239.1.100` in dns.hosts (cfg2/4) — single stable edge, cheap poisoning immunity.
2. Drop cfg2's Arvan edge-cert pin unless deliberate MITM-hardening (breaks on rotation).
3. Prefer cfg2/cfg3 daily; cfg4 only when needed; cfg1 = zero-TLS emergency path.
4. Verify Arvan panel origins for up.zyklon.ir / down.elahe-rad.ir (only unauditable piece from this box).
5. Set client loglevel warning; optionally add expectIPs geoip:ir to domestic resolvers.
6. Unused-but-provisioned infrastructure found: avistel upstream/stream* -> 188.212.99.71 / 5.10.248.167 (proxied); 20030417.xyz uplink/downlink/streamup/streamdown + AAAA v6 -> 5.10.248.34 (proxied); Gcore pair on iran-liberation-army.eu.org (gcdn.co CNAMEs); third origin server knxv.ir -> 66.23.198.52; dnstt.{avistel,knxv,wille}.ir DNS-tunnel fallback names; self-hosted NS lattice dnr/dnrr/nsr/nsrr alternating DE/CZ per zone; magi.anjomansut.ir empty zone; Zoho mail+DKIM on saleh-* zones; aggregator.saleh-mumtaz.ir TXT holds Worker JS.

## 9. Operational Playbook

Symptom table:
| Symptom | Cause | Fix |
|---|---|---|
| INTERNAL_ERROR ~60 s through CDN | #6554 download GET idle-close | direct IP, stream-up+scStreamUpServerSecs, or PR #6562 |
| silent wedge, kbit/s trickle, no logs | same, sticky variant | same |
| unexpected status 502 / bad status code 504 through CDN | same family | same |
| upstream timed out (110) with grpc:// upstream | connect/read timeout — listener dead or not speaking h2c (see §5.1; NOT trailer-waiting) | verify xray listener is up and speaks h2c; proxy_pass is the safe default for the generic location |
| connect() ENOENT at fixed daily time | UDS restart race (historic) | TCP revert applied v6.1.0 |
| malformed HTTP response client-side | ALPN h1 only | keep h2 in ALPN |
| invalid x_padding length:0 -> 400 | CDN strips query param (#4501) | avoid that CDN or padding mode |

Debug steps: xray -test config; split client vs server (same config CLI); server loglevel debug shows routing decisions; check `ss -tlnp` for 127.0.0.1:PORT listener; curl fake-site 200 masking means external probes can't distinguish — test real traffic from clients.

## 10. Alternative architecture: xray-fronted (documented option)

xray terminates TLS itself on public :443 (security tls/reality), nginx demoted to fake-site decoy on non-public port (:8080) or :80-only redirect. All xhttp modes work natively; H3/QUIC possible; REALITY possible; no grpc_pass concerns ever. Trade-offs: larger xray attack surface, cert management inside panel/xray, no nginx proxy niceties. Migration sketch: change inbound listen/port+security+certs; strip nginx proxy blocks keeping decoy; open firewall for 443; switch clients to domain+TLS configs.

## 11. References

- XHTTP discussion #4113 (salehMomtaz/proxyWars mirror was xhttp_en.md)
- Issues/PRs: #6554 (closed not_planned), #6561 Mux.Cool keepalive, #6562 stream-down alive, #6632 GetBody/GOAWAY, #4846 packet-down, #4306 scStreamUpServerSecs origin
- hub.go transport/internet/splithttp (v26.7.28): UDS listener port==0; SetHTTP1+SetUnencryptedHTTP2; stream-up padding goroutine lines ~218-229; GET handler lines ~356-396 without keepalive
- nginx docs: ngx_http_grpc_module (transparent HTTP/2 passthrough — does NOT parse gRPC trailers), ngx_http_proxy_module (buffering/timeouts/socket_keepalive)
- Installer: /home/dev/mimo/xui-lite.sh v6.1.0; migration: /home/dev/mimo/apply-tcp-revert.sh
