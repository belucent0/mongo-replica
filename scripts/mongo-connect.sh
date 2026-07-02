#!/bin/bash
# MongoDB connection settings shared by backup/restore scripts.
# Source from inside the container: . /mongodb/mongo-connect.sh

CA="${PKI_DIR:-/pki}/ca.pem"
HOSTS="${MONGO_REPLICA_HOSTS:?MONGO_REPLICA_HOSTS is required}"
DB_USER="${MONGO_INITDB_ROOT_USERNAME:-root}"
DB_PASS="${MONGO_INITDB_ROOT_PASSWORD:?MONGO_INITDB_ROOT_PASSWORD is required}"

MONGO_CONN_ARGS=(
  --host "rs0/$HOSTS"
  -u "$DB_USER" -p "$DB_PASS" --authenticationDatabase admin
  --ssl --sslCAFile "$CA"
)
