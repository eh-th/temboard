#!/bin/bash -eu
#
# auto_configure.sh setup and start a temboard-agent to manage a Postgres cluster.
#
# Run auto_configure.sh as root. You configure it like any libpq software. By
# default, the script configure an agent for the running cluster on port 5432,
# using postgres UNIX and PostgreSQL user.
#
# The agent is running on a port computed by reversing Postgres port. e.g. 5432
# generates 2345, 5433 generates 3345, etc.
#
# Each agent has its own user file. This file is emptied by the script.


catchall() {
	if [ $? -gt 0 ] ; then
		fatal "Failure. See ${LOGFILE} for details."
	else
		rm -f ${LOGFILE}
	fi
	trap - INT EXIT TERM
}

fatal() {
	echo -e "\e[1;31m$@\e[0m" | tee -a /dev/fd/3 >&2
	exit 1
}

log() {
	echo "$@" | tee -a /dev/fd/3 >&2
}

query_pgsettings() {
	# Usage: query_pgsettings name [default]

	local name=$1; shift
	local default=${1-}; shift
	val=$(sudo -Eu ${PGUSER} psql -Atc "SELECT setting FROM pg_settings WHERE name = '${name}';")

	echo "${val:-${default}}"
}

generate_configuration() {
	# Usage: generate_configuration homedir sslcert sslkey cluster_name collector_url

	# Generates minimal configuration required to adapt default
	# configuration to this cluster.

	local home=$1; shift
	local sslcert=$1; shift
	local sslkey=$1; shift
	local key=$1; shift
	local instance=$1; shift
	local collector_url=$1; shift

	local port=$(echo $PGPORT | rev)
	log "Configuring temboard-agent to run on port ${port}."
	local pg_ctl=$(which pg_ctl)

	cat <<-EOF
	#
	# Configuration file generated by ${BASH_SOURCE[0]}.
	#

	[temboard]
	home = ${home}
	hostname = ${TEMBOARD_HOSTNAME}
	port = ${port}
	ssl_cert_file = ${sslcert}
	ssl_key_file = ${sslkey}
	key = ${key}

	[logging]
	method = stderr

	[postgresql]
	host = ${PGHOST}
	port = ${PGPORT}
	user = ${PGUSER}
	dbname = ${PGDATABASE}
	instance = ${instance}

	[administration]
	pg_ctl = '${pg_ctl} %s -D ${PGDATA}'

	[monitoring]
	collector_url = ${collector_url}
	EOF
}

search_bindir() {
	# Usage: search_bindir pgversion

	# Search for bin directory where pg_ctl is installed for this version.

	local pgversion=$1; shift
	for d in /usr/lib/postgresql/$pgversion /usr/pgsql-$pgversion ; do
		if [ -x $d/bin/pg_ctl ] ; then
			echo $d/bin
			return
		fi
	done
	return 1
}

