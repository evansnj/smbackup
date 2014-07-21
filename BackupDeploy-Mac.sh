#!/bin/bash

#This script configures and deploys an rsync script on this system to connect to a
#specified server. Because mount_cifs on Macs do not support credentials files, the
#credentials are stored in a autofs map file that is readable only by root.


#If you want to "undeploy":
# # rmdir /var/root/.scripts
# # rmdir $homedir/.backup_logs
# remove /etc/auto_backup_secret and remove the reference to it in /etc/auto_master
# delete or comment out the cron job


#Set a few variables based on system, offer an out if Linux but not RHEL
if [[ $(uname) != Darwin ]]; then
	echo "This script must be run on a Mac. This does not appear to be a Mac."
	exit 1
fi
if [[ $(whoami) != root ]]; then
	echo "This script must be run as root."
	exit 1
fi

##Get user and server info
#Storage share credentials
GUESSUSER=$(last | grep console | head -1 | awk '{print $1}')
read -p "Username of account to back up [${GUESSUSER}]: " USERNAME
: ${USERNAME:="${GUESSUSER}"}
SECRET='text'
while [[ "$SECRETCONFIRM" != "$SECRET" ]]; do
	read -s -p "Password for ${USERNAME}: " SECRET
	echo ''
	read -s -p "Enter password again to confirm: " SECRETCONFIRM
	echo ''
done
echo ""
read -p "Will ${USERNAME} be the account connecting to the server? (y/n) [y]: " sameuser
: ${sameuser:="y"}
if [[ "$sameuser" != "y" ]]; then
	read -p "Username to connect to the server: " SUSERNAME
	SECRETCONFIRM='null'
	while [[ "$SECRETCONFIRM" != "$SECRET" ]]; do
		read -s -p "Password for ${SUSERNAME}: " SECRET
		echo ''
		read -s -p "Enter password again to confirm: " SECRETCONFIRM
		echo ''
	done
	echo ""
fi
HOMEDIR="/Users/${USERNAME}"
echo "By default, the user ${USERNAME}'s home directory will be backed up, at the expected"
echo "path ${HOMEDIR}. If this is not correct, or if you want to back up a"
read -p "different directory instead, enter it now [$HOMEDIR]: " LOCALDIR
: ${LOCALDIR:="$HOMEDIR"}
LOCALDIR=${LOCALDIR}
read -p "Server with share to mount [sharedstorage01.hpc.uiowa.edu]: " SERVER
: ${SERVER:="sharedstorage01.hpc.uiowa.edu"}
read -p "Path to SMB share [mrirc]: " SHAREPATH
: ${SHAREPATH:="mrirc"}
read -p "Enter a name for the backup job [MRRC_Backup]: " JOBNAME
: ${JOBNAME:="MRRC_Backup"}

#URL Encode the password for automount because otherwise it fails
CLEARTEXTSECRET=${SECRET}
SECRET=$(perl -MURI::Escape -e "print uri_escape('${SECRET}');")

if [[ -n "${SUSERNAME}" ]]; then
	MOUNTSTRING="://${SUSERNAME}:${SECRET}@${SERVER}/${SHAREPATH}"
else MOUNTSTRING="://${USERNAME}:${SECRET}@${SERVER}/${SHAREPATH}"
fi

#Add the appropriate automount mapping
mkdir -p /backup
echo "/backup	/etc/auto_backup_secret		##" >> /etc/auto_master
echo "${SHAREPATH}	-fstype=smbfs,soft	${MOUNTSTRING}" >> /etc/auto_backup_secret
chmod 600 /etc/auto_backup_secret
automount -c

#Create/delete a small test file
echo "Creating/removing small test file on share..."
if touch /backup/${SHAREPATH}/.testfile; then
	echo "Test file created."
else
	echo "Unable to create test file! Exiting..."
	exit 1
fi
if rm -f /backup/${SHAREPATH}/.testfile; then
	echo "Test file removed."
else
	echo "Unable to remove test file! Exiting..."
	exit 1
fi

#Ensure SCRIPTDIR exists
SCRIPTDIR="/var/root/.scripts"
mkdir -p -m 700 ${SCRIPTDIR}


#Deploy backup script
cat >"${SCRIPTDIR}/${JOBNAME}_${USERNAME}.sh" <<EOF
#!/bin/bash

#This script was put in place by a deployment script. Any changes made here will be
#overwritten if the deployment script is run again.

