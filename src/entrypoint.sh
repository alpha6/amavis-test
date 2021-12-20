#!/bin/bash

CLAMD=/usr/sbin/clamd
CLAMD_OPTIONS=

AMAVIS=/usr/sbin/amavisd-new
AMAVIS_OPTIONS=

IMAGE_HOME=/usr/local/amavis
IMAGE_TEMPLATES=$IMAGE_HOME/templates

# Check env vars
if [[ -z "${AV_MYDOMAIN}" ]]; then
    AV_MYDOMAIN=localdomain
fi
if [[ -z "${AV_POSTFIX_SERVICE_NAME}" ]]; then
    AV_POSTFIX_SERVICE_NAME=127.0.0.1
fi
if [[ -z "${AV_POSTFIX_SERVICE_PORT}" ]]; then
    AV_POSTFIX_SERVICE_NAME=10025
fi
if [[ -z "${AV_VIRUSADMIN_EMAIL}" ]]; then
    AV_VIRUSADMIN_EMAIL="postmaster\@${AV_MYDOMAIN}"
fi
if [[ -z "${AV_NOTIFY_SENDER}" ]]; then
	AV_NOTIFY_SENDER="postmaster\@${AV_MYDOMAIN}"
fi
if [[ -z "${AV_NOTIFY_ADMIN}" ]]; then
	AV_NOTIFY_ADMIN="postmaster\@${AV_MYDOMAIN}"
fi

####################
# Helper functions
####################
# Replace a variable in a file
# Arguments:
# $1 - file to replace variable in
# $2 - Name of variable to be replaced
# $3 - Value to replace
replace_var() {
	VARNAME=$2
	VARVALUE=${!VARNAME}
	sed -i "s:__${VARNAME}__:${VARVALUE}:g" $1
}

# Copy a template file and replace all variables in there.
# The target file will not be touched if it exists before
# Arguments:
# $1 - the template file
# $2 - the destination file
copy_template_file() {
	TMP_SRC=$1
	TMP_DST=$2

	if [ ! -f $TMP_DST ]; then
		if [ ! -f $TMP_SRC ]; then
			echo "Cannot find $TMP_SRC"
			exit 1
		fi
		echo "Creating $TMP_DST from template $TMP_SRC"
		cp $TMP_SRC $TMP_DST
		replace_var $TMP_DST 'AV_MYDOMAIN'
		replace_var $TMP_DST 'AV_POSTFIX_SERVICE_NAME'
		replace_var $TMP_DST 'AV_POSTFIX_SERVICE_PORT'
		replace_var $TMP_DST 'AV_VIRUSADMIN_EMAIL'
		replace_var $TMP_DST 'AV_NOTIFY_ADMIN'
		replace_var $TMP_DST 'AV_NOTIFY_SENDER'
		# MUSTER
		if [ ! -f $PF_TLS_CAFILE ]; then
			sed -i "s/^.*PF_TLS_CAFILE/# PF_TLS_CAFILE does not exist/g" $TMP_DST
		else
			replace_var $TMP_DST 'PF_TLS_CAFILE'
		fi
	fi
	if [ ! -f $TMP_DST ]; then
		echo "Cannot create $TMP_DST"
		exit 1
	fi
}

# Copy template files in a directory to a destination directory
copy_files() {
	SRC=$1
	DST=$2
	cd $SRC
	for file in *
	do
		copy_template_file $SRC/$file $DST/$file
	done
}

# Configure ClamAV
configure_clamd() {
	TMPL_SRC="$IMAGE_TEMPLATES/clamav"
	DEST_DIR="/etc/clamav"
	copy_files $TMPL_SRC $DEST_DIR
	chmod 644 /etc/clamav/clamd.conf
	chown -R clamav:clamav /etc/clamav
}

# Configure SpamAssassin
configure_spamassassin() {
	TMPL_SRC="$IMAGE_TEMPLATES/spamassassin"
	DEST_DIR="/etc/spamassassin"
	copy_files $TMPL_SRC $DEST_DIR
	chmod o+r $DEST_DIR/*
}

# Configure Amavis
configure_amavis() {
	TMPL_SRC="$IMAGE_TEMPLATES/amavis"
	DEST_DIR="/etc/amavis/conf.d"
	copy_files $TMPL_SRC $DEST_DIR
}

# Stopping all (we got a TERM signal at this point)
_sigterm() {
	echo "Caught SIGTERM..."
	service amavis stop
	service clamav-freshclam stop
	/etc/init.d/clamav-daemon stop
	service rsyslog stop
	kill -TERM "$TAIL_CHILD_PID" 2>/dev/null
}

#########################
# Startup procedure
#########################
cd $IMAGE_HOME

# Configure clamd
configure_clamd

# Configure SpamAssassin
configure_spamassassin

# Configure amavis
configure_amavis

# Start the syslog
service rsyslog start

# Start ClamAV
/etc/init.d/clamav-daemon start
service clamav-freshclam start

# Start Amavis
service amavis start

chmod 777 /var/virusmails

# Tail the syslog
trap _sigterm SIGTERM
tail -f /var/log/syslog &
TAIL_CHILD_PID=$!

# Enter loop for sa-update
INTERVAL=86400
COUNTDOWN=0
while kill -0 $TAIL_CHILD_PID >/dev/null 2>&1
do
	if [ "$COUNTDOWN" -le 0 ]
	then
		echo "Updating SpamAssassin rules..."
		# sa-update --nogpg --channelfile /usr/local/amavis/update-channels
		# service amavis restart
		echo "SpamAssassin rules updated."
		COUNTDOWN=$INTERVAL
	fi
	sleep 1
	((COUNTDOWN=COUNTDOWN-1))
done

