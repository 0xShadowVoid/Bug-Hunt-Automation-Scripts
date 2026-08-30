# Scan Notify

`scan.sh` is a small VPS helper for running long-running security/recon scans in the background.

It was originally created because bug-hunting/recon scans can take a long time. Instead of keeping an SSH session open and manually managing `nohup`, the script handles the background process, PID files, logs, status checks, stopping scans, and notifications.

> Use this only against domains and systems you are authorized to test.

---

## Features

- Run a scan in the background with one simple command.
- Works with any scanner — a single binary or a multi-tool pipeline script — via `SCANNER_CMD` in `config.env`.
- Automatically create a separate directory for each target.
- Automatically save scan logs.
- Track the running process with a PID file.
- Prevent accidentally starting the same target twice (file-locked, race-safe).
- Check whether a target is still running.
- Follow live output with `tail -f`.
- Stop a running scan.
- List all currently running scans.
- Send start/finish/failure notifications to Discord.
- Send start/finish/failure notifications to Telegram.
- Optionally zip each target's result directory and send it as a file attachment to Discord/Telegram.
- Optional bundled recon pipeline (`pipeline.sh`): subfinder → dnsx → httpx → nuclei, with status-code filtering and keyword matching, forwarded as a separate "Findings" notification.
- Automatically calculate and report scan duration.

---

## Directory Structure

After running a scan, the project will look like:

```text
scanner/
├── scan.sh
├── pipeline.sh          (optional bundled recon pipeline)
├── config.env
├── .gitignore
└── scans/
    └── target.com/
        ├── scan.log
        ├── scan.pid
        ├── scan.done
        └── target.com_results.zip   (if RESULTS_ZIP="true")
```

`config.env` contains secrets, so do NOT commit it to Git.

Recommended `.gitignore`:

```gitignore
config.env
scans/
```

---

## Requirements

`scan.sh` itself only needs:

- Bash
- `curl`
- `flock` (usually preinstalled on Linux; part of `util-linux`)
- Whatever scanner you point `SCANNER_CMD` at — a single tool (`pegpon`, `nmap`, `nuclei`, ...) or the bundled `pipeline.sh`
- A Discord webhook (optional)
- A Telegram bot (optional)

Check the basic commands:

```bash
bash --version
curl --version
flock --version
```

If using `pegpon` as the scanner:

```bash
pegpon --help
```

