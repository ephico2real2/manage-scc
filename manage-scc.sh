#!/bin/bash

# ----------------------------------------
# GLOBAL VARIABLES
# ----------------------------------------
NAMESPACE=""
SCC_FILE=""
ORIGINAL_SCC_NAME=""
NEW_SCC_NAME=""
NEW_FILE=""
SERVICE_ACCOUNTS=()
MISSING_SAS=()
DRY_RUN=false
EXPLICIT_DRY_RUN=false
APPLY=false
YES_TO_ALL=false
OUTPUT_DIR=""
CLUSTER_NAME=""
CLUSTER_URL=""

# ----------------------------------------
# UTILITY FUNCTIONS
# ----------------------------------------

# Display usage information
function show_usage {
    echo "Usage: $0 -n <namespace> -s <serviceaccount1> [-s <serviceaccount2> ...] -f <scc_yaml_file> [-a] [-d] [-y]"
    echo "  -n: Namespace name (e.g., fpprod, gpprod)"
    echo "  -s: Service account name(s) - can be specified multiple times"
    echo "  -f: Absolute path to the SCC YAML file (e.g., /path/to/ibm-sccm-scc.yaml)"
    echo "  -a: Apply SCCs and assign to service account(s) (optional, required for making changes)"
    echo "  -d: Dry run mode - generate commands but do not execute them (optional)"
    echo "  -y: Skip all confirmation prompts (optional, does not imply -a)"
    echo ""
    echo "Flag combinations:"
    echo "  No flags: Show what would be done, with confirmations"
    echo "  -y: Show what would be done, without confirmations"
    echo "  -a: Apply changes with confirmations"
    echo "  -a -y: Apply changes without confirmations"
    exit 1
}

# Confirm an action with the user
function confirm_action() {
    local prompt="$1"
    local default="$2"
    
    # Only skip prompts if -y is used
    if [ "$YES_TO_ALL" = true ]; then
        # If in apply mode (-a -y), proceed automatically
        if [ "$APPLY" = true ]; then
            return 0
        # If not in apply mode (just -y), only skip informational prompts
        elif [[ "$prompt" != *"apply"* ]] && [[ "$prompt" != *"execute"* ]]; then
            return 0
        fi
    fi
    
    local response
    
    if [ "$default" = "Y" ]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-Y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-N}
    fi
    
    case "$response" in
        [Yy]*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Execute a command with confirmation
function execute_with_confirmation() {
    local command="$1"
    local description="$2"
    
    echo "→ $description"
    echo "   Command: $command"
    if [ ! -z "$CLUSTER_NAME" ]; then
        echo "   Cluster: $CLUSTER_NAME"
    fi
    
    if confirm_action "Execute this command?" "Y"; then
        echo "Executing: $command"
        eval "$command"
        return $?
    else
        echo "Skipped command execution."
        return 0
    fi
}

# Check if a command is available
function check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: '$cmd' command not found. Please install it first."
        exit 1
    fi
}

# ----------------------------------------
# CLUSTER OPERATIONS FUNCTIONS
# ----------------------------------------

# Detect cluster information
function detect_cluster() {
    if oc whoami &> /dev/null; then
        # Try to get the cluster URL
        CLUSTER_URL=$(oc whoami --show-server 2>/dev/null)
        
        # Try to get cluster name from console URL
        local console_url=$(oc whoami --show-console 2>/dev/null)
        if [ ! -z "$console_url" ]; then
            CLUSTER_NAME=$(echo "$console_url" | awk -F '.' '{print $3}')
        fi
        
        # If we got cluster information, display it
        if [ ! -z "$CLUSTER_NAME" ] || [ ! -z "$CLUSTER_URL" ]; then
            echo "Current cluster: ${CLUSTER_NAME:-Unknown} (${CLUSTER_URL:-Unknown URL})"
        fi
        
        return 0
    else
        return 1
    fi
}

