#!/bin/sh

# zfs namespace
NS="poudriere"
IPS="$(sysctl -n kern.features.inet 2>/dev/null || (sysctl -n net.inet 1>/dev/null 2>&1 && echo 1) || echo 0)$(sysctl -n kern.features.inet6 2>/dev/null || (sysctl -n net.inet6 1>/dev/null 2>&1 && echo 1) || echo 0)"
RELDATE=$(sysctl kern.osreldate)

dir_empty() {
	find $1 -maxdepth 0 -empty
}

err() {
	if [ $# -ne 2 ]; then
		err 1 "err expects 2 arguments: exit_number \"message\""
	fi
	local err_msg="Error: $2"
	msg "${err_msg}" >&2
	[ -n "${MY_JOBID}" ] && job_msg "${err_msg}"
	exit $1
}

msg_n() { echo -n "====>> $1"; }
msg() { echo "====>> $1"; }
msg_verbose() {
	[ ${VERBOSE:-0} -gt 0 ] || return 0
	msg "$1"
}

msg_debug() {
	[ ${VERBOSE:-0} -gt 1 ] || return 0
	msg "DEBUG: $1" >&2
}

job_msg() {
	[ -n "${MY_JOBID}" ] || return 0
	msg "[${MY_JOBID}] $1" >&5
}

job_msg_verbose() {
	[ -n "${MY_JOBID}" ] || return 0
	msg_verbose "[${MY_JOBID}] $1" >&5
}

my_path() {
	echo ${MASTERMNT}${MY_JOBID+/../${MY_JOBID}}
}

my_name() {
	echo ${MASTERNAME}${MY_JOBID+-job-${MY_JOBID}}
}

eargs() {
	case $# in
	0) err 1 "No arguments expected" ;;
	1) err 1 "1 argument expected: $1" ;;
	*) err 1 "$# arguments expected: $*" ;;
	esac
}

log_start() {
	local logfile=$1

	# Make sure directory exists
	mkdir -p ${logfile%/*}

	exec 3>&1 4>&2
	[ ! -e ${logfile}.pipe ] && mkfifo ${logfile}.pipe
	tee ${logfile} < ${logfile}.pipe >&3 &
	export tpid=$!
	exec > ${logfile}.pipe 2>&1

	# Remove fifo pipe file right away to avoid orphaning it.
	# The pipe will continue to work as long as we keep
	# the FD open to it.
	rm -f ${logfile}.pipe
}

log_path() {
	echo "${POUDRIERE_DATA}/logs/${POUDRIERE_BUILD_TYPE}/${MASTERNAME}"
}

buildlog_start() {
	local portdir=$1
	local name=$(my_name)
	local mnt=$(my_path)

	echo "build started at $(date)"
	echo "port directory: ${portdir}"
	echo "building for: $(jail -c path=${mnt} command=uname -a)"
	echo "maintained by: $(jail -c path=${mnt} command=make -C ${portdir} maintainer)"
	echo "Makefile ident: $(ident ${mnt}/${portdir}/Makefile|sed -n '2,2p')"

	echo "---Begin Environment---"
	jail -c path=${mnt} command=env ${PKGENV} ${PORT_FLAGS}
	echo "---End Environment---"
	echo ""
	echo "---Begin make.conf---"
	cat ${mnt}/etc/make.conf
	echo "---End make.conf---"
	echo ""
	echo "---Begin OPTIONS List---"
	jail -c path=${mnt} command=make -C ${portdir} showconfig
	echo "---End OPTIONS List---"
}

buildlog_stop() {
	local portdir=$1

	echo "build of ${portdir} ended at $(date)"
}

log_stop() {
	if [ -n "${tpid}" ]; then
		exec 1>&3 3>&- 2>&4 4>&-
		wait $tpid
		unset tpid
	fi
}

attr_set() {
	local type=$1
	local name=$2
	local property=$3
	shift 3
	mkdir -p ${POUDRIERED}/${type}/${name}
	echo "$@" > ${POUDRIERED}/${type}/${name}/${property} || :
}

jset() { attr_set jails $@ ; }
pset() { attr_set ports $@ ; }

attr_get() {
	local type=$1
	local name=$2
	local property=$3
	cat ${POUDRIERED}/${type}/${name}/${property} || :
}

jget() { attr_get jails $@ ; }
pget() { attr_get ports $@ ; }

#build getter/setter
bget() {
	local id property mnt
	if [ $# -eq 2 ]; then
		id=$1
		shift
	fi
	property=$1
	mnt=${MASTERMNT}${id:+/../${id}}

	cat ${mnt}/poudriere/${property} || :
}

bset() {
	local id property mnt
	if [ $# -eq 3 ]; then
		id=$1
		shift
	fi
	property=$1
	mnt=${MASTERMNT}${id:+/../${MY_JOBID}}
	shift
	echo "$@" > ${mnt}/poudriere/${property} || :
}

sig_handler() {
	trap - SIGTERM SIGKILL
	# Ignore SIGINT while cleaning up
	trap '' SIGINT
	err 1 "Signal caught, cleaning up and exiting"
}

exit_handler() {
	# Avoid recursively cleaning up here
	trap - EXIT SIGTERM SIGKILL
	# Ignore SIGINT while cleaning up
	trap '' SIGINT
	[ ${STATUS} -eq 1 ] && cleanup
	[ -n ${CLEANUP_HOOK} ] && ${CLEANUP_HOOK}
}

siginfo_handler() {
	if [ "${POUDRIERE_BUILD_TYPE}" != "bulk" ]; then
		return 0;
	fi
	local status=$(bget status)
	local nbb=$(bget stats_built|sed -e 's/ //g')
	local nbf=$(bget stats_failed|sed -e 's/ //g')
	local nbi=$(bget stats_ignored|sed -e 's/ //g')
	local nbs=$(bget stats_skipped|sed -e 's/ //g')
	local nbq=$(bget stats_queued|sed -e 's/ //g')
	local ndone=$((nbb + nbf + nbi + nbs))
	local queue_width=2
	local j status

	if [ ${nbq} -gt 9999 ]; then
		queue_width=5
	elif [ ${nbq} -gt 999 ]; then
		queue_width=4
	elif [ ${nbq} -gt 99 ]; then
		queue_width=3
	fi

	printf "[${MASTERNAME}] [${status}] [%0${queue_width}d/%0${queue_width}d] Built: %-${queue_width}d Failed: %-${queue_width}d  Ignored: %-${queue_width}d  Skipped: %-${queue_width}d  \n" \
	  ${ndone} ${nbq} ${nbb} ${nbf} ${nbi} ${nbs}

	# Skip if stopping or starting jobs
	if [ -n "${JOBS}" -a "${status#starting_jobs:}" = "${status}" -a "${status}" != "stopping_jobs:" ]; then
		for j in ${JOBS}; do
			# Ignore error here as the zfs dataset may not be cloned yet.
			status=$(bget ${j} status 2>/dev/null || :)
			# Skip builders not started yet
			[ -z "${status}" ] && continue
			# Hide idle workers
			[ "${status}" = "idle:" ] && continue
			echo -e "\t[${j}]: ${status}"
		done
	fi
}

jail_exists() {
	[ $# -ne 1 ] && eargs jailname
	local jname=$1
	[ -d ${POUDRIERED}/jails/${jname} ] && return 0
	return 1
}

jail_runs() {
	[ $# -ne 1 ] && eargs jname
	local jname=$1
	[ -d ${POUDRIERE_DATA}/build/${MASTERNAME}/ref ] && return 0
	return 1
}

porttree_list() {
	local name method mntpoint
	for p in $(find ${POUDRIERED}/ports -type d -maxdepth 1 -mindepth 1 -print); do
		name=${p##*/}
		mnt=$(pget ${name} mnt)
		method=$(pget ${name} method)
		echo "${name} ${method:--} ${mnt}"
	done
}

