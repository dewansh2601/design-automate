#!/usr/bin/env bash
###############################################################################
###############################################################################
##                                                                           ##
##      ___        ______    ____  _____ ____ ___ ____ _   _               ##
##     / \ \      / / ___|  |  _ \| ____/ ___|_ _/ ___| \ | |               ##
##    / _ \ \ /\ / /\___ \  | | | |  _| \___ \| | |  _|  \| |               ##
##   / ___ \ V  V /  ___) | | |_| | |___ ___) | | |_| | |\  |               ##
##  /_/   \_\_/\_/  |____/  |____/|_____|____/___\____|_| \_|               ##
##                                                                           ##
##             ____  _____ _____ _   _ ____                                 ##
##            / ___|| ____|_   _| | | |  _ \                                ##
##            \___ \|  _|   | | | | | | |_) |                               ##
##             ___) | |___  | | | |_| |  __/                                ##
##            |____/|_____| |_|  \___/|_|                                   ##
##                                                                           ##
###############################################################################
###############################################################################
#                                                                             #
#   SCRIPT   : setup_project.sh                                             #
#   AUTHOR   : Generated with Claude                                        #
#                                                                             #
#   PURPOSE:                                                                 #
#     Automates project setup across two AWS services:                     #
#                                                                             #
#       1) S3            -> Creates project folder structure                #
#                            design-bucket-mb/<project_name>/<folder_name>/  #
#                                                                             #
#       2) SSM Parameter  -> Creates a SecureString parameter                #
#          Store             Name  : /mb-design/<project_name>              #
#                             Type  : SecureString                          #
#                             KeyId : alias/aws/ssm (account default KMS)    #
#                             Value : entered by the user                   #
#                                                                             #
#   AWS CREDENTIALS:                                                         #
#     This script is intended to run in CI/CD only. It expects AWS         #
#     credentials to already be present in the environment (e.g. set by    #
#     the "configure-aws-credentials" step in GitHub Actions) - no AWS     #
#     CLI profile is used.                                                  #
#     Region: us-east-1                                                     #
#                                                                             #
###############################################################################

set -euo pipefail   # exit on error / unset var / failed pipe -> safer script

###############################################################################
# SECTION 0: BANNER (printed to the terminal when the script runs)
###############################################################################
print_banner() {
cat <<'EOF'
################################################################################
##                                                                            ##
##     ___      _____   ___  ___ ___ ___ ___ _  _   ___ ___ _____ _   _ ___   ##
##    /_\ \    / / __| |   \| __/ __|_ _/ __| \| | / __| __|_   _| | | | _ \  ##
##   / _ \ \/\/ /\__ \ | |) | _|\__ \| | (_ | .` | \__ \ _|  | | | |_| |  _/  ##
##  /_/ \_\_/\_/ |___/ |___/|___|___/___\___|_|\_| |___/___| |_|  \___/|_|    ##
##                                                                            ##
################################################################################
EOF
}

print_banner

###############################################################################
# SECTION 1: CONFIGURATION
###############################################################################
# Static values used throughout the script.
# Change these here if the bucket, region, profile, or KMS key ever change.

AWS_REGION="us-east-1"         # AWS region to operate in
BUCKET_NAME="design-bucket-mb" # Target S3 bucket
KMS_KEY_ID="alias/aws/ssm"     # Default KMS key used to encrypt SecureStrings

# --- Build the AWS CLI command prefix -----------------------------------
# This script is intended to run in CI/CD only. Credentials are expected
# to already be configured in the environment before this script runs
# (e.g. via the "configure-aws-credentials" step in GitHub Actions, which
# exports AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN).
# No --profile is used - the AWS CLI picks up those credentials through
# its default credential chain.
AWSCMD=(aws --region "$AWS_REGION")


###############################################################################
# SECTION 2: HELPER FUNCTIONS
###############################################################################

# ---- die -------------------------------------------------------------------
# Print an error message to stderr and exit the script immediately.
die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---- check_prereqs -----------------------------------------------------
# Make sure the AWS CLI is installed and that we can authenticate
# with the configured profile before doing any real work.
check_prereqs() {
    command -v aws >/dev/null 2>&1 || die "AWS CLI is not installed or not in PATH."

    "${AWSCMD[@]}" sts get-caller-identity >/dev/null 2>&1 \
        || die "Unable to authenticate with AWS. Check the credentials configured in this pipeline (e.g. AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY secrets)."
}

# ---- check_bucket_exists -----------------------------------------------
# Verify the target S3 bucket exists and is accessible before
# attempting to create folders inside it.
check_bucket_exists() {
    "${AWSCMD[@]}" s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1 \
        || die "Bucket '$BUCKET_NAME' does not exist or you don't have access to it."
}

