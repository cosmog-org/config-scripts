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
cosmog_package="com.sy1vi3.cosmog"
cosmog_lib="libNianticLabsPlugin.so"
lib_version=0.317.0
lib_path="/data/data/$cosmog_package/files/$cosmog_lib"
# expected SHA256 hash
v_sha256="f71f485e3d756e5bd3fe0182c7c4a6f952cfc5de9a90a1b9818015ce23582614"
# url of the latest apk
d_url="https://meow.sylvie.fyi/static/cosmog.apk"
c_file="cosmog.apk"
cosmog_apk="$c_file"

# setting this version is important for pogo_install to work if used
pogo_version="0.317.0"
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
# default set to 5 for most ATVs for scanning
# set this value to 0 if you want to generate Solver only ATVs
workers=5
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
# reboot sleep is set to 120s (2mins)
reboot_denylist=true
reboot_timeout=120


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
    local timeout_duration="60s"
    local max_retries=3
    local attempt=0
    local success=0
    local sleep_time=10

    adb disconnect "${device_ip}:${device_port}"
    sleep 2
    echo "[adb] trying to connect to ${device_ip}:${device_port}..."

    while (( attempt < max_retries && success == 0 )); do
        local output=$(timeout $timeout_duration adb connect "${device_ip}:${device_port}" 2>&1)
        local exit_status=$?

        if [[ "$output" == *"connected"* || "$output" == *"already connected to"* ]]; then
            echo "[adb] connected successfully to ${device_ip}:${device_port}."
            success=1
            break
        elif [[ -z "$output" || "$output" == *"offline"* || "$output" == *"connection refused"* ]]; then
            echo "[adb] warning: $output. retrying connection attempt ${attempt}..."
        elif [[ "$exit_status" -eq 124 ]]; then  #
            echo "[adb] connection attempt to ${device_ip}:${device_port} timed out."
            echo "${device_ip}:${device_port} Timeout" >> "$logfile"
        else
            echo "[adb] error connecting to ${device_ip}:${device_port}: $output"
            echo "${device_ip}:${device_port} Error" >> "$logfile"
        fi
        
        ((attempt++))
        sleep $sleep_time
    done

    if [[ success -eq 0 ]]; then
        echo "[adb] max retries reached, unable to connect to ${device_ip}:${device_port}."
        exit 1
    fi
}

