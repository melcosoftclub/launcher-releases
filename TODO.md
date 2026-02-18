1. [ ] Add GitHub Action to validate `latest.json`.
2. [ ] `latest.json` schema validation.
3. [ ] Automated SHA256 verification.

# Updater Logic and Tasks

## 1. Data and folders

### 1.1. Local state file

C:\ProgramData\Melcosoft\launcher_manifest.json contains:

- launcher_version
- schema_version
- install_dir
- updated_at_utc
- pending_update
- pending_version
- pending_package_path
- pending_sha256
- update_mandatory
- update_state: up_to_date | available | downloaded | applying | failed
- last_update_error
- backup_path: C:\ProgramData\Melcosoft\Releases\{pending_version}\backup\
- installs {}

### 1.2. Update staging root

C:\ProgramData\Melcosoft\Releases\{version}\

- package.zip
- package_manifest.json (extracted from zip)
- backup\ (created during apply)
- logs\updater.log (optional)

### 1.3. Update package format (dynamic)

package.zip contains a manifest.json describing copy/move rules + config.env policy. The updater applies whatever the manifest describes.

## 2. Server side contract (minimal)

### 2.1. latest.json

GET /launcher/latest returns:

- latest_version
- sha256
- download_url
- mandatory (true/false)
- release_notes (optional)

### 2.2. package.zip

Package is served at download_url as package.zip

## 3. Client side check and state transitions

### 3.1. When to check

- On launcher start (before initial sync)
- Optionally periodically in backend (or extension), but only “stage state”, do not apply while running

### 3.2. Check logic

1. Read launcher_manifest.json
2. Call /launcher/latest
3. If latest_version == launcher_version:
   - set update_state="up_to_date"
   - pending_update=false
   - clear pending\_\* fields
   - save manifest
4. If latest_version != launcher_version:
   - set pending_update=true
   - pending_version=latest_version
   - pending_sha256=sha256
   - update_mandatory=mandatory
   - update_state="available"
   - last_update_error=null
   - backup_path = "C:\ProgramData\Melcosoft\Updates\{pending_version}\backup\"
   - save manifest
   - show notification in Playnite:
     - optional: “Update available” with buttons Update now / Later
     - mandatory: “Update required” with Update now only

## 4. Download and verify (staging)

### 4.1. Trigger download

Download can be triggered by:

- user clicks “Update now”
- or automatically after marking available (optional)
- or on next launch when pending_update=true and package not downloaded

### 4.2. Download steps

1. Create folder: C:\ProgramData\Melcosoft\Updates\{pending_version}\
2. Download to: package.zip
3. Verify sha256 == pending_sha256
4. Extract only the package manifest.json (from inside zip) into:
   - C:\ProgramData\Melcosoft\Updates\{pending_version}\package_manifest.json
5. Set in launcher_manifest.json:
   - pending_package_path = full path to package.zip
   - update_state="downloaded"
   - last_update_error=null
   - save manifest
6. If download or verify fails:
   - update_state="failed"
   - last_update_error="download_failed" or "sha_mismatch"
   - save manifest
   - show error notification

## 5. Apply conditions

### 5.1. Apply is allowed when:

- pending_update == true
- update_state == "downloaded"
- pending_package_path exists and sha verified

### 5.2. When to apply

#### A. User clicks “Update now”

1. Ensure package is downloaded+verified (if not, perform section 4 first)
2. Launch updater elevated with args:
   - --apply
   - --version {pending_version}
   - --package "{pending_package_path}"
   - --install-dir "{install_dir}"
3. Exit Playnite immediately

#### B. User clicks “Later”

- Do nothing now
- On next launcher start, BEFORE sync:
  - if pending_update && update_state=="downloaded":
    - launch updater elevated
    - exit Playnite

#### C. Mandatory update

- Block sync and normal UI until apply succeeds
- Auto-run updater when downloaded or after user clicks Update now

## 6. Updater (Melcosoft.Updater.exe) apply logic

### 6.1. Preconditions

1. Acquire global mutex (single update at a time)
2. Load launcher_manifest.json and validate:
   - pending_version matches args
   - pending_package_path exists
   - install_dir exists
3. Set manifest:
   - update_state="applying"
   - last_update_error=null
   - updated_at_utc=now
   - save

### 6.2. Read package manifest

1. Open package.zip
2. Read manifest.json inside zip (package manifest)
3. Validate it contains a list of operations (filesets) and config.env policy
4. Optionally validate package version matches pending_version

### 6.3. Stop backend service

1. sc stop Melcosoft
2. Wait until STOPPED
3. If still running:
   - kill backend process as last resort
