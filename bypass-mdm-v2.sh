#!/bin/bash
set -euo pipefail

# bypamd-mdm-v2.sh -- DEP/MDM enrollment suppression for macOS.
# IMPORTANT: On Apple Silicon / macOS 11+, the OS boots from a sealed,
# read-only System Volume. The live /etc/hosts and /var/db/ConfigurationProfiles
# actually live on the Data volume (via /private firmlink). This script writes
# to the Data volume paths, which is correct for both Intel and Apple Silicon.
#
# For a more robust solution with FileVault support, launchd override, and
# macOS 26 support, use bypass-mdm-v3.sh.
#
# RUN FROM RECOVERY (Apple Silicon: hold Power -> Options -> Utilities ->
# Terminal). Use responsibly, on devices you own.

RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

error_exit() { echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }
success()    { echo -e "${GRN}\u2713 $1${NC}"; }
info()       { echo -e "${BLU}\u2139 $1${NC}"; }

get_system_volume() {
	diskutil info / | grep "Volume Name:" | awk -F': ' '{print $2}' | xargs
}

system_volume=$(get_system_volume)
data_volume="${system_volume} - Data"

# If the standard "- Data" volume doesn't exist, try "Data"
if [ ! -d "/Volumes/$data_volume" ] && [ -d "/Volumes/Data" ]; then
	data_volume="Data"
fi

if [ ! -d "/Volumes/$data_volume" ]; then
	error_exit "Data volume not found. Ensure you're in Recovery mode."
fi

# Normalize data volume name for consistency
if [ "$data_volume" != "Data" ]; then
	diskutil rename "$data_volume" "Data" 2>/dev/null || true
	data_volume="Data"
fi

echo ""
echo -e "${CYAN}Bypass MDM v2${NC}"
success "System volume: $system_volume"
success "Data volume: $data_volume"
echo ""

PS3='Please enter your choice: '
options=("Bypass MDM from Recovery" "Reboot & Exit")
select opt in "${options[@]}"; do
	case $opt in
	"Bypass MDM from Recovery")
		echo ""
		info "Starting MDM Bypass..."
		echo ""

		# Create Temporary User on the Data volume
		echo -e "${NC}Create a Temporary Admin User${NC}"
		read -p "Enter Temporary Fullname (Default is 'Apple'): " realName
		realName="${realName:=Apple}"
		read -p "Enter Temporary Username (Default is 'Apple'): " username
		username="${username:=Apple}"
		read -p "Enter Temporary Password (Default is '1234'): " passw
		passw="${passw:=1234}"

		dscl_path="/Volumes/Data/private/var/db/dslocal/nodes/Default"
		if [ ! -d "$dscl_path" ]; then
			error_exit "Directory Services path not found: $dscl_path"
		fi

		info "Creating user account: $username"
		dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username"
		dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UserShell "/bin/zsh"
		dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" RealName "$realName"
		dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UniqueID "501"
		dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" PrimaryGroupID "20"
		mkdir -p "/Volumes/Data/Users/$username"
		dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" NFSHomeDirectory "/Users/$username"
		dscl -f "$dscl_path" localhost -passwd "/Local/Default/Users/$username" "$passw"
		dscl -f "$dscl_path" localhost -append "/Local/Default/Groups/admin" GroupMembership "$username"
		success "Admin account created"

		# Block MDM domains on the DATA volume's hosts file (SSV-safe)
		info "Blocking MDM domains..."
		hosts_file="/Volumes/Data/private/etc/hosts"
		[ -f "$hosts_file" ] || touch "$hosts_file"
		grep -q "deviceenrollment.apple.com" "$hosts_file" 2>/dev/null \
			|| echo "0.0.0.0 deviceenrollment.apple.com" >>"$hosts_file"
		grep -q "mdmenrollment.apple.com" "$hosts_file" 2>/dev/null \
			|| echo "0.0.0.0 mdmenrollment.apple.com" >>"$hosts_file"
		grep -q "iprofiles.apple.com" "$hosts_file" 2>/dev/null \
			|| echo "0.0.0.0 iprofiles.apple.com" >>"$hosts_file"
		success "MDM domains blocked"

		# Remove configuration profiles on the DATA volume
		info "Resetting enrollment markers..."
		config_path="/Volumes/Data/private/var/db/ConfigurationProfiles/Settings"
		mkdir -p "$config_path"
		rm -f "$config_path/.cloudConfigHasActivationRecord" \
		      "$config_path/.cloudConfigRecordFound"
		touch "$config_path/.cloudConfigProfileInstalled" \
		      "$config_path/.cloudConfigRecordNotFound"
		touch "/Volumes/Data/private/var/db/.AppleSetupDone"
		success "Configuration profiles reset"

		echo ""
		echo -e "${GRN}============================================${NC}"
		echo -e "${GRN}       MDM Bypass Completed Successfully!    ${NC}"
		echo -e "${GRN}============================================${NC}"
		echo ""
		echo -e "${CYAN}Login after reboot:${NC} ${YEL}$username${NC} / ${YEL}$passw${NC}"
		echo ""
		break
		;;
	"Reboot & Exit")
		info "Rebooting..."
		reboot
		break
		;;
	*) echo -e "${RED}Invalid option $REPLY${NC}" ;;
	esac
done
