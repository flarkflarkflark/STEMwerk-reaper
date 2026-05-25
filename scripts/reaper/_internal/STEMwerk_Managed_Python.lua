return {
  enabled = true,
  version = "3.12.13",
  release = "20260408",
  supportedRange = "3.10-3.12",
  entries = {
    linux_x86_64 = {
      platform = "linux",
      arch = "x86_64",
      libc = "glibc",
      url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260408/cpython-3.12.13%2B20260408-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz",
      sha256 = "ddd48f521f79395d9b8b094d34a86d7ec86772ab66c96b0de65a3b561ea7cf10",
      archiveType = "tar.gz",
      expectedPython = "bin/python3",
    },
    macos_x86_64 = {
      platform = "macos",
      arch = "x86_64",
      url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260408/cpython-3.12.13%2B20260408-x86_64-apple-darwin-install_only_stripped.tar.gz",
      sha256 = "1fee0596ba791fd83c33babf2ae8e00b0a1056b957955f2a34f7178ca8b80525",
      archiveType = "tar.gz",
      expectedPython = "bin/python3",
    },
    macos_arm64 = {
      platform = "macos",
      arch = "arm64",
      url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260408/cpython-3.12.13%2B20260408-aarch64-apple-darwin-install_only_stripped.tar.gz",
      sha256 = "ac167e74961316ceabdbe4839f19aa6000c592b08e5a1fab4646cb225ede13d5",
      archiveType = "tar.gz",
      expectedPython = "bin/python3",
    },
  },
}
