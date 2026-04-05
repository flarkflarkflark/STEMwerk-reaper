# STEMwerk v2.2.1.4

Hotfix release focused on stability and packaging consistency.

Included:
- Fixes Lua top-level local pressure in STEMwerk.lua.
- Improves Linux setup by preferring a managed, supported runtime before unsupported system Python.
- Keeps Linux setup free of privileged package-manager fallbacks.
- Enforces version consistency across VERSION, ReaPack metadata, script headers, UI strings, and CI.
- Keeps macOS setup and processing fixes from the previous stabilization round.
- Maintains working ReaPack/update flow across tested systems.

Validated flows:
- Windows: working
- macOS: working
- Linux / EndeavourOS: working
- ReaPack update + setup + processing: working on MacBookPro11,2 with EndeavourOS

### 📦 Download Options

#### 🛜 Online Installers (Standard)
The assets listed below under "**Assets**" are **EXCLUSIVELY for online installation**.
- These files are small (~275KB - 132MB).
- They **require an active internet connection** during installation to download AI models and runtime dependencies.
- Use these only if your computer is connected to the internet.

#### 📵 Offline Installers (Full Bundles)
For production machines **without internet access**, download the specific installer for your hardware using the direct links below:

| GPU Backend | Fast Model | Quality Model | 6-Stem Model | All Models |
| :--- | :--- | :--- | :--- | :--- |
| **NVIDIA (CUDA)** | [Download](https://drive.google.com/file/d/1RSzvOYbDva6-1tImeBscC-EMEYVqeJc0/view?usp=drive_link) (~2.8GB) | [Download](https://drive.google.com/file/d/1jo-JNEFsh3s3IDU0MZxKwQCKxAJhQjqK/view?usp=drive_link) (~3GB) | [Download](https://drive.google.com/file/d/1FGo9kDRy0D4_yBuQzmG8L1nyGCM2uzil/view?usp=drive_link) (~2.7GB) | [Download](https://drive.google.com/file/d/1OtCKxR2sTVGiSpCGD3n65uZhKIvRrG9k/view?usp=drive_link) (~3.1GB) |
| **AMD/Intel (DML)** | [Download](https://drive.google.com/file/d/1URoEpT51VQs1cmadxbvGagnFo45hzAC-/view?usp=drive_link) (~560MB) | [Download](https://drive.google.com/file/d/1kOr5boE_3XS4T1WXvTKs3_AJUvhalFEE/view?usp=drive_link) (~780MB) | [Download](https://drive.google.com/file/d/1q1pzMhte1CC7Vuh0Ufq2k0fCV8ZYXnmD/view?usp=drive_link) (~540MB) | [Download](https://drive.google.com/file/d/1q9LG63IqQwpj3tG2QqsjrXqOJJ9FG7EE/view?usp=drive_link) (~900MB) |
| **CPU Only** | [Download](https://drive.google.com/file/d/17RHCrAWOUdDbGJ1HbmHn9UYfb7OUIxlZ/view?usp=drive_link) (~530MB) | [Download](https://drive.google.com/file/d/1fGV0j35Xy_elNhJkSs8R0Ygg1wOlAZoO/view?usp=drive_link) (~750MB) | [Download](https://drive.google.com/file/d/127BSTCICiwwsr2ocovlYLi9bStiEDDuV/view?usp=drive_link) (~500MB) | [Download](https://drive.google.com/file/d/1lwSIsEk6rw-aO8Q2jzte6W4C5MqROkCm/view?usp=drive_link) (~870MB) |

*Full folder access for checksums/ratios: [Google Drive Folder](https://drive.google.com/drive/folders/1FuVnhxPI3MAKnKVE_4UTaoT1fHdnsv-h?usp=drive_link)*

*Note: NVIDIA installers include the full CUDA runtime libraries.*

---

Model bundles contained in the folder:
- Fast, Quality, 6-Stem, All-Models
- Specific builds for NVIDIA (CUDA), AMD/Intel (DirectML), and CPU-only.

Notes:
- These installers are self-contained and require no internet for runtime or model installation.
- Model packs (~75MB - ~421MB) are also available as separate ZIP files for existing installations.