porttree_exists() {
	[ $# -ne 1 ] && eargs portstree_name
	porttree_list |
		awk -v portstree_name=$1 '
		BEGIN { ret = 1 }
		$1 == portstree_name {ret = 0; }
		END { exit ret }
		' && return 0
	return 1
}

get_data_dir() {
	local data
	if [ -n "${POUDRIERE_DATA}" ]; then
		echo ${POUDRIERE_DATA}
		return
	fi

	if [ -z "${NO_ZFS}" ]; then
		data=$(zfs list -rt filesystem -H -o ${NS}:type,mountpoint ${ZPOOL}${ZROOTFS} | awk '$1 == "data" { print $2 }' | head -n 1)
		if [ -n "${data}" ]; then
			echo $data
		return
		fi
		zfs create -p -o ${NS}:type=data \
			-o mountpoint=${BASEFS}/data \
			${ZPOOL}${ZROOTFS}/data
	else
		mkdir -p "${BASEFS}/data"
	fi
	echo "${BASEFS}/data"
}

fetch_file() {
	[ $# -ne 2 ] && eargs destination source
	fetch -p -o $1 $2 || fetch -p -o $1 $2 || err 1 "Failed to fetch from $2"
}

createfs() {
	[ $# -ne 3 ] && eargs name mnt fs
	local name mnt fs
	name=$1
	mnt=$(echo $2 | sed -e "s,//,/,g")
	fs=$3

	if [ -n "${fs}" -a "${fs}" != "none" ]; then
		msg_n "Creating ${name} fs..."
		zfs create -p \
			-o mountpoint=${mnt} ${fs} || err 1 " Fail" && echo " done"
	else
		mkdir -p ${mnt}
	fi
}

rollbackfs() {
	[ $# -ne 2 ] && eargs name mnt
	local name=$1
	local mnt=$2
	local fs=$(zfs_getfs ${mnt})

	if [ -n "${fs}" ]; then
		zfs rollback -r ${fs}@${name}  || err 1 "Unable to rollback ${fs}"
		return
	fi

	mtree -X ${mnt}/poudriere/mtree.${name}exclude \
	-xr -f ${mnt}/poudriere/mtree.${name} -p ${mnt} | \
	while read l ; do
		case "$l" in
		*extra*Directory*) rm -rf ${mnt}/${l%% *} 2>/dev/null ;;
		*changed|*missing) echo ${MASTERMNT}/${l% *} ;;
		esac
	done | pax -rw -p p -s ",${MASTERMNT},,g" ${mnt}
}

umountfs() {
	[ $# -lt 1 ] && eargs mnt childonly
	local mnt=$1
	local childonly=$2
	local pattern
	
	[ -n "${childonly}" ] && pattern="/"

	[ -d "${mnt}" ] || return 0
	mnt=$(realpath ${mnt})
	mount | sort -r -k 2 | while read dev on pt opts; do
		case ${pt} in
		${mnt}${pattern}*)
			umount -f ${pt} || :
			if [ "${dev#/dev/md*}" != "${dev}" ]; then
				mdconfig -d -u ${dev#/dev/md*}
			fi
		;;
		esac
	done
}

zfs_getfs() {
	[ $# -ne 1 ] && eargs mnt
	local mnt=$(realpath $1)
	mount -t zfs | awk -v n="${mnt}" ' $3 == n { print $1 }'
}

unmarkfs() {
	[ $# -ne 2 ] && eargs name mnt
	local name=$1
	local mnt=$(realpath $2)

	if [ -n "$(zfs_getfs ${mnt})" ]; then
		zfs destroy -f ${fs}@${name} 2>/dev/null || :
	else
		rm -f ${mnt}/poudriere/mtree.${name} 2>/dev/null || :
	fi
}

markfs() {
	[ $# -lt 2 ] && eargs name mnt
	local name=$1
	local mnt=$(realpath $2)
	local fs="$(zfs_getfs ${mnt})"
	local dozfs=0
	local domtree=0

	case "${name}" in
	clean) [ -n "${fs}" ] && dozfs=1 ;;
	prepkg)
		[ -n "${fs}" ] && dozfs=1
		[ "${dozfs}" -eq 0 -a  "${mnt##*/}" != "ref" ] && domtree=1
		;;
	preinst) domtree=1 ;;
	esac

	if [ $dozfs -eq 1 ]; then
		# remove old snapshot if exists
		zfs destroy -r ${fs}@${name} 2>/dev/null || :
		#create new snapshot
		zfs snapshot ${fs}@${name}
	fi

	[ $domtree -eq 0 ] && return 0
	mkdir -p ${mnt}/poudriere/
	if [ "${name}" = "prepkg" ]; then
		cat > ${mnt}/poudriere/mtree.${name}exclude << EOF
./poudriere/*
./compat/linux/proc
./wrkdirs/*
./${LOCALBASE:-/usr/local}/*
./packages/*
./usr/ports/*
./distfiles/*
./ccache/*
./var/db/ports/*
EOF
	elif [ "${name}" = "preinst" ]; then
		cat >  ${mnt}/poudriere/mtree.${name}exclude << EOF
./poudriere/*
./var/db/pkg/*
./var/run/*
./wrkdirs/*
./tmp/*
./${LOCALBASE:-/usr/local}/share/nls/POSIX
./${LOCALBASE:-/usr/local}/share/nls/en_US.US-ASCII
./var/db/fontconfig
./var/log/*
./${HOME}/*
./etc/spwd.db
./etc/pwd.db
./etc/group
./etc/make.conf
./etc/make.conf.bak
./etc/passwd
./etc/master.passwd
./etc/shells
EOF
	fi
	mtree -X ${mnt}/poudriere/mtree.${name}exclude \
		-xcn -k uid,gid,mode,size \
		-p ${mnt} >> ${mnt}/poudriere/mtree.${name}
}

clonefs() {
	[ $# -lt 2 ] && eargs from to snap
	local from=$1
	local to=$2
	local snap=$3
	local name=${to##*/}
	local fs=$(zfs_getfs ${from})

	[ -d ${to} ] && destroyfs ${to} jail
	mkdir -p ${to}
	to=$(realpath ${to})
	[ ${TMPFS_ALL} -eq 1 ] && unset fs
	if [ -n "${fs}" ]; then
		# Make sure the fs is clean before cloning
		zfs rollback -R ${fs}@${snap}
		zfs clone -o mountpoint=${to} \
			${fs}@${snap} \
			${fs}/${name}
	else
		[ ${TMPFS_ALL} ] && mount -t tmpfs tmpfs ${to}
		pax -X -rw -p p -s ",${from},,g" ${from} ${to}
	fi
}

destroyfs() {
	[ $# -ne 2 ] && eargs name type
	local mnt fs type
	mnt=$1
	type=$2
	[ -d ${mnt} ] || return 0
	mnt=$(realpath ${mnt})
	fs=$(zfs_getfs ${mnt})
	umountfs ${mnt} 1
	if [ ${TMPFS_ALL} -eq 1 ]; then
		umount -f ${mnt} 2>/dev/null || :
	elif [ -n "${fs}" -a "${fs}" != "none" ]; then
		zfs destroy -r ${fs}
		rmdir ${mnt}
	else
		[ $type = "jail" ] && chflags -R noschg ${mnt}
		rm -rf ${mnt}
	fi
}

jrun() {
	[ $# -ne 3 ] && eargs jname mnt network
	local jname=$1
	local mnt=$2
	local network=$3
	local ipargs
	if [ ${network} -eq 0 ]; then
		case $IPS in
		01) ipargs="ip6.addr=::1" ;;
		10) ipargs="ip4.addr=127.0.0.1" ;;
		11) ipargs="ip4.addr=127.0.0.1 ip6.addr=::1" ;;
		esac
	else
		case $IPS in
		01) ipargs="ip6=inherit" ;;
		10) ipargs="ip4=inherit" ;;
		11) ipargs="ip4=inherit ip6=inherit" ;;
		esac
	fi
	jail -c persist name=${jname} ${ipargs} path=${mnt} \
		host.hostname=${jname} allow.sysvipc \
		allow.socket_af allow.raw_sockets allow.chflags
}

jr() {
	[ $# -le 3 ] && eargs jname mnt network
	local jname=$1
	local mnt=$2
	local network=$3
	local ipargs logarg tmarg extraargs
	shift 3
	if [ ${network} -eq 0 ]; then
		case $IPS in
		01) ipargs="ip6.addr=::1" ;;
		10) ipargs="ip4.addr=127.0.0.1" ;;
		11) ipargs="ip4.addr=127.0.0.1 ip6.addr=::1" ;;
		esac
	elif [ ${network} -eq 1 ]; then
		case $IPS in
		01) ipargs="ip6=inherit" ;;
		10) ipargs="ip4=inherit" ;;
		11) ipargs="ip4=inherit ip6=inherit" ;;
		esac
	else
		case $IPS in
		01) ipargs="ip6=disable" ;;
		10) ipargs="ip4=disable" ;;
		11) ipargs="ip6=disable ip4=disable" ;;
		esac
	fi

	if [ ${RELDATE} -gt 901000 ]; then
		[ -n "EXECTIMEOUT" ] && tmarg=exec.timeout=${EXECTIMEOUT}
		[ -n "LOGFILE" ] && logarg=exec.consolelog=${LOGFILE}
		extraargs="exec.clean ${tmarg} ${logarg}"
	fi
	jail -c name=${jname} ${ipargs} path=${mnt} \
		host.hostname=${jname} allow.chflags \
		${extraargs} command="$@"
	unset EXECTIMEOUT
}