If using the bundled `pipeline.sh` (see [Custom Scanner Pipeline](#custom-scanner-pipeline) below), it additionally expects `subfinder`, `dnsx`, `httpx`, `nuclei`, and `jq` — each stage is skipped gracefully if its tool isn't installed, so a partial toolset still runs without crashing.

For zip attachments (`RESULTS_ZIP="true"`), `zip` must be installed.

Make the scripts executable:

```bash
chmod +x scan.sh
chmod +x pipeline.sh   # if using the bundled pipeline
```

---

# Usage

## Start a scan

```bash
./scan.sh target.com
```

The script automatically:

1. Creates `scans/target.com/`
2. Starts `pegpon -d target.com` in the background
3. Creates a PID file
4. Saves the output to `scan.log`
5. Sends a "scan started" notification
6. Sends a success/failure notification when the process finishes

You no longer need to manually use:

```bash
nohup ./scan-notify.sh target.com > target_scan.log 2>&1 &
```

The script handles the background execution itself.

---

## Check Scan Status

```bash
./scan.sh status target.com
```

Example:

```text
======================================
Target: target.com
======================================
Status: RUNNING
PID   : 28491
Log   : /root/scanner/scans/target.com/scan.log
```

After completion, the status command can also show information from `scan.done`.

---

## View Live Logs

```bash
./scan.sh logs target.com
```

This follows the scan output live.

Press:

```text
Ctrl+C
```

to stop viewing the log.

This does NOT stop the scan itself.

---

## Stop a Scan

```bash
./scan.sh stop target.com
```

The script sends a normal termination signal first. If the process does not stop, it falls back to `SIGKILL`.

---

## List All Running Scans

```bash
./scan.sh list
```

Example:

```text
Running scans:

  target.com                         PID: 28491
  example.org                        PID: 29102
  testsite.com                       PID: 29441
```

---

# Configuring the Scanner (`SCANNER_CMD`)

`scan.sh` doesn't run any specific tool itself — it runs whatever you set as `SCANNER_CMD` in `config.env`, passing the target as the final argument.

```bash
nano config.env
```

```bash
SCANNER_CMD=(pegpon -d)
```

`SCANNER_CMD` must be a bash array, not a plain string — this handles tools with multi-word flags correctly. Examples:

```bash
SCANNER_CMD=(pegpon -d)
SCANNER_CMD=(nuclei -target)
SCANNER_CMD=(nmap -sV)
SCANNER_CMD=(/root/scanner/pipeline.sh)
```

If `SCANNER_CMD` isn't set, it defaults to `(pegpon -d)`.

The target is validated before use (letters, digits, dots, hyphens, underscores only — no path traversal or shell metacharacters), then run as:

```bash
"${SCANNER_CMD[@]}" "$domain"
```

---

# Custom Scanner Pipeline (`pipeline.sh`)

`pipeline.sh` is an optional bundled recon chain you can point `SCANNER_CMD` at instead of a single tool:

```bash
SCANNER_CMD=(/root/scanner/pipeline.sh)
```

## What it does

1. **subfinder** — passive subdomain enumeration
2. **dnsx** — resolves subdomains, drops dead DNS entries
3. **httpx** — checks live hosts, filtered to specific status codes
4. **keyword matching** — greps URLs and page titles against a built-in keyword list
5. **nuclei** — template-based vulnerability scan against the live hosts found

Each stage is skipped gracefully (with a warning, not a crash) if its tool isn't installed, so a partial toolset still produces partial results instead of failing outright.

## Status codes checked

```text
200, 301, 302, 307, 308, 401, 403, 405
```

`404` is deliberately excluded — it means the page doesn't exist and would just add noise. `401`/`403`/`405` are included because they confirm an endpoint exists (and is being protected), which is often a stronger signal than a plain `200`.

## Keyword categories

All keywords are grep-matched with word boundaries against the URL and page title of every live host, so a keyword only matches as a whole word — not as a substring of the domain name itself.

| Category | Keywords |
|---|---|
| Auth | `admin, administrator, login, signin, sign-in, signup, sign-up, register, dashboard, portal, panel, cpanel, console` |
| API | `api, apikey, api-key, api_key, secret, token, auth, oauth, credentials, key, access-key, private-key` |
| User | `profile, settings, account, user, users, config, configuration, preferences` |
| Backup | `backup, backups, .env, .git, .sql, dump, db, database, old, bak, tmp, temp` |
| Dev/Staging | `dev, staging, test, uat, internal, debug, beta, sandbox` |
| Cloud | `s3, bucket, storage, cloud, aws` |
| Misc | `upload, uploads, download, export, import, logs, log, monitor, health, status, actuator, swagger, graphql` |

## Editing status codes or keywords

All of these are defined as plain variables near the top of `pipeline.sh` — nothing is read from `config.env`. To change them, edit the file directly:

```bash
nano pipeline.sh
```

```bash
STATUS_CODES="200,301,302,307,308,401,403,405"

KEYWORDS_AUTH="admin|administrator|login|signin|..."
KEYWORDS_API="api|apikey|api-key|..."
# ...
```

Set any `KEYWORDS_*` variable to an empty string (`""`) to disable that entire category.

## Requirements

```bash
subfinder
dnsx
httpx
nuclei
jq
```

Install whichever of these you're missing; the pipeline runs without failing on missing tools, but a stage with no tool produces no data for that stage.

## Output

Everything lands in the same target directory `scan.sh` already manages:

```text
scans/target.com/
├── scan.log              (full pipeline output, all stages)
├── subdomains.txt
├── resolved.txt
├── httpx_output.json
├── keyword_matches.txt
├── nuclei_output.txt
└── target.com_results.zip   (if RESULTS_ZIP="true" in config.env)
```

## Findings notification

In addition to `scan.sh`'s normal start/finish notifications, if the scanner's output contains a `SUMMARY:` block (which `pipeline.sh` always prints), `scan.sh` forwards it as a separate "🎯 Findings" notification to Discord/Telegram — so you get scan-status updates and actual results as distinct messages. Example:

```text
🎯 Findings for target.com

SUMMARY:
Target: target.com
Subdomains: 12 | Resolved: 10 | Live (200,301,302,307,308,401,403,405): 6
Keyword matches: 2 | Nuclei findings: 1

Keyword hits:
https://admin.target.com [200] Admin Login Panel
https://api.target.com [401] API Gateway

Nuclei hits:
[medium] [exposed-panel] https://admin.target.com
```

---

# Discord Notifications

## 1. Create a Discord Webhook

Open your Discord server and go to:

```text
Server Settings
→ Integrations
→ Webhooks
→ New Webhook
```

Choose the channel where you want scan notifications. Copy the webhook URL. It will look similar to:

```text
https://discord.com/api/webhooks/....
```

## 2. Add It to `config.env`

```bash
nano config.env
```

```bash
DISCORD_WEBHOOK_URL="YOUR_DISCORD_WEBHOOK_URL"
```

Example:

```bash
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/123456789/xxxxxxxx"
```

Protect the file:

```bash
chmod 600 config.env
```

Do not commit this file to GitHub.

## 3. Test It

Start a scan:

```bash
./scan.sh target.com
```

You should receive a notification similar to:

```text
🚀 Scan started

Target: target.com
Time: 2026-08-29 02:11:32
PID: 28491
```

When it finishes:

```text
✅ Scan finished successfully

Target: target.com
Duration: 00h 17m 42s
Exit code: 0
```

If it fails:

```text
❌ Scan failed

Target: target.com
Duration: 00h 02m 11s
Exit code: 1
```

---

# Telegram Bot Notifications

Telegram does NOT require a separate server. The bot runs through Telegram's Bot API, and your VPS simply sends HTTPS requests to Telegram.

## 1. Create a Telegram Bot

Open Telegram and search for `@BotFather`. Send `/newbot` and follow the instructions.

Choose a bot name. For the username, Telegram requires a unique username ending in `bot`, for example:

```text
recon_sentinel_bot
```

BotFather will give you a token similar to:

```text
1234567890:AAxxxxxxxxxxxxxxxxxxxxxxxx
```

This is your `TELEGRAM_BOT_TOKEN`. Keep it private.

## 2. Start a Chat With Your Bot

Open your new bot and press Start, or send `/start`. The bot needs to receive a message before Telegram can return the chat information.

## 3. Find Your Chat ID

From the VPS, run:

```bash
curl "https://api.telegram.org/botYOUR_BOT_TOKEN/getUpdates"
```

Example:

```bash
curl "https://api.telegram.org/bot1234567890:AAxxxxxxxx/getUpdates"
```

You should see JSON containing something similar to:

```json
{
  "result": [
    {
      "message": {
        "chat": {
          "id": 123456789,
          "type": "private"
        }
      }
    }
  ]
}
```

The value `123456789` is your `TELEGRAM_CHAT_ID`.

## 4. Add Telegram Settings

```bash
nano config.env
```

```bash
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
```

Protect it:

```bash
chmod 600 config.env
```

---

# Discord + Telegram Together

You can enable both at the same time, and combine them with `SCANNER_CMD` and `RESULTS_ZIP`:

```bash
SCANNER_CMD=(/root/scanner/pipeline.sh)
RESULTS_ZIP="true"
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
TELEGRAM_BOT_TOKEN="1234567890:AAxxxxxxxx"
TELEGRAM_CHAT_ID="123456789"
```

The same scan events (start, finish/fail, findings, and results zip if enabled) are sent to both services. Useful when a scan takes a long time and you're not connected to the VPS.

---

# Optional Alias

```bash
alias scan='/root/scanner/scan.sh'
```

```bash
source ~/.bashrc
```

Then:

```bash
scan target.com
scan status target.com
scan logs target.com
scan stop target.com
scan list
```

---

# Example Workflow

```bash
./scan.sh target1.com
./scan.sh target2.com
./scan.sh target3.com
./scan.sh list
./scan.sh status target1.com
./scan.sh logs target1.com
./scan.sh stop target1.com
```

---

# Security

## Threat model

`config.env` holds plaintext secrets: API keys, Discord webhook, Telegram bot token. Anyone who reads that file gets full use of those credentials. This matters most on:

- Free or shared VPS providers, where host-level access is outside your control by design.
- Any VPS where `pegpon`, `pipeline.sh`, or another third-party tool runs with access to the same filesystem.
- Any machine where the script or `config.env` could end up in a backup, log, screen share, or accidental git commit.

If `RESULTS_ZIP="true"`, scan output (subdomains, live URLs, keyword matches, nuclei findings) leaves the VPS and is stored on Discord's/Telegram's servers indefinitely, in whatever channel/chat the webhook or bot posts to. Treat that channel/chat as part of your data's exposure surface — anyone with access to it can see target details from every scan.

## Baseline (any VPS, including free tiers)

- Never commit `config.env`. Keep it in `.gitignore`.
- `chmod 600 config.env` — owner read/write only.
- Scope API keys to the minimum permissions needed, and prefer keys that can be revoked/rotated easily.
- Rotate a key or webhook immediately if it's ever exposed — screen share, paste, log output, anything.
- Check shell history for leaked secrets and purge if found:
  ```bash
  grep -iE "api_key|token|webhook" ~/.bash_history ~/.zsh_history 2>/dev/null
  history -c
  ```
- If SSH is exposed to the internet: key-only auth, no root password login, restrict source IP with a firewall where possible.

## Optional: encrypted storage for `config.env`

If your VPS provides an encrypted volume (for example an `encfs` or LUKS mount), keep `config.env` there instead of the general filesystem:

```bash
mkdir -p /path/to/encrypted/keys
mv config.env /path/to/encrypted/keys/config.env
chmod 600 /path/to/encrypted/keys/config.env
```

Reference it from the script or source it before running:

```bash
source /path/to/encrypted/keys/config.env
```

Note the limits of this: encryption protects data at rest (disk theft, snapshots, backups). While the volume is mounted and the box is running, any process with sufficient privilege on that machine — including a compromised third-party tool — can still read the decrypted contents. Encrypted storage reduces exposure; it does not replace least-privilege keys and rotation.

---

# Future Ideas

- Queue multiple scans automatically.
- Maximum concurrent scan limit.
- Retry failed scans.
- Per-target configuration.
- Automatic log rotation.
- Disk-space monitoring.
- Colored terminal UI.
- Global process management.
- `scan all` for a predefined target list.
- Optional systemd service.
- Automatic cleanup of old scan results.
- Configurable status codes / keywords for `pipeline.sh` without editing the file (e.g. a dedicated `pipeline.env`).