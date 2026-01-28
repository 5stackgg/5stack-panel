# Tailscale Setup Automation

## Overview

The `game-node-server-setup.sh` script has been updated to automate Tailscale configuration using the Tailscale OAuth API, reducing manual setup steps from 11 to 2.

## What Changed

### Before (Manual Process - 11 Steps)
1. Manually set up ACL rules for "fivestack" tag
2. Manually set up auto-approver routes
3. Navigate to admin console to generate auth key
4. Select "Pre Approved" option
5. Copy/paste auth key
6. Navigate to DNS page to find tailnet name
7. Copy/paste network name
8. Navigate to OAuth settings
9. Copy/paste OAuth credentials
10. Wait for node to appear
11. Copy/paste node IP address

### After (Automated Process - 2 Steps)
1. **One-time**: Create OAuth client with required scopes
2. **Per-node**: Provide OAuth credentials → script automates everything else

## New Architecture

### Helper Script: `utils/tailscale-api.sh`

Contains five main functions:

- `get_oauth_token()` - Authenticates with Tailscale API using client credentials
- `create_auth_key()` - Generates pre-approved auth key with fivestack tag
- `get_tailnet_info()` - Retrieves tailnet DNS name automatically
- `update_acl_for_fivestack()` - Configures ACL rules and auto-approvers programmatically
- `wait_for_device_and_get_ip()` - Polls API for new device and retrieves its IP

### Updated Script: `game-node-server-setup.sh`

The script now:
1. Installs Tailscale
2. Prompts for OAuth credentials (one-time setup)
3. Authenticates with Tailscale API
4. Automatically retrieves tailnet information
5. Configures ACL rules (10.42.0.0/16 subnet)
6. Generates pre-approved auth key
7. Installs K3S with Tailscale integration
8. Polls for node to appear and retrieves IP
9. Saves all configuration automatically

## OAuth Client Setup

Create an OAuth client at: https://login.tailscale.com/admin/settings/oauth

### Required Scopes
- ✓ `auth_keys` (write) - Create authentication keys
- ✓ `devices` (read) - List and retrieve device information
- ✓ `policy_file` (write) - Update ACL configuration
- ✓ `dns` (read) - Retrieve tailnet DNS information

### Required Tag
- ✓ `fivestack` - Tag for game node devices

## Benefits

1. **Reduced friction**: 11 manual steps → 2 steps
2. **Fewer errors**: No manual copy/paste mistakes
3. **Faster setup**: No navigating multiple admin pages
4. **Consistent configuration**: ACL rules applied programmatically
5. **Better UX**: Clear progress indicators and error messages
6. **Reusability**: OAuth client works for multiple nodes

## API Documentation

- [Tailscale API Documentation](https://tailscale.com/kb/1101/api)
- [OAuth Clients Guide](https://tailscale.com/kb/1215/oauth-clients)
- [Auth Keys Documentation](https://tailscale.com/kb/1085/auth-keys)
- [Tailscale API Interactive Docs](https://api.tailscale.com/api/v2)

## Files Modified

- ✅ **Created**: `utils/tailscale-api.sh` - Tailscale API helper functions
- ✅ **Modified**: `utils/utils.sh` - Added source for tailscale-api.sh
- ✅ **Modified**: `game-node-server-setup.sh` - Replaced manual flow with automated OAuth flow
- ✅ **Removed**: ASCII art files (tag-setup-ascii, auto-approvers-ascii, pre-approved-ascii, auth-key-ascii)

## Fallback Behavior

If the automatic IP detection times out (5 minutes), the script falls back to manual entry, ensuring the setup can complete even if there are API issues.

## Error Handling

The script includes robust error handling:
- OAuth authentication failures
- API timeout scenarios
- Missing or invalid credentials
- ACL configuration errors (warns but continues)
- Device polling timeout (falls back to manual entry)

## Testing

To test the new setup:

1. Create a fresh OAuth client with required scopes
2. Run `./game-node-server-setup.sh` on a VM
3. Verify automated steps complete successfully
4. Check Tailscale dashboard for proper configuration
5. Verify K3S is running with Tailscale VPN active
