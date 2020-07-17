#!/bin/zsh

# Building VoltDB on Azure IaaS

# Azure Ultra Disk
# https://docs.microsoft.com/en-us/azure/virtual-machines/windows/disks-types#ultra-disk

setopt SH_WORD_SPLIT

# You should edit at least following 2 lines
readonly AZURE_ACCT="rifujita" 
readonly RES_LOC="japaneast"

# You don't need to edit, but up to you
readonly PRJ_NAME="volt"
readonly RES_GRP="${AZURE_ACCT}${PRJ_NAME}rg"

readonly VOLTDB_BUILD=0
readonly VOLTDB_NAME="voltdb-developer"
readonly VOLTDB_VER="9.3.1"
readonly VOLTDB_FILE="${VOLTDB_NAME}-${VOLTDB_VER}.tar.gz"
readonly VOLTDB_URL="https://www.voltdb.com/product/get-voltdb/developer-edition/"
readonly VOLTDB_GIT_URL="https://github.com/VoltDB/voltdb.git"
readonly VOLTDB_DIR="/opt/voltdb"
readonly VOLTDB_HOME="${VOLTDB_DIR}/${VOLTDB_NAME}-current"
readonly VOLT_SERVER_PREFIX="voltsvr"

# VNET parameters
# You don't need to edit, but up to you
readonly VNET_NAME="${AZURE_ACCT}${PRJ_NAME}vnet"
readonly VNET_SUBNET_NAME="${VNET_NAME}subnet"

# VM parameters
readonly VM_SIZE="Standard_D16s_v3"
readonly VM_NAME="${AZURE_ACCT}${PRJ_NAME}"
readonly VM_OS_DISK_SIZE="256" #256GB
readonly VM_DATA_DISK_NAME="${VM_NAME}datadisk"
readonly VM_DATA_DISK_SIZE="512" #512GB
# VM_COUNT must be over 2 in production env.
readonly VM_COUNT=2

# The file to pass parameters to remote host
readonly CREDENTIALS="credentials.inc"

# 1. Check if voltdb file exists
check_voltdb_file () {
    if [ $VOLTDB_BUILD -eq 0 ]; then
        if [ ! -e ${VOLTDB_FILE} ]; then
            echo -e "\e[31mCould not find the VoltDB archived file, ${VOLTDB_FILE}.\e[m"
            echo "Please download from ${VOLTDB_URL} and locate it in the same directory of this script."
            exit
        fi
    else #Unimplemented
        local uname=$(uname)
        if [ "$uname" = "Darwin" ]; then
            xcode-select --install
            brew cask install java8
            brew install ant cmake ccache git
        elif [ "$uname" = "Linux" ]; then
            sudo apt-get -y install ant build-essential ant-optional default-jdk python cmake \
                valgrind ntp ccache git-arch git-completion git-core git-svn git-doc \
                git-email python-httplib2 python-setuptools python-dev apt-show-versions
        fi
        git clone ${VOLTDB_GIT_URL}
        cd voltdb
        ant clean
    fi
}

# 2. Check Ultra Disk
check_ultra_disk () {
    echo -e "\e[31mChecking if Ultra Disk can be used...\e[m"
    local "st=$(date '+%s')"
    local "vm_zones=$(az vm list-skus -r virtualMachines  -l $RES_LOC --query "[?name=='$VM_SIZE'].locationInfo[0].zoneDetails[0].Name" -o tsv)"
    if [ -z "$vm_zones" ]; then
        echo "The VM size '$VM_SIZE' is not supported for Ultra Disk in the region '$RES_LOC'."
        exit
    fi
    VM_ZONE_ULTRA_DISK_AVAILABLE=${vm_zones:0:1} #choose first one
    show_elapsed_time $st
}

