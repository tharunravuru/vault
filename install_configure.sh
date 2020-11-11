#! /bin/bash
set -ex

AZURE_KEY_VAULT_NAME=$1
AZURE_TENANT_ID=$2

# os info
ENVIRONMENT_FILE="/etc/environment"
TOOLS=("unzip" "jq")

# storage info
STORAGE_ACCOUNT_KEY="DefaultEndpointsProtocol=https;AccountName=cvnadevopsdev;AccountKey=sDRuKSw1csZI8ImcLcjQJK1XRfXoDr4W2uV5Ha+pFWqEdcX0VqSJsONM2udwY0l0g9ga+TToMC5AX3U/7O463Q==;EndpointSuffix=core.windows.net"

# consul info
CONSUL_USER="consul"
CONSUL_SERVICE_NAME="consul"
CONSUL_VERSION="1.7.0"
CONSUL_PACKAGE_NAME="consul_1.7.0_linux_amd64.zip"
CONSUL_DOWNLOAD_URL="https://releases.hashicorp.com/consul/$CONSUL_VERSION/$CONSUL_PACKAGE_NAME"
CONSUL_DIRS=("/var/run/consul" "/var/consul" "/usr/local/etc/consul" "/opt/consul/data" "/opt/consul/certs")
CONSUL_TEMP_DIR="/tmp/consul-config"
STORAGE_ACCOUNT_CONTAINER_CONSUL="consul-config"

# vault info
VAULT_USER="vault"
VAULT_SERVICE_NAME="vault"
VAULT_VERSION="1.3.2"
VAULT_PACKAGE_NAME="vault_1.3.2_linux_amd64.zip"
VAULT_DOWNLOAD_URL="https://releases.hashicorp.com/vault/$VAULT_VERSION/$VAULT_PACKAGE_NAME"
VAULT_DIRS=("/opt/vault" "/opt/vault/certs" "/var/run/vault")
VAULT_TEMP_DIR="/tmp/vault-config"
STORAGE_ACCOUNT_CONTAINER_VAULT="vault-config"


function swap_size_recommendation (){
    local CURRENT_MEMORY_SIZE=$(($(getconf _PHYS_PAGES) * $(getconf PAGE_SIZE) / (1024 * 1024)))
    if (( $CURRENT_MEMORY_SIZE >= 0 && $CURRENT_MEMORY_SIZE < 2048 )); then
        local RECOMMENDED_SWAP_SIZE="1G"
    elif (( $CURRENT_MEMORY_SIZE >= 2048 && $CURRENT_MEMORY_SIZE < 6144 )); then
        local RECOMMENDED_SWAP_SIZE="2G"
    elif (( $CURRENT_MEMORY_SIZE >= 6144 && $CURRENT_MEMORY_SIZE < 12288 )); then
        local RECOMMENDED_SWAP_SIZE="3G"
    elif (( $CURRENT_MEMORY_SIZE >= 12288 && $CURRENT_MEMORY_SIZE < 16384 )); then
        local RECOMMENDED_SWAP_SIZE="4G"
    elif (( $CURRENT_MEMORY_SIZE >= 16384 && $CURRENT_MEMORY_SIZE < 24576 )); then
        local RECOMMENDED_SWAP_SIZE="5G"
    elif (( $CURRENT_MEMORY_SIZE >= 24576 && $CURRENT_MEMORY_SIZE < 32768 )); then
        local RECOMMENDED_SWAP_SIZE="6G"
    elif (( $CURRENT_MEMORY_SIZE >= 32768 && $CURRENT_MEMORY_SIZE < 65536 )); then
        local RECOMMENDED_SWAP_SIZE="8G"
    elif (( $CURRENT_MEMORY_SIZE >= 65536 && $CURRENT_MEMORY_SIZE < 131072 )); then
        local RECOMMENDED_SWAP_SIZE="11G"
    elif (( $CURRENT_MEMORY_SIZE >= 131072 )); then
        local RECOMMENDED_SWAP_SIZE="12G"
    fi
    echo $RECOMMENDED_SWAP_SIZE
}

function mk_swap () {
    local file='/var/swap'
    if [[ ! -f "$file" ]]; then
        sudo fallocate -l "$1" "$file"
        sudo mkswap "$file" && sudo chmod 600 "$file" && sudo swapon "$file"
        echo "$file"' none swap sw 0 0'  | sudo tee --append /etc/fstab
    fi
}

function install_dependent_software () {
    apt-get update
    for TOOL in "${TOOLS[@]}"
    do
        if [ $(is_software_installed $TOOL) == 1 ]; then
            apt-get install -y $TOOL
        fi
    done
}

function is_software_installed () {
    which $1 1> /dev/null
    if [ $? == 0 ]; then
        echo 0 # true; software is installed
    else
        echo 1 # false; software is not installed
    fi
}

function install_consul () {
    if [ $(is_software_installed consul) == 1 ]; then
        wget -q $CONSUL_DOWNLOAD_URL -P /tmp/
        unzip /tmp/$CONSUL_PACKAGE_NAME -d /usr/local/bin/
        rm /tmp/$CONSUL_PACKAGE_NAME
    fi
}

function install_service () {
    local SERVICE=$1
    local DOWNLOAD_URL=$2
    local PACKAGE_NAME=$3
    if [ $(is_software_installed $SERVICE) == 1 ]; then
        wget -q $DOWNLOAD_URL -P /tmp/
        unzip /tmp/$PACKAGE_NAME -d /usr/local/bin/
        rm /tmp/$PACKAGE_NAME
    fi
}

function create_consul_user () {
    groupadd --system $CONSUL_USER || true
    useradd -s /sbin/nologin --system -g $CONSUL_USER $CONSUL_USER || true
}