# Display login instructions
function show_login_instructions() {
    echo ""
    echo "=== NOT LOGGED IN TO OPENSHIFT CLUSTER ==="
    echo "To log in to an OpenShift cluster, use one of the following methods:"
    echo ""
    echo "1. Using credentials:"
    echo "   oc login <cluster_url> -u <username> -p <password>"
    echo ""
    echo "2. Using a token (recommended):"
    echo "   oc login --token=<token> --server=<cluster_url>"
    echo ""
    echo "3. Using the web console:"
    echo "   a. Log in to your OpenShift web console"
    echo "   b. Click on your username in the top right corner"
    echo "   c. Select 'Copy Login Command'"
    echo "   d. Paste and execute the command in your terminal"
    echo ""
    echo "Note: Replace <cluster_url>, <username>, <password>, and <token> with your actual values."
    echo ""
}

# Check OpenShift login status
function check_cluster_connection() {
    echo "Checking OpenShift cluster connection..."
    if ! detect_cluster; then
        if [ "$APPLY" = true ] && [ "$DRY_RUN" = false ]; then
            echo "Error: Not logged in to OpenShift cluster."
            show_login_instructions
            exit 1
        else
            echo "Warning: Not logged in to OpenShift cluster. Continuing in dry run mode only."
            show_login_instructions
            # Force dry run mode if not logged in
            DRY_RUN=true
            return 1
        fi
    else
        echo "Successfully connected to OpenShift cluster as $(oc whoami)"
        return 0
    fi
}

# Check if namespace exists
function check_namespace() {
    local ns="$1"
    if ! oc get namespace "$ns" &> /dev/null; then
        echo "Error: Namespace '$ns' does not exist."
        if confirm_action "Would you like to create the namespace?" "N"; then
            if execute_with_confirmation "oc create namespace $ns" "Creating namespace"; then
                echo "Namespace $ns created successfully."
                return 0
            else
                echo "Error: Failed to create namespace $ns."
                exit 1
            fi
        else
            echo "Cannot proceed without a valid namespace."
            exit 1
        fi
    fi
    return 0
}

