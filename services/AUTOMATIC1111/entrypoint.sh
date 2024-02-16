#!/bin/bash

set -Eeuo pipefail

# TODO: move all mkdir -p ?
mkdir -p /data/config/auto/scripts/
# mount scripts individually

while getopts "r:m:" flag > /dev/null 2>&1
do
    case ${flag} in
        r) BOOT="${OPTARG}" ;;
        m) MODELS="${OPTARG}" ;;
        *) break;; 
    esac
done

echo $BOOT
ls -lha $BOOT
ls -lha /

find "${BOOT}/scripts/" -maxdepth 1 -type l -delete
cp -vrfTs /data/config/auto/scripts/ "${BOOT}/scripts/"

cp /docker/nginx.conf /etc/nginx/nginx.conf
cp /docker/nginx-default /etc/nginx/sites-enabled/default

echo "Installing pm2..."
apt-get install -y ca-certificates curl gnupg
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_16.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y nodejs
apt-get install nodejs -y
npm install -g npm@9.8.0
npm install -g pm2@latest
pm2 status


# Set up config file
python /docker/config.py /data/config/auto/config.json

if [ ! -f /data/config/auto/ui-config.json ]; then
  echo '{}' >/data/config/auto/ui-config.json
fi

if [ ! -f /data/config/auto/styles.csv ]; then
  touch /data/config/auto/styles.csv
fi

# copy models from original models folder
mkdir -p /data/models/VAE-approx/ /data/models/karlo/

rsync -a --info=NAME ${BOOT}/models/VAE-approx/ /data/models/VAE-approx/
rsync -a --info=NAME ${BOOT}/models/karlo/ /data/models/karlo/
#rsync -a --info=NAME /docker/the-models/ /data/models/Stable-diffusion/

declare -A MOUNTS

MOUNTS["/root/.cache"]="/data/.cache"
MOUNTS["${BOOT}/models"]="/data/models"

MOUNTS["${BOOT}/embeddings"]="/data/embeddings"
MOUNTS["${BOOT}/config.json"]="/data/config/auto/config.json"
MOUNTS["${BOOT}/ui-config.json"]="/data/config/auto/ui-config.json"
MOUNTS["${BOOT}/styles.csv"]="/data/config/auto/styles.csv"
MOUNTS["${BOOT}/extensions"]="/data/config/auto/extensions"
MOUNTS["${BOOT}/config_states"]="/data/config/auto/config_states"

# extra hacks
MOUNTS["${BOOT}/repositories/CodeFormer/weights/facelib"]="/data/.cache"

for to_path in "${!MOUNTS[@]}"; do
  set -Eeuo pipefail
  from_path="${MOUNTS[${to_path}]}"
  rm -rf "${to_path}"
  if [ ! -f "$from_path" ]; then
    mkdir -vp "$from_path"
  fi
  mkdir -vp "$(dirname "${to_path}")"
  ln -sT "${from_path}" "${to_path}"
  echo Mounted $(basename "${from_path}")
done

echo "Installing extension dependencies (if any)"

# because we build our container as root:
chown -R root ~/.cache/
chmod 766 ~/.cache/

shopt -s nullglob
# For install.py, please refer to https://github.com/AUTOMATIC1111/stable-diffusion-webui/wiki/Developing-extensions#installpy
list=(./extensions/*/install.py)
for installscript in "${list[@]}"; do
  EXTNAME=$(echo $installscript | cut -d '/' -f 3)
  # Skip installing dependencies if extension is disabled in config
  if $(jq -e ".disabled_extensions|any(. == \"$EXTNAME\")" config.json); then
    echo "Skipping disabled extension ($EXTNAME)"
    continue
  fi
  PYTHONPATH=${BOOT} python "$installscript"
done

if [ -f "/data/config/auto/startup.sh" ]; then
  pushd ${BOOT}
  echo "Running startup script"
  . /data/config/auto/startup.sh
  popd
fi

mkdir ${BOOT}/models/Stable-diffusion && cd ${BOOT}/models/Stable-diffusion
wget --no-verbose --show-progress --progress=bar:force:noscroll https://huggingface.co/runwayml/stable-diffusion-v1-5/resolve/main/v1-5-pruned.safetensors
wget --no-verbose --show-progress --progress=bar:force:noscroll https://huggingface.co/stabilityai/stable-diffusion-2-1/resolve/main/v2-1_768-ema-pruned.safetensors
wget --no-verbose --show-progress --progress=bar:force:noscroll https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors
wget --no-verbose --show-progress --progress=bar:force:noscroll https://huggingface.co/stabilityai/stable-diffusion-xl-refiner-1.0/resolve/main/sd_xl_refiner_1.0.safetensors
wget --no-verbose --show-progress --progress=bar:force:noscroll "https://civitai.com/api/download/models/288982?type=Model&format=SafeTensor&size=full&fp=fp16" -O juggernautXL_v8Rundiffusion.safetensors
cd ${BOOT}

pm2 start --name webui "python -u webui.py --opt-sdp-no-mem-attention --api --port 3130 --medvram --no-half-vae"

service nginx start

# Comma separated string to array
IFS=, read -r -a models <<<"${MODELS}"

# Array to parameter list
echo "WAITING TO START UP BEFORE LOADING MODELS..."

sleep 75

# Array to parameter list
echo "Loading models: ${MODELS}"

for model in "${models[@]}"; do echo $model && python /docker/loader.py -m $model; done

echo "~~READY~~"