#!/bin/bash

URL=${1}

if [ -z "${URL}" ]; then
    echo "ERROR: the URL to be checked must be provided as argument"
    exit 1
fi

COUNT_ECHO1=0
COUNT_ECHO2=0

for i in {1..100}; do
    HOSTNAME=$(curl "${URL}" -sk | jq -rc '.environment.HOSTNAME')
    if [[ "${HOSTNAME}" == echo-1* ]]; then
        ((COUNT_ECHO1++))
    elif [[ "${HOSTNAME}" == echo-2* ]]; then
        ((COUNT_ECHO2++))
    fi
done

# Afficher les résultats
echo "Number of requests for echo-1: $COUNT_ECHO1"
echo "Number of requests for echo-2: $COUNT_ECHO2"