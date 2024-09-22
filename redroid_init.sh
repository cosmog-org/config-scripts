#!/bin/bash

# Config Variables
managePackages=true
manageSetup=true
manageDockerCompose=true
managePm2=true
manageRedroid=true

# Update and install required packages
if $managePackages ; then
    apt update -y
    apt upgrade -y
    apt install docker.io docker-compose npm adb git python3 dos2unix -y
    npm install pm2 -g

# Set up environment for redroid
    apt install linux-modules-extra-`uname -r` -y
    modprobe binder_linux devices="binder,hwbinder,vndbinder"
fi

# Let's get some info
if $manageSetup ; then
    read -p "[Required] Cosmog Auth Token: " cosmogToken
    if [ -z $cosmogToken ] ; then
        echo "Cosmog Token cannot be empty"
        exit 1
    fi
    read -p "[Required] Rotom Worker Endpoint (Port 7070): " rotomWorker
    if [ -z $rotomWorker ] ; then
        echo "Worker Endpoint cannot be empty"
        exit 1
    fi
    
    read -p "[Required] Rotom Device Endpoint (Port 7070/control): " rotomDevice
    if [ -z $rotomDevice ] ; then
        echo "Device Endpoint cannot be empty"
        exit 1
    fi

    read -p "[Required] Rotom API Endpoint (Port 7072): " rotomApi
    if [ -z $rotomApi ] ; then
	echo "API Endpoint cannot be empty"
	exit 1
    fi

    read -p "[Optional] Rotom Basic Auth Username (''): " rotomUser
    rotomUser=${rotomUser:-''}

    read -p "[Optional] Rotom Basic Auth Password (''): " rotomPass
    rotomPass=${rotomPass:-''}

    read -p "[Optional] Rotom Secret? (''): " rotomSecret
    rotomSecret=${rotomSecret:-''}
    
    read -p "[Optional] Device Basename? (Virtual): " deviceBase
    deviceBase=${deviceBase:-Virtual}

    read -p "[Optional] Starting Increment? (1): " deviceNumber
    deviceNumber=${deviceNumber:-1}

    read -p "[Optional] Public IP? (127.0.0.1): " publicIp
    publicIp=${publicIp:-127.0.0.1}

    read -p "[Optional] Worker Count? (15): " cosmogWorkers
    cosmogWorkers=${cosmogWorkers:-15}
    
    read -p "[Optional] How many instances? (3): " instanceCount
    instanceCount=${instanceCount:-3}

    read -p "[Optional] Starting Port? (5555): " startingPort
    startingPort=${startingPort:-5555}

    read -p "[Optional] PoGo Version? (0.307.1): " version
    version=${version:-0.307.1}

    # Now the setup
    port=$startingPort
    cd ~/
    mkdir -p cosmog/configs
    cd cosmog
    wget 'https://meow.sylvie.fyi/static/cosmog.apk' -O cosmog.apk
    git clone https://github.com/sy1vi3/joltik.git
    cd joltik
    python3 joltik.py --version "$version"
    cp arm64-v8a/libNianticLabsPlugin.so ../
    cd ../
    git clone https://github.com/sy1vi3/houndour.git
    echo "" > houndour/startup.sh
    echo "#!/bin/bash

sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"

sudo docker-compose -f ~/cosmog/docker-compose.yml down
sudo docker-compose -f ~/cosmog/docker-compose.yml up -d" >> houndour/startup.sh
    echo "{
	\"devices\":{" > houndour/houndour.json
    echo "services:" >> docker-compose.yml
    for i in `seq $instanceCount` ; do
        echo "    redroid${i}:
        privileged: true
        volumes:
            - ./data${i}:/data
        ports:
            - 127.0.0.1:${port}:5555
        command:
            - androidboot.redroid_gpu_mode=guest
            - androidboot.use_memfd=true
        container_name: redroid${i}
        image: 'abing7k/redroid:a11_magisk_arm'
        restart: always" >> docker-compose.yml

        echo "{
  \"device_id\": \"${deviceBase}${deviceNumber}\",
  \"rotom_worker_endpoint\": \"${rotomWorker}\",
  \"rotom_device_endpoint\": \"${rotomDevice}\",
  \"use_local_safetynet\": false,
  \"public_ip\": \"${publicIp}\",
  \"workers\": ${cosmogWorkers},
  \"token\": \"${cosmogToken}\",
  \"rotom_secret\": \"${rotomSecret}\",
  \"injection_delay_ms\": 5000,
  \"pogo_heartbeat_timeout_ms\": 5000,
  \"concurrent_login_override\": 6,
  \"worker_spawn_delay_override\": 3500
}" >> configs/${i}.json

        echo "#!/bin/bash

adb connect localhost:${port}
adb -s localhost:${port} push ./configs/${i}.json /data/local/tmp/cosmog.json
adb -s localhost:${port} shell am start -n com.nianticlabs.pokemongo.ares/com.nianticlabs.pokemongo.ares.MainActivity

sleep 10
" >> send_configs.sh

        echo "localhost:${port}" >> vm.txt
	echo "		\"${deviceBase}${deviceNumber}\": {
			\"dockerName\": \"redroid${i}\"
		}," >> houndour/houndour.json

        port=$(( $port + 1 ))
        deviceNumber=$(( $deviceNumber + 1 ))
    done
    chmod +x send_configs.sh
    sed -i '$ s/},/}/' houndour/houndour.json
    echo "	},
	\"check_interval\": 60,
	\"timeout_limit\": 5,
	\"rotom_url\": \"http://${rotomApi}\",
	\"rotom_user\": \"${rotomUser}\",
	\"rotom_pass\": \"${rotomPass}\",
	\"startup_script_path\": \"./startup.sh\"
}" >> houndour/houndour.json
fi

if $manageDockerCompose ; then
    docker-compose up -d
    if [ ! -d data1 ] ; then
	    echo "Something happened. Trying again"
	    docker-compose down ; docker-compose up -d
    fi
    echo "Docker up"
fi

if $manageRedroid ; then
    # Let's pull in some help
    wget 'https://raw.githubusercontent.com/cosmog-org/config-scripts/main/redroid_device.sh' -O redroid_device.sh
    wget 'https://raw.githubusercontent.com/cosmog-org/config-scripts/main/redroid_host.sh' -O redroid_host.sh 
    chmod +x redroid_device.sh
    chmod +x redroid_host.sh
    dos2unix redroid_device.sh
    dos2unix redroid_host.sh
    # Give the containers some time
    sleep 30
    ./redroid_host.sh
fi

if $managePm2 ; then
    pm2 start ./send_configs.sh --restart-delay 20000
    echo "PM2 Up"
    cd ~/cosmog/houndour
    pm2 start "python3 houndour.py" --name houndour
    cd ~/cosmog
fi
