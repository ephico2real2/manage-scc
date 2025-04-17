# OpenShift SCC Management Script - Comprehensive User Guide

## Introduction

This guide explains how to use the OpenShift SCC Management Script to create namespace-specific Security Context Constraints (SCCs) across multiple namespaces in an OpenShift cluster. The script helps you manage security policies independently for different environments without conflicts.

## Overview

The script solves several common challenges:

- Creates namespace-specific versions of SCCs (e.g., `ibm-sccm-scc` → `ibm-sccm-scc-approd`)
- Applies these SCCs to your OpenShift cluster
- Manages service account permissions (removing original SCCs and assigning new ones)
- Handles non-existent service accounts by pre-configuring permissions
- Provides interactive confirmations and detailed dry run options

## Prerequisites

- OpenShift CLI (`oc`) installed and available in your PATH
- **Cluster-admin rights** on the OpenShift cluster
  - Managing SCCs requires elevated privileges as these are cluster-scoped resources
  - You must have permissions to create and modify SCCs and assign them to service accounts
  - Regular users without cluster-admin cannot perform these operations
- Access to the SCC YAML files you want to modify

## Installation

1. Save the script to a file (e.g., `manage-scc.sh`)
2. Make it executable:
   ```bash
   chmod +x manage-scc.sh
   chmod +x grant-existing-scc.sh
   ```

## Basic Usage

### manage-scc.sh
The main script requires three main parameters:
- Namespace (`-n`)
- Service account(s) (`-s`)
- SCC YAML file (`-f`)

```bash
./manage-scc.sh -n <namespace> -s <serviceaccount1> [-s <serviceaccount2> ...] -f <scc_yaml_file> [-a] [-d] [-y]
```

### grant-existing-scc.sh
This script allows you to grant existing SCCs to service accounts without creating new namespace-specific SCCs. Use this when you want to grant an existing SCC directly.

```bash
./grant-existing-scc.sh -n <namespace> -s <serviceaccount> -e <scc_name> [-a] [-y]
```

Options:
| Option | Description | Required |
|--------|-------------|----------|
| `-n` | Namespace name | Yes |
| `-s` | Service account name | Yes |
| `-e` | Existing SCC name to grant | Yes |
| `-a` | Apply changes (required for making changes) | No |
| `-y` | Skip all confirmation prompts | No |

Example usage:
```bash
# Check what would happen (dry run)
./grant-existing-scc.sh -n approd -s demo-a -e privileged

# Apply the change
./grant-existing-scc.sh -n approd -s demo-a -e privileged -a

# Apply without confirmation
./grant-existing-scc.sh -n approd -s demo-a -e privileged -a -y
```
## Operation Modes

The script can run in several modes:

1. **Display Mode (Default)**: Shows what would be done, with confirmations
   ```bash
   ./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml
   ```

2. **Display Mode (No Confirmations)**: Shows what would be done, without confirmations
   ```bash
   ./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml -y
   ```

3. **Apply Mode (With Confirmations)**: Applies changes with confirmations
   ```bash
   ./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml -a
   ```

4. **Fully Automated Mode**: Applies changes without confirmations
   ```bash
   ./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml -a -y
   ```

5. **Dry Run Mode**: Shows exactly what would be done but never applies changes
   ```bash
   ./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml -d
   ```

## Detailed Examples

### 1. Dry Run Mode with approd Namespace

```bash
# Create new project
oc new-project approd
```

```bash
./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml -d
```

Dry run mode is perfect for validation before making changes:
- Generates the namespace-specific SCC file (`ibm-sccm-scc-approd.yaml`)
- Shows all commands that would be executed with their `--dry-run=client` equivalents
- Displays cluster context information
- Shows the generated YAML content for verification
- Won't apply changes even if prompted

Example output:
```
=== GENERATED SCC YAML CONTENT ===
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: ibm-sccm-scc-approd
  ...

=== DRY RUN MODE - Commands that would be executed: ===
# Apply the new SCC to the cluster
oc apply -f /path/to/namespace-specific-sccs/ibm-sccm-scc-approd.yaml
# For validation, you can use the dry-run option
oc apply -f /path/to/namespace-specific-sccs/ibm-sccm-scc-approd.yaml --dry-run=client
# Cluster: my-cluster

# For service account: app-sa
# Remove original SCC from service account
oc adm policy remove-scc-from-user ibm-sccm-scc system:serviceaccount:approd:app-sa
# You can validate with: oc adm policy remove-scc-from-user ibm-sccm-scc system:serviceaccount:approd:app-sa --dry-run=client
# Assign new namespace-specific SCC to service account
oc adm policy add-scc-to-user ibm-sccm-scc-approd system:serviceaccount:approd:app-sa
# You can validate with: oc adm policy add-scc-to-user ibm-sccm-scc-approd system:serviceaccount:approd:app-sa --dry-run=client
# Cluster: my-cluster

Dry run mode specified. No changes will be applied.
```

### 2. Managing Multiple Service Accounts in approd Namespace

```bash
./manage-scc.sh -n approd -s app-sa -s db-sa -s monitoring-sa -f /path/to/ibm-sccm-scc.yaml -a
```

This command:
- Creates a namespace-specific SCC (`ibm-sccm-scc-approd`)
- Applies it to the cluster after confirmation
- Manages SCC assignments for all three service accounts
- Shows current SCC assignments after applying changes

