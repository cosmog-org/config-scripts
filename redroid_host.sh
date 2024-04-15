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
lib_version=0.307.1

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
    line="$(date + '[%Y-%m-%dT%H:%M:%S %Z]') $@"
    echo "$line"
}

mkdir -p "$logdir"
touch "$logfile"


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
    local timeout_duration="10s"
    local max_retries=3
    local attempt=0

    # disconnect before connecting to avoid already connected status
    adb disconnect "${device_ip}"
    echo "[adb] trying to connect to ${device_ip}..."
    while (( attempt < max_retries )); do
        local output=$(timeout $timeout_duration adb connect "${device_ip}" 2>&1)
        if [[ "$output" == *"Connected"* ]]; then
            echo "[adb] connected successfully to ${device_ip}."
            return 0  # success
        elif [[ "$output" == *"offline"* ]]; then
            echo "[adb] device ${device_ip} is offline, retrying in 10 seconds..."
            ((attempt++))
            sleep 10
        elif [[ "$output" == *"Connection refused"* ]]; then
            echo "[adb] connection refused to ${device_ip}. Exiting script."
            exit 1  # exit script completely
        elif [[ $? -eq 124 ]]; then  # Check if timeout occurred
            echo "[adb] connection attempt to ${device_ip} timed out."
            echo "${device_ip} Timeout" >> "$logfile"
            exit 1  # Failure due to timeout, terminate script
        else
            echo "[error] connecting to ${device_ip}: $output"
            echo "${device_ip} Error" >> "$logfile"
            exit 1  # Unknown failure, terminate script
        fi
    done
    echo "[adb] max retries reached, unable to connect to ${device_ip}."
    return 1  # Failure after retries
}


# handle connecting via root to avoid bad installs
adb_root_device() {
    local device_ip="$1"
    local timeout_duration="10s"
    local max_retries=3
    local attempt=0

    echo "[adb] trying to connect as root to ${device_ip}"
    while (( attempt < max_retries )); do
        local output=$(timeout $timeout_duration adb -s "${device_ip}" root 2>&1)
        if [[ "$output" == *"restarting adbd"* || "$output" == *"already running"* ]]; then
            echo "[adb] running as root successfully ${device_ip}."
            return 0  # success
        elif [[ "$output" == *"error"* ]]; then
            echo "[adb] device ${device_ip} is offline, retrying in 10 seconds..."
            ((attempt++))
            sleep 10
        elif [[ "$output" == *"production builds"* ]]; then
            echo "[adb] cannot run as root in production builds on ${device_ip}."
            echo "[adb] this error means your redroid image is not correct."
            exit 1  # exit script completely
        elif [[ $? -eq 124 ]]; then  # Check if timeout occurred
            echo "[adb] connection attempt to ${device_ip} timed out."
            echo "${device_ip} Timeout" >> "$logfile"
            exit 1  # Failure due to timeout, terminate script
        else
            echo "[error] connecting to ${device_ip}: $output"
            echo "${device_ip} Error" >> "$logfile"
            exit 1  # Unknown failure, terminate script
        fi
    done
    echo "[adb] Max retries reached, unable to connect to ${device_ip}."
    return 1  # Failure after retries
}

# handle unrooting to avoid adb_vendor_key unpairing hell
adb_unroot_device() {
    local device_ip="$1"
    local timeout_duration="10s"
    local max_retries=3
    local attempt=0

    echo "[adb] trying to unroot on ${device_ip}"
    while (( attempt < max_retries )); do
        local output=$(timeout $timeout_duration adb -s "${device_ip}" unroot 2>&1)
        if [[ "$output" == *"restarting adb"* || "$output" == *"not running as root"* ]]; then
            echo "[adb] unroot is successful ${device_ip}."
            return 0  # success
        elif [[ "$output" == *"error"* ]]; then
            echo "[adb] device ${device_ip} is offline, retrying in 10 seconds..."
            ((attempt++))
            sleep 10
        elif [[ $? -eq 124 ]]; then  # Check if timeout occurred
            echo "[adb] unroot attempt to ${device_ip} timed out."
            echo "${device_ip} Timeout" >> "$logfile"
            exit 1  # Failure due to timeout, terminate script
        else
            echo "[error] unrooting ${device_ip}: $output"
            echo "${device_ip} Error" >> "$logfile"
            exit 1  # Unknown failure, terminate script
        fi
    done
    echo "[adb] Max retries reached, unable to unroot ${device_ip}."
    return 1  # Failure after retries
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
}


magisk_setup_init() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          if adb_root_device "$i"; then
            # completing magisk setup
              echo "[magisk] attempting to finish magisk init"
              timeout 10s adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisk_app'"
              echo "[magisk] magisk init setup complete"
              # sleep 5 seconds to prevent moving too fast after init
              sleep 5
          else
              echo "[magisk] Skipping $i due to connection error."
              exit 1
          fi
      else
          echo "[magisk] Skipping $i due to connection error."
          exit 1
      fi
    done
}