function create_user () {
    local USER=$1
    groupadd --system $USER || true
    useradd -s /sbin/nologin --system -g $USER $USER || true
}

function create_dir_structure () {
    local USER=$1
    shift
    local DIRS=("$@")
    for DIR in "${DIRS[@]}";
    do
        mkdir -p $DIR
        chown -R $USER:$USER $DIR
        chmod -R 775 $DIR
    done
}

function install_az_cli () {
    if [ $(is_software_installed az) == 1 ]; then
        apt-get update
        apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg -y
        curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.asc.gpg > /dev/null
        local AZ_REPO=$(lsb_release -cs)
        echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | tee /etc/apt/sources.list.d/azure-cli.list
        apt-get update
        apt-get install azure-cli
    fi
}

function download_consul_config () {
    local CONFIG=$1
    mkdir -p $CONSUL_TEMP_DIR/
    az storage blob download-batch -d $CONSUL_TEMP_DIR/ -s $STORAGE_ACCOUNT_CONTAINER_CONSUL --connection-string $STORAGE_ACCOUNT_KEY
    cp $CONSUL_TEMP_DIR/consul.service /etc/systemd/system/consul.service
    cp $CONSUL_TEMP_DIR/$(hostname).json /opt/consul/consul.json
    if [[ $CONFIG == "server" ]]; then
        cp $CONSUL_TEMP_DIR/{ca.pem,cli.pem,cli-key.pem,server.pem,server-key.pem} /opt/consul/certs/
    else
        cp $CONSUL_TEMP_DIR/ca.pem /opt/consul/certs/
    fi
    rm $CONSUL_TEMP_DIR/*
}

function get_user_managed_identity_client_id () {
    echo $(curl "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F" -H Metadata:true -s | jq -r .client_id)
}

function modify_vault_hcl () {
    local AZURE_CLIENT_ID=$(get_user_managed_identity_client_id)
    sed -i "s/AZURE_CLIENT_ID/$AZURE_CLIENT_ID/g" $VAULT_TEMP_DIR/$(hostname).hcl
    sed -i "s/AZURE_TENANT_ID/$AZURE_TENANT_ID/g" $VAULT_TEMP_DIR/$(hostname).hcl
    sed -i "s/AZURE_KEY_VAULT_NAME/$AZURE_KEY_VAULT_NAME/g" $VAULT_TEMP_DIR/$(hostname).hcl
}

function download_vault_config () {
    mkdir -p $VAULT_TEMP_DIR/
    az storage blob download-batch -d $VAULT_TEMP_DIR/ -s $STORAGE_ACCOUNT_CONTAINER_VAULT --connection-string $STORAGE_ACCOUNT_KEY
    modify_vault_hcl
    cp $VAULT_TEMP_DIR/vault.service /etc/systemd/system/vault.service
    cp $VAULT_TEMP_DIR/$(hostname).hcl /opt/vault/vault_server.hcl
    cp $VAULT_TEMP_DIR/{ca.pem,client.pem,client-key.pem,vault.pem,vault-key.pem} /opt/vault/certs/
    rm $VAULT_TEMP_DIR/*
}

function consul_cli_config () {
    CONSUL_HTTP_ADDR='CONSUL_HTTP_ADDR="https://localhost:8501"'
    CONSUL_CACERT='CONSUL_CACERT="/opt/consul/certs/ca.pem"'
    CONSUL_CLIENT_CERT='CONSUL_CLIENT_CERT="/opt/consul/certs/cli.pem"'
    CONSUL_CLIENT_KEY='CONSUL_CLIENT_KEY="/opt/consul/certs/cli-key.pem"'
    grep -qxF $CONSUL_HTTP_ADDR $ENVIRONMENT_FILE || echo $CONSUL_HTTP_ADDR >> $ENVIRONMENT_FILE
    grep -qxF $CONSUL_CACERT $ENVIRONMENT_FILE || echo $CONSUL_CACERT >> $ENVIRONMENT_FILE
    grep -qxF $CONSUL_CLIENT_CERT $ENVIRONMENT_FILE || echo $CONSUL_CLIENT_CERT >> $ENVIRONMENT_FILE
    grep -qxF $CONSUL_CLIENT_KEY $ENVIRONMENT_FILE || echo $CONSUL_CLIENT_KEY >> $ENVIRONMENT_FILE
}

function reload () {
    local SERVICE=$1
    systemctl daemon-reload
    if [ $(systemctl is-active $SERVICE.service) == "inactive" ]; then
        systemctl restart $SERVICE
    fi
}

function install_consul () {
    local CONFIG=$1
    create_user $CONSUL_USER
    create_dir_structure $CONSUL_USER "${CONSUL_DIRS[@]}"
    download_consul_config $CONFIG
    install_service $CONSUL_SERVICE_NAME $CONSUL_DOWNLOAD_URL $CONSUL_PACKAGE_NAME
    reload $CONSUL_SERVICE_NAME
    if [[ $CONFIG == "server" ]]; then
        consul_cli_config
    fi
}

function install_vault () {
    create_user $VAULT_USER
    create_dir_structure $VAULT_USER "${VAULT_DIRS[@]}"
    download_vault_config
    install_service $VAULT_SERVICE_NAME $VAULT_DOWNLOAD_URL $VAULT_PACKAGE_NAME
    reload $VAULT_SERVICE_NAME
}

function run (){
    mk_swap $(swap_size_recommendation)
    install_dependent_software
    install_az_cli
    if [[ $(hostname) == *"server"* ]]; then
        install_consul "server"
    else
        install_consul "client"
        install_vault 
    fi
}

echo "this is vault name: $KEY_VAULT_NAME"
run
