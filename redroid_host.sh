#!/bin/bash

# make sure you throw redroid_host.sh and redroid_device.sh inside cosmog folder
# this script assumes you already have your docker-compose.yml setup
# alongside houndour and configs folder with cosmog configuration files ready
# all of this should be auto created by redroid_init.sh if anything
# if redroid_init.sh is not found in the repo check back later

# leave this as is unless directed to change
cosmog_lib="libNianticLabsPlugin.so"
cosmog_package="com.sy1vi3.cosmog"
cosmog_apk=$(ls -t cosmog*.apk | head -n 1 | sed -e 's@\*@@g')
# leave this as is unless cosmog dev mandates a different version
lib_version=0.311.1
cosmog_startup=false
# Ensure the cosmog directory exists
mkdir -p ~/cosmog
cd ~/cosmog


# Ensure vm.txt exists
# vm.txt should contain ip:port of every redroid container you have per line
if [ ! -f vm.txt ]; then
    echo "[error] vm.txt file not found"
    echo "[error] you need to create vm.txt and add all your redroids to it"
    exit 1
fi

# redroid_device.sh needs to be in the same folder
# this script is required to run inside redroid
if [ ! -f redroid_device.sh ]; then
    echo "[error] redroid_device.sh file not found"
    exit 1
fi

logdir="./script-logs"
logfile=${logdir}/cosmog.script.log
cerror=${logdir}/connection_error.log

log() {
    line="$(date +'[%Y-%m-%dT%H:%M:%S %Z]') $@"
    echo "$line"
}

mkdir -p "$logdir"
touch "$logfile"
exec > >(tee -a "$logfile") 2>&1

# Clone joltik repository if not already cloned
if [ ! -d ~/cosmog/joltik ]; then
  git clone https://github.com/sy1vi3/joltik.git
fi

cd ~/cosmog/joltik

# Run joltik.py script with specified version
python3 joltik.py --version "$lib_version"

# Copy lib to cosmog directory
cp arm64-v8a/$cosmog_lib ~/cosmog

cd ~/cosmog

# Read device list from vm.txt
# format should be ip:port of your redroid containers for adb
# e.g. localhost:5555 localhost:5556, etc per line
mapfile -t devices < vm.txt

# handle adb connect and catch errors to avoid bad installs
adb_connect_device() {
    local device_ip="$1"
    local timeout_duration="3m"
    local max_retries=10
    local max_auth_retries=3
    local attempt=0
    local auth_attempt=0
    local success=0
    local sleep_time=10

    adb disconnect "${device_ip}"
    sleep 2
    echo "[adb] trying to connect to ${device_ip}..."

    while (( attempt < max_retries && success == 0 )); do
        local output=$(timeout $timeout_duration adb connect "${device_ip}" 2>&1)
        local exit_status=$?

        if [[ "$output" == *"connected"* || "$output" == *"already connected to"* ]]; then
            echo "[adb] connected successfully to ${device_ip}."
            success=1
        elif [[ "$output" == *"failed to auth"* || "$output" == *"ADB_VENDOR_KEYS"* ]]; then
            if (( auth_attempt < max_auth_retries )); then
                echo "[adb] authentication failure detected"
                echo "[adb] retrying after restarting adb server (${auth_attempt}/${max_auth_retries})..."
                adb kill-server
                sleep 5
                adb start-server
                ((auth_attempt++))
                continue
            else
                echo "[adb] critical error: persistent auth failure after ${max_auth_retries} attempts."
                echo "[adb] recommended to blow out the vm data folder and restart the container"
                exit 1
            fi
        elif [[ -z "$output" || "$output" == *"offline"* || "$output" == *"connection refused"* ]]; then
            echo "[adb] warning: $output. retrying connection attempt ${attempt}..."
        elif [[ "$exit_status" -eq 124 ]]; then  #
            echo "[adb] connection attempt to ${device_ip} timed out."
            echo "${device_ip} Timeout" >> "$logfile"
        else
            echo "[adb] error connecting to ${device_ip}: $output"
            echo "${device_ip} Error" >> "$logfile"
        fi
        
        ((attempt++))
        sleep $sleep_time
    done

    if [[ success -eq 0 ]]; then
        echo "[adb] max retries reached, unable to connect to ${device_ip}."
        exit 1
    fi
}

