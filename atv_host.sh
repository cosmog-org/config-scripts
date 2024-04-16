#!/bin/bash
# make sure you have a devices.txt in the root dir of the script
# this devices.txt should contain 1 ip address per line
# or use the nmap_adb.sh script included in this repo
# Ensure the cosmog directory exists
cd "$(dirname "$0")"

# Ensure unset variables will crash the script instead of causing silent corruption
set -u

# xml file for older opengl 2.0 devices to avoid warning pop-up
# download warning.xml from this repo
xml_file="warning.xml"
xml_name="com.nianticproject.holoholo.libholoholo.unity.UnityMainActivity.xml"
xml_path="/data/data/com.nianticlabs.pokemongo/shared_prefs/"

# leave lib_version at 0.307.1 unless specified otherwise by cosmog dev
lib_version=0.307.1
cosmog_package="com.sy1vi3.cosmog"
cosmog_apk=$(ls -t cosmog*.apk | head -n 1 | sed -e 's@\*@@g')
cosmog_lib="libNianticLabsPlugin.so"

# setting this version is important for pogo_install to work if used
pogo_version=0.307.1
pogo_package="com.nianticlabs.pokemongo"
port=5555

# options are 64, 32, or mixed for your atvs arch
arch_type="64"
# Set names for the APK files based on architecture
# please make sure these exist in the scripts root dir
apk_64="pogo64.apk"
apk_32="pogo32.apk"

# config file values
cosmog_token="COSMOG_TOKEN"
rotom_addy="ROTOM_IP:PORT"
rotom_secret="ROTOM_SECRET"

# config json creation and settings
# default set to 8 for most ATVs for scanning
# set this value to 0 if you want to generate Solver only ATVs
workers=2
# you can change the line value starting from 1 to something else
# for example: default increments from Cosmog001 to start
# or 500 starts incrementing from Cosmog500 for config json
linestart=1
# devicename, whatever you want your device to be called in config json
atvname="CMG"

# reboots atv after free_space is ran, default false
# comstud cs5 rom users should set this to true
# reboot sleep is set to 180s (3mins)
reboot_cleanup=false

# reboots atv after denylist is added
# denylist will not take effect unless android is rebooted
# default to false due to different android devices
# reboot sleep is set to 180s (3mins)
reboot_denylist=false


# Ensure devices.txt exists
if [ ! -f devices.txt ]; then
    echo "[error] devices.txt file not found"
    exit 1
fi

if [ ! -f atv_device.sh ]; then
    echo "[error] atv_device.sh file not found"
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

# Read device list from devices.txt
# ip address per line
mapfile -t devices < devices.txt

joltik(){
    # Clone joltik repository if not already cloned
    if [ ! -d ./joltik ]; then
      git clone https://github.com/sy1vi3/joltik.git || return 1
    fi
    
    cd ./joltik
    
    # Run joltik.py script with specified version for both arch
    python3 joltik.py --arch arm64-v8a --version "$lib_version" || return 1
    python3 joltik.py --arch armeabi-v7a --version "$lib_version" || return 1
    
    cd ..
}

connect_device() {
    local device_ip="$1"
    local device_port="$2"
    local timeout_duration="180s"  # Timeout after 3mins

    echo "[adb] trying to connect to ${device_ip}:${device_port}..."
    local output=$(timeout $timeout_duration adb connect "${device_ip}:${device_port}" 2>&1)

    if [[ "$output" == *"connected"* ]]; then
        echo "[adb] connected successfully to ${device_ip}."
        return 0  # Success
    elif [[ $? -eq 124 ]]; then  # Check if timeout occurred
        echo "[adb] connection attempt to ${device_ip} timed out."
        echo "${device_ip} timeout" >> "$logfile"
        return 1  # Failure due to timeout
    else
        echo "[error] connecting to ${device_ip}: $output"
        echo "${device_ip} error" >> "$logfile"
        return 1  # Failure
    fi
}

cosmog_atv_script() {
  # loop through devices.txt
  for i in "${devices[@]}";do
    if connect_device "$i" "$port"; then
        # push atv setup to device
        adb -s $i push atv_device.sh /data/local/tmp/
        # granting scripts executable permission
        adb -s $i shell "su -c chmod +x /data/local/tmp/atv_device.sh"
        echo "[setup] scripts transferred and ready"
    else
        echo "[setup] Skipping $i due to connection error."
        continue
    fi
  done
}