magisk_setup_settings() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          if adb_root_device "$i"; then
              # enabling su via shell and disabling adb root to avoid problems
              echo "[magisk] shell su granting"
              for k in `seq 1 3` ; do
            	  timeout 10s adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisk_settings'"
            	  sleep 2
              done
              if adb_unroot_device "$i"; then
                  echo "[magisk] shell su settings complete"
              else
                  echo "[magisk] unroot on $i failed, exiting"
                  exit 1
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
}


setup_do_settings() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # running global commands avoid pop-ups and issues
          echo "[setup] setting up global settings"
          timeout 10s adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh do_settings'"
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
          timeout 10s adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisk_denylist'"
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
          timeout 10s adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisksulist_app'"
          sleep 40
          timeout 10s adb -s $i reboot
          echo "[magisk] hide and sulist enabled"
          echo "[magisk] reboot needed..sleep 20"
          sleep 20
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

cosmog_install() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # install cosmog
          echo "[cosmog] killing app if it exists"
          timeout 10s adb -s $i shell "su -c 'am force-stop $cosmog_package && killall $cosmog_package'"
          timeout 10s adb -s $i install -r $cosmog_apk
          echo "[cosmog] installed cosmog"
          timeout 10s adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_cosmog_policies'"
          echo "[cosmog] policy added"

      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

cosmog_sulist() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # add cosmog and magisk to sulist
          timeout 10s adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/redroid_device.sh setup_magisk_sulist'"
          echo "[magisk] sulist packages added"
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

reboot_redroid() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # reboot redroid to avoid sulist adb problems
          timeout 10s adb -s $i shell "su -c 'reboot'"
          echo "[setup] reboot needed...sleep 20"
          sleep 20
      else
          echo "[setup] Skipping $i due to connection error."
          exit 1
      fi
    done
}

cosmog_lib() {
    for i in "${devices[@]}";do
      if adb_connect_device "$i"; then
          # send lib to device and set ownership and perm
          echo "[lib]: pushing lib and setting up dir..."
          timeout 10s adb -s $i shell "su -c 'mkdir -p /data/data/$cosmog_package/files/'"
          timeout 10s adb -s $i push joltik/arm64-v8a/$cosmog_lib /data/local/tmp/$cosmog_lib
          timeout 10s adb -s $i shell "su -c 'cp /data/local/tmp/$cosmog_lib /data/data/$cosmog_package/files/$cosmog_lib'"
          echo "[lib] changing lib perms and ownership including path"
          timeout 10s adb -s $i shell "su -c 'chown root:root /data/data/$cosmog_package/files/$cosmog_lib'"
          timeout 10s adb -s $i shell "su -c 'chmod 444 /data/data/$cosmog_package/files/$cosmog_lib'"
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
          timeout 10s adb -s $i shell "su -c 'am force-stop $cosmog_package && killall $cosmog_package'"
          # launch cosmog
          timeout 10s adb -s $i shell "su -c 'am start -n $cosmog_package/.MainActivity'"
          echo "[cosmog] launched"
      else
          echo "[cosmog] Skipping $i due to connection error."
          exit 1
      fi
    done
}

  # magisk will sometimes think it failed repacking
  # repackage manually or add in your own scripting to account for errors
  # the error is a misleading, as it does succeed, but does not replace the old apk
  # you will need reboot, then select the new repackced apk (settings)

magisk_repackage() {
  for i in "${devices[@]}";do
    if adb_connect_device "$i"; then
        echo "[magisk] attempting to repackage magisk..."
        timeout 10s adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/repackage.magisk.sh'"
        sleep 40
        timeout 10s echo "[magisk] reboot needed...sleep 20"
        adb -s $i shell "su -c 'reboot'"
        sleep 20
    else
        echo "[setup] Skipping $i due to connection error."
        exit 1
    fi
  done
}

cosmog_update() {
    cosmog_install || { log "[error] installing cosmog"; exit 1; }
    cosmog_start || { log "[error] launching cosmog"; exit 1; }
}

cosmog_lib_update() {
    cosmog_lib || { log "[error] installing lib"; exit 1; }
    cosmog_start || { log "[error] launching cosmog"; exit 1; }
}

# If no arguments are provided, run all functions
if [ $# -eq 0 ]; then
    main() {
        setup_push_script || { log "[error] transferring redroid setup script"; exit 1; }
        setup_permissions_script || { log "[error] granting redroid_device.sh chmod +x"; exit 1; }
        magisk_setup_init || { log "[error] completing magisk init"; exit 1; }
        magisk_setup_settings || { log "[error] giving shell su perms"; exit 1; }
        setup_do_settings || { log "[error] enabling global settings"; exit 1; }
        magisk_denylist || { log "[error] setting up denylist"; exit 1; }
        magisk_sulist || { log "[error] enabling sulist"; exit 1; }
        cosmog_install || { log "[error] installing cosmog"; exit 1; }
        cosmog_sulist || { log "[error] adding cosmog to sulist"; exit 1; }
        reboot_redroid || { log "[error] reboot redroid"; exit 1; }
        cosmog_lib || { log "[error] installing lib"; exit 1; }
        cosmog_start || { log "[error] launching cosmog"; exit 1; }
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
