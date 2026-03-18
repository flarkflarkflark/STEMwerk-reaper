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
mkdir -p %{buildroot}/usr/share/stemwerk-reaper
cp -a * %{buildroot}/usr/share/stemwerk-reaper/

%files
/usr/share/stemwerk-reaper

%changelog
* Sun Dec 14 2025 flarkAUDIO <noreply@example.com> - @VERSION@-1
- Automated build
