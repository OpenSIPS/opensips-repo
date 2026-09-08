%if 0%{?rhel} > 0 && 0%{?rhel} < 8
%global _source_payload w2.xzdio
%global _binary_payload w2.xzdio
%endif

Name:           opensips-repo-_TYPE_
Version:        _MVERSION_
Release:        _RELEASE_%{?dist}
Summary:        OpenSIPS _MVERSION_ _TYPE_ RPM repository configuration
License:        GPLv2+
BuildArch:      noarch
Source0:        opensips.repo
Source1:        RPM-GPG-KEY-OPENSIPS

%description
Repository configuration and public signing key for OpenSIPS _MVERSION_
_TYPE_ RPM packages.

%install
install -D -m 0644 %{SOURCE0} %{buildroot}/etc/yum.repos.d/opensips.repo
install -D -m 0644 %{SOURCE1} %{buildroot}/etc/pki/rpm-gpg/RPM-GPG-KEY-OPENSIPS

%files
%defattr(-,root,root,-)
/etc/pki/rpm-gpg/RPM-GPG-KEY-OPENSIPS
/etc/yum.repos.d/opensips.repo

%changelog
* Sun Jul 26 2026 OpenSIPS Builder <info@opensips.org> - _MVERSION_-_RELEASE_
- Generate repository package from opensips-repo CI.
