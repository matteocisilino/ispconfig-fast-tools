#!/usr/bin/env bash
#
# ispconfig-rotate-credentials.sh
#
# ==============================================================================
# AUTHOR: Matteo Cisilino
# EMAIL: matteocisilino@gmail.com
# COMPATIBILITY: Tested on ISPConfig 3.3.1p1
# LICENSE: Free Software - Use, modify, and distribute with attribution.
#
# DISCLAIMER: USE AT YOUR OWN RISK.
# This script modifies core ISPConfig database credentials. Ensure you have
# an external backup or VM snapshot before running this script. The author
# is not responsible for broken configurations or data loss.
# ==============================================================================
# Ruota le credenziali dopo un incidente di sicurezza su un cluster ISPConfig 3.2.x
# in configurazione "multiserver classico" (1 master DB di controllo, N slave che
# si collegano da remoto allo stesso utente DB di controllo).
#
# Gestisce DUE rotazioni distinte, entrambe eseguite su OGNI nodo (master e slave):
#
#   A) ROOT LOCALE per la gestione dei DB dei siti ospitati
#      (file: /usr/local/ispconfig/server/lib/mysql_clientdb.conf)
#      -> indipendente per ogni nodo, NON condivisa tra i server.
#
#   B) UTENTE DI CONTROLLO ISPConfig (es. "ispconfig") per il DB di configurazione
#      del pannello (file: config.inc.php di server e, sul master, interface)
#      -> condiviso: si cambia sul master e si propaga manualmente sugli slave.
#
# USO:
#   Sul MASTER:
#     sudo ./ispconfig-rotate-credentials.sh master
#
#   Su OGNI SLAVE (dopo aver eseguito lo script sul master):
#     sudo ./ispconfig-rotate-credentials.sh slave
#
#   Se non passi il ruolo, lo script prova ad auto-rilevarlo da db_host nel
#   config file locale (localhost/127.0.0.1 => master).
#
#   Aggiungi --dry-run per vedere cosa farebbe senza modificare nulla.
#   Aggiungi --skip-local-root per saltare la rotazione A) (es. se questo nodo
#   non gestisce database di siti ospitati e non ha mysql_clientdb.conf).
#
set -euo pipefail

DRY_RUN=0
ROLE=""
SKIP_LOCAL_ROOT=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-local-root) SKIP_LOCAL_ROOT=1 ;;
    master|slave) ROLE="$arg" ;;
    *) echo "Argomento sconosciuto: $arg" >&2; exit 1 ;;
  esac
done

ISPCONFIG_DIR=${ISPCONFIG_DIR:-"/usr/local/ispconfig"}
SERVER_CONF="${ISPCONFIG_DIR}/server/lib/config.inc.php"
INTERFACE_CONF="${ISPCONFIG_DIR}/interface/lib/config.inc.php"
CLIENTDB_CONF="${ISPCONFIG_DIR}/server/lib/mysql_clientdb.conf"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${ISPCONFIG_DIR}_$(date +%d%m-%H%M)"
LOGFILE="/root/ispconfig-rotate-${TS}.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

require_root_priv() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Devi eseguire questo script come root (sudo)." >&2
    exit 1
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "File non trovato: $1 — controlla il path di installazione di ISPConfig su questo server." >&2
    exit 1
  fi
}

backup_file() {
  local f="$1"
  local bkp="${f}.bak-${TS}"
  cp -a "$f" "$bkp"
  log "Backup creato: $bkp"
}

php_conf_get() {
  # Estrae il valore di $var['chiave'] = 'valore'; da un file php di ISPConfig
  local varname="$1" key="$2" file="$3"
  grep -oP "\\\$${varname}\\['${key}'\\]\\s*=\\s*'\\K[^']*(?=')" "$file" || true
}

php_var_get() {
  # Estrae il valore di $nome = 'valore'; (senza array associativo)
  local varname="$1" file="$2"
  grep -oP "\\\$${varname}\\s*=\\s*'\\K[^']*(?=')" "$file" || true
}

gen_password() {
  # Password random di 32 caratteri molto forte (solo alfanumerici)
  # per prevenire qualsiasi problema di parsing in my.cnf (es. '#' o '%') o in bash/PHP
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true
}

