#!/bin/bash
# you need to have nmap installed
# sudo apt install nmap -y (should come preinstalled in most *nix distributions)

# sets the output file name
# leave it as devices.txt for atv_host.sh to read
OUTPUT_FILE="devices.txt"

# verify subnet argument(s) is provided
if [ $# -eq 0 ]; then
    echo "[script] error no subnets provided"
    echo "[script] usage: ./nmap.adb.sh 192.168.1.0/24 172.16.1.0/24 10.0.0.0/24 etc..."
    echo "[script] usage: ./nmap.adb.sh 192.168.1.0-255"
    exit 1
fi

# initializes or clears devices.txt and error.log
: > $OUTPUT_FILE

# scan the provided argument(s)
for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
        # generate ip range
        IFS='-' read -r start end <<< "$arg"
        IFS='.' read -r base1 base2 base3 start4 <<< "$start"
        IFS='.' read -r end4 <<< "$end"
        for ((ip=$start4; ip<=$end4; ip++)); do
            echo "$base1.$base2.$base3.$ip" >> $OUTPUT_FILE
        done
        range_count=$((end4 - start4 + 1))
        total_count=$((total_count + range_count))
        echo "[generator] ip range $start to $end added to $OUTPUT_FILE."
    else
        echo "[nmap] scanning network $arg for devices..."
        current_count=$(nmap -p 5555 --open $arg -oG - | awk '/Up$/{print $2}' | tee -a $OUTPUT_FILE | wc -l)
        nmap -p 5555 --open $arg -oG - | awk '/Up$/{print $2}' >> $OUTPUT_FILE
        total_count=$((total_count + current_count))
        echo "[nmap] found a total of $total_count active devices"
    fi
done

echo "[script] complete, check $OUTPUT_FILE"
