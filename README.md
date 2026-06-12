# Bypass-MDM for macOS

![mdm-screen](https://raw.githubusercontent.com/assafdori/bypass-mdm/main/mdm-screen.png)

A collection of scripts to bypass Mobile Device Management (MDM) enrollment during macOS setup.

**Choose your script:**

| Script | Best for | Run from |
|--------|----------|----------|
| `bypass-mdm-express.sh` | **Recommended.** All-in-one: backup + bypass + restore | Recovery |
| `bypass-mdm-v3.sh` | Apple Silicon / macOS 11-26. SSV-aware. | Recovery |
| `bypass-mdm-v2.sh` | Simple cases, Intel Macs | Recovery |
| `bypass-mdm.sh` | Legacy, hardcoded volume names | Recovery |
| `bypass-mdm-dualboot.sh` | Dual-boot (enrolled + personal macOS) | Enrolled OS (sudo) |

---

### Express — All-in-one (Recommended)

Put this script on an external SSD, plug it into any Mac, run it from Recovery. No curl, no typing URLs, no downloads. Works entirely offline.

**What it does:**
1. Backs up your original state (hosts, config profiles, launchd config) to the SSD
2. Suppresses MDM enrollment (blocks domains, resets markers, disables daemon)
3. Can restore the original state later — take your Mac to Apple for re-enrollment, then restore

```bash
# Recovery mode -> Utilities -> Terminal
chmod +x "/Volumes/YourSSDName/bypass-mdm-express.sh"
"/Volumes/YourSSDName/bypass-mdm-express.sh"
```

The backup is stored on the SSD itself (`/.bypass-backup/`). To restore, re-run and pick "Restore original state".

---

### v3 — Apple Silicon / SSV-aware

v3 fixes the root cause of why v1/v2 fail on modern Macs: **System Volume sealing**. On Apple Silicon, macOS boots from a sealed, read-only snapshot. Writes to `/etc/hosts` or `/var/db/ConfigurationProfiles` on the System volume never reach the running OS. v3 writes everything to the **Data volume** (via `/private` firmlink) where the OS actually reads it.

**Additional improvements:**
- Detects Data volume by APFS role (no hardcoded names)
- Supports FileVault-encrypted volumes (unlocks automatically)
- Reads the org MDM host from the activation record and blocks it
- Disables the enrollment daemon via launchd override on the Data volume
- Two modes: suppress-only (no user created) or full bypass
- Leaves `gdmf.apple.com` and `albert.apple.com` unblocked (Software Update, iMessage)

```bash
# Run in Recovery mode (Utilities > Terminal)
curl -L https://raw.githubusercontent.com/assafdori/bypass-mdm/main/bypass-mdm-v3.sh -o bypass-mdm-v3.sh && chmod +x bypass-mdm-v3.sh && ./bypass-mdm-v3.sh
```

---

### v2 — Automatic volume detection

Improved version with dynamic volume detection. No need to know your volume name. Now writes to Data volume paths (SSV-aware).

```bash
curl -L https://raw.githubusercontent.com/assafdori/bypass-mdm/main/bypass-mdm-v2.sh -o bypass-mdm-v2.sh && chmod +x bypass-mdm-v2.sh && ./bypass-mdm-v2.sh
```

---

### Original (legacy) — Hardcoded volumes

Original version with hardcoded "Macintosh HD" volume names.

```bash
curl -L https://raw.githubusercontent.com/assafdori/bypass-mdm/main/bypass-mdm.sh -o bypass-mdm.sh && chmod +x ./bypass-mdm.sh && ./bypass-mdm.sh
```

---

### Dual-boot setup

If your Mac is enrolled by an organization but you have sudo access, you can create a separate partition with a fresh macOS install and bypass MDM on it:

```bash
curl -L https://raw.githubusercontent.com/assafdori/bypass-mdm/main/bypass-mdm-dualboot.sh -o bypass-mdm-dualboot.sh && sudo chmod +x bypass-mdm-dualboot.sh && sudo ./bypass-mdm-dualboot.sh
```

---

### Instructions (Recovery mode)

1. Long press Power to shut down.
2. Boot into Recovery:
   - **Apple Silicon**: Hold Power until "Loading startup options" appears, then Options > Continue.
   - **Intel**: Hold CMD + R during boot.
3. Connect to WiFi.
4. Open Terminal (Utilities > Terminal).
5. Run the script.
6. Reboot when done.

---

### Legal

This only suppresses MDM locally. Your serial stays in the org's Apple Business Manager. The permanent fix is them releasing it.

Use on devices you own. I'm not responsible for what you do with this.