do_rsync_backup() {
  log "Eseguo il backup completo di ${ISPCONFIG_DIR} in ${BACKUP_DIR} tramite rsync..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN: rsync -aq --delete ${ISPCONFIG_DIR}/ ${BACKUP_DIR}/"
  else
    rsync -aq --delete "${ISPCONFIG_DIR}/" "${BACKUP_DIR}/"
    log "Backup completo di ISPConfig terminato in ${BACKUP_DIR}/"
  fi
}

db_backup() {
  local db_name="$1"
  local dump_file="${BACKUP_DIR}/db_backup_${db_name}_${TS}.sql"
  log "Eseguo il backup del database '$db_name' in $dump_file..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN: mysqldump --defaults-extra-file=... $db_name > $dump_file"
  else
    if mysqldump --defaults-extra-file="$MYSQL_DEFAULTS_FILE" --single-transaction --events --routines "$db_name" > "$dump_file" 2>/dev/null; then
      log "Backup del database '$db_name' completato con successo."
    elif mysqldump --defaults-extra-file="$MYSQL_DEFAULTS_FILE" --skip-events "$db_name" > "$dump_file"; then
      log "Backup del database '$db_name' completato con successo (fallback senza eventi)."
    else
      log "ATTENZIONE: Impossibile effettuare il backup del database '$db_name'. L'operazione mysqldump è fallita silenziosamente o ha restituito errore."
      log "Procedo comunque con la rotazione senza backup del DB per non bloccare il flusso."
    fi
  fi
}

mysql_exec() {
  local sql="$1"
  mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" -N -B -e "$sql"
}

setup_mysql_defaults_file() {
  local user="$1" pass="$2"
  MYSQL_DEFAULTS_FILE="$(mktemp)"
  chmod 600 "$MYSQL_DEFAULTS_FILE"
  cat > "$MYSQL_DEFAULTS_FILE" <<CREDS
[client]
user=${user}
password=${pass}
CREDS
}

cleanup_mysql_defaults_file() {
  [[ -n "${MYSQL_DEFAULTS_FILE:-}" && -f "$MYSQL_DEFAULTS_FILE" ]] && shred -u "$MYSQL_DEFAULTS_FILE" 2>/dev/null || true
}
trap cleanup_mysql_defaults_file EXIT

require_root_priv
require_file "$SERVER_CONF"

# --- Auto-rilevamento ruolo se non specificato ---
if [[ -z "$ROLE" ]]; then
  DBMASTER_HOST_DETECTED="$(php_conf_get conf dbmaster_host "$SERVER_CONF")"
  if [[ -n "$DBMASTER_HOST_DETECTED" && "$DBMASTER_HOST_DETECTED" != "localhost" && "$DBMASTER_HOST_DETECTED" != "127.0.0.1" ]]; then
    ROLE="slave"
  else
    ROLE="master"
  fi
  echo "Ruolo del nodo non specificato. Rilevamento automatico in corso..."
  log "Ruolo auto-rilevato (dbmaster_host=${DBMASTER_HOST_DETECTED:-vuoto}): $ROLE"
else
  echo "Ruolo del nodo specificato manualmente: $ROLE"
  log "Ruolo specificato dall'utente: $ROLE"
fi

log "=== ispconfig-rotate-credentials.sh avviato — nodo ruolo: $ROLE, dry-run: $DRY_RUN ==="

echo "Eseguo rsync della directory ${ISPCONFIG_DIR} come backup di sicurezza (o simulazione in dry-run)..."
do_rsync_backup

# =========================================================
# PARTE A) ROOT LOCALE per gestione DB dei siti ospitati
#          (mysql_clientdb.conf) — su OGNI nodo, master o slave
# =========================================================
if [[ "$SKIP_LOCAL_ROOT" -eq 1 ]]; then
  log "Rotazione root locale (mysql_clientdb.conf) SALTATA per richiesta esplicita (--skip-local-root)."
elif [[ ! -f "$CLIENTDB_CONF" ]]; then
  log "ATTENZIONE: $CLIENTDB_CONF non trovato su questo nodo. Se questo server non gestisce DB di siti ospitati puoi ignorare, altrimenti verifica il path."
