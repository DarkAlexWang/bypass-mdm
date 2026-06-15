# Bypass MDM for macOS 💻

![mdm-screen](https://raw.githubusercontent.com/assafdori/bypass-mdm/main/mdm-screen.png)

A script to bypass Mobile Device Management (MDM) enrollment during macOS setup.

## 🚨 Update: June 2026

**Version 4 is now the default.** v4 hardens the script for Apple Silicon + Signed System Volume (macOS 11–26), adds an expanded domain blocklist, a clean undo mode, automatic hosts-file backups, and an interactive menu.

---

## ✨ Features

- **🔍 Smart Volume Detection** — Auto-detects APFS Data volume by role, name, or manual input
- **🔒 FileVault Support** — Prompts to unlock encrypted Data volumes automatically
- **📋 Interactive Menu** — Choose from Suppress only, Full bypass, Verify, Undo, or Reboot
- **🛡️ Expanded Domain Blocklist** — Blocks `identity.apple.com`, `albert.apple.com`, `cloudconfiguration.apple.com`, `*.mdmz.apple.com` in addition to standard MDM domains
- **💾 Hosts Auto-Backup** — Creates `<etc>/hosts.bypass-mdm-backup-<timestamp>` before first modification
- **↩️ Undo All Changes** — Restores hosts backup, deletes temp users, clears markers, re-enables daemons
- **🔎 Verify Mode** — Inspects current DEP markers, hosts blocklines, and launchd overrides
- **✅ Input Validation** — Validates usernames, passwords, and full names (blocks `dscl`-breaking characters)
- **🎯 UID Conflict Resolution** — Automatically finds available UIDs (501–599)
- **📊Verbose Output** — `-v` / `--verbose` echoes every `dscl`/`diskutil`/`plutil` command to stderr
- **🔐 OAuth & Profile Purging** — Removes Machine-OAuth tokens and stale MDM payload profiles after suppression
- **⚠️ Version Detection** — Warns on untested macOS versions (< 11 or > 26)

## ⚠️ Prerequisites

- **Erase disk first** — Full erase via Recovery "Disk Utility" (not just format)
- **Reinstall macOS** — Complete clean install from Recovery
- **Boot back into Recovery Mode** before running the script

## 📋 Usage

### Quick Start

**1.** Boot into **Recovery Mode**:
   - **Apple Silicon**: Hold Power → "Loading startup options" → Options
   - **Intel**: Hold <kbd>CMD</kbd> + <kbd>R</kbd> during boot

**2.** Connect to **WiFi**, then open **Utilities → Terminal**

**3.** Run the script:
```bash
curl -L https://raw.githubusercontent.com/assafdori/bypass-mdm/main/bypass-mdm-v4.sh -o bypass-mdm.sh && chmod +x ./bypass-mdm.sh && ./bypass-mdm.sh
```

**4.** The script will auto-detect your Data volume, then present a menu:

```
1) Suppress enrollment only (Mac already set up)
2) Full bypass (create admin + suppress - for stuck setup)
3) Verify current state
4) Undo all changes
5) Reboot & Exit
```

### Menu Options Explained

| Option | What It Does | Use When |
|--------|-------------|----------|
| **Suppress only** | Blocks MDM domains, clears DEP records, disables enrollment daemon. No user created. | Mac is already set up but keeps nagging about enrollment |
| **Full bypass** | Creates a temp admin account + `.AppleSetupDone`, then runs same suppression | Mac is stuck at the Remote Management / Setup Assistant screen |
| **Verify** | Shows current DEP markers, hosts blocklines, launchd overrides, macOS version | Want to check what the script has done before rebooting |
| **Undo all** | Restores hosts from backup, deletes temp users (`Apple`/`MDMBypass`), clears markers, re-enables daemons | Changed your mind, need to re-enroll |
| **Reboot & Exit** | Reboots the Mac immediately | After any operation above |

### Full Bypass: Creating a Temp Admin

When selecting "Full bypass", you'll be prompted for:
- **Full name** (default: `Apple`) — supports alphanumeric; blocks `\`, quotes, backticks, `;`, `|`, `$`
- **Username** (default: `Apple`) — letters, numbers, `_`, `-` only; must start with letter/underscore
- **Password** (default: `1234`) — minimum 4 characters

### Verbose Mode

Add `-v` or `--verbose` before the menu appears to echo every `dscl`/`diskutil`/`plutil` command to stderr:
```bash
./bypass-mdm.sh -v
```

---

## 🔄 Post-Installation Steps

**1.** **Login** with the temp account (default: `Apple` / `1234`)

**2.** **Skip Setup** — Skip all prompts (Apple ID, Siri, Touch ID, Location Services)

**3.** **Create Real Account:**
   - Navigate to **System Settings > Users and Groups**
   - Create your actual Admin account

**4.** **Switch Accounts** — Log out and sign in to your new account

**5.** **Set Up Properly** — Configure Apple ID, Siri, Touch ID, etc.

**6.** **Clean Up** — Delete the temp account:
   - Go to **System Settings > Users and Groups**
   - Select the temp profile and click the minus (−) button

**7.** **Restore Hosts File** (recommended):
   ```bash
   sudo mv /private/etc/hosts.bypass-mdm-backup-* /private/etc/hosts
   ```

**8.** **Re-enroll** (optional) — If you want MDM back, delete `/private/var/db/mdm` flags and re-push enrollment profile

**🎉 Done!**

---

## 🔧 Troubleshooting

### Volume Detection Fails

- Ensure you're in Recovery Mode (not booted into macOS normally)
- Verify macOS is installed on your drive
- Check Disk Utility — the Data volume must be visible
- If auto-detection fails, the script will prompt for the disk identifier manually

### `fdesetup` Fails in Recovery

On Apple Silicon Recovery, `fdesetup` may not be available or functional. If you see:
```
WARNING: fdesetup add FAILED.
```
After reboot, run:
```bash
sudo fdesetup add -usertoadd Apple
```
Replace `Apple` with your temp username if you used a custom one.

### Permission Errors

- Confirm you're running from Terminal in **Recovery Mode** (not a normal boot shell)
- Recovery Mode provides root-level access automatically

### Script Won't Execute

```bash
chmod +x bypass-mdm.sh
./bypass-mdm.sh
```

### Restoring Hosts After Cleanup

If you lost the backup file, you can manually remove the v4 block:
```bash
# Remove everything from "# Added by bypass-mdm-v4" to the next blank line
sudo sed -i '' '/# Added by bypass-mdm-v4/,/^$/d' /private/etc/hosts
```

---

## 📦 Version Information

| Version              | Description                                      | Status           |
|----------------------|--------------------------------------------------|------------------|
| `bypass-mdm-v4.sh`   | Hardened: expanded blocklist, undo, backup, verify | ✅ **Recommended** |
| `bypass-mdm-v3.sh`   | Previous release                                 | ⚠️ Legacy        |
| `bypass-mdm-v2.sh`   | Auto-detection & input validation                | ⚠️ Deprecated    |
| `bypass-mdm.sh`      | Original (hardcoded volume names)                | ⚠️ Legacy        |

---

## 📝 Changelog

### v4 (June 2026)
- Expanded domain blocklist: `identity.apple.com`, `albert.apple.com`, `cloudconfiguration.apple.com`, `*.mdmz.apple.com`
- Fixed hosts-file duplicate entries (exact-line matching instead of trailing regex)
- `realName` input validation (blocks `dscl`-breaking characters: `\`, quotes, backticks, `;`, `|`, `$`)
- `fdesetup` guarded with explicit post-reboot remediation on Apple Silicon Recovery
- Home directory ownership & permissions enforced (`chmod 700`, correct UID)
- "Undo all changes" menu option: restores hosts backup, deletes temp users, clears markers, re-enables daemons
- `-v` / `--verbose` flag for headless debugging
- `sw_vers`-based macOS version detection with untested-version warnings
- Hosts auto-backup: `hosts.bypass-mdm-backup-<timestamp>`
- Machine-OAuth token and MDM payload profile purging

### v3 (March 2026)
- DEP suppression mode, daemon disabling, improved SSV detection

### v2 (February 2026)
- Automatic volume detection, comprehensive error handling, input validation, UID conflict detection

---

## ⚠️ Important Limitations

- This script **SUPPRESSES** enrollment locally. It does NOT remove your device from the organization's Apple Business/School Manager.
- Your serial number will still appear in the org's inventory and will re-fetch whenever the Mac reaches Apple's servers.
- **Never run `profiles renew`** after bypassing — it will re-trigger enrollment.
- **Avoid "Erase All Content & Settings"** / factory reset — it will re-download the DEP record.

---

### ❤️ Optional Contributions

Many people have reached out asking how to say thank you for saving their Mac. **This is completely optional and not expected!** If you'd like to contribute, crypto donations are appreciated.

People have forked this repository and put the script behind a pay-wall. I do not care at all. Once again, crypto contributions are not expected, but feel free if you want to.

**Bitcoin (BTC):**
```
bc1qzguh4908r7wguz20ylzeggya9d38t6hega5ppf
```

**Monero (XMR):**
```
45RnFseY4gNZv58DvShz2KJEbx1EyaTtaMCDnU5th21KbRThWurjjK6iugEdq9wfc4Kbw3a7AAyqo6WnEmL1StAMJur8QJp
```

## ⚖️ Legal Disclaimer

> **Important:** Although it's virtually impossible to detect that you've suppressed MDM (because it was never configured locally), be aware that your device's serial number will still appear in your organization's inventory system. This script prevents MDM from being configured locally, making the device unmanageable remotely.
>
> **Use responsibly and at your own risk.** This tool is intended for personal devices and should not be used to circumvent legitimate organizational policies without proper authorization.

---

## 📄 License

This project is provided as-is for educational purposes. Use at your own discretion.