# 3. Create resource group
create_group () {
    # Checking if Resource Group exists
    echo -e "\e[31mCreating Resource Group...\e[m"
    local "st=$(date '+%s')"
    local "res=$(az group show -g $RES_GRP -o tsv --query "properties.provisioningState" 2>&1 | grep -o 'could not be found')"
    if [ "${res}" != "could not be found" ]; then
        echo "Resource Group, ${RES_GRP} has already existed."
        exit
    fi

    # Create Resource Group
    res=$(az group create -l $RES_LOC -g $RES_GRP -o tsv --query "properties.provisioningState")
    if [ "$res" != "Succeeded" ]; then
        az group delete --yes --no-wait -g $RES_GRP
        echo "Failed to create resource group."
        exit
    fi
    show_elapsed_time $st
}

# 4. Create Ultra Disks
create_ultra_disks () {
    echo -e "\e[31mCreating Ultra Disks...\e[m"
    local iops=$(expr ${VM_DATA_DISK_SIZE} \* 300)
    for num in $(seq $VM_COUNT); do
        local "st=$(date '+%s')"
        res=$(az disk create -n ${VM_DATA_DISK_NAME}${num} -g ${RES_GRP} --size-gb ${VM_DATA_DISK_SIZE} -l ${RES_LOC} --zone ${VM_ZONE_ULTRA_DISK_AVAILABLE} --sku UltraSSD_LRS --disk-iops-read-write ${iops} --disk-mbps-read-write 2000)
        show_elapsed_time $st
    done
}

# 5. Create VNET
create_vnet () {
    echo -e "\e[31mCreating VNET...\e[m"
    local "st=$(date '+%s')"
    local "res=$(az network vnet create -g $RES_GRP -n $VNET_NAME --subnet-name $VNET_SUBNET_NAME)"
    res=$(az network vnet subnet update -g $RES_GRP --vnet-name $VNET_NAME -n $VNET_SUBNET_NAME)
    show_elapsed_time $st
}

# 6. Create VM
create_vm () {
    for num in $(seq $VM_COUNT); do
        local "last_octet=$(expr $num + 3)"
        echo -e "\e[31mCreating VoltDB Server $num...\e[m"
        local "st=$(date '+%s')"
        res=$(az vm create --image Canonical:UbuntuServer:18.04-LTS:latest --size ${VM_SIZE} -g ${RES_GRP} -n ${VM_NAME}${num} \
            --admin-username ${AZURE_ACCT} \
            --generate-ssh-keys \
            --ultra-ssd-enabled true \
            --storage-sku os=Premium_LRS \
            --os-disk-size-gb $VM_OS_DISK_SIZE \
            --vnet-name $VNET_NAME \
            --subnet $VNET_SUBNET_NAME \
            -z $VM_ZONE_ULTRA_DISK_AVAILABLE \
            --public-ip-address-dns-name ${VM_NAME}${num} \
            --private-ip-address 10.0.0.$last_octet \
            --no-wait)
        show_elapsed_time $st
    done
}

# 7. Attach Ultra Disk
attach_disks () {
    echo -e "\e[31mAttaching Disks to VM...\e[m"
    local "st=$(date '+%s')"
    for num in $(seq $VM_COUNT); do
        res=$(az vm disk attach -g ${RES_GRP} --vm-name ${VM_NAME}${num} --name ${VM_DATA_DISK_NAME}${num})
    done
    show_elapsed_time $st
}

