[ "$(svcs -Ho state postgresql)" == "online" ] && \
  svcadm disable -s -t postgresql

mdata-get pgsql_pw > /tmp/pgpasswd

log "initializing PostgreSQL"

PGDATA=$(svcprop -p config/data postgresql 2>/dev/null)
: ${PGDATA:=/var/pgsql/data}
[ -d ${PGDATA} ] && rm -rf ${PGDATA}

su - postgres -c "/opt/local/bin/initdb \
                  --pgdata=${PGDATA} \
                  --encoding=UTF8 \
                  --locale=en_US.UTF-8 \
                  --auth=password \
                  --pwfile=/tmp/pgpasswd" >/dev/null || \
  error "PostgreSQL init command failed"

# symlink for the sake of Webmin's config
[ ${PGDATA} != /var/pgsql/data ] && \
  ln -s ${PGDATA} /var/pgsql/data

log "starting PostgreSQL"

svcadm enable -s postgresql && sleep 1

[ "$(svcs -Ho state postgresql)" != "online" ] && \
  error "PostgreSQL failed to start"

log "disabling PostgreSQL by default"

svcadm disable -s postgresql