else
  CLIENTDB_USER="$(php_var_get clientdb_user "$CLIENTDB_CONF")"
  CLIENTDB_HOST="$(php_var_get clientdb_host "$CLIENTDB_CONF")"

  if [[ -z "$CLIENTDB_USER" ]]; then
    echo "Impossibile determinare clientdb_user da $CLIENTDB_CONF — controlla il file manualmente." >&2
    exit 1
  fi

  echo
  echo "--- ROTAZIONE A) Root/utente locale per DB dei siti ospitati su questo nodo ---"
  echo "Utente configurato in mysql_clientdb.conf: $CLIENTDB_USER (host: ${CLIENTDB_HOST:-locale})"
  read -r -s -p "Password attuale di '${CLIENTDB_USER}' su QUESTO nodo (MySQL locale): " CURRENT_LOCAL_PASS
  echo

  setup_mysql_defaults_file "$CLIENTDB_USER" "$CURRENT_LOCAL_PASS"

  if ! mysql_exec "SELECT 1;" >/dev/null 2>&1; then
    echo "Connessione a MySQL locale come '${CLIENTDB_USER}' fallita: password errata o socket non raggiungibile." >&2
    exit 1
  fi
  log "Connessione MySQL locale verificata come '${CLIENTDB_USER}'."

  NEW_LOCAL_PASS="$(gen_password)"

  echo "Ricerca di tutti gli host associati all'utente '${CLIENTDB_USER}' nel database..."
  mapfile -t LOCAL_USER_HOSTS < <(mysql_exec "SELECT Host FROM mysql.user WHERE User='${CLIENTDB_USER}';")
  if [[ "${#LOCAL_USER_HOSTS[@]}" -eq 0 ]]; then
    echo "Nessun host trovato per l'utente '${CLIENTDB_USER}' in mysql.user su questo nodo." >&2
    exit 1
  fi
  log "Utente '${CLIENTDB_USER}' locale trovato per gli host: ${LOCAL_USER_HOSTS[*]}"

  echo
  echo "Verrà cambiata la password di ${CLIENTDB_USER}@{${LOCAL_USER_HOSTS[*]}} SOLO su questo nodo,"
  echo "e verrà aggiornato: $CLIENTDB_CONF"
  echo -e "\033[1;33m[!] LA NUOVA PASSWORD GENERATA SARA': ${NEW_LOCAL_PASS}\033[0m"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN attivo: nessuna modifica applicata per la parte A)."
  else
    read -r -p "Confermi rotazione A)? (scrivi SI per procedere) " CONFIRM_A
    if [[ "${CONFIRM_A^^}" == "SI" ]]; then
      db_backup "mysql"
      sql_cmds=""
      for h in "${LOCAL_USER_HOSTS[@]}"; do
        echo "Esecuzione: ALTER USER '${CLIENTDB_USER}'@'${h}' IDENTIFIED BY '***';"
        sql_cmds+="ALTER USER '${CLIENTDB_USER}'@'${h}' IDENTIFIED BY '${NEW_LOCAL_PASS}'; "
      done
      sql_cmds+="FLUSH PRIVILEGES;"
      mysql_exec "$sql_cmds"
      
      for h in "${LOCAL_USER_HOSTS[@]}"; do
        log "Password locale ${CLIENTDB_USER}@${h} aggiornata. La vecchia password è stata sovrascritta/eliminata."
      done

      echo "Verifica connessione locale con la nuova password appena impostata..."
      setup_mysql_defaults_file "$CLIENTDB_USER" "$NEW_LOCAL_PASS"
      if mysql_exec "SELECT 1;" >/dev/null 2>&1; then
        echo -e "\033[1;32m[OK] Autenticazione con la nuova password di '${CLIENTDB_USER}' verificata con successo!\033[0m"
      else
        echo -e "\033[1;31m[ERRORE] L'autenticazione con la nuova password di '${CLIENTDB_USER}' è fallita!\033[0m" >&2
      fi


      backup_file "$CLIENTDB_CONF"
      sed -i "s|.*\\\$clientdb_password[ \t]*=.*|\\\$clientdb_password = '${NEW_LOCAL_PASS}';|" "$CLIENTDB_CONF"
      log "Aggiornato clientdb_password in $CLIENTDB_CONF"

      echo
      echo "Nuova password locale (${CLIENTDB_USER} su questo nodo): $NEW_LOCAL_PASS"
      echo "(Non condividere questa password con altri nodi: è locale a questa macchina.)"
    else
      log "Rotazione A) annullata dall'utente."
    fi
  fi
  cleanup_mysql_defaults_file
fi

# =========================================================
# PARTE B) UTENTE STANDARD ISPConfig (locale su ogni nodo)
#          (Tutti i file in server/lib/ e interface/lib/)
# =========================================================
echo
echo "--- ROTAZIONE B) Utente standard ISPConfig (DB locale del pannello) ---"

