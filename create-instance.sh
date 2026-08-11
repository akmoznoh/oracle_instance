#!/bin/bash
set -euo pipefail

# --- KONFIGURACE ---
COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"
SUBNET_ID="${OCI_SUBNET_ID:-}"
REGION="${OCI_REGION:-eu-frankfurt-1}"
SHAPE="VM.Standard.A1.Flex"
OCPUS="${OCI_OCPUS:-2}"
RAM="${OCI_RAM:-12}"
NAME="${OCI_INSTANCE_NAME:-Ampere-A1-Instance}"
RETRY_WAIT="${OCI_RETRY_WAIT:-300}"
MAX_ATTEMPTS="${OCI_MAX_ATTEMPTS:-0}"   # 0 = nekonečno

# Ověření povinných proměnných před spuštěním
if [ -z "$COMPARTMENT_ID" ]; then
    echo "CHYBA: Není nastaven OCI_COMPARTMENT_ID." >&2
    exit 1
fi
if [ -z "$SUBNET_ID" ]; then
    echo "CHYBA: Není nastaven OCI_SUBNET_ID." >&2
    exit 1
fi

REGIONS=(
    "${REGION}|Iicj:EU-FRANKFURT-1-AD-1|${SUBNET_ID}"
    "${REGION}|Iicj:EU-FRANKFURT-1-AD-2|${SUBNET_ID}"
    "${REGION}|Iicj:EU-FRANKFURT-1-AD-3|${SUBNET_ID}"
)

KEY_DIR="${OCI_KEY_DIR:-$HOME/.ssh}"
KEY_FILE="$KEY_DIR/id_rsa_oci"
PUB_KEY_FILE="$KEY_FILE.pub"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

setup_ssh_key() {
    if [ -n "${OCI_SSH_PUBLIC_KEY:-}" ]; then
        mkdir -p "$KEY_DIR"
        echo "$OCI_SSH_PUBLIC_KEY" > "$PUB_KEY_FILE"
        chmod 600 "$PUB_KEY_FILE"
        log "SSH veřejný klíč načten z proměnné prostředí."
    elif [ ! -f "$PUB_KEY_FILE" ]; then
        log "SSH klíč nenalezen. Generuji nový pár klíčů v $KEY_DIR..."
        mkdir -p "$KEY_DIR"
        ssh-keygen -t rsa -b 4096 -N "" -f "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        log "Klíče vygenerovány: $KEY_FILE / $PUB_KEY_FILE"
    else
        log "Používám existující SSH klíč: $PUB_KEY_FILE"
    fi
}

get_image_id() {
    local region="$1"
    log "[$region] Hledám nejnovější Oracle Linux 8 image pro $SHAPE..."
    local image_id
    image_id=$(oci compute image list \
        --region "$region" \
        --compartment-id "$COMPARTMENT_ID" \
        --operating-system "Oracle Linux" \
        --operating-system-version "8" \
        --shape "$SHAPE" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")

    if [ -z "$image_id" ] || [ "$image_id" = "null" ]; then
        log "[$region] VAROVÁNÍ: Nepodařilo se najít image."
        echo ""
        return
    fi
    log "[$region] Image ID: $image_id"
    echo "$image_id"
}

try_create_instance() {
    local region="$1"
    local ad="$2"
    local subnet="$3"
    local image_id="$4"

    if [ -z "$subnet" ]; then
        log "[$region] Subnet ID není nakonfigurováno – přeskakuji."
        return 1
    fi
    if [ -z "$image_id" ]; then
        log "[$region] Image ID není dostupné – přeskakuji."
        return 1
    fi

    local output
    local rc=0
    output=$(oci compute instance launch \
        --region "$region" \
        --availability-domain "$ad" \
        --compartment-id "$COMPARTMENT_ID" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $RAM}" \
        --subnet-id "$subnet" \
        --image-id "$image_id" \
        --display-name "$NAME" \
        --ssh-authorized-keys-file "$PUB_KEY_FILE" \
        --assign-public-ip true \
        2>&1) || rc=$?

    if [ $rc -eq 0 ]; then
        echo "=================================================="
        log "ÚSPĚCH! Instance se vytváří v regionu $region / $ad"
        echo "=================================================="
        echo "$output"
        if [ -f "$KEY_FILE" ]; then
            log "Soukromý klíč: $KEY_FILE"
        fi
        log "Veřejný klíč:  $PUB_KEY_FILE"
        return 0
    else
        local err_msg
        err_msg=$(echo "$output" | grep -oP '(?<="message": ")[^"]*' | head -1 || true)
        if [ -z "$err_msg" ]; then
            err_msg=$(echo "$output" | head -n 2 | tr '\n' ' ')
        fi
        log "[$region/$ad] Pokus selhal: $err_msg"
        return 1
    fi
}

setup_ssh_key

if [ -n "${OCI_CLI_USER:-}" ]; then
    OCI_CONFIG_DIR="${OCI_CONFIG_DIR:-$HOME/.oci}"
    mkdir -p "$OCI_CONFIG_DIR"
    cat > "$OCI_CONFIG_DIR/config" <<EOF
[DEFAULT]
user=${OCI_CLI_USER}
fingerprint=${OCI_CLI_FINGERPRINT}
tenancy=${OCI_CLI_TENANCY}
region=${OCI_CLI_REGION:-eu-frankfurt-1}
key_file=${OCI_CONFIG_DIR}/oci_api_key.pem
EOF
    echo "${OCI_CLI_KEY_CONTENT}" > "$OCI_CONFIG_DIR/oci_api_key.pem"
    chmod 600 "$OCI_CONFIG_DIR/oci_api_key.pem"
    chmod 600 "$OCI_CONFIG_DIR/config"
    log "OCI CLI konfigurace sestavena z proměnných prostředí."
fi

declare -A IMAGE_IDS
IMAGE_IDS["$REGION"]=$(get_image_id "$REGION")

attempt=0
log "Spouštím smyčku (max_attempts=${MAX_ATTEMPTS:-nekonečno}, retry_wait=${RETRY_WAIT}s)."
log "Zrušení: Ctrl+C"

while true; do
    attempt=$((attempt + 1))

    for entry in "${REGIONS[@]}"; do
        IFS='|' read -r region ad subnet <<< "$entry"
        log "Pokus #$attempt – region=$region ad=$ad"

        if try_create_instance "$region" "$ad" "$subnet" "${IMAGE_IDS[$region]:-}"; then
            exit 0
        fi
    done

    if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        log "Dosažen maximální počet pokusů ($MAX_ATTEMPTS). Ukončuji."
        exit 1
    fi

    log "Všechny pokusy selhaly. Čekám ${RETRY_WAIT}s před dalším kolem..."
    sleep "$RETRY_WAIT"
done