# ---- project_folder_exists ----------------------------------------------
# Returns 0 (true) if ANY object already exists under the "<project_name>/"
# prefix in the bucket, meaning the project folder already exists.
# Returns 1 (false) otherwise.
project_folder_exists() {
    local prefix="$1"
    local result
    result=$("${AWSCMD[@]}" s3api list-objects-v2 \
        --bucket "$BUCKET_NAME" \
        --prefix "$prefix" \
        --max-items 1 \
        --query 'Contents[0].Key' \
        --output text 2>/dev/null || true)

    [[ -n "$result" && "$result" != "None" ]]
}

# ---- param_exists --------------------------------------------------------
# Returns 0 (true) if the given SSM parameter already exists.
param_exists() {
    local name="$1"
    "${AWSCMD[@]}" ssm get-parameter --name "$name" >/dev/null 2>&1
}


###############################################################################
# SECTION 3: COLLECT USER INPUT
###############################################################################
# Supports two modes:
#   1) INTERACTIVE (default)   - prompts for everything, as before.
#   2) NON-INTERACTIVE (CI/CD) - values supplied via flags or env vars, no
#                                 prompts, safe to run from GitHub Actions.
#
# Non-interactive values can be provided as flags:
#   ./setup_project.sh --project myproject --folder assets --value "secret"
# or as environment variables:
#   PROJECT_NAME=myproject FOLDER_NAME=assets PARAM_VALUE=secret ./setup_project.sh
#
# --value / PARAM_VALUE is only required if the SSM parameter doesn't
# already exist -- see STEP 4 below.

usage() {
    cat <<USAGE
Usage: $0 [--project NAME] [--folder NAME] [--value VALUE]

  --project NAME   Project name (S3 folder + SSM parameter path)
  --folder NAME    Sub-folder name to create inside the project folder
  --value VALUE    SSM parameter value (only needed if the parameter
                    does not already exist)
  -h, --help       Show this help message

If a flag is omitted, the script falls back to its environment variable
(PROJECT_NAME / FOLDER_NAME / PARAM_VALUE), and finally to an interactive
prompt if that's also unset.
USAGE
}

PROJECT_NAME="${PROJECT_NAME:-}"
FOLDER_NAME="${FOLDER_NAME:-}"
PARAM_VALUE="${PARAM_VALUE:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT_NAME="$2"; shift 2 ;;
        --folder)  FOLDER_NAME="$2"; shift 2 ;;
        --value)   PARAM_VALUE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (use --help for usage)" ;;
    esac
done

echo "=============================================="
echo " STEP 0: COLLECT INPUT"
echo "=============================================="

# --- Project name (used for S3 folder + SSM parameter path) ----------------
if [[ -z "$PROJECT_NAME" ]]; then
    read -rp "Enter project name: " PROJECT_NAME
fi
[[ -n "$PROJECT_NAME" ]] || die "Project name cannot be empty."


###############################################################################
# SECTION 4: PRE-FLIGHT CHECKS
###############################################################################

echo
echo "=============================================="
echo " STEP 1: PRE-FLIGHT CHECKS"
echo "=============================================="
# (STEP 0 = collect project name, above)

echo "-> Checking AWS CLI installation and credentials..."
check_prereqs

echo "-> Checking that bucket '$BUCKET_NAME' exists..."
check_bucket_exists


###############################################################################
# SECTION 5: S3 - CHECK IF PROJECT ALREADY EXISTS
###############################################################################
# If a folder for this project already exists in the bucket, we don't
# recreate it -- we just ask for a new sub-folder name and create that
# inside the existing project folder. Otherwise this is a brand-new
# project, so we create both the project folder and the first sub-folder.

echo
echo "=============================================="
echo " STEP 2: CHECK IF PROJECT ALREADY EXISTS"
echo "=============================================="

PROJECT_KEY="${PROJECT_NAME}/"   # e.g. myproject/

echo "-> Checking s3://${BUCKET_NAME}/${PROJECT_KEY} ..."
PROJECT_EXISTS=false
if project_folder_exists "$PROJECT_KEY"; then
    PROJECT_EXISTS=true
    echo "-> Project '${PROJECT_NAME}' already exists."
    echo "   Going into s3://${BUCKET_NAME}/${PROJECT_KEY} to add a new folder."
else
    echo "-> Project '${PROJECT_NAME}' does not exist yet. It will be created."
fi

# --- Ask for the (sub-)folder name now that we know whether the project ----
# --- already exists, so the prompt text makes sense either way. ------------
if [[ -z "$FOLDER_NAME" ]]; then
    read -rp "Enter folder name (to create inside ${PROJECT_KEY}): " FOLDER_NAME