CTRL_DB_USER="$(php_conf_get conf db_user "$SERVER_CONF")"
if [[ -z "$CTRL_DB_USER" ]]; then
  echo "Impossibile determinare db_user da $SERVER_CONF — controlla il file manualmente." >&2
  exit 1
fi

if [[ -n "${NEW_LOCAL_PASS:-}" && "${CONFIRM_A^^}" == "SI" ]]; then
  echo "Utilizzo la password ROOT locale appena generata nella Parte A per autorizzare questa operazione..."
  MASTER_ROOT_PASS="$NEW_LOCAL_PASS"
else
  read -r -s -p "Password ROOT MySQL locale (per autorizzare il cambio dell'utente '${CTRL_DB_USER}'): " MASTER_ROOT_PASS
  echo
fi

setup_mysql_defaults_file "root" "$MASTER_ROOT_PASS"

if ! mysql_exec "SELECT 1;" >/dev/null 2>&1; then
  echo "Connessione a MySQL come root fallita: password errata o socket non raggiungibile." >&2
  exit 1
fi
log "Connessione root MySQL verificata."

NEW_CTRL_PASS="$(gen_password)"

echo "Ricerca di tutti gli host associati all'utente standard '${CTRL_DB_USER}'..."
mapfile -t CTRL_USER_HOSTS < <(mysql_exec "SELECT Host FROM mysql.user WHERE User='${CTRL_DB_USER}';")
if [[ "${#CTRL_USER_HOSTS[@]}" -eq 0 ]]; then
  echo "Nessun host trovato per l'utente '${CTRL_DB_USER}' in mysql.user." >&2
  exit 1
fi
log "Utente standard '${CTRL_DB_USER}' trovato per gli host: ${CTRL_USER_HOSTS[*]}"

echo
echo "Verrà cambiata la password di ${CTRL_DB_USER}@{${CTRL_USER_HOSTS[*]}} su questo nodo"
echo "e aggiornati tutti i file PHP in ${ISPCONFIG_DIR}/server/lib/ (e interface/lib/ se presente)"
echo -e "\033[1;33m[!] LA NUOVA PASSWORD GENERATA SARA': ${NEW_CTRL_PASS}\033[0m"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY RUN attivo: nessuna modifica applicata per la parte B)."
else
  read -r -p "Confermi rotazione B)? (scrivi SI per procedere) " CONFIRM_B
  if [[ "${CONFIRM_B^^}" == "SI" ]]; then
    CTRL_DB_NAME="$(php_conf_get conf db_database "$SERVER_CONF")"
    if [[ -n "$CTRL_DB_NAME" ]]; then
      db_backup "$CTRL_DB_NAME"
    else
      log "ATTENZIONE: Impossibile rilevare db_database in $SERVER_CONF. Salto backup DB di controllo."
    fi

    sql_cmds=""
    for h in "${CTRL_USER_HOSTS[@]}"; do
      echo "Esecuzione: ALTER USER '${CTRL_DB_USER}'@'${h}' IDENTIFIED BY '***';"
      sql_cmds+="ALTER USER '${CTRL_DB_USER}'@'${h}' IDENTIFIED BY '${NEW_CTRL_PASS}'; "
    done
    sql_cmds+="FLUSH PRIVILEGES;"
    mysql_exec "$sql_cmds"

    for h in "${CTRL_USER_HOSTS[@]}"; do
      log "Password ${CTRL_DB_USER}@${h} aggiornata. La vecchia password è stata sovrascritta/eliminata."
    done

    echo "Verifica connessione con la nuova password per l'utente '${CTRL_DB_USER}'..."
    setup_mysql_defaults_file "$CTRL_DB_USER" "$NEW_CTRL_PASS"
    if mysql_exec "SELECT 1;" >/dev/null 2>&1; then
      echo -e "\033[1;32m[OK] Autenticazione con la nuova password di '${CTRL_DB_USER}' verificata con successo!\033[0m"
    else
      echo -e "\033[1;31m[ERRORE] L'autenticazione con la nuova password di '${CTRL_DB_USER}' è fallita!\033[0m" >&2
    fi


    # Trova e aggiorna tutti i file PHP nelle directory lib
    LIB_DIRS=("${ISPCONFIG_DIR}/server/lib" "${ISPCONFIG_DIR}/interface/lib")
    for d in "${LIB_DIRS[@]}"; do
      if [[ -d "$d" ]]; then
        while IFS= read -r f; do
          if grep -q "\$conf\['db_password'\]" "$f"; then
            backup_file "$f"
            sed -i "s|.*\\\$conf\\['db_password'\\][ \t]*=.*|\\\$conf['db_password'] = '${NEW_CTRL_PASS}';|" "$f"
            log "Aggiornato db_password in $f"
          fi
        done < <(find "$d" -maxdepth 1 -type f -name "*.php" 2>/dev/null)
      fi
    done

    # --- AGGIORNAMENTO SERVIZI ESTERNI ---
    
    # 1. Dovecot
    DOVECOT_CONF="/etc/dovecot/dovecot-sql.conf"
    if [[ -f "$DOVECOT_CONF" ]]; then
      backup_file "$DOVECOT_CONF"
      sed -i "s/password=[^ ]*/password=${NEW_CTRL_PASS}/" "$DOVECOT_CONF"
      log "Aggiornata password in $DOVECOT_CONF"
    fi

    # 2. Pure-FTPd
    PUREFTPD_CONF="/etc/pure-ftpd/db/mysql.conf"
    if [[ -f "$PUREFTPD_CONF" ]]; then
      backup_file "$PUREFTPD_CONF"
      sed -i -E "s/^[[:space:]]*MYSQLPassword.*/MYSQLPassword   ${NEW_CTRL_PASS}/i" "$PUREFTPD_CONF"
      log "Aggiornata MYSQLPassword in $PUREFTPD_CONF"
    fi

    # 3. Postfix
    if ls /etc/postfix/mysql-*.cf 1> /dev/null 2>&1; then
      for f in /etc/postfix/mysql-*.cf; do
        if [[ -f "$f" ]]; then
          backup_file "$f"
          sed -i "s/^password[ \t]*=.*/password = ${NEW_CTRL_PASS}/" "$f"
          log "Aggiornata password in $f"
        fi
      done
    fi
    # --- FINE AGGIORNAMENTO SERVIZI ESTERNI ---

    echo
    echo "=================================================================="
    echo " Nuova password utente standard '${CTRL_DB_USER}' applicata con successo."
    echo "=================================================================="
  else
    log "Rotazione B) annullata dall'utente."
  fi
