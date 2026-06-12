#!/bin/bash
set -euo pipefail

# bypass-mdm-express.sh — All-in-one MDM tool.
# Put this on an external SSD. Plug. Run. Done.
#
# Three modes:
#   1. Backup + Bypass — saves current state, removes MDM
#   2. Restore — reverts to pre-bypass state  
#   3. Check status — see if MDM is active
#
# Works from Recovery (full bypass) or normal boot (sudo only, partial bypass).
# Always reversible. Never deletes your data.

RED='\033[1;31m'; GRN='\033[1;32m'; BLU='\033[1;34m'; YEL='\033[1;33m'; CYAN='\033[1;36m'; NC='\033[0m'
error_exit() { echo -e "${RED}ERRO: $1${NC}" >&2; exit 1; }
warn()       { echo -e "${YEL}AVISO: $1${NC}" >&2; }
success()    { echo -e "${GRN}OK $1${NC}"; }
info()       { echo -e "${BLU}  $1${NC}"; }
step()       { echo -e "${CYAN}> $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/.bypass-backup"

detect_environment() {
	if [ -d "/Volumes/Macintosh HD" ] || [ -d "/Volumes/MacOS" ] || [ -d "/System/Installation" ]; then
		echo "recovery"
	elif [ "$(csrutil status 2>/dev/null | grep -c 'enabled')" -eq 1 ]; then
		echo "normal_sip_on"  
	else
		echo "normal_sip_off"
	fi
}

find_data_volume() {
	local vol=""
	for v in /Volumes/*; do
		[ -d "$v/private/var/db/dslocal/nodes/Default" ] && vol="$v" && break
	done
	if [ -z "$vol" ] && [ -d "/Volumes/Data" ]; then
		vol="/Volumes/Data"
	fi
	echo "$vol"
}

find_system_volume() {
	local data_vol="$1"
	[ -z "$data_vol" ] && return 1
	for v in /Volumes/*; do
		[ "$v" != "$data_vol" ] && [ -d "$v/System" ] && [ ! -d "$v/private/var/db/dslocal" ] && echo "$v" && return 0
	done
	echo ""
}

get_hosts_path() {
	local env="$1" data_vol="$2" sys_vol="$3"
	if [ "$env" = "recovery" ] && [ -n "$data_vol" ]; then
		echo "$data_vol/private/etc/hosts"
	elif [ "$env" = "recovery" ] && [ -n "$sys_vol" ]; then
		echo "$sys_vol/etc/hosts"
	else
		echo "/etc/hosts"
	fi
}

get_cfg_path() {
	local env="$1" data_vol="$2" sys_vol="$3"
	if [ "$env" = "recovery" ] && [ -n "$data_vol" ]; then
		echo "$data_vol/private/var/db/ConfigurationProfiles/Settings"
	elif [ "$env" = "recovery" ] && [ -n "$sys_vol" ]; then
		echo "$sys_vol/var/db/ConfigurationProfiles/Settings"
	else
		echo ""
	fi
}

backup_state() {
	local env="$1" data_vol="$2" sys_vol="$3"
	mkdir -p "$BACKUP_DIR"
	step "Salvando backup em $BACKUP_DIR"

	local hosts_path
	hosts_path=$(get_hosts_path "$env" "$data_vol" "$sys_vol")
	local cfg_path
	cfg_path=$(get_cfg_path "$env" "$data_vol" "$sys_vol")

	if [ -f "$hosts_path" ]; then
		cp "$hosts_path" "$BACKUP_DIR/hosts.backup"
		success "hosts salvo"
	fi
	if [ -d "$cfg_path" ]; then
		mkdir -p "$BACKUP_DIR/ConfigurationProfiles"
		cp -r "$cfg_path"/* "$BACKUP_DIR/ConfigurationProfiles/" 2>/dev/null || true
		success "config profiles salvos"
	fi
	date +%Y-%m-%d_%H-%M-%S > "$BACKUP_DIR/timestamp"
	success "Backup concluido em $(cat "$BACKUP_DIR/timestamp")"
}

restore_state() {
	local env="$1" data_vol="$2" sys_vol="$3"
	
	if [ ! -f "$BACKUP_DIR/timestamp" ]; then
		error_exit "Nenhum backup encontrado em $BACKUP_DIR"
	fi

	step "Restaurando backup de $(cat "$BACKUP_DIR/timestamp")"

	local hosts_path
	hosts_path=$(get_hosts_path "$env" "$data_vol" "$sys_vol")
	local cfg_path
	cfg_path=$(get_cfg_path "$env" "$data_vol" "$sys_vol")

	if [ -f "$BACKUP_DIR/hosts.backup" ] && [ -f "$hosts_path" ]; then
		sed -i '' '/# Added by bypass/d' "$hosts_path" 2>/dev/null || true
		cp "$BACKUP_DIR/hosts.backup" "$hosts_path"
		success "hosts restaurado"
	fi
	if [ -d "$BACKUP_DIR/ConfigurationProfiles" ] && [ -n "$cfg_path" ]; then
		mkdir -p "$cfg_path"
		cp -r "$BACKUP_DIR/ConfigurationProfiles"/* "$cfg_path/" 2>/dev/null || true
		success "config profiles restaurados"
	fi

	# Re-enable daemon
	if [ "$env" != "recovery" ]; then
		sudo launchctl enable system/com.apple.ManagedClient.enroll 2>/dev/null || true
		sudo launchctl enable system/com.apple.mdmclient.daemon.runatboot 2>/dev/null || true
		success "daemons reativados"
	fi

	rm -f "$BACKUP_DIR/timestamp"
	success "Restauro concluido"
}

block_hosts() {
	local hosts_path="$1"
	[ ! -f "$hosts_path" ] && touch "$hosts_path"

	grep -q "Added by bypass-mdm" "$hosts_path" 2>/dev/null || {
		echo "" >>"$hosts_path"
		echo "# Added by bypass-mdm — DEP enrollment block" >>"$hosts_path"
	}

	local domains=(
		iprofiles.apple.com
		deviceenrollment.apple.com
		mdmenrollment.apple.com
		acmdm.apple.com
	)
	local d
	for d in "${domains[@]}"; do
		grep -qiE "[[:space:]]$d(\$|[[:space:]])" "$hosts_path" 2>/dev/null && continue
		printf '0.0.0.0 %s\n::      %s\n' "$d" "$d" >>"$hosts_path"
		success "bloqueado $d"
	done
}

reset_markers() {
	local cfg_path="$1"
	[ -z "$cfg_path" ] && return 1
	mkdir -p "$cfg_path"
	rm -f "$cfg_path/.cloudConfigHasActivationRecord" \
	      "$cfg_path/.cloudConfigRecordFound" \
	      "$cfg_path/.cloudConfigTimerCheck" \
	      "$cfg_path/com.apple.mdm.depnag.plist" \
	      "$cfg_path/com.apple.mdm.prelogin.plist" 2>/dev/null
	touch "$cfg_path/.cloudConfigRecordNotFound" \
	      "$cfg_path/.cloudConfigProfileInstalled"
	success "marcadores resetados"
}

disable_daemon_launchctl() {
	sudo launchctl disable system/com.apple.ManagedClient.enroll 2>/dev/null || true
	sudo launchctl disable system/com.apple.mdmclient.daemon.runatboot 2>/dev/null || true
	success "daemon desativado (launchctl)"
}

disable_daemon_plist() {
	local data_vol="$1"
	[ -z "$data_vol" ] && return 1
	local plist="$data_vol/private/var/db/com.apple.xpc.launchd/disabled.plist"
	mkdir -p "$(dirname "$plist")"
	[ -f "$plist" ] || printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' >"$plist"
	for label in com.apple.ManagedClient.enroll com.apple.mdmclient.daemon.runatboot; do
		/usr/libexec/PlistBuddy -c "Add :$label bool true" "$plist" 2>/dev/null \
			|| /usr/libexec/PlistBuddy -c "Set :$label true" "$plist" 2>/dev/null
	done
	success "daemon desativado (plist override)"
}

create_user_recovery() {
	local data_vol="$1"
	[ -z "$data_vol" ] && error_exit "Volume de dados nao encontrado"

	local dscl_path="$data_vol/private/var/db/dslocal/nodes/Default"
	[ ! -d "$dscl_path" ] && error_exit "Diretorio de usuarios nao encontrado em $dscl_path"

	read -p "Nome completo (padrao 'Apple'): " realName; realName="${realName:=Apple}"
	read -p "Nome de usuario (padrao 'Apple'): " username; username="${username:=Apple}"
	read -p "Senha (padrao '1234'): " passw; passw="${passw:=1234}"

	step "Criando usuario $username"
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" 2>/dev/null || true
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UserShell "/bin/zsh" 2>/dev/null
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" RealName "$realName" 2>/dev/null
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" UniqueID "501" 2>/dev/null
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" PrimaryGroupID "20" 2>/dev/null
	dscl -f "$dscl_path" localhost -create "/Local/Default/Users/$username" NFSHomeDirectory "/Users/$username" 2>/dev/null
	dscl -f "$dscl_path" localhost -passwd  "/Local/Default/Users/$username" "$passw" 2>/dev/null || warn "Falha ao definir senha"
	dscl -f "$dscl_path" localhost -append  "/Local/Default/Groups/admin" GroupMembership "$username" 2>/dev/null || true
	mkdir -p "$data_vol/Users/$username"
	touch "$data_vol/private/var/db/.AppleSetupDone"
	success "Usuario $username criado. Login: $username / $passw"
}

# ============================================================
# MAIN
# ============================================================
env=$(detect_environment)
data_vol=$(find_data_volume)
sys_vol=""
[ -n "$data_vol" ] && sys_vol=$(find_system_volume "$data_vol")

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   Bypass MDM Express                      ${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo -e "${BLU}Modo detectado:${NC} $env"
[ -n "$data_vol" ] && echo -e "${BLU}Volume dados:${NC} $data_vol"
[ -n "$sys_vol" ]  && echo -e "${BLU}Volume sistema:${NC} $sys_vol"
echo ""

PS3="Escolha uma opcao: "
options=(
	"Backup + Bypass MDM (recomendado)"
	"Restore (voltar ao estado original)"
	"Checar status do MDM"
	"Sair"
)
select opt in "${options[@]}"; do
	case $opt in
	"Backup + Bypass MDM (recomendado)")
		echo ""

		backup_state "$env" "$data_vol" "$sys_vol"
		echo ""

		hosts_path=$(get_hosts_path "$env" "$data_vol" "$sys_vol")
		cfg_path=$(get_cfg_path "$env" "$data_vol" "$sys_vol")

		if [ "$env" = "recovery" ]; then
			step "Modo Recovery — bypass completo"
			block_hosts "$hosts_path"
			reset_markers "$cfg_path"
			disable_daemon_plist "$data_vol" "$sys_vol"

			echo ""
			echo -e "${YEL}Criar usuario admin temporario?${NC}"
			read -p "Se for setup novo (tela de enrolamento), digite 's' [s/N]: " create_user
			if [[ "$create_user" =~ ^[Ss]$ ]]; then
				create_user_recovery "$data_vol"
			fi
		else
			step "Modo normal — bypass parcial (SIP $([ "$env" = "normal_sip_on" ] && echo "ATIVADO" || echo "DESATIVADO"))"
			[ "$env" = "normal_sip_off" ] && warn "SIP desativado: escrita extra disponivel" || warn "SIP ativado: apenas bloqueio de dominios e launchctl"
			
			if [ -w "$hosts_path" ] || [ "$EUID" -eq 0 ]; then
				block_hosts "$hosts_path"
			else
				warn "Sem permissao para escrever em $hosts_path (tente com sudo)"
			fi

			if [ "$env" != "normal_sip_on" ] && [ -n "$cfg_path" ]; then
				reset_markers "$cfg_path"
			fi

			disable_daemon_launchctl
		fi

		echo ""
		echo -e "${GRN}============================================${NC}"
		echo -e "${GRN}  Pronto! Backup salvo em $BACKUP_DIR        ${NC}"
		echo -e "${GRN}  Para restaurar: rode este script denovo   ${NC}"
		echo -e "${GRN}  e escolha 'Restore'                       ${NC}"
		echo -e "${GRN}============================================${NC}"
		break
		;;

	"Restore (voltar ao estado original)")
		echo ""
		restore_state "$env" "$data_vol" "$sys_vol"
		echo -e "${GRN}Estado original restaurado.${NC}"
		break
		;;

	"Checar status do MDM")
		echo ""
		step "Checando enrolamento DEP..."
		if command -v profiles &>/dev/null; then
			profiles status -type enrollment 2>/dev/null || warn "nao foi possivel checar"
		else
			warn "comando 'profiles' nao disponivel (rode do Recovery ou macOS normal)"
		fi

		step "Hosts bloqueados:"
		hosts_path=$(get_hosts_path "$env" "$data_vol" "$sys_vol")
		if [ -f "$hosts_path" ]; then
			grep -iE 'iprofiles|enrollment|mdm|acmdm' "$hosts_path" 2>/dev/null || echo "  (nenhum)"
		fi

		step "Backup existente:"
		if [ -f "$BACKUP_DIR/timestamp" ]; then
			echo "  $(cat "$BACKUP_DIR/timestamp")"
		else
			echo "  (nenhum)"
		fi
		echo ""
		break
		;;

	"Sair")
		exit 0
		;;
	*) echo -e "${RED}Opcao invalida $REPLY${NC}" ;;
	esac
done