# handle connecting via root to avoid bad installs
adb_root_device() {
    local device_ip="$1"
    local timeout_duration="3m"
    local max_retries=3
    local auth_attempt=0
    local max_auth_retries=3
    local attempt=0
    local success=0
    local sleep_time=10

    echo "[adb] Trying to connect as root to ${device_ip}."
    sleep 2

    while (( attempt < max_retries && success == 0 )); do
        local output=$(timeout $timeout_duration adb -s "${device_ip}" root 2>&1)
        local exit_status=$?

        if [[ "$output" == *"restarting adbd"* || "$output" == *"already running as root"* || "$output" == *"success"* ]]; then
            echo "[adb] running as root successfully on ${device_ip}."
            success=1
        elif [[ -z "$output" ]]; then
            echo "[adb] no output received, possibly a delayed response. waiting and retrying..."
        elif [[ "$output" == *"error"* && ! "$output" == *"failed to auth"* && ! "$output" == *"ADB_VENDOR_KEYS"* ]]; then
            echo "[adb] error: ${output}. retrying in $sleep_time seconds..."
        elif [[ "$output" == *"production builds"* ]]; then
            echo "[adb] cannot run as root in production builds on ${device_ip}."
            echo "[adb] this error means your redroid image is not correct."
            exit 1  # Exit script completely, non-recoverable error - bad image
        elif [[ "$output" == *"failed to auth"* || "$output" == *"ADB_VENDOR_KEYS"* ]]; then
            if (( auth_attempt < max_auth_retries )); then
                echo "[adb] authentication failure detected. retrying after restarting ADB server (${auth_attempt}/${max_auth_retries})..."
                adb kill-server
                sleep 5
                adb start-server
                sleep 5
                timeout 30 adb connect "${device_ip}"
                ((auth_attempt++))
                continue
            else
                echo "[adb] critical persistent failure after ${max_auth_retries} attempts."
                echo "[adb] rm -rf data folder and restart container"
                exit 1
            fi
        elif [[ $exit_status -eq 124 ]]; then
            echo "[adb] connection attempt to ${device_ip} timed out."
            echo "${device_ip} Timeout" >> "$logfile"
        else
            echo "[error] unexpected issue when connecting to ${device_ip}: $output"
            echo "${device_ip} Error" >> "$logfile"
        fi

        ((attempt++))
        sleep $sleep_time
    done

    if [[ success -eq 0 ]]; then
        echo "[adb] max retries reached, unable to connect as root to ${device_ip}."
        exit 1
    fi
}

# handle unrooting to avoid adb_vendor_key unpairing hell
adb_unroot_device() {
    local device_ip="$1"
    local timeout_duration="3m"
    local max_retries=3
    local attempt=0
    local success=0
    local sleep_time=10

    echo "[adb] trying to unroot on ${device_ip}"
    sleep 2

    while (( attempt < max_retries && success == 0 )); do
        local output=$(timeout $timeout_duration adb -s "${device_ip}" unroot 2>&1)
        local exit_status=$?

        if [[ "$output" == *"restarting adbd as non-root"* || "$output" == *"not running as root"* ]]; then
            echo "[adb] unroot is successful ${device_ip}."
            success=1
        elif [[ -z "$output" ]]; then
            echo "[adb] no output received, possibly a delayed response. waiting and retrying..."
        elif [[ "$output" == *"error"* ]]; then
            echo "[adb] device ${device_ip} is offline, retrying in $sleep_time seconds..."
        elif [[ $exit_status -eq 124 ]]; then
            echo "[adb] unroot attempt to ${device_ip} timed out."
            echo "${device_ip} Timeout" >> "$logfile"
        else
            echo "[error] unrooting ${device_ip}: $output"
            echo "${device_ip} Error" >> "$logfile"
        fi

        ((attempt++))
        sleep $sleep_time
    done

    if [[ success -eq 0 ]]; then
        echo "[adb] max retries reached, attempting a server restart as final attempt to unroot ${device_ip}."
        adb kill-server
        sleep 5
        adb start-server
        sleep 5
        timeout 30 adb connect "${device_ip}"
        local final_output=$(adb -s "${device_ip}" unroot 2>&1)
        if [[ "$final_output" == *"restarting adbd as non-root"* || "$final_output" == *"not running as root"* ]]; then
            echo "[adb] final unroot attempt successful on ${device_ip}."
        else
            echo "[adb] final unroot attempt failed on ${device_ip}: $final_output"
            echo "[adb] consider restarting container and restarting script"
            echo "${device_ip} Error" >> "$logfile"
            exit 1
        fi
    fi
}

