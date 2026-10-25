# Patroni 不在官方 postgres 镜像里：基于官方镜像装 patroni（etcd3 extra），
# psycopg 必须显式装——官方镜像自带的 libpq 不含 Python 驱动，缺了 Patroni 直接 FATAL。
FROM postgres:17.5

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip \
    && pip3 install --no-cache-dir --break-system-packages \
        "patroni[etcd3]==4.0.4" "psycopg[binary]==3.2.3" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
USER postgres
