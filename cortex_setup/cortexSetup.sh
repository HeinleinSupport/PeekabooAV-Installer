#!/bin/bash

# tested with thehiveproject/cortex:3.1.4
# `auth.method.basic=true` is needed in the application.conf of Cortex

POSITIONAL_ARGS=()
REGEX_INDEX='"_index":"([^"]*)"'
REGEX_ALPHANUM='^[a-zA-Z0-9+/]*$'

if [ -z $CORTEX_ADMIN_PASSWORD ]; then
  CORTEX_ADMIN_PASSWORD=$( tr -dc A-Za-z0-9 </dev/urandom | head -c 16 ; echo '' )
fi
echo "$CORTEX_ADMIN_PASSWORD"

check_last_command () {
  if [ $? -eq 0 ]; then
    echo -e " \033[38;5;118mo\033[0m"
  else
    echo -e "\033[?25h"
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -cu|--cortex-url)
      CORTEX_URL="$2"
      shift # past argument
      shift # past value
      ;;
    -eu|--elasticsearch-url)
      ELASTIC_URL="$2"
      shift # past argument
      shift # past value
      ;;
    -k|--api-key)
      PEEKABOO_CORTEX_API_TOKEN="$2"
      shift # past argument
      shift # past value
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      ;;
  esac
done
shift # past argument

if [ -z "$CORTEX_URL" ]; then
 echo "must specify a URL with -cu / --cortex-url (without path or trailing /, e.g. http://cortex:9001)"
 echo "Or set CORTEX_URL as an environment variable"
 exit 1
fi
if [ -z "$ELASTIC_URL" ]; then
 echo "must specify a URL with -eu / --elasticsearch-url (without path or trailing /, e.g. http://elasticsearch:9200)"
 echo "Or set ELASTIC_URL as an environment variable"
 exit 1
fi
if [ -z "$PEEKABOO_CORTEX_API_TOKEN" ] || ! [[ $PEEKABOO_CORTEX_API_TOKEN =~ $REGEX_ALPHANUM ]]; then
 echo -e "must specify an arbitrary, but secure;), API key with -k / --api-key (only use alphanumeric characters)"
 echo "Or set PEEKABOO_CORTEX_API_TOKEN as an environment variable"
 exit 1
fi
echo -e "\033[?25l"

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$CORTEX_URL/api/job")
echo -e "\033[38;5;242m$CODE\033[0m"

if [ $CODE -eq "520" ]; then
  echo -e "\nCortex needs to be set-up"

  echo -ne "\t\033[38;5;226mMigrate Database... \033[0m"
  curl -f -s -XPOST -H 'Content-Type: application/json' \
    "$CORTEX_URL/api/maintenance/migrate" -d '{}'
  sleep 3
  check_last_command

  echo -e "\t\033[38;5;226mMake admin user... \033[38;5;242m"
  curl -f -s -XPOST -H 'Content-Type: application/json' "$CORTEX_URL/api/user" \
    -d '{"login":"admin","name":"admin","password":"'"$CORTEX_ADMIN_PASSWORD"'","roles":["superadmin"],"organization":"cortex"}'
  check_last_command

  echo -e "\t\033[38;5;226mCreate organization 'PeekabooAV'... \033[38;5;242m"
  curl -f -s -XPOST -u "admin:$CORTEX_ADMIN_PASSWORD" \
    -H 'Content-Type: application/json' "$CORTEX_URL/api/organization" \
    -d '{ "name": "PeekabooAV", "description": "PeekabooAV organization", "status": "Active"}' 
  check_last_command

  echo -e "\t\033[38;5;226mCreate orgAdmin user... \033[38;5;242m"
  curl -f -s -XPOST -u "admin:$CORTEX_ADMIN_PASSWORD" \
    -H 'Content-Type: application/json' "$CORTEX_URL/api/user" \
    -d '{ "name": "Peekaboo org Admin","password":"'"$CORTEX_ADMIN_PASSWORD"'","roles": ["read","analyze","orgadmin"], "organization": "PeekabooAV", "login": "peekaboo-admin" }'
  check_last_command
  ORG_ADMIN_KEY=$(curl -s -XPOST -u "admin:$CORTEX_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$CORTEX_URL/api/user/peekaboo-admin/key/renew")
  echo -e "\t\t\033[38;5;242mAPI key: $ORG_ADMIN_KEY"

  echo -e "\t\033[38;5;226mCreate normal user... \033[38;5;242m"
  curl -f -s -XPOST -H "Authorization: Bearer $ORG_ADMIN_KEY" \
    -H 'Content-Type: application/json' "$CORTEX_URL/api/user" \
    -d '{ "name": "Peekaboo", "roles": ["read","analyze"], "organization": "PeekabooAV", "login": "peekaboo-analyze" }'
  check_last_command

  echo -e "\t\033[38;5;226mGet cortex elasticsearch index... \033[38;5;242m"
  ELASTIC_SEARCH=$(curl -s "$ELASTIC_URL/_search?q=_id:peekaboo-analyze")
  if [[ $ELASTIC_SEARCH =~ $REGEX_INDEX ]] ;then
    ELASTIC_INDEX=${BASH_REMATCH[1]}
  else
    echo -e "\033[38;5;197mThere was no _index found in Elastiscsearch response\033[0m"
    echo -e "\033[?25h"
    exit 1
  fi
  echo -ne "\t\t\033[38;5;242mIndex: $ELASTIC_INDEX"
  check_last_command

  echo -e "\t\033[38;5;226mPlace own API key in the database... \033[38;5;242m"
  curl -f -s -XPOST -H 'Content-Type: application/json' \
  -d '{"doc": {"key": "'"$PEEKABOO_CORTEX_API_TOKEN"'"}}' "$ELASTIC_URL/$ELASTIC_INDEX/_update/peekaboo-analyze"
  check_last_command
  echo -e "$PEEKABOO_CORTEX_API_TOKEN"

  # analyzers einrichten lassen

  echo -e "\t\033[38;5;226mEnable FileInfo 8.0 Analyzer... \033[38;5;242m"
  curl -f -XPOST -H "Authorization: Bearer $ORG_ADMIN_KEY" \
  -H 'Content-Type: application/json' "$CORTEX_URL/api/organization/analyzer/FileInfo_8_0" \
  -d '{"name": "FileInfo_8_0", "configuration": {}}'
  check_last_command

elif [ $CODE -eq "401" ]; then
  echo "Cortex does not need to be set-up"
fi

CORTEX_ADMIN_PASSWORD=""
echo -e "\033[?25h"

echo -e "\033[32mAll good!"

exit 0