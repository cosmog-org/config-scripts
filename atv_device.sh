#!/system/bin/sh

magisk='/sbin/magisk'
logdir=/sdcard/.magisk-install
logfile=${logdir}/install.log

log() {
    line="`date +'[%Y-%m-%dT%H:%M:%S %Z]'` $@"
    echo "$line"
}

if [ "$(id -u)" -ne 0 ]; then
    log '[shell] root required, re-run as root.'
    exit 1
fi


setup_magisk_settings() {
    # root access for shell:
    shell_uid=$(id -u shell)
    log "Got $shell_uid for shell UID"
    "$magisk" --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES($shell_uid,2,0,1,1);" || return 1
}

do_settings() {
    settings put global policy_control 'immersive.navigation=*'
    settings put global policy_control 'immersive.full=*'
    settings put secure immersive_mode_confirmations confirmed || return 1
    settings put global heads_up_enabled 0
    settings put global bluetooth_disabled_profiles 1 || return 1
    settings put global bluetooth_on 0 || return 1
    settings put global package_verifier_user_consent -1 || return 1
}

setup_magisk_denylist() {
    # add common packages to denylist
    "$magisk" --sqlite "REPLACE INTO denylist (package_name,process) VALUES('com.android.vending','com.android.vending');" || return 1
    "$magisk" --sqlite "REPLACE INTO denylist (package_name,process) VALUES('com.google.android.gms','com.google.android.gms');" || return 1
    "$magisk" --sqlite "REPLACE INTO denylist (package_name,process) VALUES('com.google.android.gms.setup','com.google.android.gms.setup');" || return 1
    "$magisk" --sqlite "REPLACE INTO denylist (package_name,process) VALUES('com.google.android.gsf','com.google.android.gsf');" || return 1
    "$magisk" --sqlite "REPLACE INTO denylist (package_name,process) VALUES('com.nianticlabs.pokemongo','com.nianticlabs.pokemongo');" || return 1
    # add cosmog workers to denylist
    i=1
    while [ $i -le 100 ]; do
      "$magisk" --sqlite "REPLACE INTO denylist (package_name,process) VALUES('com.sy1vi3.cosmog','com.sy1vi3.cosmog:worker$i.com.nianticlabs.pokemongo');"
      i=$((i + 1))
    done
    # enable zygisk
    "$magisk" --sqlite "REPLACE INTO settings (key,value) VALUES('zygisk',1);"
    # enable denylist
    "$magisk" --sqlite "REPLACE INTO settings (key,value) VALUES('denylist',1);"
    "$magisk" --denylist enable


}

setup_cosmog_policies() {
    cosmog_uid=$(dumpsys package com.sy1vi3.cosmog | grep userId= | awk -F= '{ print $2 }')
    if [ -n "$cosmog_uid" ]; then
        "$magisk" --sqlite "REPLACE INTO policies (uid,policy,until,logging,notification) VALUES($cosmog_uid,2,0,1,0);" || return 1
        log '[cosmog] policy update complete!'
    else
        log '[cosmog] policy update failed... package does not exist'
        return 1
    fi
}

setup_cosmog_perms() {
    # Replace these paths with your actual source and target paths
    cosmog_dir="/data/data/com.sy1vi3.cosmog"
    files_dir="$cosmog_dir/files"

    # Extract owner, group, and permissions
    owner=$(stat -c "%U" "$cosmog_dir")
    group=$(stat -c "%G" "$cosmog_dir")
    perms=$(stat -c "%a" "$cosmog_dir")

    # Apply the owner and group to the target
    chown -R "$owner":"$group" "$files_dir"

    # Apply the permissions to the target
    chmod -R "$perms" "$files_dir"
}

# If no arguments are provided, run all functions
if [ $# -eq 0 ]; then
    main() {
        setup_magisk_settings || { log "Error setting up Magisk settings"; exit 1; }
        do_settings || { log "Error doing settings"; exit 1; }
        setup_magisk_denylist || { log "Error setting up Magisk denylist"; exit 1; }
        setup_cosmog_policies || { log "Error setting up Cosmog policies"; exit 1; }
    }

    main
# If argument is provided, attempt to call the function with that name
else
    while [[ $# -gt 0 ]]; do
        "$1" || { log "Error running function '$1'"; exit 1; }
        shift
    done
fi