#This script mirrors the user's home directory to a previously-specified storage share.
#Intended to be run as a nightly cron job.

#Various variables
_USERNAME=${USERNAME}
_SHAREPATH=${SHAREPATH}
_MOUNTPOINT=/backup/\${_SHAREPATH}
_LOCALDIR=${LOCALDIR}
_DESTDIR=\${_MOUNTPOINT}/\$(hostname -s)/\${_USERNAME}/
_DATE=\$(date +"%Y%m%d")
_LOGDIR=\${_MOUNTPOINT}/\$(hostname -s)/\${_USERNAME}_logs
_LOGFILE=\${_LOGDIR}/\${_USERNAME}-\${_DATE}
_LOCALLOGDIR=\${_LOCALDIR}/.backup_logs
_LOCALLOGFILE=\${_LOCALLOGDIR}/\${_USERNAME}-\${_DATE}


#Sleep for up to 5000 seconds to try to reduce traffic to share
RAND_SLEEP=\$[ ( \$RANDOM % 5000 ) + 1 ]
echo "Sleeping for ${RAND_SLEEP} seconds to reduce concurrent traffic to share..."
sleep \${RAND_SLEEP}

START="Backup script started at: \$(date +"%H:%M:%S %m/%d/%Y")"

#Add a redirect to LOCALLOGFILE (will cp to LOGFILE later)
mkdir -p -m 755 \${_LOCALLOGDIR}
touch \${_LOCALLOGFILE}
chmod 755 \${_LOCALLOGFILE}
exec > >(tee \${_LOCALLOGFILE}) 2>&1


echo '----------------------------------------------------------'
echo '                MRRC Home Directory Backup                '
echo '----------------------------------------------------------'
echo ''

echo \${START}

#Check if share is mounted
if mount | grep -qs \${_SHAREPATH}; then
	echo "Backup share is mounted."
elif touch ${_MOUNTPOINT}/.mounted; then #If the automount has timed out, this should bring it back up
	echo "Backup share is mounted."
else
	echo "Backup share is not mounted! Check autofs mappings and try again."
	exit 1
fi

#Ensure LOGDIRs and DESTDIR exist
mkdir -p -m 755 \${_LOGDIR}
mkdir -p -m 700 \${_DESTDIR}
chown -R \${_USERNAME} \${_DESTDIR}



#Set rsync options
#       --delete : deletes files from the remote share that no longer exist locally
# (all of -a except -l)
#             -r : recursive
#             -p : preserve permissions
#             -t : preserve modification times
#             -g : preserve group
#             -o : preserve owner
#             -D : --devices and --specials
#             -v : verbose output
#     --exclude= : exclude files matching PATTERN
_RSYNC_OPTIONS='-rptgoDv --exclude .Trash --exclude .cache --delete'

#Run the rsync job
echo 'Starting rsync with parameters:'
echo "    Source      : \$_LOCALDIR"
echo "    Destination : \$_DESTDIR"
echo "    Options     : \$_RSYNC_OPTIONS"
rsync \${_RSYNC_OPTIONS} \${_LOCALDIR}/ \${_DESTDIR}
echo ''

#Clean up log files older than 7 days
echo -n 'Cleaning up old logs (1 of 2)...'
find \${_LOGDIR} -type f -mtime +7 -exec rm '{}' \;
echo 'Done.'
echo -n 'Cleaning up old logs (2 of 2)...'
find \${_LOCALLOGDIR} -type f -mtime +7 -exec rm '{}' \;
echo 'Done.'

FINISH="Script finished at: \$(date +"%H:%M:%S %m/%d/%Y")"
echo \${FINISH}

#Copy LOCALLOGFILE to LOGDIR
cp \${_LOCALLOGFILE} \${_LOGFILE}
chmod 755 \${_LOGFILE}

exit
EOF

#Change permissions
chmod 700 ${SCRIPTDIR}/${JOBNAME}_$USERNAME.sh

#Add script as a cron job
crontab -l | grep -v "${SCRIPTDIR}/${JOBNAME}_$USERNAME.sh" > /tmp/crontab.tmp
#Starts at 2AM daily
echo "0 2 * * * ${SCRIPTDIR}/${JOBNAME}_$USERNAME.sh > /dev/null 2>&1" >> /tmp/crontab.tmp
crontab /tmp/crontab.tmp

echo "Backup script deployed successfully."
exit 0