setup_push_script() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          adb -s $i push redroid_device.sh /data/local/tmp/
          echo "[setup] scripts transferred and ready"
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
    return 0
}

setup_permissions_script() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          if adb_root_device "$i"; then
                # granting scripts executable permission
                adb -s $i shell "su -c chmod +x /data/local/tmp/redroid_device.sh"
                echo "[setup] script chmod +x successful"
            else
                echo "[setup] Skipping $i due to connection error."
                exit 1
          fi
      else
          echo "[magisk] Skipping $i due to connection error."
          exit 1
      fi
    done
    return 0
}


setup_permissions_script_noroot() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # granting scripts executable permission
          adb -s $i shell "su -c chmod +x /data/local/tmp/redroid_device.sh"
          echo "[setup] script chmod +x successful"
      else
          echo "[magisk] Skipping $i due to connection error."
          exit 1
      fi
    done
    return 0
}

magisk_setup_settings() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          if adb_root_device "$i"; then
              # enabling su via shell and disabling adb root to avoid problems
              echo "[magisk] shell su granting"
              for k in `seq 1 3` ; do
            	  adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisk_settings'"
              done
              echo "[adb] performing unroot to avoid adb_vendor_key pairing issues"
              if adb_unroot_device "$i"; then
                  echo "[adb] unroot successful"
              fi
          else
              echo "[magisk] Skipping $i due to connection error."
              exit 1
          fi
      else
            echo "[magisk] Skipping $i due to connection error."
            exit 1
      fi
    done
    return 0
}

magisk_setup_init() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # completing magisk setup
          echo "[magisk] attempting to finish magisk init"
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisk_app'"
          sleep 60
          echo "[magisk] magisk init setup complete"
          echo "[magisk] reboot needed..."
      else
          echo "[magisk] Skipping $i due to connection error."
          exit 1
      fi
    done
    return 0
}

setup_do_settings() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # running initial global commands to avoid pop-ups and issues
          echo "[setup] setting up global settings"
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh do_settings'"
          echo "[setup] global settings complete"
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

magisk_denylist() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # adding common packages to denylist
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisk_denylist'"
          echo "[magisk] denylist complete"
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

magisk_sulist() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # setting up magiskhide + sulist
          echo "[magisk] starting magisk hide and sulist services..."
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisksulist_app'"
          sleep 60
          echo "[magisk] hide and sulist enabled"
          echo "[magisk] reboot needed..."
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
    return 0
}

