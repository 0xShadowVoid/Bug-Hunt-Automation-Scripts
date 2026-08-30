# Scan Notify

`scan.sh` is a small VPS helper for running long-running security/recon scans in the background.

It was originally created because bug-hunting/recon scans can take a long time. Instead of keeping an SSH session open and manually managing `nohup`, the script now handles the background process, PID files, logs, status checks, stopping scans, and notifications.

> Use this only against domains and systems you are authorized to test.

---

## Features

- Run a scan in the background with one simple command.
- Automatically create a separate directory for each target.
- Automatically save scan logs.
- Track the running process with a PID file.
- Prevent accidentally starting the same target twice.
- Check whether a target is still running.
- Follow live output with `tail -f`.
- Stop a running scan.
- List all currently running scans.
- Send start/finish/failure notifications to Discord.
- Send start/finish/failure notifications to Telegram.
- Automatically calculate and report scan duration.

---

## Directory Structure

After running a scan, the project will look like:

```text
scanner/
├── scan.sh
├── config.env
├── .gitignore
└── scans/
    └── target.com/
        ├── scan.log
        ├── scan.pid
        └── scan.done
```

`config.env` contains secrets, so do NOT commit it to Git.

Recommended `.gitignore`:

```gitignore
config.env
scans/
```

---

## Requirements

The script expects:

- Bash
- `curl`
- `pegpon`
- A Discord webhook (optional)
- A Telegram bot (optional)

Check the basic commands:

```bash
bash --version
curl --version
pegpon --help
```

Make the script executable:

```bash
chmod +x scan.sh
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

# Discord Notifications

Discord is the easiest notification option.

## 1. Create a Discord Webhook

Open your Discord server and go to:

```text
Server Settings
→ Integrations
→ Webhooks
→ New Webhook
```

Choose the channel where you want scan notifications.

Copy the webhook URL.

It will look similar to:

```text
https://discord.com/api/webhooks/....
```

## 2. Add It to `config.env`

Create:

```bash
nano config.env
```

Add:

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

Telegram does NOT require a separate server.

The bot itself runs through Telegram's Bot API, and your VPS simply sends HTTPS requests to Telegram.

## 1. Create a Telegram Bot

Open Telegram and search for:

```text
@BotFather
```

Send:

```text
/newbot
```

Follow the instructions.

Choose a bot name.

### Suggested bot names

Good choices for this project:

- `Recon Sentinel`
- `Scan Sentinel`
- `Recon Watcher`
- `VPS Scan Bot`
- `Target Watcher`
- `ReconPulse`

My pick:

```text
Recon Sentinel
```

For the username, Telegram requires a unique username ending in `bot`, for example:

```text
recon_sentinel_bot
```

BotFather will give you a token similar to:

```text
1234567890:AAxxxxxxxxxxxxxxxxxxxxxxxx
```

This is your:

```text
TELEGRAM_BOT_TOKEN
```

Keep it private.

---

## 2. Start a Chat With Your Bot

Open your new bot and press Start, or send:

```text
/start
```

The bot needs to receive a message before Telegram can return the chat information.

---

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

The value:

```text
123456789
```

is your:

```text
TELEGRAM_CHAT_ID
```

---

## 4. Add Telegram Settings

Open:

```bash
nano config.env
```

Add:

```bash
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
```

Example:

```bash
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
TELEGRAM_BOT_TOKEN="1234567890:AAxxxxxxxxxxxxxxxx"
TELEGRAM_CHAT_ID="123456789"
```

Protect it:

```bash
chmod 600 config.env
```

---

# Discord + Telegram Together

You can enable both at the same time:

```bash
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
TELEGRAM_BOT_TOKEN="1234567890:AAxxxxxxxx"
TELEGRAM_CHAT_ID="123456789"
```

The same scan event will be sent to both services.

This is useful when a VPS scan takes a long time and you want a notification even when you are not connected to the VPS.

---

# Optional Alias

For easier usage, add an alias to your shell:

```bash
alias scan='/root/scanner/scan.sh'
```

Then reload:

```bash
source ~/.bashrc
```

After that:

```bash
scan target.com
```

```bash
scan status target.com
```

```bash
scan logs target.com
```

```bash
scan stop target.com
```

```bash
scan list
```

---

# Example Workflow

Start several authorized targets:

```bash
./scan.sh target1.com
./scan.sh target2.com
./scan.sh target3.com
```

Check everything currently running:

```bash
./scan.sh list
```

Check one target:

```bash
./scan.sh status target1.com
```

Watch its output:

```bash
./scan.sh logs target1.com
```

Stop it if necessary:

```bash
./scan.sh stop target1.com
```

---

# Security Notes

Never commit your Telegram bot token or Discord webhook to a public repository.

Keep secrets in:

```text
config.env
```

and add:

```text
config.env
```

to `.gitignore`.

If a token or webhook is accidentally exposed, rotate/revoke it immediately.

Also remember that this tool is intended for authorized security testing only.

---

# Future Ideas

Possible future improvements:

- Queue multiple scans automatically.
- Maximum concurrent scan limit.
- Retry failed scans.
- Per-target configuration.
- Scan summaries attached to Discord/Telegram.
- Automatic log rotation.
- Disk-space monitoring.
- Colored terminal UI.
- Global process management.
- `scan all` for a predefined target list.
- Optional systemd service.
- Automatic cleanup of old scan results.
---
# settings for segfault VPS for more secure
`
mkdir -p /sec/root/keys
cat > /sec/root/keys/.env_keys <<'EOF'
API_KEY=your_real_key
DISCORD_WEBHOOK=your_real_webhook
TELEGRAM_BOT_TOKEN=your_real_token
EOF
chmod 600 /sec/root/keys/.env_keys
`

`source /sec/root/keys/.env_keys`