# 8. Wait for VM
wait_for_vm () {
    echo -e "\e[31mWaiting for VM booting up...\e[m"
    local "st=$(date '+%s')"
    # Wait for VM can be connected via ssh
    fqdn="${VM_NAME}1.${RES_LOC}.cloudapp.azure.com"
    echo -e "Connecting $fqdn..."
    ssh-keygen -R $fqdn 2>&1
    trying=0
    sshres=$(ssh -o "StrictHostKeyChecking no " "${AZURE_ACCT}@$fqdn" 'uname')
    while [ "$sshres" != "Linux" ]; do
        trying=$(expr $trying + 1)
        echo "Challenge: $trying"
        if [ $trying -eq 30 ]; then
            echo "Could not login $fqdn for 5 mins. Please check if 22/tcp is open."
            exit
        fi
        sleep 10
        sshres=$(ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" 'uname')
    done
}

# 9. Install VoltDB
install_voltdb () {
    cat <<- EOS > ${CREDENTIALS}
	export VM_COUNT="$VM_COUNT"
	export VOLTDB_FILE="$VOLTDB_FILE"
	export VOLTDB_NAME="$VOLTDB_NAME"
	export VOLTDB_VER="$VOLTDB_VER"
	export VOLTDB_DIR="$VOLTDB_DIR"
	export VOLTDB_HOME="$VOLTDB_HOME"
	export VOLT_SERVER_PREFIX="$VOLT_SERVER_PREFIX"
	EOS
    for num in $(seq $VM_COUNT); do
        # On Local
        echo -e "\e[31mConfiguring VoltDB server $num...\e[m"
        local "st=$(date '+%s')"
        fqdn="${VM_NAME}${num}.${RES_LOC}.cloudapp.azure.com"

        # Copy credentials
        scp -o "StrictHostKeyChecking no" ${CREDENTIALS} ${AZURE_ACCT}@"$fqdn:~/"
        # Copy VoltDB file
        scp -o "StrictHostKeyChecking no" ${VOLTDB_FILE} ${AZURE_ACCT}@"$fqdn:~/"
        # SSH Login and execute commands
        ssh -o "StrictHostKeyChecking no" "${AZURE_ACCT}@$fqdn" <<-'EOF'

        # On Remote
        source credentials.inc
        ssh-keygen -t rsa -f ~/.ssh/id_rsa -N "" > /dev/null

        # Find Ultra or Premium SSD
        for lt in $(ls /dev/sd[a-z] | sed 's/\/dev\/sd//'); do
            disk_check=$(sudo parted /dev/sd$lt --script 'print' 2>&1 | grep 'Partition Table: unknown')
            if [ "$disk_check" != "" ]; then
                target_disk="/dev/sd$lt"
            fi
        done

        # Make a mount point for data disk
        sudo sh -c "
            parted ${target_disk} --script 'mklabel gpt mkpart primary 0% 100%';
            sleep 2;
            mkfs.xfs -f "${target_disk}1" > /dev/null;
            sleep 5;
            echo \"${target_disk}1 $VOLTDB_DIR xfs defaults,discard 0 0\" >> /etc/fstab;
            mkdir -p $VOLTDB_DIR;
            mount $VOLTDB_DIR;
            "

        # Add voltdb user
        sudo sh -c "
            useradd -d $VOLTDB_DIR -s $(which nologin) voltdb
            "

        # 2.2. Installing VoltDB
        # https://docs.voltdb.com/UsingVoltDB/installDist.php
        sudo sh -c "
            tar -zxvf $VOLTDB_FILE -C ${VOLTDB_DIR}
            ln -s ${VOLTDB_DIR}/${VOLTDB_NAME}-${VOLTDB_VER} ${VOLTDB_HOME}
            chown -R voltdb.voltdb ${VOLTDB_DIR}
            "

        # 2.3. Setting Up Your Environment
        # https://docs.voltdb.com/UsingVoltDB/SetUpEnv.php
        # Configure in the script for systemd 

        # 2.2. Install Required Software
        # https://docs.voltdb.com/AdminGuide/adminserversw.php
        sudo sh -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get -y update > /dev/null;
            apt-get -y install openjdk-11-jre > /dev/null
            "

        # 2.3. Configure Memory Management
        # https://docs.voltdb.com/AdminGuide/adminmemmgt.php
        sudo sh -c "cat >> /etc/sysctl.conf" <<- EOS
		vm.swappiness=0
		vm.overcommit_memory=1
		EOS
        sudo sh -c "
            sysctl -w vm.swappiness=0 > /dev/null
            sysctl -w vm.overcommit_memory=1 > /dev/null
            "
        total_mem=$(free --giga | grep 'Mem:' | awk '{print $2}')
        if [ $total_mem -ge 64 ]; then
            sudo sh -c "
                echo "vm.max_map_count=1048576" >> /etc/sysctl.conf
                sysctl -w vm.max_map_count=1048576 > /dev/null
                "
        fi
        sudo sh -c "cat > /etc/rc.local" <<- EOS
		#!/bin/bash
		echo never > /sys/kernel/mm/transparent_hugepage/enabled
		echo never > /sys/kernel/mm/transparent_hugepage/defrag
		EOS
        sudo sh -c "
            chmod u+x /etc/rc.local
            echo never > /sys/kernel/mm/transparent_hugepage/enabled
            echo never > /sys/kernel/mm/transparent_hugepage/defrag
            "

        # 2.4. Turn off TCP Segmentation
        # https://docs.voltdb.com/AdminGuide/adminservertcpseg.php
        sudo sh -c "cat >> /etc/rc.local" <<- EOS
		ethtool -K eth0 tso off
		ethtool -K eth0 gro off
		EOS
        sudo sh -c "
            ethtool -K eth0 tso off
            ethtool -K eth0 gro off
            "

        # 2.5. Configure Time Services
        # https://docs.voltdb.com/AdminGuide/adminserverntp.php
        # Not needed on Azure
        # 2.6. Increase Resource Limits
        # https://docs.voltdb.com/AdminGuide/adminserverulimit.php
        # Not needed on Azure

        # 2.7. Configure the Network
        # https://docs.voltdb.com/AdminGuide/adminserverdns.php
        for num in $(seq $VM_COUNT); do
            last_octet=$(expr $num + 3)
            sudo sh -c "cat >> /etc/hosts" <<- EOS
		10.0.0.$last_octet $VOLT_SERVER_PREFIX$num
		EOS
        done

        # 2.8. Assign Network Ports
        # https://docs.voltdb.com/AdminGuide/adminserverports.php
        # Configure in NSG

        # 2.9. Eliminating Server Process Latency
        # https://docs.voltdb.com/AdminGuide/adminserverlatency.php
        # Configure in the script for systemd 

        # 3.1. Configuring the Cluster and Database
        # https://docs.voltdb.com/AdminGuide/StartStopChap.php
        sudo sh -c "cat > ${VOLTDB_DIR}/deployment.xml" <<- EOS
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<deployment>
		    <cluster sitesperhost="$(lscpu | sed -ne "/^CPU(s): */s/^CPU(s): *\([0-9]\)/\1/p")" kfactor="1" schema="ddl"/>
		    <paths>
		        <!-- <voltdbroot path="${VOLTDB_HOME}/voltdbroot"/> -->
		        <snapshots path="snapshots"/>
		        <exportoverflow path="export_overflow"/>
		        <droverflow path="dr_overflow"/>
		        <commandlog path="command_log"/>
		        <commandlogsnapshot path="command_log_snapshot"/>
		        <largequeryswap path="large_query_swap"/>
		    </paths>
		    <partition-detection/>
		    <heartbeat/>
		    <ssl/>
		    <httpd enabled="true">
		        <jsonapi enabled="true"/>
		    </httpd>
		    <snapshot enabled="true"/>
		    <commandlog enabled="false">
		        <frequency/>
		    </commandlog>
		    <systemsettings>
		        <temptables/>
		        <snapshot/>
		        <elastic/>
		        <query/>
		        <procedure/>
		        <resourcemonitor>
		            <memorylimit/>
		        </resourcemonitor>
		    </systemsettings>
		    <security/>
		</deployment>
		EOS

        # 3.2. Initializing the Database Root Directory
        # https://docs.voltdb.com/AdminGuide/OpsInit.php
        # Configure in the script for systemd

        # Create VoltDB script
        voltdb_hosts=""
        for num in $(seq $VM_COUNT); do
            voltdb_hosts=("$voltdb_hosts ${VOLT_SERVER_PREFIX}${num}")
        done
        voltdb_hosts=$(echo $voltdb_hosts | sed 's/\([^ ]*\) \([^ ]*\)/\1,\2/g')
        sudo sh -c "cat > ${VOLTDB_DIR}/voltdb.sh" <<- EOS
		#!/bin/bash
		
		export VOLTDB_DIR="${VOLTDB_DIR}"
		export VOLTDB_HOME="\${VOLTDB_DIR}/${VOLTDB_NAME}-current"
		export PATH="\$PATH:\${VOLTDB_HOME}/bin"
		export VOLTDB_OPTS='-XX:+PerfDisableSharedMem'
		
		ACMD="\$1"
		ARGV="\$@"
		
		cd \${VOLTDB_HOME}
		
		case \$ACMD in
		start)
		    voltdb start -D \${VOLTDB_HOME} -H $voltdb_hosts -c ${VM_COUNT} -B
		    ;;
		stop)
		    voltadmin stop
		    ;;
		init)
		    deployment="\${VOLTDB_DIR}/deployment.xml"
		    if [ ! -e \$deployment ]; then
		        echo "Could not find \$deployment"
		        exit
		    fi
		    voltdb init -D \${VOLTDB_HOME} -C \${deployment} -f
		    ;;
		*)
		esac
		EOS
        sudo chmod 755 ${VOLTDB_DIR}/voltdb.sh

        # Create systemd unit file
        sudo sh -c "cat > /etc/systemd/system/voltdb.service" <<- EOS
		[Unit]
		Description=VoltDB
		Requires=network.target remote-fs.target rc-local.service
		After=network.target remote-fs.target rc-local.service
		
		[Service]
		Type=forking
		User=voltdb
		Group=voltdb
		ExecStart=${VOLTDB_DIR}/voltdb.sh start
		ExecStop=${VOLTDB_DIR}/voltdb.sh stop
		
		[Install]
		WantedBy=multi-user.target
		EOS

        sudo -H -u voltdb ${VOLTDB_DIR}/voltdb.sh init
        sudo sh -c "
            systemctl daemon-reload
            systemctl enable --now voltdb
            "

	EOF
        show_elapsed_time $st
    done
    rm -f ${CREDENTIALS}
}