check_magisk_sulist() {
    for i in "${devices[@]}"; do
        if adb_connect_device "$i"; then
            echo "[check] checking MagiskHide status on device $i..."
            output=$(adb -s "$i" shell "su -c '/system/bin/magiskhide status'" 2>&1)
            # Clean up the output for whitespace and newlines, make case insensitive
            output=$(echo "$output" | tr -d '\n' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
            
            if [[ "$output" == *"magiskhide is enabled"* ]]; then
                echo "[check] MagiskHide is properly configured on $i."
                # verify sulist status
                echo "[check] checking SuList status on device $i..."
                output=$(adb -s "$i" shell "su -c '/system/bin/magiskhide sulist'" 2>&1)
                output=$(echo "$output" | tr -d '\n' | tr -s ' ' | tr '[:upper:]' '[:lower:]')
                if [[ "$output" == *"sulist is enforced"* ]]; then
                    echo "[check] SuList is properly configured on $i."
                    continue
                else
                    echo "[error] Configuration issue on device $i. SuList is not properly set."
                    exit 1
                fi
            else
                echo "[error] Configuration issue on device $i. MagiskHide is not properly set."
                exit 1
            fi
        else
            echo "[setup] Skipping device $i due to connection error."
            exit 1
        fi
    done
    return 0
}

cosmog_install() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # install cosmog
          echo "[cosmog] killing app if it exists"
          adb -s $i shell "su -c 'am force-stop $cosmog_package && killall $cosmog_package'"
          adb -s $i install -r $cosmog_apk
          echo "[cosmog] installed cosmog"
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_cosmog_policies'"
          echo "[cosmog] policy added"
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

cosmog_uninstall() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # uninstall cosmog
          echo "[cosmog] killing app if it exists"
          adb -s $i shell "su -c 'am force-stop $cosmog_package && killall $cosmog_package'"
          adb -s $i uninstall $cosmog_package
          echo "[cosmog] uninstalled"
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
    return 0
}

cosmog_sulist() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # add cosmog and magisk to sulist
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisk_sulist'"
          echo "[magisk] sulist packages added"
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

check_cosmog_sulist() {
    for i in "${devices[@]}"; do
        if adb_connect_device "$i"; then
            echo "[magisk] verifying packages made it to sulist on device $i..."
            output=$(adb -s "$i" shell "su -c '/system/bin/magiskhide ls'" 2>&1)
            # Clean up the output for whitespace and newlines
            output=$(echo "$output" | tr -d '\n' | tr -s ' ')
            # Check for com.android.shell
            if [[ "$output" == *"com.android.shell|com.android.shell"* ]]; then
                echo "[magisk] com.android.shell is confirmed on device $i."
            else
                echo "[error] com.android.shell failed to be added to sulist on device $i."
                exit 1
            fi

            # Check for com.sy1vi3.cosmog
            output=$(adb -s "$i" shell "su -c '/system/bin/magiskhide ls'" 2>&1)
            # Clean up the output for whitespace and newlines
            output=$(echo "$output" | tr -d '\n' | tr -s ' ')
            if [[ "$output" == *"com.sy1vi3.cosmog|com.sy1vi3.cosmog"* ]]; then
                echo "[magisk] com.sy1vi3.cosmog is confirmed on device $i."
            else
                echo "[error] com.sy1vi3.cosmog failed to be added to sulist on device $i."
                exit 1
            fi

        else
            echo "[setup] Skipping device $i due to connection error."
            exit 1
        fi
    done
    return 0
}

cosmog_lib() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # send lib to device and set ownership and perm
          echo "[lib]: pushing lib and setting up dir..."
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_cosmog_perms'"
          adb -s $i push joltik/arm64-v8a/$cosmog_lib /data/local/tmp/$cosmog_lib
          adb -s $i shell "su -c 'cp /data/local/tmp/$cosmog_lib /data/data/$cosmog_package/files/$cosmog_lib'"
          echo "[lib] changing lib perms and ownership including path"
          adb -s $i shell "su -c 'chown root:root /data/data/$cosmog_package/files/$cosmog_lib'"
          adb -s $i shell "su -c 'chmod 444 /data/data/$cosmog_package/files/$cosmog_lib'"
          echo "[lib] all done"
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