# Check which service accounts exist
function check_service_accounts() {
    local ns="$1"
    shift
    local accounts=("$@")
    
    MISSING_SAS=()
    
    for sa in "${accounts[@]}"; do
        if ! oc get serviceaccount "$sa" -n "$ns" &> /dev/null; then
            echo "Warning: Service account '$sa' does not exist in namespace '$ns'."
            MISSING_SAS+=("$sa")
        else
            echo "Service account '$sa' exists in namespace '$ns'."
        fi
    done
    
    # If there are missing service accounts
    if [ ${#MISSING_SAS[@]} -gt 0 ]; then
        echo ""
        echo "The following service accounts do not exist in namespace '$ns':"
        for missing_sa in "${MISSING_SAS[@]}"; do
            echo "  - $missing_sa"
        done
        
        if confirm_action "Would you like to continue anyway? The SCC will be created, but you'll need to create the missing service accounts later." "Y"; then
            echo "Continuing with missing service accounts. You will need to create them later."
            # Display commands to create service accounts
            echo ""
            echo "=== Commands to create missing service accounts ==="
            for missing_sa in "${MISSING_SAS[@]}"; do
                echo "oc create serviceaccount $missing_sa -n $ns"
                echo "# You can validate with: oc create serviceaccount $missing_sa -n $ns --dry-run=client"
                if [ ! -z "$CLUSTER_NAME" ]; then
                    echo "# Cluster: $CLUSTER_NAME"
                fi
            done
            echo ""
            return 0
        else
            echo "Aborted. Please create the missing service accounts and try again."
            exit 1
        fi
    fi
    
    return 0
}

# ----------------------------------------
# SCC MANAGEMENT FUNCTIONS
# ----------------------------------------

# Extract SCC name from YAML file
function extract_scc_name() {
    local file="$1"
    local scc_name=""
    
    # Try different patterns to find the SCC name
    scc_name=$(grep -E "^kind:\s*SecurityContextConstraints" -A 5 "$file" | grep -E "^  name:" | awk '{print $2}')
    
    if [ -z "$scc_name" ]; then
        scc_name=$(grep -E "^name:" "$file" | head -1 | awk '{print $2}')
        
        if [ -z "$scc_name" ]; then
            scc_name=$(grep -E "name:" "$file" | head -1 | awk '{print $2}')
            
            if [ -z "$scc_name" ]; then
                echo "Error: Could not determine SCC name in $file."
                exit 1
            fi
        fi
    fi
    
    echo "$scc_name"
}

# Create namespace-specific SCC file
function create_scc_file() {
    local original_file="$1"
    local original_name="$2"
    local new_name="$3"
    local output_file="$4"
    
    echo "Creating new SCC file: $output_file with SCC name: $new_name"
    
    if confirm_action "Generate namespace-specific SCC file?" "Y"; then
        sed "s/name: $original_name/name: $new_name/" "$original_file" > "$output_file"
        echo "Generated SCC file: $output_file"
        return 0
    else
        echo "Aborted file generation."
        exit 0
    fi
}

# Apply SCC to cluster
function apply_scc() {
    local file="$1"
    local scc_name="$2"
    
    if confirm_action "Apply SCC $scc_name to the cluster?" "Y"; then
        echo "Applying SCC $scc_name to the cluster..."
        if execute_with_confirmation "oc apply -f $file" "Applying SCC to cluster"; then
            echo "SCC $scc_name applied successfully."
            
            # Display current SCC assignments (if any)
            display_scc_assignments "$scc_name"
            return 0
        else
            echo "Error: Failed to apply SCC $scc_name to the cluster."
            return 1
        fi
    else
        echo "Skipped applying SCC to the cluster."
        return 1
    fi
}

# Handle existing service account SCC assignments
function manage_existing_sa_scc() {
    local ns="$1"
    local sa="$2"
    local original_scc="$3"
    local new_scc="$4"
    
    # Check if ClusterRoleBinding for original SCC exists
    if oc get clusterrolebinding system:openshift:scc:$original_scc &> /dev/null; then
        # Use direct jsonpath query to get all service accounts and their namespaces
        local binding_output=$(oc get clusterrolebinding system:openshift:scc:$original_scc -o jsonpath='{range .subjects[*]}{"\nServiceAccount: "}{.name}{" in namespace: "}{.namespace}{end}')
        
        # Check if our specific service account is in the binding
        if echo "$binding_output" | grep -q "ServiceAccount: $sa in namespace: $ns"; then
            # Confirm before removing the original SCC
            if confirm_action "Remove original SCC $original_scc from service account $sa?" "Y"; then
                if execute_with_confirmation "oc adm policy remove-scc-from-user $original_scc system:serviceaccount:$ns:$sa" "Removing original SCC from service account"; then
                    echo "Successfully removed original SCC from $sa."
                else
                    echo "Warning: Failed to remove original SCC $original_scc from service account $sa. Continuing..."
                fi
            else
                echo "Skipped removal of original SCC from $sa."
            fi
        else
            echo "Original SCC $original_scc is not assigned to service account $sa in the ClusterRoleBinding. No removal needed."
        fi
    else
        echo "No ClusterRoleBinding found for SCC $original_scc. No removal needed."
    fi
    
    # Confirm before assigning the new SCC
    if confirm_action "Assign new SCC $new_scc to service account $sa?" "Y"; then
        if execute_with_confirmation "oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa" "Assigning new SCC to service account"; then
            echo "Successfully assigned new SCC to $sa."
        else
            echo "Error: Failed to assign new SCC $new_scc to service account $sa."
        fi
    else
        echo "Skipped assignment of new SCC to $sa."
    fi
}

# Handle future service account SCC pre-assignments
function manage_future_sa_scc() {
    local ns="$1"
    local sa="$2"
    local new_scc="$3"
    
    echo "Service account $sa does not exist yet. SCC binding will be set up in advance."
    
    # Assign the new SCC to the service account anyway (it will take effect when SA is created)
    if confirm_action "Pre-assign new SCC $new_scc to future service account $sa?" "Y"; then
        if execute_with_confirmation "oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa" "Pre-assigning new SCC to future service account"; then
            echo "Successfully pre-assigned new SCC to $sa. Remember to create this service account later."
        else
            echo "Error: Failed to pre-assign new SCC $new_scc to service account $sa."
        fi
    else
        echo "Skipped pre-assignment of new SCC to $sa."
    fi
}
# Remind about missing service accounts
function remind_missing_sas() {
    local ns="$1"
    shift
    local missing=("$@")
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo ""
        echo "REMINDER: The following service accounts need to be created:"
        for missing_sa in "${missing[@]}"; do
            echo "  oc create serviceaccount $missing_sa -n $ns"
            echo "  # You can validate with: oc create serviceaccount $missing_sa -n $ns --dry-run=client"
            if [ ! -z "$CLUSTER_NAME" ]; then
                echo "  # Cluster: $CLUSTER_NAME"
            fi
        done
        echo ""
        echo "The SCC bindings have been created in advance and will take effect once the service accounts exist."
    fi
}

# Display ServiceAccounts assigned to an SCC
function display_scc_assignments() {
    local scc_name="$1"
    
    echo ""
    echo "=== Current ServiceAccounts assigned to SCC: $scc_name ==="
    
    if [ "$DRY_RUN" = true ]; then
        echo "# You can view the current assignments with:"
        echo "oc get clusterrolebinding system:openshift:scc:$scc_name -o jsonpath='{range .subjects[*]}{\"\\nServiceAccount: \"}{.name}{\" in namespace: \"}{.namespace}{end}'"
        if [ ! -z "$CLUSTER_NAME" ]; then
            echo "# Cluster: $CLUSTER_NAME"
        fi
        return 0
    fi
    
    # Check if the clusterrolebinding exists
    if ! oc get clusterrolebinding system:openshift:scc:$scc_name &> /dev/null; then
        echo "No clusterrolebinding found for this SCC yet. This may be normal for a newly created SCC."
        return 0
    fi
    
    # Get and display the assignments using jsonpath
    local result=$(oc get clusterrolebinding system:openshift:scc:$scc_name -o jsonpath='{range .subjects[*]}{"\nServiceAccount: "}{.name}{" in namespace: "}{.namespace}{end}' 2>/dev/null)
    
    if [ -z "$result" ]; then
        echo "No ServiceAccounts are currently assigned to this SCC."
    else
        echo -e "$result"
    fi
    echo ""
}
# Display summary of operations
function display_summary() {
    local ns="$1"
    local accounts="$2"
    local missing="$3"
    local original_scc="$4"
    local new_scc="$5"
    local new_file="$6"
    
    echo ""
    echo "=== Summary of Operations ==="
    echo "Namespace: $ns"
    echo "Service accounts: $accounts"
    if [ ! -z "$missing" ] && [ "$missing" != " " ]; then
        echo "Missing service accounts (need to be created): $missing"
    fi
    echo "Original SCC: $original_scc"
    echo "New SCC: $new_scc"
    echo "Generated file: $new_file"
    if [ ! -z "$CLUSTER_NAME" ]; then
        echo "Target cluster: $CLUSTER_NAME"
    fi
    echo ""
}

# Show commands for dry run
function show_dry_run_commands() {
    local ns="$1"
    local accounts="$2"
    local missing="$3"
    local original_scc="$4"
    local new_scc="$5"
    local new_file="$6"
    
    # Display the content of the generated SCC file
    echo ""
    echo "=== GENERATED SCC YAML CONTENT ==="
    cat "$new_file"
    echo ""
    
    echo "=== DRY RUN MODE - Commands that would be executed: ==="
    echo "# Apply the new SCC to the cluster"
    echo "oc apply -f $new_file"
    echo "# For validation, you can use the dry-run option"
    echo "oc apply -f $new_file --dry-run=client"
    if [ ! -z "$CLUSTER_NAME" ]; then
        echo "# Cluster: $CLUSTER_NAME"
    fi
    
    # Convert space-separated list to array for processing
    IFS=' ' read -r -a account_array <<< "$accounts"
    IFS=' ' read -r -a missing_array <<< "$missing"
    
    # Show commands for removing original SCCs and assigning new SCCs
    for sa in "${account_array[@]}"; do
        # Check if this is a missing service account
        if [[ " ${missing_array[*]} " =~ " ${sa} " ]]; then
            echo "# For service account: $sa (does not exist yet, needs to be created)"
            echo "oc create serviceaccount $sa -n $ns"
            echo "# You can validate with: oc create serviceaccount $sa -n $ns --dry-run=client"
            echo "# Assign new namespace-specific SCC to service account (after creation)"
            echo "oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa"
            echo "# You can validate with: oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa --dry-run=client"
        else
            echo "# For service account: $sa"
            echo "# Remove original SCC from service account"
            echo "oc adm policy remove-scc-from-user $original_scc system:serviceaccount:$ns:$sa"
            echo "# You can validate with: oc adm policy remove-scc-from-user $original_scc system:serviceaccount:$ns:$sa --dry-run=client"
            echo "# Assign new namespace-specific SCC to service account"
            echo "oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa"
            echo "# You can validate with: oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa --dry-run=client"
        fi
        if [ ! -z "$CLUSTER_NAME" ]; then
            echo "# Cluster: $CLUSTER_NAME"
        fi
    done
    
    if [ ! -z "$missing" ] && [ "$missing" != " " ]; then
        echo ""
        echo "# Commands to create missing service accounts:"
        for missing_sa in "${missing_array[@]}"; do
            echo "oc create serviceaccount $missing_sa -n $ns"
            echo "# You can validate with: oc create serviceaccount $missing_sa -n $ns --dry-run=client"
            if [ ! -z "$CLUSTER_NAME" ]; then
                echo "# Cluster: $CLUSTER_NAME"
            fi
        done
    fi
}

# Show commands for manual execution
function show_manual_commands() {
    local ns="$1"
    local accounts="$2"
    local missing="$3"
    local original_scc="$4"
    local new_scc="$5"
    local new_file="$6"
    
    # Display the content of the generated SCC file
    echo ""
    echo "=== GENERATED SCC YAML CONTENT ==="
    cat "$new_file"
    echo ""
    
    echo "=== Commands to apply the SCC and manage service account permissions ==="
    echo "# Apply the new SCC to the cluster"
    echo "oc apply -f $new_file"
    echo "# For validation, you can use the dry-run option"
    echo "oc apply -f $new_file --dry-run=client"
    if [ ! -z "$CLUSTER_NAME" ]; then
        echo "# Cluster: $CLUSTER_NAME"
    fi
    
    # Convert space-separated list to array for processing
    IFS=' ' read -r -a account_array <<< "$accounts"
    IFS=' ' read -r -a missing_array <<< "$missing"
    
    for sa in "${account_array[@]}"; do
        # Check if this is a missing service account
        if [[ " ${missing_array[*]} " =~ " ${sa} " ]]; then
            echo "# For service account: $sa (does not exist yet, needs to be created)"
            echo "oc create serviceaccount $sa -n $ns"
            echo "# You can validate with: oc create serviceaccount $sa -n $ns --dry-run=client"
            echo "# Assign new namespace-specific SCC to service account (after creation)"
            echo "oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa"
            echo "# You can validate with: oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa --dry-run=client"
        else
            echo "# For service account: $sa"
            echo "# Remove original SCC from service account"
            echo "oc adm policy remove-scc-from-user $original_scc system:serviceaccount:$ns:$sa"
            echo "# You can validate with: oc adm policy remove-scc-from-user $original_scc system:serviceaccount:$ns:$sa --dry-run=client"
            echo "# Assign new namespace-specific SCC to service account"
            echo "oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa"
            echo "# You can validate with: oc adm policy add-scc-to-user $new_scc system:serviceaccount:$ns:$sa --dry-run=client"
        fi
        if [ ! -z "$CLUSTER_NAME" ]; then
            echo "# Cluster: $CLUSTER_NAME"
        fi
    done
}

# Process SCC assignments for service accounts
function process_scc_assignments() {
    local namespace="$1"
    local new_scc="$2"
    local original_scc="$3"
    
    # Process each service account
    for sa in "${SERVICE_ACCOUNTS[@]}"; do
        if [[ " ${MISSING_SAS[*]} " =~ " ${sa} " ]]; then
            manage_future_sa_scc "$namespace" "$sa" "$new_scc"
        else
            manage_existing_sa_scc "$namespace" "$sa" "$original_scc" "$new_scc"
        fi
    done
    
    # Remind about missing service accounts if any
    remind_missing_sas "$namespace" "${MISSING_SAS[@]}"
    
    # Display current SCC assignments
    display_scc_assignments "$new_scc"
}

# ----------------------------------------
# MAIN SCRIPT
# ----------------------------------------

# Check if oc command is available
check_command "oc"

# Parse command line arguments
while getopts "n:s:f:ady" opt; do
    case $opt in
        n) NAMESPACE="$OPTARG" ;;
        s) SERVICE_ACCOUNTS+=("$OPTARG") ;;
        f) SCC_FILE="$OPTARG" ;;
        a) APPLY=true ;;
        d) DRY_RUN=true; EXPLICIT_DRY_RUN=true ;;
        y) YES_TO_ALL=true ;;
        *) show_usage ;;
    esac