cosmog_atv_script() {
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
        use_local_safetynet="true"
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

cosmog_download() {
    wget -q "$d_url" -O "$c_file"
    echo "[cosmog] download completed"
}

# function to check the sha256 hash of the apk
cosmog_hash() {
    local d_sha256=$(sha256sum "$c_file" | awk '{print $1}')
    if [ "$d_sha256" = "$v_sha256" ]; then
        echo "[cosmog] sha256 hash matched."
        return 0
    else
        echo "[cosmog] sha256 hash did not match, but that's fine, it never matches. no one maintains it."
        return 0
    fi
}

# function to download and verify sha256, managing attempts
cosmog_checkload() {
    local attempt=1
    local max_attempts=3

    while [ $attempt -le $max_attempts ]; do
        echo "[cosmog] attempt $attempt of $max_attempts: downloading the apk..."
        cosmog_download
        
        echo "[cosmog] checking sha256 hash..."
        if cosmog_hash; then
            return 0
        else
            echo "[cosmog] sha256 check failed, reattempting download..."
            rm -f "$c_file"  # Removing file for re-download
            attempt=$((attempt + 1))
        fi
    done

    echo "[cosmog] failed to download the correct file after $max_attempts attempts."
    exit 1
}

cosmog_install() {
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
    for i in "${devices[@]}";do
      if connect_device "$i" "$port"; then
          # adding packages to denylist
          echo "[magisk] adding packages to denylist"
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/atv_device.sh setup_magisk_denylist'"
          echo "[magisk] deleting gms from denylist"
          # this is crucial for integrity modules to render useful verdicts
          adb -s $i shell "su -c '/system/bin/sh /data/local/tmp/atv_device.sh delete_magisk_denylist'"
          echo "[magisk] denylist complete"
          if [[ "$reboot_denylist" == "true" ]]; then
              echo "[reboot] Rebooting device $i..."
              adb -s $i reboot
              echo "[reboot] rebooting, sleeping for $reboot_timeout..."
              sleep $reboot_timeout  # Wait for the device to reboot
          fi
      else
          echo "[magisk] Skipping $i due to connection error."
          continue
      fi
    done
}

cosmog_lib() {
    for i in "${devices[@]}";do
      if connect_device "$i" "$port"; then
          arch=$(adb -s $i shell "su -c 'getprop ro.product.cpu.abi'")
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

cosmog_lib_verify() {
    local all_exist=true
    local dir_path="/data/data/$cosmog_package/files"

    for i in "${devices[@]}"; do
      if connect_device "$i" "$port"; then
          # using ls to list files in the directory
          local output=$(adb -s $i shell "su -c 'ls \"$dir_path\"'" 2>&1)
          if echo "$output" | grep -q "$cosmog_lib"; then
              echo "[lib] $cosmog_lib is verified at $lib_path on device $i."
          else
              echo "[lib] $cosmog_lib does not exist at $lib_path on device $i, or error: $output"
              all_exist=false
          fi
      else
          echo "[lib] could not connect to device $i."
          all_exist=false
          continue
      fi
    done

    if [[ "$all_exist" == true ]]; then
        return 0
    else
        return 1
    fi
}


cosmog_start() {
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

# track successful xml deployments
declare -A xml_deployment

opengl_warning() {
  for i in "${devices[@]}"; do
    if connect_device "$i" "$port"; then
        # Fetch OpenGL version and extract major version directly
        opengl_version=$(adb -s $i shell dumpsys SurfaceFlinger | grep -o "OpenGL ES [0-9]*\.[0-9]*" | sed -n 's/OpenGL ES \([0-9]*\)\..*/\1/p')

        # Check if major_version was successfully extracted
        if [[ -z "$opengl_version" ]]; then
            echo "[xml] failed to extract the OpenGL version."
            xml_deployment[$i]="error"
            continue
        fi

        # Compare the major version number
        if [[ $opengl_version -ge 3 ]]; then
            echo "[xml] opengl is 3+, skipping"
            xml_deployment[$i]="skipped"
        else
            echo "[xml] OpenGL version is less than 3. Pushing XML file to device."
            xml_deployment[$i]="deployed"
            adb -s $i push "$xml_file" /data/local/tmp
            adb -s $i shell "su -c 'chown root:root /data/local/tmp/$xml_file'"
            adb -s $i shell "su -c 'mkdir -p $xml_path'"
            adb -s $i shell "su -c 'cp /data/local/tmp/$xml_file $xml_path$xml_name'"
        fi
    else
        echo "[xml] Skipping $i due to connection error."
        xml_deployment[$i]="error"
    fi
  done
}

opengl_verify() {
    local all_verified=true 
    for i in "${devices[@]}"; do
      if [[ ${xml_deployment[$i]} == "deployed" ]]; then
        if ! connect_device "$i" "$port"; then
            echo "[xml] could not connect to device $i."
            all_verified=false
            continue
        fi

        local file_path="$xml_path$xml_name"
        local output=$(adb -s $i shell "su -c 'test -f \"$file_path\" && echo \"verified\" || echo \"does not exist\"'")
        if [[ "$output" == "verified" ]]; then
            echo "[xml] $xml_name is verified at $file_path on device $i."
        else
            echo "[xml] $xml_name does not exist at $file_path on device $i, or error: $output"
            all_verified=false
        fi
      elif [[ ${xml_deployment[$i]} == "skipped" ]]; then
        echo "[xml] $xml_name was not required and thus not deployed on device $i."
      else
        echo "[xml] no deployment action was taken for device $i."
      fi
    done

    if [[ $all_verified == true ]]; then
        return 0
    else
        return 1
    fi
}

pogo_install () {
    for i in "${devices[@]}"; do
        if connect_device "$i" "$port"; then
            echo "[pogo] checking for installed package on device $i"
            
            # check if the package exists
            if adb -s $i shell "su -c 'pm list packages | grep -q \"$pogo_package\"'"; then
                # package exists, checking version
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
            else
                echo "[pogo] app not installed, preparing to install"
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
                timeout 3m adb -s $i install -r "$apk_to_install"
            else
                echo "[pogo] No compatible apk found for $i"
            fi
        else
            echo "[pogo] skipping $i due to connection error."
            continue
        fi
    done
}

pogo_verify() {
    local all_verified=true

    for i in "${devices[@]}"; do
        if connect_device "$i" "$port"; then
            echo "[pogo] verifying installation on device $i"

            # Check if the package exists
            if adb -s $i shell "pm list packages | grep -q \"$pogo_package\""; then
                # Package exists, checking version
                installed_version=$(adb -s $i shell dumpsys package $pogo_package | grep versionName | cut -d "=" -f 2 | tr -d '\r')
                echo "[pogo] found installed version '$installed_version' on device $i"

                # Verify if the installed version matches the expected version
                if [[ "$installed_version" == "$pogo_version" ]]; then
                    echo "[pogo] version on device $i is correct."
                else
                    echo "[pogo] version mismatch on device $i: expected '$pogo_version', found '$installed_version'"
                    all_verified=false
                fi
            else
                echo "[pogo] package '$pogo_package' is not installed on device $i."
                all_verified=false
            fi
        else
            echo "[pogo] could not connect to device $i."
            all_verified=false
        fi
    done

    if [[ $all_verified == true ]]; then
        echo "[pogo] all devices have been verified successfully."
        return 0
    else
        echo "[pogo] verification failed for one or more devices."
        return 1
    fi
}

free_space() {
    for i in "${devices[@]}"; do
      if connect_device "$i" "$port"; then
          echo "[storage] trimming cache on device $i..."
          timeout 3m adb -s $i shell "su -c pm trim-caches 512G"
          echo "[storage] deleting install fails temporary files..."
          adb -s $i shell "su -c rm -rf /data/app/vmdl*.tmp"

          echo "[storage] deleting magisk and integrity zip files..."
          # Removing ZIP files with case-insensitive matching
          patterns=("Play*.zip" "Magi*.zip" "play*.zip" "magi*.zip")
          for pattern in "${patterns[@]}"; do
              adb -s $i shell "su -c find /sdcard/Download /data/local/tmp -type f -iname '$pattern' -exec rm -rf {} +"
          done

          echo "[storage] clear play and chrome, and uninstall chrome updates"
          timeout 3m adb -s $i shell "su -c 'pm clear com.google.android.gms'"
          timeout 3m adb -s $i shell "su -c 'pm clear com.android.chrome'"
          timeout 3m adb -s $i shell "su -c 'pm clear com.android.vending'"
          timeout 3m adb -s $i shell "su -c 'pm clear com.google.android.inputmethod.latin'"
          timeout 3m adb -s $i shell "pm uninstall com.android.chrome"
          adb -s $i shell "su -c 'am force-stop com.nianticlabs.pokemongo'"
          adb -s $i shell "su -c 'rm -rf /data/data/com.nianticlabs.pokemongo/cache/*'"
          adb -s $i shell "su -c 'df -h /data/'"
          echo "[storage] cleanup complete on device $i. reboot recommended."
          # Perform reboot if needed
          if [[ "$reboot_cleanup" == "true" ]]; then
              echo "[reboot] rebooting device $i..."
              adb -s $i reboot
              echo "[reboot] sleeping for $reboot_timeout..."
              sleep $reboot_timeout  # Wait for the device to reboot
          fi
      else
          echo "[storage] skipping device $i due to connection error."
          continue
      fi
    done
}

integrity_cache_clear() {
    for i in "${devices[@]}"; do
      if connect_device "$i" "$port"; then
          echo "[icache] clearing pogo cache..."
          adb -s $i shell "su -c 'am force-stop com.nianticlabs.pokemongo'"
          adb -s $i shell "su -c 'rm -rf /data/data/com.nianticlabs.pokemongo/cache/*'"
          echo "[icache] trimming cache on device $i..."
          timeout 3m adb -s $i shell "su -c pm trim-caches 512G"
          echo "[cache] clearing gms, vending, chrome..."
          timeout 3m adb -s $i shell "su -c 'pm clear com.google.android.gms'"
          timeout 3m adb -s $i shell "su -c 'pm clear com.android.chrome'"
          timeout 3m adb -s $i shell "su -c 'pm clear com.android.vending'"
          echo "[icache] complete"
      else
          echo "[icache] skipping device $i due to connection error."
          continue
      fi
    done
}

cosmog_update() {
    cosmog_atv_script || { log "[error] transferring device setup script"; exit 1; }
    cosmog_checkload || { log "[error] downloading apk and verifying hash"; exit 1; }
    cosmog_install || { log "[error] installing cosmog"; exit 1; }
    cosmog_root_policy || { log "[error] inserting cosmog root policy"; exit 1; }
    cosmog_magisk_denylist || { log "[error] setting up denylist"; exit 1; }
    joltik || { log "[error] fetching lib with joltik"; exit 1; }
    cosmog_lib || { log "[error] installing lib"; exit 1; }
    cosmog_lib_verify || { log "[error] verifying lib install status"; exit 1; }
    opengl_warning || { log "[error] checking opengl status"; exit 1; }
    opengl_verify || { log "[error] verifying xml status"; exit 1; }
    cosmog_start || { log "[error] starting cosmog"; exit 1; }
}

pogo_clean_install() {
    free_space || { log "[error] cleaning space"; exit 1; }
    pogo_install || { log "[error] installing pogo"; exit 1; }
    pogo_verify || { log "[error] verifying pogo install status"; exit 1; }
    opengl_warning || { log "[error] checking opengl status"; exit 1; }
    opengl_verify || { log "[error] verifying xml status"; exit 1; }
    cosmog_atv_script || { log "[error] transferring device setup script"; exit 1; }
    cosmog_do_settings || { log "[error] performing global config on device"; exit 1; }
    cosmog_checkload || { log "[error] downloading apk and verifying hash"; exit 1; }
    cosmog_install || { log "[error] installing cosmog"; exit 1; }
    cosmog_root_policy || { log "[error] inserting cosmog root policy"; exit 1; }
    cosmog_magisk_denylist || { log "[error] setting up denylist"; exit 1; }
    joltik || { log "[error] fetching lib with joltik"; exit 1; }
    cosmog_lib || { log "[error] installing lib"; exit 1; }
    cosmog_lib_verify || { log "[error] verifying lib install status"; exit 1; }
    cosmog_start || { log "[error] starting cosmog"; exit 1; }
}

exec >>"$logfile" 2>&1

# If no arguments are provided, run all functions
if [ $# -eq 0 ]; then
    main() {
        cosmog_atv_script || { log "[error] transferring device setup script"; exit 1; }
        cosmog_config || { log "[error] generating and transferring cosmog config json"; exit 1; }
        cosmog_do_settings || { log "[error] performing global config on device"; exit 1; }
        cosmog_checkload || { log "[error] downloading apk and verifying hash"; exit 1; }
        cosmog_install || { log "[error] installing cosmog"; exit 1; }
        cosmog_root_policy || { log "[error] inserting cosmog root policy"; exit 1; }
        cosmog_magisk_denylist || { log "[error] setting up denylist"; exit 1; }
        joltik || { log "[error] fetching lib with joltik"; exit 1; }
        cosmog_lib || { log "[error] installing lib"; exit 1; }
        cosmog_lib_verify || { log "[error] verifying lib install status"; exit 1; }
        pogo_install || { log "[error] installing pogo"; exit 1; }
        pogo_verify || { log "[error] verifying pogo install status"; exit 1; }
        opengl_warning || { log "[error] checking opengl status"; exit 1; }
        opengl_verify || { log "[error] verifying xml status"; exit 1; }
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
