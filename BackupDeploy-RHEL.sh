#!/bin/bash

#This script configures and deploys an rsync script on this system to connect to a 
#specified server. The credentials are stored in a credentials file.

#This script can be run as many times as needed, as it will overwrite any files it
#originally created.


#Must be run as root
if [[ $UID -ne 0 ]]; then
	echo "This script must be run as root!"
	exit 1
fi

#Set a few variables, offer an out if Linux but not RHEL
if [[ $(uname) == Linux ]]; then
	if [[ ! -f /etc/redhat-release ]]; then 
		echo "You're not on a RedHat-based system. Use this script at your own risk."
		read -p "Continue? (y/n) [y]: " quitnow
		: ${quitnow:="y"}
		if [[ $quitnow == y ]]; then
			exit 1
		fi
	fi
else
	echo "This script has only been tested on Linux. Exiting..."
	exit 1
fi

#Get user and server info
##Storage share credentials
GUESSUSER=$(last | grep tty | head -1 | awk '{print $1}')
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
HOMEDIR=$(getent passwd | grep ${USERNAME} | cut -d':' -f6)
echo "By default, the user ${USERNAME}'s home directory will be backed up, at the expected"
echo "path ${HOMEDIR}. If this is not correct, or if you want to back up a"
read -p "different directory instead, enter it now [$HOMEDIR]: " LOCALDIR
: ${LOCALDIR:="$HOMEDIR"}
LOCALDIR=${LOCALDIR}/
read -p "Server with share to mount [sharedstorage01.hpc.uiowa.edu]: " SERVER
: ${SERVER:="sharedstorage01.hpc.uiowa.edu"}
read -p "Path to SMB share [/mrirc]: " SHAREPATH
: ${SHAREPATH:="/mrirc"}
read -p "Enter a name for the backup job [MRRC_Backup] : " JOBNAME
: ${JOBNAME:="MRRC_Backup"}

#Ensure SCRIPTDIR exists
SCRIPTDIR="/root/.scripts"
mkdir -p -m 700 ${SCRIPTDIR}
chown ${USERNAME} ${SCRIPTDIR}

#Store credentials in plaintext file in SCRIPTDIR
CREDSFILE="${SCRIPTDIR}/${JOBNAME}_${USERNAME}_secret"
cat >${CREDSFILE} <<EOF
username=${SUSERNAME}
password=${SECRET}
EOF

#Ensure readable by root only
chmod 400 ${CREDSFILE}
chown ${USERNAME} ${CREDSFILE}

#Ensure mount point
MOUNTPOINT='/mnt/backup'
mkdir -p ${MOUNTPOINT}

#Test the mount
UNCPATH="//${SERVER}${SHAREPATH}"
if mount -t cifs ${UNCPATH} ${MOUNTPOINT} -o credentials=${CREDSFILE}; then
	echo "Mounted backup share to ${MOUNTPOINT}"
else
	echo "Unable to mount backup share. Exiting..."
	echo ''
	exit 1
fi

#Create/delete a small test file
echo "Creating/removing small test file on share..."
if touch ${MOUNTPOINT}/.testfile; then
	echo "Test file created."
else
	echo "Unable to create test file! Exiting..."
	exit 1
fi
if rm -f ${MOUNTPOINT}/.testfile; then
	echo "Test file removed."
else
	echo "Unable to remove test file! Exiting..."
	exit 1
fi

#Unmount the test mount
echo -n 'Unmounting backup share...'
if umount ${MOUNTPOINT}; then
	echo 'Done.'
elif sleep 5 && umount ${MOUNTPOINT}; then
	echo 'Done.'
else echo 'FAILED.'
fi

#Deploy backup script
cat >${SCRIPTDIR}/${JOBNAME}_${USERNAME}.sh <<EOF
#!/bin/bash

#This script was put in place by a deployment script. Any changes made here will be 
#overwritten if the deployment script is run again.

#This script mirrors the user's home directory to a previously-specified storage share.
#Intended to be run as a nightly cron job.


#Various variables
_USERNAME=${USERNAME}
_CREDSFILE=${CREDSFILE}
_SHAREPATH=${SHAREPATH}
_UNCPATH="//${SERVER}\${_SHAREPATH}"
_MOUNTPOINT=${MOUNTPOINT}
_LOCALDIR=${LOCALDIR}
_DESTDIR=\${_MOUNTPOINT}/\$(hostname -s)/\${_USERNAME}
_DATE=\$(date +"%Y%m%d")
_LOGDIR=\${_MOUNTPOINT}/\$(hostname -s)/\${_USERNAME}_logs
_LOGFILE=\${_LOGDIR}/\${_USERNAME}-\${_DATE}
_LOCALLOGDIR=/tmp/.backup_logs
_LOCALLOGFILE=\${_LOCALLOGDIR}/\${_USERNAME}-\${_DATE}