cosmog_start() {
    # Loop through each device
    for i in "${devices[@]}";do
      if adb_connect_device "$i" "$port"; then
          # stop cosmog if it is running
          adb -s $i shell "su -c 'am force-stop $cosmog_package && killall $cosmog_package'"
          # launch cosmog
          adb -s $i shell "su -c 'am start -n $cosmog_package/.MainActivity'"
          echo "[cosmog] launched"
      else
          echo "[cosmog] Skipping $i due to connection error."
          exit 1
      fi
    done
}

  # magisk will sometimes think it failed repacking
  # repackage manually or add in your own scripting to account for errors
  # the error is misleading, as it does succeed, but does not replace the old apk
  # you will need to reboot, then select the new repacked apk (settings)

magisk_repackage() {
  for i in "${devices[@]}";do
    if adb_connect_device "$i"; then
        echo "[magisk] attempting to repackage magisk..."
        adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh repackage_magisk'"
        sleep 60
        echo "[magisk] reboot needed..."
        adb -s $i shell "su -c 'reboot'"
        sleep 30
    else
        echo "[setup] Skipping $i due to connection error."
        exit 1
    fi
  done
  return 0
}

setup_do_more_settings() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # running more global commands to avoid pop-ups and issues
          echo "[setup] setting up more global settings"
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh do_more_settings'"
          echo "[setup] more global settings complete"
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

reboot_redroid() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # reboot redroid
          adb -s $i shell "su -c 'reboot'"
          echo "[setup] reboot needed...sleep 30"
          sleep 30
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
    return 0
}

cosmog_update() {
    setup_push_script || { log "[error] transferring redroid setup script"; exit 1; }
    setup_permissions_script_noroot || { log "[error] granting redroid_device.sh chmod +x"; exit 1; }
    cosmog_install || { log "[error] installing cosmog"; exit 1; }
    if $cosmog_startup ; then
        cosmog_start || { log "[error] launching cosmog"; exit 1; }
    fi
}

cosmog_lib_update() {
    setup_push_script || { log "[error] transferring redroid setup script"; exit 1; }
    setup_permissions_script_noroot || { log "[error] granting redroid_device.sh chmod +x"; exit 1; }
    cosmog_lib || { log "[error] installing lib"; exit 1; }
    if $cosmog_startup ; then
        cosmog_start || { log "[error] launching cosmog"; exit 1; }
    fi
}

# If no arguments are provided, run all functions
if [ $# -eq 0 ]; then
    main() {
        setup_push_script || { log "[error] transferring redroid setup script"; exit 1; }
        setup_permissions_script || { log "[error] granting redroid_device.sh chmod +x"; exit 1; }
        magisk_setup_settings || { log "[error] giving shell su perms"; exit 1; }
        magisk_setup_init || { log "[error] completing magisk init"; exit 1; }
        reboot_redroid || { log "[error] rebooting redroid"; exit 1; }
        magisk_denylist || { log "[error] setting up denylist"; exit 1; }
        magisk_sulist || { log "[error] enabling sulist"; exit 1; }
        reboot_redroid || { log "[error] rebooting redroid"; exit 1; }
        check_magisk_sulist || { log "[error] verifying sulist status"; exit 1; }
        cosmog_install || { log "[error] installing cosmog"; exit 1; }
        cosmog_sulist || { log "[error] adding cosmog to sulist"; exit 1; }
        reboot_redroid || { log "[error] reboot redroid"; exit 1; }
        check_cosmog_sulist || { log "[error] verifying sulist packages"; exit 1; }
        setup_do_more_settings || { log "[error] enabling global settings"; exit 1; }
        reboot_redroid || { log "[error] reboot redroid"; exit 1; }
        cosmog_lib || { log "[error] installing lib"; exit 1; }
        if $cosmog_startup ; then
            cosmog_start || { log "[error] launching cosmog"; exit 1; }
        fi
}


    main

# If argument is provided, attempt to call the function with that name
else
    while [[ $# -gt 0 ]]; do
        if typeset -f "$1" > /dev/null; then
          "$1" || { log "[error] running function '$1'"; exit 1; }
        else
            log "[error] no such function: '$1'"
            exit 1
        fi
        shift
    done
fi
