#!/bin/bash

# ----------------------------------------
# GLOBAL VARIABLES
# ----------------------------------------
NAMESPACE=""
SERVICE_ACCOUNTS=()
EXISTING_SCC=""
APPLY=false
YES_TO_ALL=false
CLUSTER_NAME=""
CLUSTER_URL=""

# ----------------------------------------
# UTILITY FUNCTIONS
# ----------------------------------------

# Display usage information
function show_usage {
    echo "Usage: $0 -n <namespace> -s <serviceaccount> -e <scc_name> [-a] [-y]"
    echo "  -n: Namespace name"
    echo "  -s: Service account name"
    echo "  -e: Existing SCC name to grant"
    echo "  -a: Apply changes (required for making changes)"
    echo "  -y: Skip all confirmation prompts"
    exit 1
}

# Confirm an action with the user
function confirm_action() {
    local prompt="$1"
    local default="$2"
    
    if [ "$YES_TO_ALL" = true ]; then
        return 0
    fi
    
    read -p "$prompt [Y/n]: " response
    case "$response" in
        [Nn]* ) return 1;;
        * ) return 0;;
    esac
}

# Execute command with confirmation
function execute_with_confirmation() {
    local command="$1"
    local description="$2"
    
    echo "→ $description"
    echo "   Command: $command"
    
    if confirm_action "Execute this command?" "Y"; then
        echo "Executing: $command"
        eval "$command"
        return $?
    else
        echo "Skipped command execution."
        return 1
    fi
}

# Grant access to existing SCC
function grant_existing_scc() {
    local ns="$1"
    local sa="$2"
    local scc_name="$3"

    # Check if the SCC exists
    if ! oc get scc "$scc_name" &> /dev/null; then
        echo "Error: SCC $scc_name does not exist in the cluster"
        return 1
    fi

    # Check if service account already has this SCC
    local sa_has_scc=$(oc get scc "$scc_name" -o jsonpath='{.users}' | grep "system:serviceaccount:$ns:$sa" || true)

    if [ ! -z "$sa_has_scc" ]; then
        echo "Service account $sa already has SCC $scc_name"
        return 0
    fi

    if [ "$APPLY" = true ]; then
        if execute_with_confirmation "oc adm policy add-scc-to-user $scc_name system:serviceaccount:$ns:$sa" "Grant SCC $scc_name to $sa"; then
            echo "Successfully granted SCC '$scc_name' to service account '$sa' in namespace '$ns'"
            return 0
        fi
        return 1
    else
        echo "Would grant SCC $scc_name to $sa"
        return 0
    fi
}

# ----------------------------------------
# MAIN SCRIPT
# ----------------------------------------

# Parse command line arguments
while getopts "n:s:e:ay" opt; do
    case $opt in
        n) NAMESPACE="$OPTARG" ;;
        s) SERVICE_ACCOUNTS+=("$OPTARG") ;;
        e) EXISTING_SCC="$OPTARG" ;;
        a) APPLY=true ;;
        y) YES_TO_ALL=true ;;
        *) show_usage ;;
    esac
done

# Validate required arguments
if [ -z "$NAMESPACE" ] || [ ${#SERVICE_ACCOUNTS[@]} -eq 0 ] || [ -z "$EXISTING_SCC" ]; then
    echo "Error: Missing required arguments."
    show_usage
fi

# Process each service account
for sa in "${SERVICE_ACCOUNTS[@]}"; do
    grant_existing_scc "$NAMESPACE" "$sa" "$EXISTING_SCC"
done
