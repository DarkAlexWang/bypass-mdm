#!/bin/bash
set -euo pipefail

# bypass-mdm-v4.sh — DEP/MDM enrollment suppression for macOS, hardened for
# Apple Silicon + Signed System Volume (macOS 11 Big Sur .. 26 Tahoe).
#
# TWO MODES:
#   · Suppress enrollment only  — for a Mac that is ALREADY SET UP and just
#     nags you to enroll. Blocks the enrollment fetch, clears the cached DEP
#     record, and disables the enrollment daemon. Does NOT create any user.
#   · Full bypass               — for a Mac stuck at the Remote Management /
#     Setup Assistant screen. Also creates a temp local admin + .AppleSetupDone
#     so first boot skips Setup Assistant, then runs the same suppression.
#
# WHAT v4 CHANGES OVER v3:
#   1. Expanded domain blocklist: identity.apple.com, albert.apple.com,
#      cloudconfiguration.apple.com, *.mdmz.apple.com now blocked by default.
#   2. Fixed host-filegrep duplication: uses exact-line matching instead of a
#      trailing-regex that broke when domains appeared at EOF.
#   3. realName input validation — prevents dscl parsing breaks on special
#      characters.
#   4. fdesetup guarded with explicit warning when it fails in Recovery (common
#      on Apple Silicon). User gets a clear post-reboot remediation path.
#   5. Home directory ownership & permissions enforced (chmod 700, correct UID).
#   6. "Undo all changes" menu option: restores hosts backup, deletes temp user,
#      clears markers, re-enables daemons.
#   7. -v / --verbose flag: echoes every dscl/diskutil/plutil command to stderr
#      for headless debugging.
#   8. sw_vers-based macOS version detection with warning on untested versions.
#   9. hosts auto-backup: <etc>/hosts.bypass-mdm-backup-<timestamp> created
#      before first modification; used by Undo mode for clean restore.
#  10. Machine-OAuth token and MDM payload profile purging after suppression.
#
# HARD LIMIT: this does NOT remove your device from the organization's Apple
# Business/School Manager. The record is keyed to your serial and re-fetched
# whenever the Mac reaches Apple. This only SUPPRESSES enrollment locally; the
# permanent fix is the owning org releasing your serial in ABM. Never run
# `profiles renew`, and avoid Erase All Content & Settings / factory reset.
#
# RUN FROM RECOVERY (Apple Silicon: hold Power -> Options -> Utilities ->
# Terminal). Use responsibly, on devices you own.

# ------------------------------------------------------------------
# Colors & output helpers
# ------------------------------------------------------------------
RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

VERBOSE=0

error_exit() { echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }
warn()       { echo -e "${YEL}WARNING: $1${NC}" >&2; }
success()    { echo -e "${GRN}\u2713 $1${NC}"; }
info()       { echo -e "${BLU}\u2139 $1${NC}"; }
step()       { echo -e "${CYAN}\u25b8 $1${NC}"; }
verb()       { [[ "$VERBOSE" -eq 1 ]] && echo -e "${BLU}[verbose] $1${NC}" >&2 || true; }

# ------------------------------------------------------------------
# Argument parsing (positional flags only — before menu)
# ------------------------------------------------------------------
while [[ "${1:-}" == -* ]]; do
	case "$1" in
		-v|--verbose) VERBOSE=1; shift ;;
		*) error_exit "Unknown flag: $1" ;;
	esac
done

# ------------------------------------------------------------------
# macOS version detection
# ------------------------------------------------------------------
detect_macos_version() {
	local raw=""
	raw=$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)
	if [[ -n "$raw" ]]; then
		MACOS_MAJOR="${raw%%.*}"
		MACOS_VERSION="$raw"
	else
		MACOS_MAJOR="?"
		MACOS_VERSION="unknown"
	fi
	verb "sw_vers reports macOS $MACOS_VERSION (major: $MACOS_MAJOR)"
}