4. If cannot stop:
   - set manifest update_state="failed", last_update_error="service_stop_failed"
   - save and exit updater with failure

### 6.4. Create backup folder

1. Ensure backup_path exists:
   C:\ProgramData\Melcosoft\updates\{version}\backup\
2. Backup these targets if they exist:
   - {install_dir}\MelcosoftBackend\ (entire directory)
   - {install_dir}\MelcosoftService.exe
   - {install_dir}\Playnite.DesktopApp.exe
   - {install_dir}\Themes\ (only if you overwrite it)
   - {install_dir}\Localization\ (only if you overwrite it)
   - %AppData%\Playnite\Extensions\MelcosoftLauncher\ (your extension folder only)
3. Backup method:
   - prefer rename/move into backup\ (fast)
   - fallback to copy if move fails

### 6.5. Apply update operations from package manifest

For each operation in package manifest:

1. Determine destination root:
   - install_dir
   - appdata_roaming_playnite
   - programdata_melcosoft
2. Determine full destination path
3. Apply mode:
   - overwrite: copy files over existing
   - merge: copy files, keep existing extras
   - replace_dir: remove/rename existing dir then copy dir fresh
4. Never touch user data folders unless explicitly declared:
   - never overwrite Playnite databases
   - never overwrite ExtensionsData
   - never overwrite entire Extensions folder, only your folder(s)

### 6.6. config.env policy (merge-preserve default)

If package manifest contains config.env payload:

1. If policy == "overwrite":
   - replace C:\ProgramData\Melcosoft\config.env fully
2. Else (default merge-preserve):
   - read existing config.env (if exists)
   - read new config.env (from package)
   - output merged:
     - keep existing keys if present
     - add any new keys from package
     - optionally update keys only if package marks them force=true
   - write back to C:\ProgramData\Melcosoft\config.env

### 6.7. Manifest migrations (launcher_manifest schema)

If package includes migration instructions or schema_version bump:

1. Load current launcher_manifest.json
2. Apply migration functions (preserve installs mapping)
3. Save updated launcher_manifest.json

### 6.8. Start backend service and healthcheck

1. sc start Melcosoft
2. Wait until RUNNING
3. Healthcheck:
   - call backend /health locally
4. If healthcheck fails:
   - rollback (section 7)
   - mark failed
   - exit updater with failure

### 6.9. Finalize success

1. Update launcher_manifest.json:
   - launcher_version = pending_version
   - pending_update=false
   - pending_version=null
   - pending_package_path=null
   - pending_sha256=null
   - update_mandatory=false
   - update_state="up_to_date"
   - last_update_error=null
   - updated_at_utc=now
   - save
2. Relaunch Playnite:
   - start "{install_dir}\Playnite.DesktopApp.exe"
3. Exit updater success

## 7. Rollback logic (if apply fails after backup)

### 7.1. When rollback triggers

- Any failure after backups were made (copy failures, service start fail, healthcheck fail)

### 7.2. Rollback steps

1. sc stop Melcosoft (best effort)
2. Restore from backup_path:
   - restore {install_dir}\MelcosoftBackend\
   - restore {install_dir}\MelcosoftService.exe
   - restore {install_dir}\Playnite.DesktopApp.exe and any overwritten dirs
   - restore %AppData%\Playnite\Extensions\MelcosoftLauncher\
3. sc start Melcosoft (best effort)
4. Update launcher_manifest.json:
   - update_state="failed"
   - last_update_error = specific error code
   - pending_update stays true (optional) or set false (recommended set false until next check)
   - save
5. Optionally relaunch Playnite anyway and show “Update failed, rolled back” notification

## 8. Notifications

### 8.1. On available

- Optional: toast with Update now / Later
- Mandatory: modal/toast with Update now only, block sync

### 8.2. On downloaded

- toast: “Update ready, will apply on next restart” + Update now

### 8.3. On failure

- toast: “Update failed, rolled back” + link to logs

## 9. Ownership boundaries (who does what)

- Playnite extension:
  - shows notifications and buttons
  - triggers download
  - triggers updater launch
  - exits Playnite

- Pre-launch Playnite hook (your Playnite fork):
  - before sync: if pending_update && update_state=="downloaded": launch updater and exit

- Backend (optional role):
  - can periodically check latest version and stage state, but must not apply updates itself

- Updater:
  - only component that stops service + overwrites files + rollbacks + restarts

## 10. Error codes (use these strings in last_update_error)

- download_failed
- sha_mismatch
- manifest_invalid
- service_stop_failed
- file_copy_failed
- service_start_failed
- healthcheck_failed
- rollback_failed