cosmog_config() {
    # start at $deviceName001
    line=$linestart

    # Pre-determine directories and flags outside the loop if all devices use the same worker count
    config_dir="configs/scanners"  # Default directory for scanners
    use_local_safetynet="true"
    disable_attest_delay="false"

    if [[ "$workers" -eq 0 ]]; then
        config_dir="configs/solvers"  # Directory for solvers
        use_local_safetynet="false"
        disable_attest_delay="true"
    fi

    # Create directory once if it doesn't exist
    mkdir -p "$config_dir"

    # loop through devices.txt
    for i in "${devices[@]}";do
        # pad device number
        n=$(printf "%03d" "$line")
        # prefix device name, change from COSMOG to something else
        deviceName="${atvname}${n}"
        echo "[config] setting up for $deviceName"
        config_path="${config_dir}/${deviceName}.json"

        # create custom config based on type: scanner or solver
        # write the config file using a here-document
        cat > "$config_path" <<EOL
        {
            "device_id": "$deviceName",
            "rotom_worker_endpoint": "ws://$rotom_addy/",
            "rotom_device_endpoint": "ws://$rotom_addy/control",
            "use_local_safetynet": $use_local_safetynet,
            "public_ip": "127.0.0.1",
            "workers": $workers,
            "token": "$cosmog_token",
            "rotom_secret": "$rotom_secret",
            "injection_delay_ms": 5000,
            "pogo_heartbeat_timeout_ms": 45000,
            "concurrent_login_override": 0,
            "worker_spawn_delay_override": 12500,
            "disable_attest_delay": $disable_attest_delay
        }
EOL
        echo "[config] written to $config_path"
        # push cosmog config to device
        timeout 1m adb connect "$i:$port"
        timeout 1m adb -s $i push "${config_dir}/${deviceName}.json" /data/local/tmp/cosmog.json
        ((line++))
    done
}

cosmog_do_settings() {
    # Loop through each device
    for i in "${devices[@]}";do
      if connect_device "$i" "$port"; then
          # running global commands avoid pop-ups and issues
          echo "[setup] setting up global settings"
          adb -s $i shell "su -c 'whoami'"
          adb -s $i shell "su -c 'which sh'"
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/atv_device.sh do_settings'"
          echo "[setup] global settings complete"
      else
          echo "[setup] Skipping $i due to connection error."
          continue
      fi

    done
}

cosmog_install() {
    # Loop through each device
    for i in "${devices[@]}";do
      if connect_device "$i" "$port"; then
          # install cosmog
          echo "[cosmog] killing app if it exists"
          adb -s $i shell "su -c 'am force-stop $cosmog_package && killall $cosmog_package'"
          #adb -s $i uninstall $cosmog_package
          #echo "[cosmog] uninstall cosmog"
          timeout 5m adb -s $i install -r $cosmog_apk
          echo "[cosmog] installed cosmog"
      else
          echo "[cosmog] Skipping $i due to connection error."
          continue
      fi
    done
}

cosmog_root_policy() {
    # Loop through each device
    for i in "${devices[@]}";do
      if connect_device "$i" "$port"; then
          # setup cosmog root policy
          adb -s $i shell "su -c sh /data/local/tmp/atv_device.sh setup_cosmog_policies"
          echo "[cosmog] policy added"
      else
          echo "[cosmog] Skipping $i due to connection error."
          continue
      fi
    done
}

cosmog_magisk_denylist() {
    # Loop through each device
    for i in "${devices[@]}";do
      if connect_device "$i" "$port"; then
          # adding packages to denylist
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/atv_device.sh setup_magisk_denylist'"
          echo "[magisk] denylist complete"
          if [[ "$reboot_denylist" == "true" ]]; then
              echo "[reboot] Rebooting device $i..."
              adb -s $i reboot
              echo "[reboot] rebooting, sleeping for 180s..."
              sleep 180  # Wait for the device to reboot
          fi
      else
          echo "[magisk] Skipping $i due to connection error."
          continue
      fi
    done
}

