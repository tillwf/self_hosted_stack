FROM nextcloud:apache

RUN apt-get update; \
    apt-get install -y procps smbclient libsmbclient-dev; \
    pecl install smbclient; \
    docker-php-ext-enable smbclient; \
    apt install libpcre3-dev; \
    pecl install oauth; \
    docker-php-ext-enable oauth; \
    rm -rf /var/lib/apt/lists/*