fi
[[ -n "$FOLDER_NAME" ]] || die "Folder name cannot be empty."

SUBFOLDER_KEY="${PROJECT_NAME}/${FOLDER_NAME}/" # e.g. myproject/assets/


###############################################################################
# SECTION 6: S3 - CREATE PROJECT FOLDER STRUCTURE
###############################################################################
# NOTE: S3 does not have real folders. A zero-byte object whose key ends
# in "/" is the standard way the AWS console/CLI simulate a folder.

echo
echo "=============================================="
echo " STEP 3: CREATE S3 FOLDER(S)"
echo "=============================================="

if [[ "$PROJECT_EXISTS" == false ]]; then
    # --- 6a. Create the top-level project folder (new project only) --------
    echo "-> Creating folder: s3://${BUCKET_NAME}/${PROJECT_KEY}"
    "${AWSCMD[@]}" s3api put-object \
        --bucket "$BUCKET_NAME" \
        --key "$PROJECT_KEY" >/dev/null \
        || die "Failed to create folder '${PROJECT_KEY}'."
else
    echo "-> Project folder already exists, skipping creation."
fi

# --- 6b. Create the (sub-)folder inside the project folder ------------------
echo "-> Creating folder: s3://${BUCKET_NAME}/${SUBFOLDER_KEY}"
"${AWSCMD[@]}" s3api put-object \
    --bucket "$BUCKET_NAME" \
    --key "$SUBFOLDER_KEY" >/dev/null \
    || die "Failed to create folder '${SUBFOLDER_KEY}'."

echo "-> S3 folder(s) ready:"
[[ "$PROJECT_EXISTS" == false ]] && echo "     s3://${BUCKET_NAME}/${PROJECT_KEY}"
echo "     s3://${BUCKET_NAME}/${SUBFOLDER_KEY}"


###############################################################################
# SECTION 7: SYSTEMS MANAGER - CREATE PARAMETER STORE ENTRY
###############################################################################

echo
echo "=============================================="
echo " STEP 4: CREATE SSM PARAMETER STORE ENTRY"
echo "=============================================="

PARAM_CREATED=false          # default; set to true below only on fresh creation
PARAM_NAME="/mb-design/${PROJECT_NAME}"

# --- 7a. Skip creation if this project's parameter already exists -----------
# (Typical when re-running the script to add another folder to an
#  existing project -- the parameter was already created the first time.)
echo "-> Checking if parameter '${PARAM_NAME}' already exists..."
if param_exists "$PARAM_NAME"; then
    echo "-> Parameter '${PARAM_NAME}' already exists. Skipping creation."
    PARAM_CREATED=false
else
    # --- 7b. Get the value only when we actually need to create it ---------
    if [[ -z "$PARAM_VALUE" ]]; then
        read -rsp "Enter the value for SSM parameter ${PARAM_NAME}: " PARAM_VALUE
        echo   # move to a new line since -s (silent) suppresses the newline on Enter
    fi
    [[ -n "$PARAM_VALUE" ]] || die "Parameter value cannot be empty. (Pass --value or set PARAM_VALUE.)"

    echo "-> Creating SecureString parameter '${PARAM_NAME}'..."
    "${AWSCMD[@]}" ssm put-parameter \
        --name "$PARAM_NAME" \
        --value "$PARAM_VALUE" \
        --type "SecureString" \
        --key-id "$KMS_KEY_ID" >/dev/null \
        || die "Failed to create SSM parameter '${PARAM_NAME}'."

    echo "-> SSM parameter created successfully:"
    echo "     Name : ${PARAM_NAME}"
    echo "     Type : SecureString"
    echo "     KMS  : ${KMS_KEY_ID}"
    PARAM_CREATED=true
fi


###############################################################################
# SECTION 8: SUMMARY
###############################################################################

echo
echo "=============================================="
echo " SUMMARY"
echo "=============================================="
if [[ "$PROJECT_EXISTS" == true ]]; then
    echo " Project           : ${PROJECT_NAME} (already existed)"
else
    echo " Project           : ${PROJECT_NAME} (newly created)"
fi
echo " Folder created    : s3://${BUCKET_NAME}/${SUBFOLDER_KEY}"
if [[ "$PARAM_CREATED" == true ]]; then
    echo " SSM parameter     : ${PARAM_NAME} (SecureString, KMS: ${KMS_KEY_ID}) - newly created"
else
    echo " SSM parameter     : ${PARAM_NAME} - already existed, unchanged"
fi
echo "=============================================="
echo " All done."
echo "=============================================="