#Sleep for up to 5000 seconds to try to reduce traffic to share
RAND_SLEEP=\$[ ( \$RANDOM % 5000 ) + 1 ]
echo "Sleeping for \${RAND_SLEEP} seconds to reduce concurrent traffic to share..."
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

#Check if share is mounted, else mount it
if grep -qs \${_MOUNTPOINT} /proc/mounts; then
	echo 'Backup share already mounted.'
else
	if [[ ! -f \${_CREDSFILE} ]]; then
		echo "Credentials file does not exist. Exiting..."
		echo ''
		exit 1
	fi
	if mount -t cifs \${_UNCPATH} \${_MOUNTPOINT} -o credentials=\${_CREDSFILE}; then
		echo "Mounted backup share to \${_MOUNTPOINT}"
	else
		echo "Unable to mount backup share. Exiting..."
		echo "Script stopped at \$(date +"%H:%M:%S %m/%d/%Y")"
		cat >/tmp/failmsg.txt <<-EOF
		The nightly MRRC backup job failed.
		If you have changed your password recently, this is likely the cause. Run the 
		UpdatePassword.sh script found on the ICTS sysadmin share.

		Contact ICTS if you need help.
		EOF
		mailx -s 'MRRC backup job failed!' root < /tmp/mail.txt
		echo ''
		exit 1
	fi
fi

#Ensure LOGDIR and DESTDIR exist
mkdir -p -m 755 \${_LOGDIR}
mkdir -p -m 700 \${_DESTDIR}
chown -R \${_USERNAME} \${_DESTDIR}

#Set rsync options
#       --delete : deletes files from the remote share that no longer exist locally
#             -r : recursive
#             -p : preserve permissions
#             -t : preserve modification times
#             -g : preserve group
#             -o : preserve owner
#             -D : --devices and --specials
#             -v : verbose output
#     --exclude= : exclude files matching PATTERN
_RSYNC_OPTIONS="-rptgoDv --exclude .cache --exclude .mozilla --delete"

#Run the rsync job
echo 'Starting rsync with parameters:'
echo "    Source      : \$_LOCALDIR"
echo "    Destination : \$_DESTDIR"
echo "    Options     : \$_RSYNC_OPTIONS"
rsync \${_RSYNC_OPTIONS} \${_LOCALDIR} \${_DESTDIR}
echo ''

#Clean up log files older than 7 days
echo -n 'Cleaning up old logs (1 of 2)...'
find \${_LOGDIR} -type f -mtime +7 -exec rm '{}' \;
echo 'Done.'
echo -n 'Cleaning up old logs (2 of 2)...'
find \${_LOCALLOGDIR} -type f -mtime +7 -exec rm '{}' \;
echo 'Done.'

FINISH="Script finished at: \$(date +"%H:%M:%S %m/%d/%Y")"
echo \$FINISH

#Copy LOCALLOGFILE to LOGDIR
cp \${_LOCALLOGFILE} \${_LOGFILE}
chmod 755 \${_LOGFILE}

#Unmount the share
echo -n 'Unmounting backup share...'
if umount \$_MOUNTPOINT; then
	echo 'Done.'
elif sleep 5 && umount \$_MOUNTPOINT; then
	echo 'Done.'
else echo 'FAILED.'
fi

echo \$FINISH
exit
EOF

#Change permissions
chown ${USERNAME} ${SCRIPTDIR}/${JOBNAME}_${USERNAME}.sh
chmod 700 ${SCRIPTDIR}/${JOBNAME}_${USERNAME}.sh



#Add script as a cron job
crontab -l | grep -v "${SCRIPTDIR}/${JOBNAME}_${USERNAME}.sh" > /tmp/crontab.tmp
#Starts at 2AM daily
echo "0 2 * * *	${SCRIPTDIR}/${JOBNAME}_${USERNAME}.sh > /dev/null 2>&1" >> /tmp/crontab.tmp
crontab /tmp/crontab.tmp
rm /tmp/crontab.tmp

echo "Backup script deployed successfully."
exit 0