# OpenPath Linux Agent Troubleshooting

> Status: maintained
> Applies to: `linux/`
> Last verified: 2026-04-13
> Source of truth: `linux/TROUBLESHOOTING.md`

## First Checks

```bash
sudo openpath status
sudo openpath health
sudo openpath test
sudo openpath log 100
```

## Important Services

```bash
systemctl status dnsmasq
systemctl status openpath-dnsmasq.timer
systemctl status openpath-agent-update.timer
systemctl status dnsmasq-watchdog.timer
systemctl status captive-portal-detector.service
systemctl status openpath-sse-listener.service
```

## Common Symptoms

### DNS does not resolve

```bash
sudo systemctl restart dnsmasq
sudo openpath update
ss -ulnp | grep :53
```

### Rules changed upstream but the machine did not update

```bash
sudo systemctl restart openpath-sse-listener.service
sudo openpath update
sudo openpath force
```

### Firefox-approved page dependencies still fail

Firefox runtime dependencies are local-only. The browser native host writes a
small queue entry and the root-owned Linux agent validates it before adding a
temporary `dnsmasq` overlay entry.

```bash
sudo systemctl status openpath-runtime-dependency-apply.path
sudo systemctl status openpath-runtime-dependency-apply.service
sudo ls -la /var/lib/openpath/runtime-dependency-queue
sudo jq . /var/lib/openpath/runtime-dependency-overlay.json
sudo openpath status
```

### Browser unblock request says configuration is incomplete

If the blocked page shows `No se pudo enviar la solicitud` and mentions
incomplete configuration for domain requests, the machine has browser request
UI without the required API/enrollment state.

```bash
sudo openpath status
test -s /etc/openpath/api-url.conf
test -s /etc/openpath/whitelist-url.conf
```

`sudo openpath status` must show `Enrolled: YES` and
`Solicitudes: configuradas`. If it does not, rerun setup with a fresh classroom
enrollment command, for example:

```bash
sudo openpath setup --api-url "https://api.example.com" --classroom-id "<classroom-id>" --enrollment-token "<token>"
```

After setup succeeds, run:

```bash
sudo openpath self-update --force
sudo openpath update
```

### Watchdog or integrity fallback triggered

```bash
sudo openpath health
sudo openpath log 200 | grep -E 'WATCHDOG|INTEGRITY|FAIL_OPEN|STALE_FAILSAFE|TAMPERED'
ls -l /var/lib/openpath/
```

### Self-update or package rollback questions

```bash
sudo openpath self-update --check
dpkg -s openpath-dnsmasq
```

## Useful Files

- `/etc/openpath/whitelist-url.conf`
- `/etc/openpath/api-url.conf`
- `/etc/openpath/classroom.conf`
- `/etc/openpath/classroom-id.conf`
- `/etc/openpath/overrides.conf`
- `/var/lib/openpath/health-status`
- `/var/lib/openpath/watchdog-fails`
- `/var/lib/openpath/integrity.sha256`
- `/var/lib/openpath/runtime-dependency-queue/`
- `/var/lib/openpath/runtime-dependency-overlay.json`
- `/var/log/openpath.log`
- `/var/log/captive-portal-detector.log`
