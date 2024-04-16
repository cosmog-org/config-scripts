# config-scripts
 cosmog configuration scripts

1. **redroid_init.sh**
    - This script is written to take your new server from nothing to running Cosmog.
    - This will pull in both redroid_host.sh and redroid_setup.sh.
    - Config files for redroid_host.sh, Cosmog and Houndour will be auto generated based on answers to questions.
    - **SCRIPT HAS ONLY BEEN TESTED ON UBUNTU SYSTEMS. YMMV**


2. **redroid_host.sh**
    - This script should be run on your redroid host
    - Requirements:
        - redroid_setup.sh
        - vm.txt
          - ip per line:
          - localhost:5555, localhost:5556, localhost:5557, etc
    - redroid containers should already be running before you start

3. **redroid_setup.sh**
    - This script is required by redroid_host.sh
    - This performs all of the necessary steps inside of redroid itself
    - Including setting up magisk and all necessary features

4. **atv_host.sh**
    - This script must be run on a host on the same network as your android device(s)
    - Requirements in the directory:
        - cosmog*.apk
        - atv_device.sh
        - warning.xml (disables opengl warning on opengl devices < 3)
        - devices.txt
          - ip or host per line:
          - 192.168.1.1, 192.168.1.2, etc

5. **atv_device.sh**
    - This script is required by atv_host.sh
    - This performs all of the necessary steps inside of android itself
    - Including setting up magisk features

6. **nmap_adb.sh**
    - This script performs a network search for port 5555
    - It will output the results into devices.txt
    - You can also have it auto generate all IPs specified by a range
    - Argument options:
      - ./nmap_adb.sh 192.168.1.0/24
      - ./nmap_adb.sh 172.16.0.0/24 10.0.1.0/16
      - ./nmap_adb.sh 192.169.1.0-50 (generator)
