# Get password from metadata, unless passed as MYSQL_PW.
# If neither then generate our own password.
MYSQL_PW=${MYSQL_PW:-$(mdata-get mysql_pw 2>/dev/null)} || MYSQL_PW=$(od -An -N8 -x /dev/random | head -1 | tr -d ' ');

# Start with a MB representation of the zone memory size
MYSQL_RAM_IN_MB=$((RAM_IN_BYTES/1024/1024))

# Only dedicate half the memory to MySQL, this is a multi-purpose dataset
((MYSQL_RAM_IN_MB=MYSQL_RAM_IN_MB/2))

# If MySQL is 32bit, force the limits down so that a total memory footprint
# larger than 2 GB is never reached, otherwise MySQL would crash
if ! file /opt/local/sbin/mysqld | grep AMD64 >/dev/null && \
   [ ${MYSQL_RAM_IN_MB} -gt 2048 ]; then
  MYSQL_RAM_IN_MB=2048
fi

# Default query to lock down access and clean up
MYSQL_INIT="DELETE from mysql.user;
GRANT ALL on *.* to 'root'@'localhost' identified by '${MYSQL_PW}' with grant option;
GRANT ALL on *.* to 'root'@'${PRIVATE_IP:-${PUBLIC_IP}}' identified by '${MYSQL_PW}' with grant option;
GRANT LOCK TABLES,SELECT,RELOAD,SUPER,REPLICATION CLIENT on *.* to '${QB_US}'@'localhost' identified by '${QB_PW}';
DROP DATABASE test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;";

# MySQL tuning
MY_KBF=$((${MYSQL_RAM_IN_MB}/6*10/10))
[ ${MY_KBF} -lt 1000 ] && MY_KBF=$((${MY_KBF}/10*10)) || MY_KBF=$((${MY_KBF}/100*100))
[ ${MY_KBF} -le 40 ] && MY_KBF=25

MY_IBS=${MY_KBF}

MY_ILS=$(echo -e "scale=1; ${MYSQL_RAM_IN_MB}/15/100" | bc) && MY_ILS=$(printf "%.0f" ${MY_ILS}) && MY_ILS=$((${MY_ILS}*100))
[ ${MY_ILS} -lt 100 ] && MY_ILS=50
[ ${MY_ILS} -gt 400 ] && MY_ILS=400

MY_MSB=$((${MYSQL_RAM_IN_MB}/30))
[ ${MY_MSB} -lt 50 ] && MY_MSB=32 || MY_MSB=64

MY_TBC=$((${MYSQL_RAM_IN_MB}/4))
[ ${MY_TBC} -lt 256 ] && MY_TBC=256
[ ${MY_TBC} -gt 512 ] && MY_TBC=512

MY_QRC=$((${MYSQL_RAM_IN_MB}/60))
[ ${MY_QRC} -lt 10 ] && MY_QRC=8
[ ${MY_QRC} -gt 10 ] && [ ${MY_QRC} -lt 35 ] && MY_QRC=16
[ ${MY_QRC} -gt 35 ] && MY_QRC=32

MY_MXC=$((${MYSQL_RAM_IN_MB}/4/100*100))
[ ${MY_MXC} -eq 1000 ] && MY_MXC=500
[ ${MY_MXC} -eq 2000 ] && MY_MXC=1000
[ ${MY_MXC} -gt 3000 ] && MY_MXC=5000

MY_THC=$((${MY_MXC}/2))
[ ${MY_THC} -gt 1000 ] && MY_THC=1000

log "tuning MySQL configuration"
sed -i'' \
	-e "s/##MY_KBF##/${MY_KBF}M/" \
	-e "s/##MY_IBS##/${MY_IBS}M/" \
	-e "s/##MY_ILS##/${MY_ILS}M/" \
	-e "s/##MY_MSB##/${MY_MSB}M/" \
	-e "s/##MY_TBC##/${MY_TBC}/" \
	-e "s/##MY_THC##/${MY_THC}/" \
	-e "s/##MY_QRC##/${MY_QRC}M/" \
	-e "s/##MY_MXC##/${MY_MXC}/" \
	-e "s/##PRIVATE_IP##/${PRIVATE_IP}/" \
	/opt/local/etc/my.cnf

if [[ "$(svcs -Ho state mysql)" == "online" ]]; then
	log "disabling existing MySQL instance"
	svcadm disable -s -t mysql
fi

log "starting the new MySQL instance"
svcadm enable mysql

log "waiting for the socket to show up"
while [[ ! -e /tmp/mysql.sock ]]; do
	sleep 1
	((COUNT=COUNT+1))
	if [[ ${COUNT} -eq 60 ]]; then
          log "ERROR Could not talk to MySQL after 60 seconds"
          ERROR=yes
          break 1
	fi
done
[[ -n "${ERROR}" ]] && exit 31;

log "it took ${COUNT} seconds to start properly"
sleep 1

[[ "$(svcs -Ho state mysql)" == "online" ]] || \
  (log "ERROR MySQL SMF not reporting as 'online'" && exit 31)

log "running the access lockdown SQL query"
mysql -u root -e "${MYSQL_INIT}" >/dev/null || \
  (log "ERROR MySQL query failed to execute." && exit 31)