done

# Validate required arguments
if [ -z "$NAMESPACE" ] || [ ${#SERVICE_ACCOUNTS[@]} -eq 0 ] || [ -z "$SCC_FILE" ]; then
    echo "Error: Missing required arguments."
    show_usage
fi

# Check if the SCC file exists
if [ ! -f "$SCC_FILE" ]; then
    echo "Error: SCC file '$SCC_FILE' does not exist."
    exit 1
fi

# Check OpenShift login status
check_cluster_connection

# Only check namespace and service accounts if we're connected to the cluster
if [ "$DRY_RUN" = false ]; then
    check_namespace "$NAMESPACE"
    check_service_accounts "$NAMESPACE" "${SERVICE_ACCOUNTS[@]}"
fi

# Create output directory if it doesn't exist
OUTPUT_DIR="$(dirname "$SCC_FILE")/namespace-specific-sccs"
mkdir -p "$OUTPUT_DIR"
echo "Created output directory: $OUTPUT_DIR"

# Extract the original SCC name from the YAML file
ORIGINAL_SCC_NAME=$(extract_scc_name "$SCC_FILE")
echo "Detected original SCC name: $ORIGINAL_SCC_NAME"

# Get the filename without path
FILENAME=$(basename "$SCC_FILE")
BASE_NAME="${FILENAME%.*}"
EXTENSION="${FILENAME##*.}"

# New SCC name with namespace suffix
NEW_SCC_NAME="${ORIGINAL_SCC_NAME}-${NAMESPACE}"
NEW_FILENAME="${BASE_NAME}-${NAMESPACE}.${EXTENSION}"
NEW_FILE="$OUTPUT_DIR/$NEW_FILENAME"

# Create the new file with updated name
create_scc_file "$SCC_FILE" "$ORIGINAL_SCC_NAME" "$NEW_SCC_NAME" "$NEW_FILE"

# Convert arrays to space-separated strings for easier function passing
SA_LIST="${SERVICE_ACCOUNTS[*]}"
MISSING_LIST="${MISSING_SAS[*]}"

# Display summary of operations
display_summary "$NAMESPACE" "$SA_LIST" "$MISSING_LIST" "$ORIGINAL_SCC_NAME" "$NEW_SCC_NAME" "$NEW_FILE"

# Display operation mode
if [ "$APPLY" = true ] && [ "$YES_TO_ALL" = true ]; then
    echo "Running in fully automated mode (-a -y)"
elif [ "$APPLY" = true ]; then
    echo "Running in apply mode with confirmations (-a)"
elif [ "$YES_TO_ALL" = true ]; then
    echo "Running in display mode, skipping confirmations (-y)"
else
    echo "Running in display mode with confirmations (default)"
fi

# Always show commands first
show_manual_commands "$NAMESPACE" "$SA_LIST" "$MISSING_LIST" "$ORIGINAL_SCC_NAME" "$NEW_SCC_NAME" "$NEW_FILE"

# Determine if we should apply changes
if [ "$APPLY" = true ]; then
    if [ "$DRY_RUN" = false ]; then
        # Apply the SCC to the cluster
        if apply_scc "$NEW_FILE" "$NEW_SCC_NAME"; then
            # Process SCC assignments
            process_scc_assignments "$NAMESPACE" "$NEW_SCC_NAME" "$ORIGINAL_SCC_NAME"
        fi
    else
        echo "Dry run mode specified. No changes will be applied."
    fi
else
    echo "To apply these changes, run the script again with the -a flag."
fi

echo "Operation completed successfully."