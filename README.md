# Melcosoft Launcher Releases

This repository contains the **release artifacts** for the **Melcosoft Launcher** updater system.

It is the single source of truth for:

- `latest.json` (release metadata).
- Versioned release folders (e.g. `0.0.2/`).
- `package.zip` files used by the launcher auto-updater.

The launcher backend periodically checks this repository (via HTTPS) to determine whether a new version is available.

---

### 📦 Repository Structure

```
.
├── latest.json
├── 0.0.2/
│ └── package.zip
├── 0.0.3/
│ └── package.zip
└── ...
```

Each version folder must contain exactly one `package.zip`. No other files are required.

---

### 🌐 Public Endpoints

Hosted at: https://launcher-releases.melc.cc

The launcher fetches:

- Latest metadata: https://launcher-releases.melc.cc/latest.json
- Version package: https://launcher-releases.melc.cc/<version>/package.zip

Example: https://launcher-releases.melc.cc/0.0.2/package.zip

### 🧾 latest.json Structure

Example:

```json
{
  "latest_version": "0.0.2",
  "min_supported_version": "0.0.1",
  "sha256": "fce36266aeda06bdab606fe9eb17719335214dff2578c34f66976a0285eea406",
  "download_url": "https://launcher-releases.melc.cc/0.0.2/package.zip",
  "mandatory": false,
  "release_notes": "Initial launcher updater test and release."
}
```

#### Fields

- `latest_version [str]`: The newest available launcher bundle version.
- `min_supported_version [str]`: The minimum launcher version allowed to update. If a client version is lower than this, it must be blocked and forced to update.
- `sha256 [str]`: SHA256 hash of `package.zip`. Used by the launcher backend to verify integrity after download.
- `download_url [str]`: Absolute HTTPS URL to the package.
- `mandatory [bool]`: If true, the launcher must force update before continuing.
- `release_notes [str]`: Optional user-facing text shown in update notification.

### 🚀 How To Publish a New Version

#### Step 1: Build the Update Package

Create package.zip under a specific <version> folder.

Important:

- The version folder name must match the version string exactly.
- Versions must be immutable.
- Never modify an existing version directory.

Example: `1.0.3/package.zip`

#### Step 2: Compute SHA256

On your local machine:

```bash
sha256sum package.zip
```

Copy the hash.

#### Step 3: Add Version Folder

1. Create a new folder in this repo: `/1.0.3/package.zip`
2. Commit the new folder.

#### Step 4: Update latest.json

Update:

- `latest_version`
- `min_supported_version` (if needed)
- `sha256`
- `download_url`
- `mandatory`
- `release_notes`

Example:

```json
{
  "latest_version": "1.0.3",
  "min_supported_version": "0.9.0",
  "sha256": "NEW_SHA256_HASH",
  "download_url": "https://launcher-releases.melc.cc/1.0.3/package.zip",
  "mandatory": false,
  "release_notes": "Bug fixes and backend improvements."
}
```

#### Step 5: Push to GitHub

```bash
git add .
git commit -m "Release 1.0.3"
git push
```

The server is configured to automatically pull changes. No manual deployment required.

### 🔒 Versioning Rules

- Version folders are immutable.
- Never edit an old package.
- Only update `latest.json` to point to a new version.
- Always verify SHA256 before committing.
- `latest.json` must always remain valid JSON.

### 🔄 Rollback Procedure

To rollback to a previous version:

1. Edit `latest.json`.
2. Set `latest_version` to a previous folder.
3. Update sha256 accordingly.
4. Push.

No other changes required.

### 🧠 Best Practices

- Use semantic versioning (MAJOR.MINOR.PATCH).
- Keep release notes concise.
- Only set mandatory: true for breaking changes.
- Do not delete old versions.
- Do not reuse version numbers.

---

Maintained by **Melcosoft**.