### 3. Cross-Namespace Examples

For different namespaces:

```bash
# For production namespace
./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml -a

# For another production namespace
./manage-scc.sh -n bpprod -s app-sa -f /path/to/ibm-sccm-scc.yaml -a

# For test namespace
./manage-scc.sh -n bptest -s app-sa -f /path/to/ibm-sccm-scc.yaml -a
```

This creates three separate namespace-specific SCCs:
- `ibm-sccm-scc-approd`
- `ibm-sccm-scc-bpprod`
- `ibm-sccm-scc-bptest`

Each namespace gets its own SCC with its own permissions, allowing for independent management without conflicts.

### 4. Non-Interactive Dry Run for approd Namespace

```bash
./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml -d -y
```

This combines dry run mode with skipping confirmations:
- Shows all commands without executing them
- Skips all confirmation prompts
- Never switches to apply mode
- Useful for automation or scripting validation steps

## Interactive Features

The script provides interactive prompts for each major step:

1. **Generating SCC Files**:
   ```
   Generate namespace-specific SCC file? [Y/n]:
   ```

2. **Applying to Cluster**:
   ```
   Apply SCC ibm-sccm-scc-approd to the cluster? [Y/n]:
   ```

3. **Managing Service Account Permissions**:
   ```
   Remove original SCC ibm-sccm-scc from service account app-sa? [Y/n]:
   Assign new SCC ibm-sccm-scc-approd to service account app-sa? [Y/n]:
   ```

4. **Command Execution**:
   ```
   → Applying SCC to cluster
     Command: oc apply -f /path/to/ibm-sccm-scc-approd.yaml
     Cluster: my-cluster
   Execute this command? [Y/n]:
   ```

## Handling Non-Existent Service Accounts

When working with service accounts that don't exist yet:

```bash
./manage-scc.sh -n approd -s future-sa -f /path/to/ibm-sccm-scc.yaml -a
```

The script will:
1. Detect that the service account doesn't exist
2. Warn you and ask if you want to continue
3. Apply the SCC to the cluster
4. Pre-configure SCC bindings for the future service account
5. Provide reminder commands to create the service account later:

```
REMINDER: The following service accounts need to be created:
  oc create serviceaccount future-sa -n approd
  # You can validate with: oc create serviceaccount future-sa -n approd --dry-run=client
  # Cluster: my-cluster

The SCC bindings have been created in advance and will take effect once the service accounts exist.
```

## Cluster Detection

The script automatically detects which cluster you're working with:

```
Checking OpenShift cluster connection...
Current cluster: my-cluster (https://api.my-cluster.example.com:6443)
Successfully connected to OpenShift cluster as admin
```

## Advanced Features

### Displaying Current SCC Assignments

After applying changes, the script shows the service accounts assigned to the new SCC:

```
=== Current ServiceAccounts assigned to SCC: ibm-sccm-scc-approd ===
ServiceAccount: app-sa in namespace: approd
ServiceAccount: db-sa in namespace: approd
```

### Operation Mode Indicator

The script displays which operation mode it's running in:

```
Running in apply mode with confirmations (-a)
```

### Validation Commands

For each operation, the script shows how to validate it using the `--dry-run=client` flag:

```
# You can validate with: oc apply -f file.yaml --dry-run=client
```

## Best Practices

1. **Verify Cluster-Admin Rights**: Ensure you have proper permissions before running the script
   ```bash
   oc auth can-i create scc
   oc auth can-i update scc
   oc auth can-i use scc
   ```

2. **Start with Dry Run**: Always use `-d` flag first to validate changes before applying them.
   ```bash
   ./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml -d
   ```

3. **Consistent Naming**: Use consistent namespace naming conventions across environments (e.g., `approd`, `bpprod`, `bptest`).

4. **Multiple Service Accounts**: Include all service accounts that need the same SCC in a single command.
   ```bash
   ./manage-scc.sh -n approd -s app-sa -s db-sa -s monitoring-sa -f /path/to/ibm-sccm-scc.yaml -a
   ```

5. **Pre-Configure for CI/CD**: For new deployments, create SCCs and pre-configure permissions before creating service accounts.

6. **Automation**: Use the `-y` flag for CI/CD pipelines to skip interactive prompts.
   ```bash
   ./manage-scc.sh -n approd -s app-sa -f /path/to/ibm-sccm-scc.yaml -a -y
   ```

## Troubleshooting

1. **Permission Denied Errors**
   - Ensure you have cluster-admin role
   - Run `oc whoami --show-permissions` to check your permissions
   - Contact your cluster administrator if you need elevated privileges

2. **SCC Assignment Issues**
   - Verify the service account exists: `oc get sa <sa-name> -n <namespace>`
   - Check current SCC assignments: `oc get scc -o wide | grep <sa-name>`

3. **Cluster Connection Problems**
   - Use `oc status` to check your connection
   - Follow the login instructions provided by the script

## Summary

This script provides a robust solution for managing namespace-specific SCCs across multiple OpenShift namespaces like approd, bpprod, and bptest. By creating dedicated SCCs for each namespace with appropriate service account bindings, you can maintain clear security boundaries and manage policies independently without conflicts.

The dry run mode with `-d` flag makes it easy to validate your changes before applying them, providing a safe way to manage SCC configurations in production environments. Remember that cluster-admin rights are required for all operations involving SCCs, as these are cluster-scoped resources that affect OpenShift's security posture.