fi

# =========================================================
# PARTE C) UTENTE SLAVE SUL MASTER DB (Solo sui nodi Slave)
# =========================================================
if [[ "$ROLE" == "slave" ]]; then
  echo
  echo "--- ROTAZIONE C) Utente slave ISPConfig sul Master DB remoto ---"
  
  DBMASTER_USER="$(php_conf_get conf dbmaster_user "$SERVER_CONF")"
  DBMASTER_HOST="$(php_conf_get conf dbmaster_host "$SERVER_CONF")"
  
  if [[ -z "$DBMASTER_USER" || -z "$DBMASTER_HOST" ]]; then
    echo "Impossibile determinare dbmaster_user o dbmaster_host da $SERVER_CONF (forse non è uno slave?)." >&2
  else
    echo "Il nodo slave si connette al Master ($DBMASTER_HOST) con l'utente '$DBMASTER_USER'."
    read -r -s -p "Password ROOT MySQL del MASTER remoto ($DBMASTER_HOST): " REMOTE_MASTER_ROOT_PASS
    echo
    
    setup_mysql_defaults_file "root" "$REMOTE_MASTER_ROOT_PASS"
    
    if ! mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" -h "$DBMASTER_HOST" -N -B -e "SELECT 1;" >/dev/null 2>&1; then
      echo "Connessione al Master MySQL remoto come root fallita. Verifica credenziali e firewall." >&2
      exit 1
    fi
    log "Connessione root al Master remoto ($DBMASTER_HOST) verificata."
    
    NEW_DBMASTER_PASS="$(gen_password)"
    
    echo "Ricerca di tutti gli host associati all'utente slave '${DBMASTER_USER}' sul Master remoto..."
    mapfile -t REMOTE_USER_HOSTS < <(mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" -h "$DBMASTER_HOST" -N -B -e "SELECT Host FROM mysql.user WHERE User='${DBMASTER_USER}';")
    if [[ "${#REMOTE_USER_HOSTS[@]}" -eq 0 ]]; then
      echo "Nessun host trovato per l'utente '${DBMASTER_USER}' in mysql.user sul Master remoto." >&2
      exit 1
    fi
    log "Utente slave '${DBMASTER_USER}' trovato sul master per gli host: ${REMOTE_USER_HOSTS[*]}"
    
    echo
    echo "Verrà cambiata la password di ${DBMASTER_USER}@{${REMOTE_USER_HOSTS[*]}} sul MASTER DB ($DBMASTER_HOST)"
    echo "e verrà aggiornato dbmaster_password localmente su questo nodo."
    echo -e "\033[1;33m[!] LA NUOVA PASSWORD GENERATA SARA': ${NEW_DBMASTER_PASS}\033[0m"
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY RUN attivo: nessuna modifica applicata per la parte C)."
    else
      read -r -p "Confermi rotazione C)? (scrivi SI per procedere) " CONFIRM_C
      if [[ "${CONFIRM_C^^}" == "SI" ]]; then
        sql_cmds=""
        for h in "${REMOTE_USER_HOSTS[@]}"; do
          echo "Esecuzione remota: ALTER USER '${DBMASTER_USER}'@'${h}' IDENTIFIED BY '***';"
          sql_cmds+="ALTER USER '${DBMASTER_USER}'@'${h}' IDENTIFIED BY '${NEW_DBMASTER_PASS}'; "
        done
        sql_cmds+="FLUSH PRIVILEGES;"
        mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" -h "$DBMASTER_HOST" -N -B -e "$sql_cmds"
        
        for h in "${REMOTE_USER_HOSTS[@]}"; do
          log "Password remota ${DBMASTER_USER}@${h} aggiornata sul Master."
        done
        
        echo "Verifica connessione remota con la nuova password per l'utente '${DBMASTER_USER}' sul Master..."
        setup_mysql_defaults_file "$DBMASTER_USER" "$NEW_DBMASTER_PASS"
        if mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE" -h "$DBMASTER_HOST" -N -B -e "SELECT 1;" >/dev/null 2>&1; then
          echo -e "\033[1;32m[OK] Autenticazione remota con la nuova password verificata con successo!\033[0m"
        else
          echo -e "\033[1;31m[ERRORE] L'autenticazione remota con la nuova password è fallita!\033[0m" >&2
        fi

        
        # Aggiorna dbmaster_password locale
        LIB_DIRS=("${ISPCONFIG_DIR}/server/lib" "${ISPCONFIG_DIR}/interface/lib")
        for d in "${LIB_DIRS[@]}"; do
          if [[ -d "$d" ]]; then
            while IFS= read -r f; do
              if grep -q "\$conf\['dbmaster_password'\]" "$f"; then
                backup_file "$f"
                sed -i "s|.*\\\$conf\\['dbmaster_password'\\][ \t]*=.*|\\\$conf['dbmaster_password'] = '${NEW_DBMASTER_PASS}';|" "$f"
                log "Aggiornato dbmaster_password in $f"
              fi
            done < <(find "$d" -maxdepth 1 -type f -name "*.php" 2>/dev/null)
          fi
        done
        
        echo
        echo "=================================================================="
        echo " Nuova password utente slave '${DBMASTER_USER}' applicata con successo."
        echo "=================================================================="
      else
        log "Rotazione C) annullata dall'utente."
      fi
    fi
  fi
fi

cleanup_mysql_defaults_file

echo
echo "Verifica dopo l'esecuzione su master + tutti gli slave:"
echo "  tail -f /var/log/ispconfig/ispconfig.log"

if [[ "${CONFIRM_B:-}" == "SI" || "${CONFIRM_B:-}" == "si" ]] && [[ "$DRY_RUN" -eq 0 ]]; then
  echo
  read -r -p "Vuoi riavviare i servizi (Dovecot, Pure-FTPd, Postfix) per applicare la nuova password? [SI/no]: " RESTART_SRV
  if [[ -z "$RESTART_SRV" || "${RESTART_SRV^^}" == "SI" ]]; then
    log "Riavvio servizi richiesto dall'utente..."
    for svc in dovecot pure-ftpd-mysql pure-ftpd postfix; do
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "Riavvio di $svc in corso..."
        systemctl restart "$svc" || true
        log "Servizio $svc riavviato."
      fi
    done
    echo "Riavvio completato."
  else
    echo "Riavvio ignorato. Ricordati di riavviarli manualmente."
  fi
fi

log "=== Script terminato ==="
