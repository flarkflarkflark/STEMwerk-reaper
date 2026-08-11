Name:           stemwerk
Version:        @VERSION@
Release:        1%{?dist}
Summary:        STEMwerk REAPER scripts and helpers
License:        MIT
URL:            https://github.com/flarkflarkflark/STEMwerk
Source0:        stemwerk-%{version}.tar.gz
BuildArch:      x86_64

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
mkdir -p %{buildroot}/usr/share/icons/hicolor/512x512/apps
mkdir -p %{buildroot}/usr/share/icons/hicolor/scalable/apps
if [ -f %{buildroot}/usr/share/stemwerk-reaper/stemwerk.png ]; then
	cp -f %{buildroot}/usr/share/stemwerk-reaper/stemwerk.png %{buildroot}/usr/share/icons/hicolor/512x512/apps/stemwerk.png
fi
if [ -f %{buildroot}/usr/share/stemwerk-reaper/stemwerk.svg ]; then
	cp -f %{buildroot}/usr/share/stemwerk-reaper/stemwerk.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/stemwerk.svg
fi

%post
echo
echo "STEMwerk installed to /usr/share/stemwerk-reaper"
echo "Next step: Open REAPER and run STEMwerk-SETUP.lua before using STEMwerk.lua."
echo
PLAIN_MESSAGE=$(printf 'STEMwerk is installed to /usr/share/stemwerk-reaper\n\nNext step:\nOpen REAPER and run STEMwerk-SETUP.lua before using STEMwerk.lua.')
if [ -n "${DISPLAY}${WAYLAND_DISPLAY}" ]; then
	if command -v zenity >/dev/null 2>&1; then
		RICH_MESSAGE='<span size="x-large"><span foreground="#d83b01"><b>S</b></span><span foreground="#107c10"><b>T</b></span><span foreground="#0078d4"><b>E</b></span><span foreground="#ffb900"><b>M</b></span><b>werk Installer</b></span>

STEMwerk is installed to /usr/share/stemwerk-reaper

<b>Next step</b>
Open REAPER and run STEMwerk-SETUP.lua before using STEMwerk.lua.'
		zenity --info --width=520 --title="STEMwerk Installer" --text="$RICH_MESSAGE" >/dev/null 2>&1 || :
	elif command -v kdialog >/dev/null 2>&1; then
		RICH_MESSAGE='<span size="x-large"><span foreground="#d83b01"><b>S</b></span><span foreground="#107c10"><b>T</b></span><span foreground="#0078d4"><b>E</b></span><span foreground="#ffb900"><b>M</b></span><b>werk Installer</b></span>

STEMwerk is installed to /usr/share/stemwerk-reaper

<b>Next step</b>
Open REAPER and run STEMwerk-SETUP.lua before using STEMwerk.lua.'
		kdialog --msgbox "$RICH_MESSAGE" --title "STEMwerk Installer" >/dev/null 2>&1 || :
	elif command -v notify-send >/dev/null 2>&1; then
		notify-send -i stemwerk "STEMwerk Installer" "$PLAIN_MESSAGE" >/dev/null 2>&1 || :
	fi
fi

%files
/usr/share/stemwerk-reaper
/usr/share/icons/hicolor/512x512/apps/stemwerk.png
/usr/share/icons/hicolor/scalable/apps/stemwerk.svg

%changelog
* Sun Dec 14 2025 flarkAUDIO <noreply@example.com> - @VERSION@-1
- Automated build