cosmog_lib() {
    # Loop through each device
    for i in "${devices[@]}";do
      if connect_device "$i" "$port"; then
          arch=$(adb -s $i shell getprop ro.product.cpu.abi)
          # send lib to device and set ownership and perm
          echo "[lib]: pushing lib and setting up dir..."
          adb -s $i shell "su -c 'mkdir -p /data/data/$cosmog_package/files/'"
          adb -s $i push joltik/$arch/$cosmog_lib /data/local/tmp/$cosmog_lib
          adb -s $i shell "su -c 'cp /data/local/tmp/$cosmog_lib /data/data/$cosmog_package/files/$cosmog_lib'"
          echo "[lib] changing lib perms and ownership"
          # setup cosmog root policy
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/atv_device.sh setup_cosmog_perms'"
          adb -s $i shell "su -c 'chown root:root /data/data/$cosmog_package/files/$cosmog_lib'"
          adb -s $i shell "su -c 'chmod 444 /data/data/$cosmog_package/files/$cosmog_lib'"
      else
          echo "[cosmog] Skipping $i due to connection error."
          continue
      fi
    done
}

cosmog_start() {
    # Loop through each device
    for i in "${devices[@]}";do
      if connect_device "$i" "$port"; then
          # launch cosmog if start=true
          adb -s $i shell "su -c monkey -p com.sy1vi3.cosmog 1"
          echo "[script]: $i is complete and cosmog launched"
      else
          echo "[cosmog] Skipping $i due to connection error."
          continue
      fi
    done
}

opengl_warning() {
  # Loop through each device
  for i in "${devices[@]}";do
    if connect_device "$i" "$port"; then
        # Fetch OpenGL version and extract major version directly
        opengl_version=$(adb -s $i shell dumpsys SurfaceFlinger | grep -o "OpenGL ES [0-9]*\.[0-9]*" | sed -n 's/OpenGL ES \([0-9]*\)\..*/\1/p')

        # Check if major_version was successfully extracted
        if [[ -z "$opengl_version" ]]; then
            echo "[xml] failed to extract the OpenGL version."
            return 1
        fi

        # Compare the major version number
        if [[ $opengl_version -ge 3 ]]; then
            echo "[xml] opengl is 3+, skipping"
        else
            echo "[xml] OpenGL version is less than 3. Pushing XML file to device."
            # Push XML file to the device
            adb -s $i push "$xml_file" /data/local/tmp
            adb -s $i shell "su -c 'chown root:root /data/local/tmp/$xml_file'"
            adb -s $i shell "su -c 'mkdir -p $xml_path'"
            adb -s $i shell "su -c 'cp /data/local/tmp/$xml_file $xml_path$xml_name'"
        fi
    else
        echo "[xml] Skipping $i due to connection error."
        continue
      fi
    done
}

pogo_install () {
    # Loop through each device
    for i in "${devices[@]}"; do
        if connect_device "$i" "$port"; then
            echo "[pogo] checking for installed package on device $i"

            # check if the package exists
            if adb -s $i shell "su -c 'pm list packages | grep -q \"$pogo_package\"'"; then
                echo "[pogo] app not installed, preparing to install"
            else
                # get installed version
                installed_version=$(adb -s $i shell dumpsys package $pogo_package | grep versionName | cut -d "=" -f 2 | tr -d '\r')
                echo "[pogo] installed version is '$installed_version'"

                # check if the installed version is outdated
                if [[ "$(printf '%s\n' "$pogo_version" "$installed_version" | sort -V | head -n1)" != "$installed_version" ]]; then
                    echo "[pogo] installed version is outdated, preparing to update"
                    echo "[pogo] killing app if it exists and uninstalling"
                    adb -s $i shell "su -c 'am force-stop $pogo_package && killall $pogo_package'"
                    adb -s $i uninstall $pogo_package
                else
                    echo "[pogo] already up-to-date, skipping install"
                    continue  # Skip to the next device
                fi
            fi

            # Define APK based on architecture type
            apk_to_install="${apk_64}"  # Default to 64-bit
            if [[ "$arch_type" == "32" ]]; then
                apk_to_install="${apk_32}"
            elif [[ "$arch_type" == "mixed" ]]; then
                device_arch=$(adb -s $i shell getprop ro.product.cpu.abi | tr -d '\r')
                if [[ "$device_arch" == *"arm64"* ]]; then
                    apk_to_install="${apk_64}"
                elif [[ "$device_arch" == *"armeabi"* ]]; then
                    apk_to_install="${apk_32}"
                fi
            fi

            # Install the selected APK
            if [[ -n "$apk_to_install" ]]; then
                echo "[pogo] Installing $apk_to_install on $i"
                timeout 10m adb -s $i install -r "$apk_to_install"
            else
                echo "[pogo] No compatible apk found for $i"
            fi
        else
            echo "[pogo] skipping $i due to connection error."
            continue
        fi
    done
}


