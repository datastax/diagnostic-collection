#!/usr/bin/env bash
# This script encrypts a diagnostic tarball and uploads it to S3
##

function usage() {
    echo "Usage: $0 [options]"
    echo " ----- Required --------"
    echo "   -B S3 bucket - AWS S3 bucket to upload the artifacts to"
    echo "   -f file_name - diagnostic file to encrypt and upload to S3"
    echo "   -T ticket/ref id - ticket/ref id for the S3 upload and encrypted tarball naming"
    echo " ----- Optional --------"
    echo "   -e encryption key file - Key file for encryption of the generated tarball"
    echo "   -S S3 secret - AWS secret for the S3 upload (can be passed as env variable named DS_AWS_SECRET)"
    echo "   -K S3 key - AWS key for the S3 upload (can be passed as env variable named DS_AWS_KEY)"
}

function maybe_generate_key() {
    ENCRYPTION_KEY="$TICKET.key" 
    if [ ! -f "$ENCRYPTION_KEY" ]; then
        echo "Generating encryption key..."
        openssl rand -base64 256 > ${ENCRYPTION_KEY}
        echo "An encryption key has been generated as ${ENCRYPTION_KEY}"
    else
        echo "Using existing encryption key: ${ENCRYPTION_KEY}"
    fi
}

function s3_push() {
  local srcFilePath="$1"
  local dstFileName="$2"
  local ticket="$3"
  local s3_bucket="$4"
  local s3_key="$5"
  local s3_secret="$6"
  local timestamp="$7"
  contentType="application/octet-stream"
  s3Date="$(LC_ALL=C date -u +"%a, %d %b %Y %X %z")"

  resource="/${s3_bucket}/${ticket}-${timestamp}/${dstFileName}"

  stringToSign="PUT\n\n${contentType}\n${s3Date}\n${resource}"
  signature=$(echo -en "${stringToSign}" | openssl sha1 -hmac "${s3_secret}" -binary | base64)
  curl -X PUT -T "${srcFilePath}" \
        -H "Host: ${s3_bucket}.s3-us-west-2.amazonaws.com" \
        -H "Date: ${s3Date}" \
        -H "Content-Type: ${contentType}" \
        -H "Authorization: AWS ${s3_key}:${signature}" \
        https://"${s3_bucket}.s3-us-west-2.amazonaws.com/${ticket}-${timestamp}/${dstFileName}"
  return $?
}

s3_push_complete_marker() {
  local ticket="$1"
  local s3_bucket="$2"
  local s3_key="$3"
  local s3_secret="$4"
  local timestamp="$5"
  local base_dir="$6"
  local completeFileName="collector_upload.complete"
  local completeFilePath="${base_dir}/${completeFileName}"

  touch "${completeFilePath}"
  s3_push "${completeFilePath}" "${completeFileName}" "$ticket" "$s3_bucket" "$s3_key" "$s3_secret" "$timestamp"  
  rm -f ${completeFilePath}
}

TARBALL_NAME=""
ENCRYPTION_KEY=""
TICKET=""
S3_BUCKET=""

# ---------------
# Parse arguments
# ---------------

while getopts ":f:e:S:K:T:B:" opt; do
    case $opt in
        e) ENCRYPTION_KEY="$OPTARG"
           ;;
        f) TARBALL_NAME="$OPTARG"
           ;;
        S) DS_AWS_SECRET="$OPTARG"
           ;;
        K) DS_AWS_KEY="$OPTARG"
           ;;
        B) S3_BUCKET="$OPTARG"
           ;;
        T) TICKET="$OPTARG"
           ;;
        h) usage
           exit 0
           ;;
        *) echo "Unknown flag passed: '$opt'"
           usage
           exit 1
           ;;
    esac
done
shift "$((OPTIND -1))"
echo "Using output directory: ${OUT_DIR}"

echo "S3 bucket: ${S3_BUCKET}"
if [ -z "$S3_BUCKET" ]; then
    echo "S3 bucket arg is missing"
    usage
    exit 1
fi

if [ -z "$DS_AWS_SECRET" ]; then
    echo "S3 secret arg/env variable is missing"
    usage
    exit 1
fi

if [ -z "$DS_AWS_KEY" ]; then
    echo "S3 key arg/env variable is missing"
    usage
    exit 1
fi

if [ -z "$TICKET" ]; then
    echo "Ticket number arg is missing"
    usage
    exit 1
fi

if [ -z "$ENCRYPTION_KEY" ]; then
    maybe_generate_key
fi

if [ -z "$TARBALL_NAME" ]; then
    echo "Diagnostic file arg is missing"
    usage
    exit 1
fi


tarball=${TARBALL_NAME##*/}
tarball_path=${TARBALL_NAME%/*}
if [ "$tarball_path" == "$tarball" ]; then
    tarball_path="."
fi
echo "Encrypting $tarball..."
SECRET=$(cat "${ENCRYPTION_KEY}")
timestamp=$(date +"%b-%d-%H-%M")
artifactPath="$tarball_path/$TICKET-$timestamp.tar.gz.enc"
openssl enc -aes-256-cbc -salt -in "$TARBALL_NAME" -out "${artifactPath}" -pass pass:"${SECRET}"
echo "Tarball was encrypted as ${artifactPath}"
`s3_push "${artifactPath}" "$TICKET-$timestamp.tar.gz.enc" "$TICKET" "$S3_BUCKET" "$DS_AWS_KEY" "$DS_AWS_SECRET" "$timestamp"`
`s3_push_complete_marker "$TICKET" "$S3_BUCKET" "$DS_AWS_KEY" "$DS_AWS_SECRET" "$timestamp" "$tarball_path"`
echo "S3 upload finished with status $?" 