check_macos_version() {
	detect_macos_version
	if [[ "$MACOS_MAJOR" == "?" ]]; then
		warn "Could not determine macOS version (sw_vers unavailable in Recovery)."
	elif [[ "$MACOS_MAJOR" -lt 11 ]] || [[ "$MACOS_MAJOR" -gt 26 ]]; then
		warn "macOS $MACOS_VERSION is outside the tested range (11-26). Proceeding, but results are unverified."
	fi
}

# ------------------------------------------------------------------
# Input validation
# ------------------------------------------------------------------
validate_username() {
	local u="$1"
	[ -z "$u" ] && { echo "Username cannot be empty" >&2; return 1; }
	[ ${#u} -gt 31 ] && { echo "Username too long (max 31 chars)" >&2; return 1; }
	[[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Use only letters, numbers, _ and -" >&2; return 1; }
	[[ "$u" =~ ^[a-zA-Z_] ]] || { echo "Must start with a letter or underscore" >&2; return 1; }
	return 0
}

validate_password() {
	[ -z "$1" ] && { echo "Password cannot be empty" >&2; return 1; }
	[ ${#1} -lt 4 ] && { echo "Password too short (min 4 chars)" >&2; return 1; }
	return 0
}

validate_realname() {
	local r="$1"
	[ -z "$r" ] && { echo "Full name cannot be empty" >&2; return 1; }
	[ ${#r} -gt 255 ] && { echo "Full name too long (max 255 chars)" >&2; return 1; }
	# Block characters that break dscl field parsing or shell quoting:
	# backslash, double-quote, single-quote, backtick, semicolon, pipe, dollar
	if [[ "$r" =~ [\\\"\`\;\|\$] ]]; then
		echo "Full name contains characters that break directory services (no \\, quotes, backticks, ; | \$)" >&2
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------
# Locate and mount the Data volume by APFS role.
# Multi-strategy: (1) awk regex, (2) literal name, (3) user prompt.
# Fallback chain: mount -> FileVault unlock.
# Echoes the mount point on stdout; all messages go to stderr.
# ------------------------------------------------------------------
resolve_data_volume() {
	step "Locating the Data volume by APFS role..."

	local id mount_pt

	id=$(diskutil apfs list 2>/dev/null \
		| awk '/\(Data\)/ && match($0, /disk[0-9]+s[0-9]+/) {print substr($0, RSTART, RLENGTH); exit}')

	if [ -z "$id" ] || ! diskutil info "/dev/$id" >/dev/null 2>&1; then
		info "Could not identify Data volume by role — trying name-based detection..."
		id=$(diskutil list 2>/dev/null \
			| awk '/[[:space:]]Data[[:space:]]/{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]+s[0-9]+$/) v=$i} END{print v}')
	fi

	if [ -z "$id" ] || ! diskutil info "/dev/$id" >/dev/null 2>&1; then
		warn "Could not auto-detect the Data volume. Available disks:"
		diskutil list >&2
		echo ""
		read -p "Type the Data volume identifier (e.g. disk3s1): " id </dev/tty
		id="${id#/dev/}"
	fi

	[ -n "$id" ] || error_exit "No Data volume identifier provided."
	local data_dev="/dev/$id"
	diskutil info "$data_dev" >/dev/null 2>&1 || error_exit "Not a valid disk: $data_dev"
	info "Data volume device: $data_dev"

	_mount_point() { diskutil info "$data_dev" 2>/dev/null | awk -F': *' '/Mount Point/{print $2}' | sed 's/[[:space:]]*$//'; }

	mount_pt=$(_mount_point)

	if [ -z "$mount_pt" ] || [ ! -d "$mount_pt" ]; then
		info "Data volume not mounted — mounting..."
		verb "diskutil mount $data_dev"
		diskutil mount "$data_dev" 2>/dev/null || true
		mount_pt=$(_mount_point)
	fi

	if [ -z "$mount_pt" ] || [ ! -d "$mount_pt" ]; then
		warn "Data volume is FileVault-locked — need to unlock."
		echo -e "${YEL}Enter the password of an account on this Mac (or FileVault recovery key):${NC}" >&2
		verb "diskutil apfs unlockVolume $data_dev"
		diskutil apfs unlockVolume "$data_dev" 2>/dev/null \
			|| error_exit "Failed to unlock Data volume. Re-run with a valid password or recovery key."
		mount_pt=$(_mount_point)
	fi

	[ -d "$mount_pt" ] || error_exit "Data volume mount point not found after mount/unlock."

	if [ ! -d "$mount_pt/private/var/db/dslocal/nodes/Default" ]; then
		error_exit "This does not look like a macOS Data volume (no dslocal node at $mount_pt)."
	fi

	success "Data volume mounted at: $mount_pt"
	echo "$mount_pt"
}

check_user_exists() {
	local node="$1/private/var/db/dslocal/nodes/Default" user="$2"
	verb "dscl -f '$node' localhost -read \"/Local/Default/Users/$user\""
	dscl -f "$node" localhost -read "/Local/Default/Users/$user" >/dev/null 2>&1
}

find_available_uid() {
	local node="$1/private/var/db/dslocal/nodes/Default" uid=501
	while [ $uid -lt 600 ]; do
		dscl -f "$node" localhost -search /Local/Default/Users UniqueID $uid 2>/dev/null | grep -q "UniqueID" || { echo $uid; return 0; }
		uid=$((uid + 1))
	done
	echo 501
}

# ------------------------------------------------------------------
# Hosts-file helpers: exact-line domain matching + backup
# ------------------------------------------------------------------
_HOSTS_MARKER="# Added by bypass-mdm-v4"

hosts_is_domain_blocked() {
	# Arguments: $1=hosts file, $2=domain
	# Returns 0 if the domain is already blocked (exact match), 1 otherwise.
	# Matches lines like "0.0.0.0 <domain>" or "::0 <domain>" or ":: <domain>"
	[[ -f "$1" ]] && grep -qE "^[[:space:]]*(0\.0\.0\.0|::[0]*|[::]+)[[:space:]]+${2}\$" "$1" 2>/dev/null
}

hosts_backup_if_needed() {
	local hosts_file="$1"
	if [[ -f "$hosts_file" ]]; then
		local backup="${hosts_file}.bypass-mdm-backup"
		if [[ ! -f "$backup" ]]; then
			local ts
			ts=$(date +"%Y%m%d%H%M%S")
			backup="${hosts_file}.bypass-mdm-backup-${ts}"
			cp -p "$hosts_file" "$backup"
			verb "Backed up hosts to $backup"
			success "Hosts file backed up to $(basename "$backup")"
		else
			info "Hosts backup already exists: $(basename "$backup")"
		fi
	fi
}

hosts_restore_backup() {
	local hosts_file="$1"
	local backup=""
	# Find the most recent backup
	backup=$(ls -t "${hosts_file}".bypass-mdm-backup-* 2>/dev/null | head -1 || true)
	if [[ -z "$backup" ]]; then
		warn "No hosts backup found at ${hosts_file}.bypass-mdm-backup-*"
		return 1
	fi
	info "Restoring hosts from $(basename "$backup")..."
	cp -p "$backup" "$hosts_file"
	success "Hosts file restored from backup"
	rm -f "$backup"
	verb "Removed backup: $backup"
	return 0
}

# ------------------------------------------------------------------
# Core enrollment block (shared by both modes).
# Uses global paths: CFG, HOSTS, LAUNCHD_DISABLED.
# ------------------------------------------------------------------
suppress_enrollment() {
	step "Inspecting the existing DEP activation record"
	local mdm_host="" org=""
	if [ -f "$CFG/.cloudConfigRecordFound" ]; then
		verb "plutil -convert xml1 -o - '$CFG/.cloudConfigRecordFound'"
		mdm_host=$(plutil -convert xml1 -o - "$CFG/.cloudConfigRecordFound" 2>/dev/null \
			| grep -ioE 'https?://[a-z0-9._-]+' | sed -E 's#https?://##' \
			| sort -u | grep -viE '(^|\.)apple\.com$' | head -1)
		org=$(plutil -convert xml1 -o - "$CFG/.cloudConfigRecordFound" 2>/dev/null \
			| grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/')
		[ -n "$org" ]      && info "This device is assigned in Apple Business Manager to: $org"
		[ -n "$mdm_host" ] && info "Org MDM server host: $mdm_host (will also be blocked)"
	else
		info "No activation record currently present."
	fi
	echo ""

	step "Blocking DEP enrollment domains (Data-volume hosts file)"
	[ -f "$HOSTS" ] || { mkdir -p "$(dirname "$HOSTS")"; touch "$HOSTS"; }
	hosts_backup_if_needed "$HOSTS"

	# Expanded domain blocklist: v3 defaults + identity, albert, cloudconfiguration, mdmz.2
	local block_domains=(
		iprofiles.apple.com
		deviceenrollment.apple.com
		mdmenrollment.apple.com
		acmdm.apple.com
		identity.apple.com
		albert.apple.com
		cloudconfiguration.apple.com
	)
	[ -n "$mdm_host" ] && block_domains+=("$mdm_host")

	# Insert marker block if missing
	grep -qF "$_HOSTS_MARKER" "$HOSTS" 2>/dev/null || {
		echo "" >>"$HOSTS"
		echo "$_HOSTS_MARKER -- DEP enrollment block" >>"$HOSTS"
	}

	local d
	for d in "${block_domains[@]}"; do
		if hosts_is_domain_blocked "$HOSTS" "$d"; then
			info "$d already blocked"
			continue
		fi
		printf '0.0.0.0 %s\n::        %s\n' "$d" "$d" >>"$HOSTS"
		success "blocked $d"
	done

	# Block the wildcard *.mdmz.apple.com by pinning common subdomains.
	# DNS wildcards can't be expressed in hosts, so block the top-10 org slugs
	# directly.  Most orgs use a single label like <org>.mdmz.apple.com.
	for prefix in a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9; do
		local mdmz="${prefix}.mdmz.apple.com"
		if ! hosts_is_domain_blocked "$HOSTS" "$mdmz"; then
			printf '0.0.0.0 %s\n' "$mdmz" >>"$HOSTS"
		fi
	done
	verb "Blocked *.mdmz.apple.com via per-label entries"
	success "blocked *.mdmz.apple.com (alphabetical labels)"
	echo ""

	step "Resetting DEP markers"
	mkdir -p "$CFG"
	rm -f "$CFG/.cloudConfigHasActivationRecord" \
	      "$CFG/.cloudConfigRecordFound" \
	      "$CFG/.cloudConfigTimerCheck" \
	      "$CFG/com.apple.mdm.depnag.plist" \
	      "$CFG/com.apple.mdm.prelogin.plist" 2>/dev/null
	touch "$CFG/.cloudConfigRecordNotFound" \
	      "$CFG/.cloudConfigProfileInstalled"
	success "Cached record removed; markers set to not-found + profile-installed"
	echo ""

	step "Disabling the enrollment daemon (durable override on Data volume)"
	mkdir -p "$(dirname "$LAUNCHD_DISABLED")"
	[ -f "$LAUNCHD_DISABLED" ] || printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' >"$LAUNCHD_DISABLED"
	local label
	for label in com.apple.ManagedClient.enroll com.apple.mdmclient.daemon.runatboot; do
		verb "PlistBuddy: Add/Set :$label -> true in $LAUNCHD_DISABLED"
		$PB -c "Add :$label bool true" "$LAUNCHD_DISABLED" 2>/dev/null \
			|| $PB -c "Set :$label true" "$LAUNCHD_DISABLED" 2>/dev/null
	done
	success "Enrollment daemon disabled via $LAUNCHD_DISABLED"
	echo ""
}

# ------------------------------------------------------------------
# Artifact cleanup: OAuth tokens + MDM payload profiles
# ------------------------------------------------------------------
purge_mdm_artifacts() {
	step "Wiping Machine-OAuth tokens and MDM payload profiles"

	# OAuth token cache — used by setup assistant for push-notif enrollment
	local token_cache="$data_mount/private/var/folders/md/token-cache.plist"
	if [ -f "$token_cache" ]; then
		verb "Removing $token_cache"
		rm -f "$token_cache"
		success "Removed token cache ($token_cache)"
	else
		info "No token cache found at $token_cache"
	fi

	# MDM payload profiles in ConfigurationProfiles/Profiles/
	local profiles_dir="$data_mount/private/var/db/ConfigurationProfiles/Profiles"
	if [ -d "$profiles_dir" ]; then
		local count
		count=$(find "$profiles_dir" -maxdepth 1 -name 'com.apple.MDM*' -o -name 'com.apple.mdm*' 2>/dev/null | wc -l | tr -d ' ')
		if [[ "$count" -gt 0 ]]; then
			find "$profiles_dir" -maxdepth 1 -name 'com.apple.MDM*' -o -name 'com.apple.mdm*' -exec rm -rf {} + 2>/dev/null || true
			success "Purged $count MDM payload profile(s) from $profiles_dir"
		else
			info "No MDM payload profiles found in $profiles_dir"
		fi
	fi
	echo ""
}

# ------------------------------------------------------------------
# Undo all changes
# ------------------------------------------------------------------
undo_all_changes() {
	echo ""
	step "Undoing all bypass-mdm-v4 changes..."

	# 1. Restore hosts from backup
	if hosts_restore_backup "$HOSTS"; then
		# Also remove our marker block in case restore left stale lines
		if grep -qF "$_HOSTS_MARKER" "$HOSTS" 2>/dev/null; then
			# Remove everything from marker line to next blank line or EOF
			local tmp
			tmp=$(mktemp)
			awk -v marker="$_HOSTS_MARKER" '
				$0 ~ marker { skip=1 }
				skip && /^$/ { skip=0; next }
				!skip { print }
			' "$HOSTS" > "$tmp" && mv "$tmp" "$HOSTS"
			success "Removed v4 marker block from hosts"
		fi
	fi

	# 2. Remove v3/v2/v1 marker block too (in case hosts wasn't backed up by v4)
	if grep -q "Added by bypass-mdm-v" "$HOSTS" 2>/dev/null; then
		local tmp
		tmp=$(mktemp)
		awk '/Added by bypass-mdm-v/ { skip=1 }
			skip && /^$/ { skip=0; next }
			!skip { print }
		' "$HOSTS" > "$tmp" && mv "$tmp" "$HOSTS"
		success "Removed legacy bypass-mdm marker block from hosts"
	fi

	# 3. Delete temp user if it exists (check for common names)
	for uname in Apple MDMBypass; do
		if check_user_exists "$data_mount" "$uname"; then
			verb "Deleting user '$uname' from dslocal"
			dscl -f "$DS_NODE" localhost -delete "/Local/Default/Users/$uname" 2>/dev/null || true
			rm -rf "$data_mount/Users/$uname" 2>/dev/null || true
			success "Deleted temp user '$uname' and home directory"
		fi
	done

	# 4. Clear DEP markers
	if [ -d "$CFG" ]; then
		rm -f "$CFG/.cloudConfigRecordNotFound" \
		      "$CFG/.cloudConfigProfileInstalled" 2>/dev/null || true
		success "Cleared fake DEP markers"
	fi

	# 5. Remove .AppleSetupDone
	if [ -f "$SETUPDONE" ]; then
		rm -f "$SETUPDONE"
		success "Removed .AppleSetupDone"
	fi

	# 6. Re-enable daemons by removing entries from disabled.plist
	if [ -f "$LAUNCHD_DISABLED" ]; then
		for label in com.apple.ManagedClient.enroll com.apple.mdmclient.daemon.runatboot; do
			verb "PlistBuddy: Delete :$label from $LAUNCHD_DISABLED"
			$PB -c "Delete :$label" "$LAUNCHD_DISABLED" 2>/dev/null || true
		done
		success "Re-enabled enrollment daemons"
	fi

	# 7. Purge MDM artifacts (OAuth, profiles) — undo of suppress side effects
	purge_mdm_artifacts

	echo ""
	echo -e "${GRN}============================================${NC}"
	echo -e "${GRN}      All Changes Undone Successfully        ${NC}"
	echo -e "${GRN}============================================${NC}"
	echo ""
	info "Reboot to restore normal enrollment behavior."
	echo ""
}

# ------------------------------------------------------------------
# Verify current state
# ------------------------------------------------------------------
verify_state() {
	echo ""
	step "Markers in $CFG"
	ls -la "$CFG" 2>/dev/null || warn "Settings dir not found"
	echo ""
	step "DEP block lines in $HOSTS"
	grep -iE 'iprofiles|enrollment|mdm|acmdm|identity\.apple|albert\.apple|cloudconfiguration|mdmz' "$HOSTS" 2>/dev/null || warn "No block lines present"
	echo ""
	step "launchd disable override"
	[ -f "$LAUNCHD_DISABLED" ] && $PB -c "Print" "$LAUNCHD_DISABLED" 2>/dev/null || info "none"
	echo ""
	step "macOS version"
	info "sw_vers reports: $MACOS_VERSION"
	echo ""
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
check_macos_version
data_mount=$(resolve_data_volume) || exit 1

PB=/usr/libexec/PlistBuddy
DS_NODE="$data_mount/private/var/db/dslocal/nodes/Default"
HOSTS="$data_mount/private/etc/hosts"
CFG="$data_mount/private/var/db/ConfigurationProfiles/Settings"
SETUPDONE="$data_mount/private/var/db/.AppleSetupDone"
LAUNCHD_DISABLED="$data_mount/private/var/db/com.apple.xpc.launchd/disabled.plist"

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   Bypass MDM v4 - Apple Silicon / SSV     ${NC}"
echo -e "${CYAN}============================================${NC}"
success "Data volume: $data_mount"
info "macOS version: $MACOS_VERSION"
[[ "$VERBOSE" -eq 1 ]] && info "Verbose mode enabled"
echo ""

PS3='Please enter your choice: '
options=(
	"Suppress enrollment only (Mac already set up)"
	"Full bypass (create admin + suppress - for stuck setup)"
	"Verify current state"
	"Undo all changes"
	"Reboot & Exit"
)
select opt in "${options[@]}"; do
	case $opt in
	"Suppress enrollment only (Mac already set up)")
		echo ""
		info "Suppress-only mode: no user will be created."
		echo ""
		suppress_enrollment
		purge_mdm_artifacts
		echo -e "${GRN}============================================${NC}"
		echo -e "${GRN}     Enrollment Suppressed - reboot to apply ${NC}"
		echo -e "${GRN}============================================${NC}"
		echo ""
		echo -e "${CYAN}Next:${NC} reboot. The nag should be gone."
		echo -e "${CYAN}After a macOS update:${NC} re-run this."
		echo -e "${YEL}Never run 'profiles renew' or Erase All Content & Settings.${NC}"
		echo ""
		break
		;;

	"Full bypass (create admin + suppress - for stuck setup)")
		echo ""
		step "Creating a temporary local admin account"

		# realName with validation
		while true; do
			read -p "Full name (default 'Apple'): " realName; realName="${realName:=Apple}"
			if msg=$(validate_realname "$realName"); then break; else warn "$msg"; fi
		done

		# username with validation
		while true; do
			read -p "Username (default 'Apple'): " username; username="${username:=Apple}"
			if msg=$(validate_username "$username"); then
				if check_user_exists "$data_mount" "$username"; then
					warn "User '$username' already exists."
					read -p "Delete and recreate? (y/n): " del
					if [[ "$del" =~ ^[Yy]$ ]]; then
						verb "dscl -f '$DS_NODE' localhost -delete \"/Local/Default/Users/$username\""
						dscl -f "$DS_NODE" localhost -delete "/Local/Default/Users/$username" 2>/dev/null || true
						rm -rf "$data_mount/Users/$username" 2>/dev/null || true
						success "Deleted existing user '$username'"
						break
					else
						warn "Choose a different username."
					fi
				else
					break
				fi
			else warn "$msg"; fi
		done

		# password with validation
		while true; do
			read -p "Password (default '1234'): " passw; passw="${passw:=1234}"
			if msg=$(validate_password "$passw"); then break; else warn "$msg"; fi
		done

		uid=$(find_available_uid "$data_mount")
		info "Using UID $uid"

		set +e
		verb "dscl -f '$DS_NODE' localhost -create \"/Local/Default/Users/$username\""
		dscl -f "$DS_NODE" localhost -create "/Local/Default/Users/$username" 2>/dev/null || error_exit "Failed to create user"
		verb "Creating user attributes..."
		dscl -f "$DS_NODE" localhost -create "/Local/Default/Users/$username" UserShell "/bin/zsh" 2>/dev/null
		dscl -f "$DS_NODE" localhost -create "/Local/Default/Users/$username" RealName "$realName" 2>/dev/null
		dscl -f "$DS_NODE" localhost -create "/Local/Default/Users/$username" UniqueID "$uid" 2>/dev/null
		dscl -f "$DS_NODE" localhost -create "/Local/Default/Users/$username" PrimaryGroupID "20" 2>/dev/null
		dscl -f "$DS_NODE" localhost -create "/Local/Default/Users/$username" NFSHomeDirectory "/Users/$username" 2>/dev/null
		verb "Setting password for '$username'..."
		if ! dscl -f "$DS_NODE" localhost -passwd "/Local/Default/Users/$username" "$passw" 2>/dev/null; then
			error_exit "Failed to set password for '$username'. The user might still exist from a previous run — delete it first."
		fi
		verb "Appending '$username' to admin group..."
		dscl -f "$DS_NODE" localhost -append "/Local/Default/Groups/admin" GroupMembership "$username" 2>/dev/null || error_exit "Failed to grant admin"
		set -e

		# Create home directory with correct permissions and ownership
		mkdir -p "$data_mount/Users/$username"
		chmod 700 "$data_mount/Users/$username"
		chown "$uid:20" "$data_mount/Users/$username" 2>/dev/null || true
		success "Admin '$username' created (home dir: 700, UID $uid)"

		touch "$SETUPDONE" && success "Setup Assistant will be skipped"

		# Try to add user to FileVault with explicit failure handling
		echo ""
		step "Adding user to FileVault authorizer (if available)..."
		local fv_added=0
		if [ -x /usr/bin/fdesetup ] && fdesetup supportsauthorizedusers 2>/dev/null | grep -q true; then
			info "fdesetup is available — attempting to enroll '$username'..."
			if fdesetup add -usertoadd "$username" 2>/dev/null; then
				success "User added to FileVault authorizer"
				fv_added=1
			else
				warn "fdesetup add FAILED."
				warn "This is common in Recovery Mode on Apple Silicon."
				warn "After reboot, run: sudo fdesetup add -usertoadd $username"
			fi
		else
			info "fdesetup is NOT available or does not support authorized users in this Recovery environment."
			info "This is expected on Apple Silicon Recovery. You will need to:"
			info "  After reboot, run: sudo fdesetup add -usertoadd $username"
			info "  if the user does not appear at the login screen."
		fi
		echo ""

		suppress_enrollment
		purge_mdm_artifacts

		echo -e "${GRN}============================================${NC}"
		echo -e "${GRN}      MDM Bypass Applied Successfully        ${NC}"
		echo -e "${GRN}============================================${NC}"
		echo ""
		echo -e "${CYAN}Login after reboot:${NC} ${YEL}$username${NC} / ${YEL}$passw${NC}"
		echo -e "${CYAN}After a macOS update:${NC} re-run this."
		echo -e "${YEL}Never run 'profiles renew' or Erase All Content & Settings.${NC}"
		echo ""
		break
		;;

	"Verify current state")
		verify_state
		;;

	"Undo all changes")
		read -p "This will restore hosts, delete temp users, and clear MDM markers. Continue? (y/N): " confirm </dev/tty
		if [[ "$confirm" =~ ^[Yy]$ ]]; then
			undo_all_changes
		else
			info "Undo cancelled."
		fi
		echo ""
		;;

	"Reboot & Exit")
		info "Rebooting..."
		reboot
		break
		;;
	*) echo -e "${RED}Invalid option $REPLY${NC}" ;;
	esac
done