setup_pq() {
	# Ensure used libpq vars are defined for configuration template.

	export PGUSER=${PGUSER-postgres}
	log "Configuring for user ${PGUSER}."
	export PGDATABASE=${PGDATABASE-${PGUSER}}
	export PGPORT=${PGPORT-5432}
	log "Configuring for cluster on port ${PGPORT}."
	export PGHOST=${PGHOST-$(query_pgsettings unix_socket_directories)}
	PGHOST=${PGHOST%%,*}
	if ! sudo -Eu ${PGUSER} psql -tc "SELECT 'Postgres connection working.';" ; then
		fatal "Can't connect to Postgres cluster."
	fi
	export PGDATA=$(query_pgsettings data_directory)
	log "Configuring for cluster at ${PGDATA}."

	read PGVERSION < ${PGDATA}/PG_VERSION
	if ! which pg_ctl &>/dev/null ; then
		bindir=$(search_bindir $PGVERSION)
		log "Using ${bindir}/pg_ctl."
		export PATH=$bindir:$PATH
	fi

	# Instance name defaults to cluster_name. If unset (e.g. Postgres 9.4),
	# use the tail of ${PGDATA} after ~postgres has been removed. If PGDATA
	# is not in postgres home, compute a cluster name from version and port.
	local home=$(eval readlink -e ~${PGUSER})
	if [ -z "${PGDATA##${home}/*}" ] ; then
		default_cluster_name=${PGDATA##${home}/}
	else
		default_cluster_name=$PGVERSION/pg${PGPORT}
	fi
	export PGCLUSTER_NAME=$(query_pgsettings cluster_name $default_cluster_name)
}

setup_ssl() {
	local name=${1//\//-}; shift
	local pki;
	for d in /etc/pki/tls /etc/ssl /etc/temboard-agent/$name; do
		if [ -d $d ] ; then
			pki=$d
			break
		fi
	done
	if [ -z "${pki-}" ] ; then
		fatal "Failed to find PKI directory."
	fi

	if [ -f $pki/certs/ssl-cert-snakeoil.pem -a -f $pki/private/ssl-cert-snakeoil.key ] ; then
		log "Using snake-oil SSL certificate."
		sslcert=$pki/certs/ssl-cert-snakeoil.pem
		sslkey=$pki/private/ssl-cert-snakeoil.key
	else
		sslcert=$pki/certs/temboard-agent-$name.pem
		sslkey=$pki/private/temboard-agent-$name.key
		openssl req -new -x509 -days 365 -nodes \
			-subj "/C=XX/ST= /L=Default/O=Default/OU= /CN= " \
			-out $sslcert -keyout $sslkey
	fi
	echo $sslcert $sslkey
}

if [ -n "${DEBUG-}" ] ; then
	exec 3>/dev/null
else
	LOGFILE=/var/log/temboard-agent-auto-configure.log
	exec 3>&2 2>${LOGFILE} 1>&2
	chmod 0600 ${LOGFILE}
	trap 'catchall' INT EXIT TERM
fi

# Now, log everything.
set -x

cd $(readlink -m ${BASH_SOURCE[0]}/..)

ETCDIR=${ETCDIR-/etc/temboard-agent}
VARDIR=${VARDIR-/var/lib/temboard-agent}
LOGDIR=${LOGDIR-/var/log/temboard-agent}

export TEMBOARD_HOSTNAME=${TEMBOARD_HOSTNAME-$(hostname --fqdn)}
if [ -n "${TEMBOARD_HOSTNAME##*.*}" ] ; then
	fatal "FQDN is not properly configured. Set agent hostname with TEMBOARD_HOSTNAME env var.".
fi
log "Using hostname ${TEMBOARD_HOSTNAME}."

ui=${1-${TEMBOARD_UI-}}
if [ -z "${ui}" ] ; then
	fatal "Missing UI url."
fi
if ! curl --silent --show-error --insecure --head ${ui} >/dev/null 2>&3; then
	fatal "Can't contact ${ui}."
fi
collector_url=$ui/monitoring/collector
log "Sending monitoring data to ${ui}."

setup_pq

name=${PGCLUSTER_NAME}
home=${VARDIR}/${name}
# Create directories
install -o ${PGUSER} -g ${PGUSER} -m 0750 -d \
	${ETCDIR}/${name}/temboard-agent.conf.d/ \
	${LOGDIR}/${name} ${home}

# Start with default configuration
log "Configuring temboard-agent in ${ETCDIR}/${name}/temboard-agent.conf ."
install -o ${PGUSER} -g ${PGUSER} -m 0640 temboard-agent.conf ${ETCDIR}/${name}/
install -b -o ${PGUSER} -g ${PGUSER} -m 0600 /dev/null ${ETCDIR}/${name}/users

sslfiles=($(set -eu; setup_ssl $name))
key=$(od -vN 16 -An -tx1 /dev/urandom | tr -d ' \n')

# Inject autoconfiguration in dedicated file.
generate_configuration $home "${sslfiles[@]}" $key $name $collector_url | tee ${ETCDIR}/${name}/temboard-agent.conf.d/auto.conf

# systemd
if [ -x /bin/systemctl ] ; then
	unit=temboard-agent@${name//\//-}.service
	systemctl enable $unit
	log "Enabling systemd unit ${unit}."
	start_cmd="systemctl start $unit"
else
	start_cmd="sudo -u ${PGUSER} temboard-agent -c ${ETCDIR}/${name}/temboard-agent.conf"
fi

log
log "Success. You can now start temboard--agent using:"
log
log "    ${start_cmd}"
log
log "For registration, use secret key ${key} ."
log "See documentation for detailed instructions."
