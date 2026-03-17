Name:           stemwerk
Version:        @VERSION@
Release:        1%{?dist}
Summary:        STEMwerk REAPER scripts and helpers
License:        MIT
URL:            https://github.com/flarkflarkflark/STEMwerk
Source0:        stemwerk-%{version}.tar.gz
BuildArch:      noarch

%description
Installs the STEMwerk REAPER scripts and helper files.

%prep
%setup -q

%build
# nothing to build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/usr/share/stemwerk
cp -a reaper i18n README.md LICENSE TODO.md INTEGRATION.md TESTING.md %{buildroot}/usr/share/stemwerk/

%files
/usr/share/stemwerk

%changelog
* Sun Dec 14 2025 flarkAUDIO <noreply@example.com> - @VERSION@-1
- Automated build