do_jail_mounts() {
	[ $# -ne 2 ] && eargs mnt arch
	local mnt=$1
	local arch=$2
	local devfspath="null zero random urandom stdin stdout stderr fd fd/*"

	# clone will inherit from the ref jail
	if [ ${mnt##*/} = "ref" ]; then
		mkdir -p ${mnt}/proc
		mkdir -p ${mnt}/dev
		mkdir -p ${mnt}/compat/linux/proc
		mkdir -p ${mnt}/usr/ports
		mkdir -p ${mnt}/wrkdirs
		mkdir -p ${mnt}/${LOCALBASE:-/usr/local}
		mkdir -p ${mnt}/distfiles
		mkdir -p ${mnt}/packages
		mkdir -p ${mnt}/ccache
		mkdir -p ${mnt}/var/db/ports
	fi

	# ref jail only needs devfs
	mount -t devfs devfs ${mnt}/dev
	devfs -m ${mnt}/dev rule apply hide
	for p in ${devfspath} ; do
		devfs -m ${mnt}/dev/ rule apply path "${p}" unhide
	done
	if [ "${mnt##*/}" != "ref" ]; then
		mount -t fdescfs fdesc ${mnt}/dev/fd
		mount -t procfs proc ${mnt}/proc
		if [ -z "${NOLINUX}" ]; then
			if [ "${arch}" = "i386" -o "${arch}" = "amd64" ]; then
				mount -t linprocfs linprocfs ${mnt}/compat/linux/proc
			fi
		fi
	fi
}

use_options() {
	[ $# -ne 2 ] && eargs mnt optionsdir
	local mnt=$1
	local optionsdir=$2

	if [ "${optionsdir}" = "-" ]; then
		optionsdir="${POUDRIERED}/options"
	else
		optionsdir="${POUDRIERED}/${optionsdir}-options"
	fi
	[ -d "${optionsdir}" ] || return 1
	optionsdir=$(realpath ${optionsdir} 2>/dev/null)
	msg "Mounting /var/db/ports from: ${optionsdir}"
	mount -t nullfs -o ro ${optionsdir} ${mnt}/var/db/ports || err 1 "Failed to mount OPTIONS directory"

	return 0
}

do_portbuild_mounts() {
	[ $# -lt 3 ] && eargs mnt jname ptname setname
	local mnt=$1
	local jname=$2
	local ptname=$3
	local setname=$4
	local portsdir=$(pget ${ptname} mnt)
	local optionsdir

	optionsdir="${MASTERNAME}"
	[ -n "${setname}" ] && optionsdir="${optionsdir} ${jname}-${setname}"
	optionsdir="${optionsdir} ${jname}-${ptname} ${jname} -"
 
	mkdir -p ${POUDRIERE_DATA}/packages/${MASTERNAME}/All
	if [ ${mnt##*/} != "ref" ]; then
		if [ -d "${CCACHE_DIR:-/nonexistent}" ]; then
			msg "Mounting ccache from: ${CCACHE_DIR}"
			mount -t nullfs ${CCACHE_DIR} ${mnt}/ccache
		fi
		[ -n "${MFSSIZE}" ] && mdmfs -M -S -o async -s ${MFSSIZE} md ${mnt}/wrkdirs
		[ ${TMPFS_WRKDIR} -eq 1 ] && mount -t tmpfs tmpfs ${mnt}/wrkdirs
	fi

	mount -t nullfs -o ro ${portsdir} ${mnt}/usr/ports || err 1 "Failed to mount the ports directory "
	mount -t nullfs ${POUDRIERE_DATA}/packages/${MASTERNAME} ${mnt}/packages || err 1 "Failed to mount the packages directory "
	mount -t nullfs ${DISTFILES_CACHE} ${mnt}/distfiles || err 1 "Failed to mount the distfiles cache directory"

	for opt in ${optionsdir}; do
		use_options ${mnt} ${opt} && break || continue
	done
}

jail_start() {
	[ $# -lt 2 ] && eargs name ptname setname
	local name=$1
	local ptname=$2
	local setname=$3
	local portsdir=$(pget ${ptname} mnt)
	local arch=$(jget ${name} arch)
	local mnt=$(jget ${name} mnt)
	local needfs="nullfs procfs"
	local makeconf

	local tomnt=${POUDRIERE_DATA}/build/${MASTERNAME}/ref

	if [ -z "${NOLINUX}" ]; then
		if [ "${arch}" = "i386" -o "${arch}" = "amd64" ]; then
			needfs="${needfs} linprocfs linsysfs"
			sysctl -n compat.linux.osrelease >/dev/null 2>&1 || kldload linux
		fi
	fi
	[ -n "${USE_TMPFS}" ] && NEEDFS="${NEEDFS} tmpfs"
	for fs in ${needfs}; do
		lsvfs $fs >/dev/null 2>&1 || kldload $fs
	done
	jail_exists ${name} || err 1 "No such jail: ${name}"
	jail_runs ${MASTERNAME} && err 1 "jail already running: ${MASTERNAME}"

	msg_n "Creating the reference jail..."
	clonefs ${mnt} ${tomnt} clean
	echo " done"

	msg "Mounting system devices for ${MASTERNAME}"
	do_jail_mounts ${tomnt} ${arch}

	[ -d "${portsdir}/ports" ] && portsdir="${portsdir}/ports"
	msg "Mounting ports/packages/distfiles"
	do_portbuild_mounts ${tomnt} ${name} ${ptname} ${setname}

	if [ -d "${CCACHE_DIR:-/nonexistent}" ]; then
		echo "WITH_CCACHE_BUILD=yes" >> ${tomnt}/etc/make.conf
		echo "MAKE_ENV+= CCACHE_DIR=/ccache" >> ${tomnt}/etc/make.conf
	fi
	echo "PACKAGES=/packages" >> ${tomnt}/etc/make.conf
	echo "DISTDIR=/distfiles" >> ${tomnt}/etc/make.conf

	makeconf="- ${name} ${name}-${ptname}"
	[ -n "${setname}" ] && makeconf="${makeconf} ${name}-${setname}"
	makeconf="${makeconf} ${MASTERNAME}"
	for opt in ${makeconf}; do
		append_make ${tomnt} ${opt}
	done

	test -n "${RESOLV_CONF}" && cp -v "${RESOLV_CONF}" "${tomnt}/etc/"
	msg "Starting jail ${MASTERNAME}"
	jrun ${MASTERNAME} ${tomnt} 0
	# Only set STATUS=1 if not turned off
	# jail -s should not do this or jail will stop on EXIT
	WITH_PKGNG=$(jail -c path=${MASTERMNT} command=make -f /usr/ports/Mk/bsd.port.mk -V WITH_PKGNG)
	if [ -n "${WITH_PKGNG}" ]; then
		export PKGNG=1
		export PKG_EXT="txz"
		export PKG_ADD="${LOCALBASE:-/usr/local}/sbin/pkg add"
		export PKG_DELETE="${LOCALBASE:-/usr/local}/sbin/pkg delete -y -f"
	else
		export PKGNG=0
		export PKG_ADD=pkg_add
		export PKG_DELETE=pkg_delete
		export PKG_EXT="tbz"
	fi

	[ ${SET_STATUS_ON_START-1} -eq 1 ] && export STATUS=1
}

jail_stop() {
	[ $# -ne 0 ] && eargs
	jail_runs ${MASTERNAME} || err 1 "No such jail running: ${MASTERNAME}"
	local fs=$(zfs_getfs ${MASTERMNT})
	bset status "stop:"


	jail -r ${MASTERNAME} >/dev/null
	# Shutdown all builders
	if [ ${PARALLEL_JOBS} -ne 0 ]; then
		# - here to only check for unset, {start,stop}_builders will set this to blank if already stopped
		for j in ${JOBS-$(jot -w %02d ${PARALLEL_JOBS})}; do
			jail -r ${MASTERNAME}-job-${j} >/dev/null 2>&1 || :
			destroyfs ${MASTERMNT}/../${j} jail
		done
	fi
	msg "Umounting file systems"
	destroyfs ${MASTERMNT} jail
	rm -rf ${MASTERMNT}/../
	export STATUS=0
}

cleanup() {
	[ -n "${CLEANED_UP}" ] && return 0
	msg "Cleaning up"
	# If this is a builder, don't cleanup, the master will handle that.
	if [ -n "${MY_JOBID}" ]; then
		[ -n "${PKGNAME}" ] && clean_pool ${PKGNAME} 1 || :
		return 0

	fi
	# Prevent recursive cleanup on error
	if [ -n "${CLEANING_UP}" ]; then
		echo "Failure cleaning up. Giving up." >&2
		return
	fi
	export CLEANING_UP=1
	[ -z "${MASTERNAME}" ] && err 2 "Fail: Missing MASTERNAME"
	log_stop

	# Kill all children - this does NOT recurse, so orphans can still
	# occur. This is just to avoid requiring pid files for parallel_run
	for pid in $(jobs -p); do
		kill ${pid} 2>/dev/null || :
	done

	if [ -d ${MASTERMNT}/poudriere/var/run ]; then
		for pid in ${MASTERMNT}/poudriere/var/run/*.pid; do
			# Ensure there is a pidfile to read or break
			[ "${pid}" = "${MASTERMNT}/poudriere/var/run/*.pid" ] && break
			pkill -15 -F ${pid} >/dev/null 2>&1 || :
		done
	fi
	wait

	jail_stop
	export CLEANED_UP=1
}

injail() {
	local jname=$1
	shift
	jexec -U root ${jname} $@
}

sanity_check_pkgs() {
	local ret=0
	local depfile
	[ ! -d ${POUDRIERE}/packages/${MASTERNAME}/All ] && return $ret
	[ -n "$(dir_empty ${POUDRIERE}/packages/${MASTERNAME}/All)" ] && return $ret
	for pkg in ${POUDRIERE}/packages/${MASTERNAME}/All/*.${PKG_EXT}; do
		# Check for non-empty directory with no packages in it
		[ "${pkg}" = "${POUDRIERE}/packages/${MASTERNAME}/All/*.${PKG_EXT}" ] && break
		depfile=$(deps_file ${pkg})
		while read dep; do
			if [ ! -e "${POUDRIERE}/packages/${MASTERNAME}/All/${dep}.${PKG_EXT}" ]; then
				ret=1
				msg_debug "${pkg} needs missing ${POUDRIERE}/packages/${MASTERNAME}/All/${dep}.${PKG_EXT}"
				msg "Deleting ${pkg}: missing dependencies"
				delete_pkg ${pkg}
				break
			fi
		done < "${depfile}"
	done

	return $ret
}

check_leftovers() {
	local mnt=$1
	mtree -X ${mnt}/poudriere/mtree.preinstexclude -x \
		-f ${mnt}/poudriere/mtree.preinst \
		-p ${mnt} | while read l ; do
		case ${l} in
		*extra)
			if [ -d ${mnt}/${l% *} ]; then
				find ${mnt}/${l% *} -exec echo "+ . {}" \;
			else
				echo "+ ${mnt}/${l% *}"
			fi
			;;
		*missing) echo "- ${mnt}/${l% *}" ;;
		*changed) echo "M ${mnt}/${l% *}" ;;
		esac
	done
}

# Build+test port and return on first failure
build_port() {
	[ $# -ne 1 ] && eargs portdir
	local portdir=$1
	local port=${portdir##/usr/ports/}
	local targets="check-config fetch checksum extract patch configure build run-depends install-mtree install package ${PORTTESTING:+deinstall}"
	local mnt=$(my_path)
	local name=$(my_name)

	for phase in ${targets}; do
		bset ${MY_JOBID} status "${phase}:${port}"
		job_msg_verbose "Status for build ${port}: ${phase}"
		if [ "${phase}" = "fetch" ]; then
			jail -r ${name} >/dev/null
			jrun ${name} ${mnt} 1
		fi
		case ${phase} in
		install) [ -n ${PORTTESTING} ] && markfs preinst ${mnt} ;;
		deinstall)
			msg "Checking shared library dependencies"
			if [ ${PKGNG} -eq 0 ]; then
				PLIST="/var/db/pkg/${PKGNAME}/+CONTENTS"
				grep -v "^@" ${mnt}${PLIST} | \
					sed -e "s,^,${PREFIX}/," | \
					xargs injail ${name} ldd 2>&1 | \
					grep -v "not a dynamic executable" | \
					awk ' /=>/{ print $3 }' | sort -u
			else
				injail ${name} pkg query "%Fp" ${PKGNAME} | \
					xargs injail ${name} ldd 2>&1 | \
					grep -v "not a dynamic executable" | \
					awk '/=>/ { print $3 }' | sort -u
			fi
			;;
		esac

		print_phase_header ${phase}
		injail ${name} env ${PKGENV} ${PORT_FLAGS} make -C ${portdir} ${phase} || return 1
		print_phase_footer

		if [ "${phase}" = "checksum" ]; then
			jail -r ${name} >/dev/null
			jrun ${name} ${mnt} 1
		fi
		if [ "${phase}" = "deinstall" ]; then
			msg "Checking for extra files and directories"
			PREFIX=`injail ${name} env ${PORT_FLAGS} make -C ${portdir} -VPREFIX`
			bset ${MY_JOBID} status "leftovers:${port}"
			local portname datadir etcdir docsdir examplesdir wwwdir site_perl
			local add=$(mktemp ${jailbase}/tmp/add.XXXXXX)
			local add1=$(mktemp ${jailbase}/tmp/add1.XXXXXX)
			local del=$(mktemp ${jailbase}/tmp/del.XXXXXX)
			local del1=$(mktemp ${jailbase}/tmp/del1.XXXXXX)
			local mod=$(mktemp ${jailbase}/tmp/mod.XXXXXX)
			local mod1=$(mktemp ${jailbase}/tmp/mod1.XXXXXX)
			local die=0

			sedargs=$(injail ${name} env ${PORT_FLAGS} make -C ${portdir} -V'${PLIST_SUB:NLIB32*:NPERL_*:NPREFIX*:N*="":N*="@comment*:C/(.*)=(.*)/-es!\2!%%\1%%!g/}')

			check_leftovers ${mnt} | \
				while read mod path; do
				local ppath

				# If this is a directory, use @dirrm in output
				if [ -d "${path}" ]; then
					ppath="@dirrm "`echo $path | sed \
						-e "s,^${mnt},," \
						-e "s,^${PREFIX}/,," \
						${sedargs} \
					`
				else
					ppath=`echo "$path" | sed \
						-e "s,^${mnt},," \
						-e "s,^${PREFIX}/,," \
						${sedargs} \
					`
				fi
				case $mod$type in
				+) echo "${ppath}" >> ${add};;
				-) echo "${ppath}" >> ${del};;
				M) echo "${ppath}" >> ${mod};;
				esac
			done
			sort ${add} > ${add1}
			sort ${del} > ${del1}
			sort ${mod} > ${mod1}
			comm -12 ${add1} ${del1} >> ${mod1}
			comm -23 ${add1} ${del1} > ${add}
			comm -13 ${add1} ${del1} > ${del}
			if [ -s "${add}" ]; then
				msg "Files or directories left over:"
				die=1
				grep -v "^@dirrm" ${add}
				grep "^@dirrm" ${add} | sort -r
			fi
			if [ -s "${del}" ]; then
				msg "Files or directories removed:"
				die=1
				cat ${del}
			fi
			if [ -s "${mod}" ]; then
				msg "Files or directories modified:"
				die=1
				cat ${mod1}
			fi
			rm -f ${add} ${add1} ${del} ${del1} ${mod} ${mod1}
			[ $die -eq 0 ] || return 1
		fi
	done
	jail -r ${name} >/dev/null
	jrun ${name} ${mnt} 0
	bset ${MY_JOBID} status "idle:"
	return 0
}

# Save wrkdir and return path to file
save_wrkdir() {
	[ $# -ne 4 ] && eargs mnt port portdir phase
	local mnt=$1
	local port="$2"
	local portdir="$3"
	local phase="$4"
	local tardir=${POUDRIERE_DATA}/wrkdirs/${MASTERNAME}/${PTNAME}
	local tarname=${tardir}/${PKGNAME}.${WRKDIR_ARCHIVE_FORMAT}
	local mnted_portdir=${mnt}/wrkdirs/${portdir}

	[ -n "${SAVE_WRKDIR}" ] || return 0
	# Only save if not in fetch/checksum phase
	[ "${failed_phase}" != "fetch" -a "${failed_phase}" != "checksum" ] || return 0

	mkdir -p ${tardir}

	# Tar up the WRKDIR, and ignore errors
	case ${WRKDIR_ARCHIVE_FORMAT} in
	tar) COMPRESSKEY="" ;;
	tgz) COMPRESSKEY="z" ;;
	tbz) COMPRESSKEY="j" ;;
	txz) COMPRESSKEY="J" ;;
	esac
	rm -f ${tarname}
	tar -s ",${mnted_portdir},," -c${COMPRESSKEY}f ${tarname} ${mnted_portdir}/work > /dev/null 2>&1

	if [ -n "${MY_JOBID}" ]; then
		job_msg "Saved ${port} wrkdir to: ${tarname}"
	else
		msg "Saved ${port} wrkdir to: ${tarname}"
	fi
}

start_builders() {
	local jname=$1
	local ptname=$2
	local setname=$3
	local arch=$(jail -c path=${MASTERMNT} command=uname -p)
	local mnt name

	for j in ${JOBS}; do
		mnt=${MASTERMNT}/../${j}
		name="${MASTERNAME}-job-${j}"
		bset status "starting_jobs:${j}"
		# Jail might be lingering from previous build. Already recursively
		# destroyed all the builder datasets, so just try stopping the jail
		# and ignore any errors
		jail -r ${name} >/dev/null 2>&1 || :
		destroyfs ${mnt} jail
		mkdir -p "${mnt}"
		clonefs ${MASTERMNT} ${mnt} prepkg
		markfs prepkg ${mnt}
		do_jail_mounts ${mnt} ${arch}
		do_portbuild_mounts ${mnt} ${jname} ${ptname} ${setname}
		jrun ${name} ${mnt} 0
		bset ${MY_JOBID} status "idle:"
	done
}

stop_builders() {
	local mnt

	# wait for the last running processes
	cat ${MASTERMNT}/poudriere/var/run/*.pid 2>/dev/null | xargs pwait 2>/dev/null

	msg "Stopping ${PARALLEL_JOBS} builders"

	for j in ${JOBS}; do
		jail -r ${MASTERNAME}-job-${j} >/dev/null 2>&1 || :
		destroyfs ${MASTERMNT}/../${j} jail
	done

	# No builders running, unset JOBS
	JOBS=""
}

build_stats_list() {
	[ $# -ne 3 ] && eargs html_path type display_name
	local html_path="$1"
	local type=$2
	local display_name="$3"
	local port cnt pkgname extra port_category port_name
	local status_head="" status_col=""
	local reason_head="" reason_col=""

	if [ "${type}" != "skipped" ]; then
		status_head="<th>status</th>"
	fi

	# ignored has a reason
	if [ "${type}" = "ignored" -o "${type}" = "skipped" ]; then
		reason_head="<th>reason</th>"
	elif [ "${type}" = "failed" ]; then
		reason_head="<th>phase</th>"
	fi

cat >> ${html_path} << EOF
    <div id="${type}">
      <h2>${display_name} ports </h2>
      <table>
        <tr>
          <th>Port</th>
          <th>Origin</th>
	  ${status_head}
	  ${reason_head}
        </tr>
EOF
	cnt=0
	while read port extra; do
		pkgname=$(cache_get_pkgname ${port})
		port_category=${port%/*}
		port_name=${port#*/}

		if [ -n "${status_head}" ]; then
			status_col="<td><a href=\"${pkgname}.log\">logfile</a></td>"
		fi

		if [ "${type}" = "ignored" ]; then
			reason_col="<td>${extra}</td>"
		elif [ "${type}" = "skipped" ]; then
			reason_col="<td>depends failed: <a href="#tr_pkg_${extra}">${extra}</a></td>"
		elif [ "${type}" = "failed" ]; then
			reason_col="<td>${extra}</td>"
		fi

		cat >> ${html_path} << EOF
        <tr>
          <td id="tr_pkg_${pkgname}">${pkgname}</td>
          <td><a href="http://portsmon.freebsd.org/portoverview.py?category=${port_category}&amp;portname=${port_name}">${port}</a></td>
	  ${status_col}
	  ${reason_col}
        </tr>
EOF
		cnt=$(( cnt + 1 ))
	done <  ${MASTERMNT}/poudriere/ports.${type}

	if [ "${type}" = "skipped" ]; then
		# Skipped lists the skipped origin for every dependency that wanted it
		bset stats_skipped $(
			awk '{print $1}' ${MASTERMNT}/poudriere/ports.skipped |
			sort -u |
			wc -l)
	else
		bset stats_${type} $cnt
	fi

cat >> ${html_path} << EOF
      </table>
    </div>
EOF
}

build_stats() {
	local should_refresh=${1:-1}
	local port logdir pkgname html_path refresh_meta=""

	if [ "${POUDRIERE_BUILD_TYPE}" = "testport" ]; then
		# Discard test stats page for now
		html_path="/dev/null"
	else
		logdir=`log_path`
		[ -d "${logdir}" ] || mkdir -p "${logdir}"
		html_path="${logdir}/index.html.tmp"
	fi
	
	[ ${should_refresh} -eq 1 ] && \
		refresh_meta='<meta http-equiv="refresh" content="10">'

	cat > ${html_path} << EOF
<html>
  <head>
    ${refresh_meta}
    <meta http-equiv="pragma" content="NO-CACHE">
    <title>Poudriere bulk results</title>
    <style type="text/css">
      table {
        display: block;
        border: 2px;
        border-collapse:collapse;
        border: 2px solid black;
        margin-top: 5px;
      }
      th, td { border: 1px solid black; }
      #built td { background-color: #00CC00; }
      #failed td { background-color: #E00000 ; }
      #skipped td { background-color: #CC6633; }
      #ignored td { background-color: #FF9900; }
      :target { color: #FF0000; }
    </style>
    <script type="text/javascript">
      function toggle_display(id) {
        var e = document.getElementById(id);
        if (e.style.display != 'none')
          e.style.display = 'none';
        else
          e.style.display = 'block';
      }
    </script>
  </head>
  <body>
    <h1>Poudriere bulk results</h1>
    Page will auto refresh every 10 seconds.
    <ul>
      <li>Jail: ${MASTERNAME}</li>
      <li>Ports tree: ${PTNAME}</li>
      <li>Set Name: ${SETNAME:-none}</li>
EOF
	cnt=$(bget stats_queued)
	cat >> ${html_path} << EOF
      <li>Nb ports queued: ${cnt}</li>
    </ul>
    <hr />
    <button onclick="toggle_display('built');">Show/Hide success</button>
    <button onclick="toggle_display('failed');">Show/Hide failure</button>
    <button onclick="toggle_display('ignored');">Show/Hide ignored</button>
    <button onclick="toggle_display('skipped');">Show/Hide skipped</button>
    <hr />
EOF

	build_stats_list "${html_path}" "built" "Successful"
	build_stats_list "${html_path}" "failed" "Failed"
	build_stats_list "${html_path}" "ignored" "Ignored"
	build_stats_list "${html_path}" "skipped" "Skipped"

	cat >> ${html_path} << EOF
  </body>
</html>
EOF


	[ "${html_path}" = "/dev/null" ] || mv ${html_path} ${html_path%.tmp}
}

build_queue() {

	local j cnt name pkgname read_queue builders_active should_build_stats
	local mnt=$(my_path)

	should_build_stats=1 # Always build stats on first pass
	mkfifo ${MASTERMNT}/poudriere/builders.pipe
	exec 6<> ${MASTERMNT}/poudriere/builders.pipe
	rm -f ${MASTERMNT}/poudriere/builders.pipe
	while :; do
		builders_active=0
		for j in ${JOBS}; do
			name="${MASTERNAME}-job-${j}"
			if [ -f  "${mnt}/poudriere/var/run/${j}.pid" ]; then
				if pgrep -F "${mnt}/poudriere/var/run/${j}.pid" >/dev/null 2>&1; then
					builders_active=1
					continue
				fi
				should_build_stats=1
				rm -f "${mnt}/poudriere/var/run/${j}.pid"
				bset ${MY_JOBID} status "idle:"

			fi

			pkgname=$(next_in_queue)
			if [ -z "${pkgname}" ]; then
				# pool empty ?
				[ -n "$(dir_empty ${mnt}/poudriere/pool)" ] && return 0

				# Pool is waiting on dep, wait until a build
				# is done before checking the queue again
			else
				MY_JOBID="${j}" build_pkg "${pkgname}" >/dev/null 2>&1 &
				echo "$!" > ${mnt}/poudriere/var/run/${j}.pid

				# A new job is spawned, try to read the queue
				# just to keep things moving
				builders_active=1
			fi
		done
		read jobid <&6

		if [ ${builders_active} -eq 0 ]; then
			msg "Dependency loop or poudriere bug detected."
			find ${mnt}/poudriere/pool || echo "pool missing"
			find ${mnt}/poudriere/deps || echo "deps missing"
			err 1 "Queue is unprocessable"
		fi

		if [ ${should_build_stats} -eq 1 ]; then
			build_stats
			should_build_stats=0
		fi
	done
	exec 6<&-
	exec 6>&-
}

# Build ports in parallel
# Returns when all are built.
parallel_build() {
	local jname=$1
	local ptname=$2
	local setname=$3
	local nbq=$(bget stats_queued)
	local real_parallel_jobs=${PARALLEL_JOBS}

	# If pool is empty, just return
	test ${nbq} -eq 0 && return 0

	# Minimize PARALLEL_JOBS to queue size
	if [ ${PARALLEL_JOBS} -gt ${nbq} ]; then
		PARALLEL_JOBS=${nbq##* }
	fi

	msg "Building ${nbq} packages using ${PARALLEL_JOBS} builders"
	JOBS="$(jot -w %02d ${PARALLEL_JOBS})"

	bset status "starting_jobs:"
	start_builders ${jname} ${ptname} ${setname}

	# Duplicate stdout to socket 5 so the child process can send
	# status information back on it since we redirect its
	# stdout to /dev/null
	exec 5<&1

	bset status "parallel_build:"
	build_queue
	build_stats 0

	bset status "stopping_jobs:"
	stop_builders
	bset status "idle:"

	# Close the builder socket
	exec 5>&-

	# Restore PARALLEL_JOBS
	PARALLEL_JOBS=${real_parallel_jobs}

	return $(($(bget stats_failed) + $(bget stats_skipped)))
}

clean_pool() {
	[ $# -ne 2 ] && eargs pkgname clean_rdepends
	local pkgname=$1
	local clean_rdepends=$2
	local port skipped_origin

	[ ${clean_rdepends} -eq 1 ] && port=$(cache_get_origin "${pkgname}")

	# Cleaning queue (pool is cleaned here)
	lockf -s -k ${MASTERMNT}/poudriere/.lock.pool sh ${SCRIPTPREFIX}/clean.sh "${MASTERMNT}" "${pkgname}" ${clean_rdepends} | sort -u | while read skipped_pkgname; do
		skipped_origin=$(cache_get_origin "${skipped_pkgname}")
		echo "${skipped_origin} ${pkgname}" >> ${MASTERMNT}/poudriere/ports.skipped
		job_msg "Skipping build of ${skipped_origin}: Dependent port ${port} failed"
	done
}

print_phase_header() {
	printf "=======================<phase: %-12s>==========================\n" "$1"
}

print_phase_footer() {
	echo "======================================================================"
}

build_pkg() {
	# If this first check fails, the pool will not be cleaned up,
	# since PKGNAME is not yet set.
	[ $# -ne 1 ] && eargs pkgname
	local pkgname="$1"
	local port portdir
	local build_failed=0
	local name=${MASTERNAME}-job-${MY_JOBID}
	local mnt=$(my_path)
	local failed_status failed_phase cnt
	local clean_rdepends=0
	local ignore

	export PKGNAME="${pkgname}" # set ASAP so cleanup() can use it
	port=$(cache_get_origin ${pkgname})
	portdir="/usr/ports/${port}"

	job_msg "Starting build of ${port}"
	bset ${MY_JOBID} status "starting:${port}"

	if [ -n "${TMPFS_LOCALBASE}" ]; then
		umount -f ${mnt}/${LOCALBASE:-/usr/local} 2>/dev/null || :
		mount -t tmpfs tmpfs ${mnt}/${LOCALBASE:-/usr/local}
	fi

	rollbackfs prepkg ${mnt}

	# If this port is IGNORED, skip it
	# This is checked here instead of when building the queue
	# as the list may start big but become very small, so here
	# is a less-common check
	ignore="$(jail -c path=${mnt} command=make -C ${portdir} -VIGNORE)"

	msg "Cleaning up wrkdir"
	rm -rf ${mnt}/wrkdirs/*

	log_start $(log_path)/${PKGNAME}.log
	msg "Building ${port}"
	buildlog_start ${portdir}

	if [ -n "${ignore}" ]; then
		msg "Ignoring ${port}: ${ignore}"
		echo "${port} ${ignore}" >> "${MASTERMNT}/poudriere/ports.ignored"
		job_msg "Finished build of ${port}: Ignored: ${ignore}"
		clean_rdepends=1
	else
		bset ${MY_JOBID} status "depends:${port}"
		job_msg_verbose "Status for build ${port}: depends"
		print_phase_header "depends"
		if ! injail ${name} make -C ${portdir} pkg-depends fetch-depends extract-depends \
			patch-depends build-depends lib-depends; then
			build_failed=1
			failed_phase="depends"
		else
			print_phase_footer
			# Only build if the depends built fine
			injail ${name} make -C ${portdir} clean
			if ! build_port ${portdir}; then
				build_failed=1
				failed_status=$(bget status)
				failed_phase=${failed_status%:*}

				save_wrkdir ${mnt} "${port}" "${portdir}" "${failed_phase}" || :
			fi

			injail ${name} make -C ${portdir} clean
		fi

		if [ ${build_failed} -eq 0 ]; then
			echo "${port}" >> "${MASTERMNT}/poudriere/ports.built"

			job_msg "Finished build of ${port}: Success"
			# Cache information for next run
			pkg_cache_data "${POUDRIERE_DATA}/packages/${MASTERNAME}/All/${PKGNAME}.${PKG_EXT}" ${port} || :
		else
			echo "${port} ${failed_phase}" >> "${MASTERMNT}/poudriere/ports.failed"
			job_msg "Finished build of ${port}: Failed: ${failed_phase}"
			clean_rdepends=1
		fi
	fi

	clean_pool ${PKGNAME} ${clean_rdepends}

	bset ${MY_JOBID} status "done:${port}"
	buildlog_stop ${portdir}
	log_stop $(log_path)/${PKGNAME}.log
	echo ${MY_JOBID} >&6
}

list_deps() {
	[ $# -ne 1 ] && eargs directory
	local dir=$1
	local makeargs="-VPKG_DEPENDS -VBUILD_DEPENDS -VEXTRACT_DEPENDS -VLIB_DEPENDS -VPATCH_DEPENDS -VFETCH_DEPENDS -VRUN_DEPENDS"
	[ -d "${PORTSDIR}/${dir}" ] && dir="/usr/ports/${dir}"

	jail -c path=${MASTERMNT} command=make -C ${dir} $makeargs | tr '\n' ' ' | \
		sed -e "s,[[:graph:]]*/usr/ports/,,g" -e "s,:[[:graph:]]*,,g" | sort -u
}

deps_file() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local depfile=$(pkg_cache_dir ${pkg})/deps

	if [ ! -f "${depfile}" ]; then
		if [ "${PKG_EXT}" = "tbz" ]; then
			tar -xf "${pkg}" -O +CONTENTS | awk '$1 == "@pkgdep" { print $2 }' > "${depfile}"
		else
			pkg info -qdF "${pkg}" > "${depfile}"
		fi
	fi

	echo ${depfile}
}

pkg_get_origin() {
	[ $# -lt 1 ] && eargs pkg
	local pkg=$1
	local originfile=$(pkg_cache_dir ${pkg})/origin
	local origin=$2

	if [ ! -f "${originfile}" ]; then
		if [ -z "${origin}" ]; then
			if [ "${PKG_EXT}" = "tbz" ]; then
				origin=$(tar -xf "${pkg}" -O +CONTENTS | awk -F: '$1 == "@comment ORIGIN" { print $2 }')
			else
				origin=$(pkg query -F "${pkg}" "%o")
			fi
		fi
		echo ${origin} > "${originfile}"
	else
		read origin < "${originfile}"
	fi
	echo ${origin}
}

pkg_get_options() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local optionsfile=$(pkg_cache_dir ${pkg})/options
	local compiled_options

	if [ ! -f "${optionsfile}" ]; then
		if [ "${PKG_EXT}" = "tbz" ]; then
			compiled_options=$(tar -xf "${pkg}" -0 +CONTENTS | awk -F: '$1 == "@comment OPTIONS" {print $2}' | tr ' ' '\n' | sed -n 's/^\+\(.*\)/\1/p' | sort | tr '\n' ' ')
		else
			compiled_options=$(pkg query -F "${pkg}" '%Ov %Ok' | awk '$1 == "on" {print $2}' | sort | tr '\n' ' ')
		fi
		echo "${compiled_options}" > "${optionsfile}"
		echo "${compiled_options}"
		return 0
	fi
	# optionsfile is multi-line, no point for read< trick here
	cat "${optionsfile}"
}

pkg_cache_data() {
	[ $# -ne 2 ] && eargs pkg origin
	# Ignore errors in here
	set +e
	local pkg=$1
	local origin=$2
	local cachedir=$(pkg_cache_dir ${pkg})
	local originfile=${cachedir}/origin

	mkdir -p $(pkg_cache_dir ${pkg})
	pkg_get_options ${pkg} > /dev/null
	pkg_get_origin ${pkg} ${origin} > /dev/null
	deps_file ${pkg} > /dev/null
	set -e
}

pkg_to_pkgname() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local pkg_file=${pkg##*/}
	local pkgname=${pkg_file%.*}
	echo ${pkgname}
}

cache_dir() {
	echo ${POUDRIERE_DATA}/cache/${MASTERNAME}
}

# Return the cache dir for the given pkg
# @param string pkg $PKGDIR/All/PKGNAME.PKG_EXT
pkg_cache_dir() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1
	local pkg_file=${pkg##*/}

	echo $(cache_dir)/${pkg_file}
}

clear_pkg_cache() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1

	rm -fr $(pkg_cache_dir ${pkg})
}

delete_pkg() {
	[ $# -ne 1 ] && eargs pkg
	local pkg=$1

	# Delete the package and the depsfile since this package is being deleted,
	# which will force it to be recreated
	rm -f "${pkg}"
	clear_pkg_cache ${pkg}
}

# Deleted cached information for stale packages (manually removed)
delete_stale_pkg_cache() {
	local pkgname
	local cachedir=$(cache_dir)
	[ ! -d ${cachedir} ] && return 0
	[ -n "$(dir_empty ${cachedir})" ] && return 0
	for pkg in ${cachedir}/*.${PKG_EXT}; do
		pkg_file=${pkg##*/}
		# If this package no longer exists in the PKGDIR, delete the cache.
		if [ ! -e "${POUDRIERE}/packages/${MASTERNAME}/All/${pkg_file}" ]; then
			clear_pkg_cache ${pkg}
		fi
	done
}

delete_old_pkg() {
	local pkg="$1"
	local mnt=$(my_path)
	local o v v2 compiled_options current_options
	if [ "${pkg##*/}" = "repo.txz" ]; then
		msg "Removing invalid pkg repo file: ${pkg}"
		rm -f ${pkg}
		return 0
	fi

	mkdir -p $(pkg_cache_dir ${pkg})

	o=$(pkg_get_origin ${pkg})
	v=${pkg##*-}
	v=${v%.*}
	if [ ! -d "${mnt}/usr/ports/${o}" ]; then
		msg "${o} does not exist anymore. Deleting stale ${pkg##*/}"
		delete_pkg ${pkg}
		return 0
	fi
	v2=$(cache_get_pkgname ${o})
	v2=${v2##*-}
	if [ "$v" != "$v2" ]; then
		msg "Deleting old version: ${pkg##*/}"
		delete_pkg ${pkg}
		return 0
	fi

	# Check if the compiled options match the current options from make.conf and /var/db/options
	if [ "${CHECK_CHANGED_OPTIONS:-no}" != "no" ]; then
		current_options=$(injail ${MASTERNAME} make -C /usr/ports/${o} pretty-print-config | tr ' ' '\n' | sed -n 's/^\+\(.*\)/\1/p' | sort | tr '\n' ' ')
		compiled_options=$(pkg_get_options ${pkg})

		if [ "${compiled_options}" != "${current_options}" ]; then
			msg "Options changed, deleting: ${pkg##*/}"
			if [ "${CHECK_CHANGED_OPTIONS}" = "verbose" ]; then
				msg "Pkg: ${compiled_options}"
				msg "New: ${current_options}"
			fi
			delete_pkg ${pkg}
			return 0
		fi
	fi
}

delete_old_pkgs() {
	[ ! -d ${POUDRIERE}/packages/${MASTERNAME}/All ] && return 0
	[ -n "$(dir_empty ${POUDRIERE}/packages/${MASTERNAME}/All)" ] && return 0
	for pkg in ${POUDRIERE}/packages/${MASTERNAME}/All/*.${PKG_EXT}; do
		# Check for non-empty directory with no packages in it
		[ "${pkg}" = "${POUDRIERE}/packages/${MASTERNAME}/All/*.${PKG_EXT}" ] && break
		parallel_run "delete_old_pkg ${pkg}"
	done
	parallel_stop
}

next_in_queue() {
	local p

	[ ! -d ${MASTERMNT}/poudriere/pool ] && err 1 "Build pool is missing"
	p=$(lockf -k -t 60 ${MASTERMNT}/poudriere/.lock.pool find ${MASTERMNT}/poudriere/pool -type d -depth 1 -empty -print -quit || :)
	[ -n "$p" ] || return 0
	touch ${p}/.building
	# pkgname
	echo ${p##*/}
}

lock_acquire() {
	[ $# -ne 1 ] && eargs lockname
	local lockname=$1

	while :; do
		if mkdir ${POUDRIERE_DATA}/.lock-${MASTERNAME}-${lockname} 2>/dev/null; then
			break
		fi
		sleep 0.1
	done
}

lock_release() {
	[ $# -ne 1 ] && eargs lockname
	local lockname=$1

	rmdir ${POUDRIERE_DATA}/.lock-${MASTERNAME}-${lockname} 2>/dev/null
}

cache_get_pkgname() {
	[ $# -ne 1 ] && eargs origin
	local origin=${1%/}
	local pkgname="" existing_origin
	local cache_origin_pkgname=${MASTERMNT}/poudriere/var/cache/origin-pkgname/${origin%%/*}_${origin##*/}
	local cache_pkgname_origin

	[ -f ${cache_origin_pkgname} ] && read pkgname < ${cache_origin_pkgname}

	# Add to cache if not found.
	if [ -z "${pkgname}" ]; then
		[ -d "${PORTSDIR}/${origin}" ] || err 1 "Invalid port origin '${origin}' not found."
		pkgname=$(jail -c path=${MASTERMNT} command=make -C /usr/ports/${origin} -VPKGNAME)
		# Make sure this origin did not already exist
		existing_origin=$(cache_get_origin "${pkgname}" 2>/dev/null || :)
		# It may already exist due to race conditions, it is not harmful. Just ignore.
		if [ "${existing_origin}" != "${origin}" ]; then
			[ -n "${existing_origin}" ] && \
				err 1 "Duplicated origin for ${pkgname}: ${origin} AND ${existing_origin}. Rerun with -vv to see which ports are depending on these."
			echo "${pkgname}" > ${cache_origin_pkgname}
			cache_pkgname_origin="${MASTERMNT}/poudriere/var/cache/pkgname-origin/${pkgname}"
			echo "${origin}" > "${cache_pkgname_origin}"
		fi
	fi

	echo ${pkgname}
}

cache_get_origin() {
	[ $# -ne 1 ] && eargs pkgname
	local pkgname=$1
	local cache_pkgname_origin="${MASTERMNT}/poudriere/var/cache/pkgname-origin/${pkgname}"

	cat "${cache_pkgname_origin%/}"
}

# Take optional pkgname to speedup lookup
compute_deps() {
	[ $# -lt 1 ] && eargs port
	[ $# -gt 2 ] && eargs port pkgnme
	local port=$1
	local pkgname="${2:-$(cache_get_pkgname ${port})}"
	local mnt=$(my_path)
	local dep_pkgname dep_port
	local pkg_pooldir="${mnt}/poudriere/deps/${pkgname}"
	mkdir "${pkg_pooldir}" 2>/dev/null || return 0

	msg_verbose "Computing deps for ${port}"

	for dep_port in `list_deps ${port}`; do
		msg_debug "${port} depends on ${dep_port}"
		# Detect bad cat/origin/ dependency which pkgng will not register properly
		[ "${dep_port}" = "${dep_port%/}" ] || err 1 "${port} depends on bad origin '${dep_port}'; Please contact maintainer of the port to fix this."
		dep_pkgname=$(cache_get_pkgname ${dep_port})

		# Only do this if it's not already done, and not ALL, as everything will
		# be touched anyway
		[ ${ALL:-0} -eq 0 ] && ! [ -d "${mnt}/poudriere/deps/${dep_pkgname}" ] && \
			compute_deps "${dep_port}" "${dep_pkgname}"

		touch "${pkg_pooldir}/${dep_pkgname}"
		mkdir -p "${mnt}/poudriere/rdeps/${dep_pkgname}"
		ln -sf "${pkg_pooldir}/${dep_pkgname}" \
			"${mnt}/poudriere/rdeps/${dep_pkgname}/${pkgname}"
	done
}

listed_ports() {
	if [ ${ALL:-0} -eq 1 ]; then
		PORTSDIR=$(pget ${PTNAME} mnt)
		[ -d "${PORTSDIR}/ports" ] && PORTSDIR="${PORTSDIR}/ports"
		for cat in $(awk '$1 == "SUBDIR" { print $3}' ${PORTSDIR}/Makefile); do
			awk -v cat=${cat}  '$1 == "SUBDIR" { print cat"/"$3}' ${PORTSDIR}/${cat}/Makefile
		done
		return 0
	fi
	if [ -z "${LISTPORTS}" ]; then
		if [ -n "${LISTPKGS}" ]; then
			grep -v -E '(^[[:space:]]*#|^[[:space:]]*$)' ${LISTPKGS}
		fi
	else
		echo ${LISTPORTS} | tr ' ' '\n'
	fi
}

parallel_stop() {
	wait
}

_reap_children() {
	local skip_count=${1:-0}
	PARALLEL_CHILDREN_COUNT=0
	running_jobs=$(jobs -p) # |wc -l here will always be 0
	for pid in ${running_jobs}; do
		PARALLEL_CHILDREN_COUNT=$((PARALLEL_CHILDREN_COUNT + 1))
	done
	[ ${PARALLEL_CHILDREN_COUNT} -lt ${skip_count} ] && return 0

	# No available slot, try to reap some children to find one
	for pid in ${running_jobs}; do
		if ! kill -0 ${pid} 2>/dev/null; then
			wait ${pid} 2>/dev/null || :
			PARALLEL_CHILDREN_COUNT=$((PARALLEL_CHILDREN_COUNT - 1))
		fi
	done
}

parallel_run() {
	local cmd="$@"

	while :; do
		_reap_children ${PARALLEL_JOBS}
		if [ ${PARALLEL_CHILDREN_COUNT} -lt ${PARALLEL_JOBS} ]; then
			# Execute the command in the background
			eval "${cmd} &"
			return 0
		fi
		sleep 0.1
	done

	return 0
}

# Get all data that make this build env unique,
# so if the same build is done again,
# we can use the some of the same cached data
cache_get_key() {
	if [ -z "${CACHE_KEY}" ]; then
		CACHE_KEY=$({
			jail -c path=${MASTERMNT} command=env
			cat ${MASTERMNT}/etc/make.conf
			jail -c path=${MASTERMNT} command=find /var/db/ports -exec sha256 {} +
			echo ${MASTERNAME}
			if [ -f ${MASTERMNT}/usr/ports/poudriere.stamp ]; then
				cat ${MASTERMNT}/usr/ports/poudriere.stamp
			else
				# This is not a poudriere-managed ports tree.
				# Just toss in getpid() to invalidate the cache
				# as there is no quick way to hash the tree without
				# taking possibly minutes+
				echo $$
			fi
		} | sha256)
	fi
	echo ${CACHE_KEY}
}

prepare_ports() {
	local pkg

	msg "Calculating ports order and dependencies"
	mkdir -p "${MASTERMNT}/poudriere"
	[ -n "${TMPFS_DATA}" ] && mount -t tmpfs tmpfs "${MASTERMNT}/poudriere"
	rm -rf "${MASTERMNT}/poudriere/var/cache/origin-pkgname" \
	       "${MASTERMNT}/poudriere/var/cache/pkgname-origin" 2>/dev/null || :
	mkdir -p "${MASTERMNT}/poudriere/pool" \
		"${MASTERMNT}/poudriere/deps" \
		"${MASTERMNT}/poudriere/rdeps" \
		"${MASTERMNT}/poudriere/var/run" \
		"${MASTERMNT}/poudriere/var/cache" \
		"${MASTERMNT}/poudriere/var/cache/origin-pkgname" \
		"${MASTERMNT}/poudriere/var/cache/pkgname-origin"

	bset stats_queued 0
	:> ${MASTERMNT}/poudriere/ports.built
	:> ${MASTERMNT}/poudriere/ports.failed
	:> ${MASTERMNT}/poudriere/ports.ignored
	:> ${MASTERMNT}/poudriere/ports.skipped
	build_stats

	bset status "computingdeps:"
	for port in $(listed_ports); do
		[ -d "${MASTERMNT}/usr/ports/${port}" ] || err 1 "Invalid port origin: ${port}"
		parallel_run "compute_deps ${port}"
	done
	parallel_stop

	bset status "sanity:"

	if [ ${CLEAN_LISTED:-0} -eq 1 ]; then
		listed_ports | while read port; do
			pkg="${MASTERMNT}/packages/All/$(cache_get_pkgname  ${port}).${PKG_EXT}"
			if [ -f "${pkg}" ]; then
				msg "Deleting existing package: ${pkg##*/}"
				delete_pkg ${pkg}
			fi
		done
	fi

	if [ $SKIPSANITY -eq 0 ]; then
		msg "Sanity checking the repository"
		delete_stale_pkg_cache
		delete_old_pkgs

		while :; do
			sanity_check_pkgs && break
		done
	fi

	msg "Deleting stale symlinks"
	find -L ${MASTERMNT}/packages -type l -exec rm -vf {} +

	bset status "cleaning:"
	msg "Cleaning the build queue"
	export LOCALBASE=${LOCALBASE:-/usr/local}
	for pn in $(ls ${MASTERMNT}/poudriere/deps/); do
		if [ -f "${MASTERMNT}/packages/All/${pn}.${PKG_EXT}" ]; then
			# Cleanup rdeps/*/${pn}
			for rpn in $(ls "${MASTERMNT}/poudriere/deps/${pn}"); do
				echo "${MASTERMNT}/poudriere/rdeps/${rpn}/${pn}"
			done
			echo "${MASTERMNT}/poudriere/deps/${pn}"
			# Cleanup deps/*/${pn}
			if [ -d "${MASTERMNT}/poudriere/rdeps/${pn}" ]; then
				for rpn in $(ls "${MASTERMNT}/poudriere/rdeps/${pn}"); do
					echo "${MASTERMNT}/poudriere/deps/${rpn}/${pn}"
				done
				echo "${MASTERMNT}/poudriere/rdeps/${pn}"
			fi
		fi
	done | xargs rm -rf

	local nbq=0
	nbq=$(find ${MASTERMNT}/poudriere/deps -type d -depth 1 | wc -l)
	bset stats_queued ${nbq##* }

	# Create a pool of ready-to-build from the deps pool
	find "${MASTERMNT}/poudriere/deps" -type d -empty|xargs -J % mv % "${MASTERMNT}/poudriere/pool"
}

append_make() {
	[ $# -ne 2 ] && eargs mnt makeconf
	local mnt=$1
	local makeconf=$2

	if [ "${makeconf}" = "-" ]; then
		makeconf="${POUDRIERED}/make.conf"
	else
		makeconf="${POUDRIERED}/${makeconf}-make.conf"
	fi

	[ -f "${makeconf}" ] || return 0
	makeconf="$(realpath ${makeconf} 2>/dev/null)"
	msg "Appending to /etc/make.conf: ${makeconf}"
	cat "${makeconf}" >> ${mnt}/etc/make.conf
}

RESOLV_CONF=""
STATUS=0 # out of jail #

test -f ${SCRIPTPREFIX}/../../etc/poudriere.conf || err 1 "Unable to find ${SCRIPTPREFIX}/../../etc/poudriere.conf"
. ${SCRIPTPREFIX}/../../etc/poudriere.conf
POUDRIERED=${SCRIPTPREFIX}/../../etc/poudriere.d

# If the zfs module is not loaded it means we can't have zfs
[ -z "${NO_ZFS}" ] && lsvfs zfs >/dev/null 2>&1 || NO_ZFS=yes
[ -z "${NO_ZFS}" -a -z "$(zpool list -H -o name 2>/dev/null)" ] && NO_ZFS=yes

[ -z "${NO_ZFS}" -a -z ${ZPOOL} ] && err 1 "ZPOOL variable is not set"
[ -z ${BASEFS} ] && err 1 "Please provide a BASEFS variable in your poudriere.conf"

trap sig_handler SIGINT SIGTERM SIGKILL
trap exit_handler EXIT
trap siginfo_handler SIGINFO

# Test if zpool exists
if [ -z "${NO_ZFS}" ]; then
	zpool list ${ZPOOL} >/dev/null 2>&1 || err 1 "No such zpool: ${ZPOOL}"
fi

: ${SVN_HOST="svn.FreeBSD.org"}
: ${GIT_URL="git://github.com/freebsd/freebsd-ports.git"}
: ${FREEBSD_HOST="${FTP_HOST:-ftp.FreeBSD.org}"}
if [ -z "${NO_ZFS}" ]; then
	: ${ZROOTFS="/poudriere"}
	case ${ZROOTFS} in
	[!/]*) err 1 "ZROOTFS shoud start with a /" ;;
	esac
fi

[ -n "${MFSSIZE}" -a -n "${USE_TMPFS}" ] && err 1 "You can't use both tmpfs and mdmfs"

TMPFS_WRKDIR=0
TMPFS_DATA=0
TMPFS_ALL=0
TMPFS_LOCALBASE=0
for val in ${USE_TMPFS}; do
	case ${val} in
	wrkdir|yes) TMPFS_WRKDIR=1 ;;
	data) TMPFS_DATA=1 ;;
	all) TMPFS_ALL=1 ;;
	localbase) TMPFS_LOCALBASE=1 ;;
	*) err 1 "Unkown value for USE_TMPFS can be a combinaison of wrkdir,data,all,yes,localbase" ;;
	esac
done

case ${TMPFS_WRKDIR}${TMPFS_DATA}${TMPFS_LOCALBASE}${TMPFS_ALL} in
1**1|*1*1|**11)
	TMPFS_WRKDIR=0
	TMPFS_DATA=0
	TMPFS_LOCALBASE=0
	;;
esac

: ${CRONDIR="${POUDRIERE_DATA}/cron"}
POUDRIERE_DATA=`get_data_dir`
: ${WRKDIR_ARCHIVE_FORMAT="tbz"}
case "${WRKDIR_ARCHIVE_FORMAT}" in
	tar|tgz|tbz|txz);;
	*) err 1 "invalid format for WRKDIR_ARCHIVE_FORMAT: ${WRKDIR_ARCHIVE_FORMAT}" ;;
esac

#Converting portstree if any
if [ ! -d ${POUDRIERED}/ports ]; then
	mkdir -p ${POUDRIERED}/ports
	[ -z "${NO_ZFS}" ] && zfs list -t filesystem -H \
		-o ${NS}:type,${NS}:name,${NS}:method,mountpoint,name | \
		grep "^ports" | \
		while read t name method mnt fs; do
			msg "Converting the ${name} ports tree"
			pset ${name} method ${method}
			pset ${name} mnt ${mnt}
			pset ${name} fs ${fs}
			# Delete the old properties
			zfs inherit -r ${NS}:type ${fs}
			zfs inherit -r ${NS}:name ${fs}
			zfs inherit -r ${NS}:method ${fs}
		done
	if [ -f ${POUDRIERED}/portstrees ]; then
		while read name method mnt; do
			msg "Converting the ${name} ports tree"
			mkdir ${POUDRIERED}/ports/${name}
			echo ${method} > ${POUDRIERED}/ports/${name}/method
			echo ${mnt} > ${POUDRIERED}/ports/${name}/mnt
		done < ${POUDRIERED}/portstrees
		rm -f ${POUDRIERED}/portstrees
	fi
fi

#Converting jails if any
if [ ! -d ${POUDRIERED}/jails ]; then
	mkdir -p ${POUDRIERED}/jails
	[ -z "${NO_ZFS}" ] && zfs list -t filesystem -H \
		-o ${NS}:type,${NS}:name,${NS}:version,${NS}:arch,${NS}:method,mountpoint,name | \
		grep "^rootfs" | \
		while read t name version arch method mnt fs; do
			msg "Converting the ${name} jail"
			jset ${name} version ${version}
			jset ${name} arch ${arch}
			jset ${name} method ${method}
			jset ${name} mnt ${mnt}
			jset ${name} fs ${fs}
			# Delete the old properties
			zfs inherit -r ${NS}:type ${fs}
			zfs inherit -r ${NS}:name ${fs}
			zfs inherit -r ${NS}:method ${fs}
			zfs inherit -r ${NS}:version ${fs}
			zfs inherit -r ${NS}:arch ${fs}
			zfs inherit -r ${NS}:stats_built ${fs}
			zfs inherit -r ${NS}:stats_failed ${fs}
			zfs inherit -r ${NS}:stats_skipped ${fs}
			zfs inherit -r ${NS}:stats_status ${fs}
		done
fi

case ${PARALLEL_JOBS} in
''|*[!0-9]*)
	PARALLEL_JOBS=$(sysctl -n hw.ncpu)
	;;
esac