# 10. Configure Firewall
configure_fw () {
    echo -e "\e[31mConfiguring Firewall...\e[m"
    local "st=$(date '+%s')"
    # Open 3306/tcp of Spider Data nodes
    for num in $(seq $VM_COUNT); do
        local "res=$(az vm open-port --port 3306 -g ${RES_GRP} -n ${VM_NAME}$num)"
        local "nicid=$(az vm show -g ${RES_GRP} -n ${VM_NAME}$num --query 'networkProfile.networkInterfaces[0].id' -o tsv)"
        local "ipid=$(az network nic show -g ${RES_GRP} --ids $nicid --query 'ipConfigurations[0].publicIpAddress.id' -o tsv)"
        res=$(az network nic update --ids $nicid --remove 'ipConfigurations[0].publicIpAddress')
        res=$(az network public-ip delete -g ${RES_GRP} --ids $ipid)
    done
    show_elapsed_time $st
}

# 11. Show and write all settings
show_settings () {
    NODE_NAMES=()
    for num in $(seq $VM_COUNT); do
        last_octet=$(expr 3 + $num)
        node_ipaddress="10.0.0.$last_octet"
        NODE_NAMES+=($node_ipaddress)
        part_comment_ar+=("PARTITION pt$num COMMENT = 'srv \\\"backend$num\\\"'")
        mysql_com_ar+=(",    mysql -u ${SPIDER_USER} -p${SPIDER_PASS} -h $node_ipaddress")
    done
    
    echo -e "\e[31mWriting all settings to 'settings.txt'...\e[m\n"
    cat <<- EOF | tee settings_${AZURE_ACCT}${PRJ_NAME}.txt
		Azure Region   : ${RES_LOC}
		Resource Group : ${RES_GRP}
		VoltDB Servers  : ${VM_NAME}1.${RES_LOC}.cloudapp.azure.com
		
		Please open ${VM_NAME}1.${RES_LOC}.cloudapp.azure.com:8080 for the source IP address you use.
		EOF
}

show_elapsed_time () {
    st=$1
    echo "Elapsed time: $(expr $(date '+%s') - $st) secs"
}


##### MAIN
total_st=$(date '+%s')

check_voltdb_file
check_ultra_disk
create_group
create_ultra_disks
create_vnet
create_vm
wait_for_vm
attach_disks
install_voltdb
#configure_fw
show_settings

show_elapsed_time $total_st
