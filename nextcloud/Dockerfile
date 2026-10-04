# Nextcloud only supports upgrading one major version at a time, so this tag is
# pinned deliberately. To upgrade, bump NC_VERSION by a single major release,
# redeploy, confirm `occ status` reports the new version with
# needsDbUpgrade: false, and only then bump again. See ../README.md.
ARG NC_VERSION=32.0.15

FROM nextcloud:${NC_VERSION}-apache

# PHP extensions this instance depends on:
#   smbclient - external SMB/CIFS storage (files_external app)
#   oauth     - required by the oauth2 app
#
# Debian 13 dropped libpcre3-dev in favour of libpcre2-dev, which pecl needs to
# build oauth. Try pcre2 first and fall back to pcre3 so this keeps building
# across base-image upgrades.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        procps \
        smbclient \
        libsmbclient-dev; \
    { apt-get install -y --no-install-recommends libpcre2-dev \
      || apt-get install -y --no-install-recommends libpcre3-dev; }; \
    pecl install smbclient; \
    docker-php-ext-enable smbclient; \
    pecl install oauth; \
    docker-php-ext-enable oauth; \
    rm -rf /var/lib/apt/lists/*