free_space() {
    # Loop through each device
    for i in "${devices[@]}"; do
      if connect_device "$i" "$port"; then
          echo "[storage] trimming cache on device $i..."
          timeout 10m adb -s $i shell "su -c pm trim-caches 512G"
          echo "[storage] deleting install fails temporary files..."
          adb -s $i shell "su -c rm -rf /data/app/vmdl*.tmp"

          echo "[storage] deleting magisk and integrity zip files..."
          # Removing ZIP files with case-insensitive matching
          patterns=("Play*.zip" "Magi*.zip" "play*.zip" "magi*.zip")
          for pattern in "${patterns[@]}"; do
              adb -s $i shell "su -c find /sdcard/Download /data/local/tmp -type f -iname '$pattern' -exec rm -rf {} +"
          done

          echo "[storage] clear play and chrome, and uninstall chrome updates"
          timeout 10m adb -s $i shell "su -c 'pm clear com.google.android.gms'"
          timeout 10m adb -s $i shell "su -c 'pm clear com.android.chrome'"
          timeout 10m adb -s $i shell "pm uninstall com.android.chrome"
          adb -s $i shell "su -c 'df -h /data/'"
          echo "[storage] cleanup complete on device $i. reboot recommended."
          # Perform reboot if needed
          if [[ "$reboot_cleanup" == "true" ]]; then
              echo "[reboot] Rebooting device $i..."
              adb -s $i reboot
              echo "[reboot] sleepign for 180s..."
              sleep 180  # Wait for the device to reboot
          fi
      else
          echo "[storage] skipping device $i due to connection error."
          continue
      fi
    done
}

cosmog_update() {
    cosmog_atv_script || { log "[error] transferring device setup script"; exit 1; }
    cosmog_install || { log "[error] installing cosmog"; exit 1; }
    cosmog_root_policy || { log "[error] inserting cosmog root policy"; exit 1; }
    cosmog_magisk_denylist || { log "[error] setting up denylist"; exit 1; }
    joltik || { log "[error] fetching lib with joltik"; exit 1; }
    cosmog_lib || { log "[error] installing lib"; exit 1; }
    opengl_warning || { log "[error] installing pogo"; exit 1; }
    cosmog_start || { log "[error] starting cosmog"; exit 1; }
}

pogo_clean_install() {
    free_space || { log "[error] cleaning space"; exit 1; }
    pogo_install || { log "[error] installing pogo"; exit 1; }
    opengl_warning || { log "[error] installing pogo"; exit 1; }
    cosmog_atv_script || { log "[error] transferring device setup script"; exit 1; }
    cosmog_do_settings || { log "[error] performing global config on device"; exit 1; }
    cosmog_install || { log "[error] installing cosmog"; exit 1; }
    cosmog_root_policy || { log "[error] inserting cosmog root policy"; exit 1; }
    cosmog_magisk_denylist || { log "[error] setting up denylist"; exit 1; }
    joltik || { log "[error] fetching lib with joltik"; exit 1; }
    cosmog_lib || { log "[error] installing lib"; exit 1; }
    cosmog_start || { log "[error] starting cosmog"; exit 1; }
}

exec >>"$logfile" 2>&1

# If no arguments are provided, run all functions
if [ $# -eq 0 ]; then
    main() {
        cosmog_atv_script || { log "[error] transferring device setup script"; exit 1; }
        cosmog_config || { log "[error] generating and transferring cosmog config json"; exit 1; }
        cosmog_do_settings || { log "[error] performing global config on device"; exit 1; }
        cosmog_install || { log "[error] installing cosmog"; exit 1; }
        cosmog_root_policy || { log "[error] inserting cosmog root policy"; exit 1; }
        cosmog_magisk_denylist || { log "[error] setting up denylist"; exit 1; }
        joltik || { log "[error] fetching lib with joltik"; exit 1; }
        cosmog_lib || { log "[error] installing lib"; exit 1; }
        pogo_install || { log "[error] installing pogo"; exit 1; }
        opengl_warning || { log "[error] installing opengl warning bypass"; exit 1; }
        cosmog_start || { log "[error] starting cosmog"; exit 1; }
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
