# Komari + Cloudflare + Nginx bootstrap

Safely moves an existing Docker-based [Komari](https://github.com/komari-monitor/komari) panel behind Nginx and Cloudflare on **Debian 13**.

It changes an existing public Komari port mapping to `127.0.0.1:25774:25774`. Nginx then provides public HTTPS on port 443. The existing `/app/data` bind mount is detected and retained.

## What the script does

- Validates that the supplied Cloudflare Origin Certificate and private key match.
- Installs and enables Nginx.
- Creates a TLS Nginx reverse proxy with WebSocket support required by Komari.
- Preserves the old Komari container as a stopped, timestamped rollback container.
- Creates the replacement container without pulling a new image or deleting data.
- Optionally enables Debian unattended **security** updates, which include Nginx security updates.
- Tests the Nginx configuration and the local Komari endpoint before reporting success.

It never prints certificate keys, opens firewall ports, disables a firewall, changes SSH settings, installs Docker, or uploads any secret.

## Before running

1. In Cloudflare DNS, create a hostname such as `komari.example.com` as an `A` record pointing at the VPS and keep it **proxied** (orange cloud).
2. In **SSL/TLS → Origin Server → Create certificate**, use “Cloudflare generates a private key and a CSR”. Ensure the certificate lists your hostname or a matching one-level wildcard (for example, `*.example.com` covers `komari.example.com`). Create the certificate and copy both output blocks before leaving the page.
3. On the VPS, create two files. Do not paste these values into shell history or commit them to Git.

   ```bash
   install -d -m 0700 /root/komari-origin
   nano /root/komari-origin/origin.pem
   nano /root/komari-origin/origin.key
   chmod 600 /root/komari-origin/origin.key
   ```

   Paste the Origin Certificate into `origin.pem` and the private key into `origin.key`.

4. Confirm that your existing SSH port plus TCP ports 80 and 443 are permitted by the VPS provider and host firewall. Do **not** leave Komari's internal or former public port open.

## Run

Download a released copy of the script, inspect it, then run it as root:

```bash
chmod 700 komari-cloudflare-nginx.sh
./komari-cloudflare-nginx.sh \
  --domain komari.example.com \
  --cert-file /root/komari-origin/origin.pem \
  --key-file /root/komari-origin/origin.key \
  --enable-security-updates
```

It asks for confirmation before it changes Nginx or replaces the running Komari container. Add `--yes` only after reading the script and confirming the paths.

## After the script completes

In Cloudflare:

1. Go to **SSL/TLS → Overview** and set encryption mode to **Full (strict)**.
2. Enable **Always Use HTTPS**.
3. Visit `https://komari.example.com`.

Cloudflare's orange cloud hides the origin IP from normal DNS responses, but it does not itself make the origin inaccessible. For stricter origin protection, enable Cloudflare Authenticated Origin Pulls or restrict ports 80/443 at the firewall to Cloudflare IP ranges.

## Rollback

The script retains a stopped container named similar to `komari-before-nginx-20260810120000`.

To roll back, replace `BACKUP_NAME` with that name:

```bash
docker stop komari
docker rm komari
docker rename BACKUP_NAME komari
docker start komari
```

This restores the old public port mapping. It does not delete the Komari data directory.

## Verification

```bash
docker ps
ss -ltnp | grep -E ':(80|443|25774)\\b'
nginx -t
curl -I https://komari.example.com
```

Expected result: Nginx listens publicly on `80` and `443`; Docker listens only at `127.0.0.1:25774`; no Docker port is published publicly.

## License

MIT. See [LICENSE](LICENSE).
