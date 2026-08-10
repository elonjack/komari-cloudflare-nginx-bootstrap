# Komari + Cloudflare + Nginx bootstrap

Safely moves an existing Docker-based [Komari](https://github.com/komari-monitor/komari) panel behind Nginx and Cloudflare on **Debian 13**.

It changes an existing public Komari port mapping to `127.0.0.1:25774:25774`. Nginx provides **HTTPS only** on port 443. The existing `/app/data` bind mount is detected and retained.

## What the script does

- Validates that the supplied Cloudflare Origin Certificate and private key match.
- Installs and enables Nginx.
- Creates a TLS Nginx reverse proxy with WebSocket support required by Komari.
- Does not create an HTTP listener for Komari; the VPS firewall only needs to allow TCP 443.
- Preserves the old Komari container as a stopped, timestamped rollback container.
- Creates the replacement container without pulling a new image or deleting data.
- Optionally enables Debian unattended **security** updates, which include Nginx security updates.
- Tests the Nginx configuration and the local Komari endpoint before reporting success.

It never prints certificate keys, opens firewall ports, disables a firewall, changes SSH settings, installs Docker, or uploads any secret.

## Before running

1. In Cloudflare DNS, create a hostname such as `komari.example.com` as an `A` record pointing at the VPS and keep it **proxied** (orange cloud).
2. In **SSL/TLS → Origin Server → Create certificate**, use “Cloudflare generates a private key and a CSR”. Ensure the certificate lists your hostname or a matching one-level wildcard (for example, `*.example.com` covers `komari.example.com`). Create the certificate and copy both output blocks before leaving the page.
3. On the VPS, save the two Cloudflare values to files. Do not paste either value into shell history or commit it to Git.

   Create the protected directory and open the certificate file:

   ```bash
   install -d -m 0700 /root/komari-origin
   nano /root/komari-origin/origin.pem
   ```

   Paste the entire **Origin Certificate**, including its `BEGIN CERTIFICATE` and `END CERTIFICATE` lines. Save in Nano with `Ctrl+O`, press `Enter` to confirm the file name, then exit with `Ctrl+X`.

   Open the private-key file:

   ```bash
   nano /root/komari-origin/origin.key
   ```

   Paste the entire **Private Key**, including its `BEGIN PRIVATE KEY` and `END PRIVATE KEY` lines. Again use `Ctrl+O`, `Enter`, then `Ctrl+X` to save and exit. Finally restrict the key file:

   ```bash
   chmod 600 /root/komari-origin/origin.key
   ls -l /root/komari-origin
   ```

   The final command should show both files. Do not post their contents anywhere.

4. Confirm that your existing SSH port plus **TCP 443** are permitted by the VPS provider and host firewall. Do **not** open TCP 80, Komari's internal port, or its former public port.

## Run

Run these commands as root. They download the current script, make it executable, and start its interactive setup:

```bash
mkdir -p /root/komari-bootstrap
cd /root/komari-bootstrap
curl --proto '=https' --tlsv1.2 -fLO https://raw.githubusercontent.com/elonjack/komari-cloudflare-nginx-bootstrap/main/komari-cloudflare-nginx.sh
chmod 700 komari-cloudflare-nginx.sh
./komari-cloudflare-nginx.sh \
  --cert-file /root/komari-origin/origin.pem \
  --key-file /root/komari-origin/origin.key \
  --enable-security-updates
```

The script asks for the public Komari domain. Type your own domain there, then press `Enter`. It then asks for confirmation before it changes Nginx or replaces the running Komari container. Enter `y` to continue. Do not add `--yes` unless you have already checked every path and option.

If you prefer not to use the interactive domain prompt, replace `komari.example.com` below with your own domain, then run:

```bash
./komari-cloudflare-nginx.sh \
  --domain komari.example.com \
  --cert-file /root/komari-origin/origin.pem \
  --key-file /root/komari-origin/origin.key \
  --enable-security-updates
```

## After the script completes

In Cloudflare:

1. Go to **SSL/TLS → Overview** and set encryption mode to **Full (strict)**.
2. Enable **Always Use HTTPS**. Cloudflare redirects HTTP at its edge; the VPS does not need TCP 80 open.
3. Visit `https://komari.example.com`.

Cloudflare's orange cloud hides the origin IP from normal DNS responses, but it does not itself make the origin inaccessible. For stronger protection, use the optional Authenticated Origin Pulls setup below. Alternatively, restrict TCP 443 at the firewall to Cloudflare IP ranges; maintain those ranges carefully as Cloudflare can update them.

### Optional: Authenticated Origin Pulls (stronger origin protection)

This prevents direct HTTPS clients from reaching Nginx even if they know the origin IP. Follow Cloudflare's [global AOP setup](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/global/) to download its public Origin Pull CA certificate and enable global AOP for the zone. Save that CA PEM on the VPS, then run the script with:

```bash
./komari-cloudflare-nginx.sh \
  --domain komari.example.com \
  --cert-file /root/komari-origin/origin.pem \
  --key-file /root/komari-origin/origin.key \
  --cloudflare-aop-ca-file /root/komari-origin/cloudflare-aop-ca.pem \
  --enable-security-updates
```

Only use this option after enabling AOP in Cloudflare; otherwise Cloudflare cannot complete the TLS handshake to the origin.

## Security baseline

After setup, keep these controls in place:

- Use a unique, high-entropy Komari administrator password and enable two-factor authentication.
- Disable remote terminal and command execution on every Komari Agent with `--disable-web-ssh`.
- Keep the Cloudflare DNS record proxied, use **Full (strict)**, and never set the zone to Flexible mode.
- Remove the former Komari port from the cloud firewall/security group after verifying the HTTPS URL.
- Run the script with `--enable-security-updates` to install Debian security updates automatically. This applies Nginx security fixes; it does not indiscriminately upgrade all packages.

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
ss -ltnp | grep -E ':(443|25774)\\b'
nginx -t
curl -I https://komari.example.com
```

Expected result: Nginx listens publicly on `443`; Docker listens only at `127.0.0.1:25774`; no Docker port is published publicly.

## License

MIT. See [LICENSE](LICENSE).
