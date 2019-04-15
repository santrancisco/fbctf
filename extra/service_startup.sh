#!/bin/bash

set -e

function reset_remote_db_from_docker() {
  local __u="ctf"
  local __p="ctf"
  local __user=$DB_USER
  local __pwd=$DB_PASSWORD
  local __db=$DB_NAME
  local __path="/root/database"
  if [ ! -z $DB_SCHEMA_PATH ]; then
      local __path="$DB_SCHEMA_PATH"
  fi

  echo "Creating DB - $__db"
  mysql -u "$__user" --password="$__pwd" -h $DB_HOST -e "CREATE DATABASE IF NOT EXISTS \`$__db\`;"

  echo "Importing schema..."
  mysql -u "$__user" --password="$__pwd" -h $DB_HOST "$__db" -e "source $__path/schema.sql;"
  echo "Importing countries..."
  mysql -u "$__user" --password="$__pwd" -h $DB_HOST "$__db" -e "source $__path/countries.sql;"
  echo "Importing logos..."
  mysql -u "$__user" --password="$__pwd" -h $DB_HOST "$__db" -e "source $__path/logos.sql;"
  local PASSWORD
  echo "Adding default admin user"
  
  PASSWORDHASH='$2y$12$WHmbOTH50MHKAbhrZjCq.OzSlPKkg9eiV5T/euix1LGs/L3HSucJO'

  # First try to delete the existing admin user
  mysql -u "$__user" --password="$__pwd" -h $DB_HOST "$__db" -e "DELETE FROM teams WHERE name='admin' AND admin=1;"

  # Then insert the new admin user with ID 1 (just as a convention, we shouldn't rely on this in the code)
  mysql -u "$__user" --password="$__pwd" -h $DB_HOST "$__db" -e "INSERT INTO teams (id, name, password_hash, admin, protected, logo, created_ts) VALUES (1, 'admin', '$PASSWORDHASH', 1, 1, 'admin', NOW());"

  echo ""
  echo "The password for admin is: password"
  if [[ "$__multiservers" == true ]]; then
      echo
      echo "Please note password as it will not be displayed again..."
      echo
      sleep 10
  fi
  echo ""
}

if [[ -e /root/tmp/certbot.sh ]]; then
    /bin/bash /root/tmp/certbot.sh
fi

if [[ -e /var/run/hhvm/sock ]]; then
    rm -f /var/run/hhvm/sock
fi

chown -R mysql:mysql /var/lib/mysql
chown -R mysql:mysql /var/run/mysqld
chown -R mysql:mysql /var/log/mysql
chown -R www-data:www-data /var/www/fbctf
service hhvm stop
service hhvm restart
service nginx restart

function configure_remote_db_from_docker() {
  if [ ! -z "$RESET_DB" ]; then
     reset_remote_db_from_docker
  fi
  echo "update settings.ini configuration with remote mysql address"
  sed -i "s/DB_HOST = '127.0.0.1'/DB_HOST = '$DB_HOST'/g" /var/www/fbctf/settings.ini
  sed -i "s/DB_NAME = 'fbctf'/DB_NAME = '$DB_NAME'/g" /var/www/fbctf/settings.ini
  sed -i "s/DB_USERNAME = 'ctf'/DB_USERNAME = '$DB_USER'/g" /var/www/fbctf/settings.ini
  sed -i "s/DB_PASSWORD = 'ctf'/DB_PASSWORD = '$DB_PASSWORD'/g" /var/www/fbctf/settings.ini
}

if [ ! -z "$DB_HOST" ] && [ ! -z "$DB_NAME" ] && [ ! -z "$DB_USER" ] && [ ! -z "$DB_PASSWORD" ] ; then 
  echo 'Using remote db setting'
  configure_remote_db_from_docker
  service mysql stop
else
  service mysql restart
fi

function configure_remote_memcached_for_docker() {
  echo "update settings.ini configuration with memcached address"
  sed -i "s/MC_HOST\[\] = 'MCHOST'/MC_HOST\[\] = '$MCHOST'/g" /var/www/fbctf/settings.ini
}

if [ ! -z "$MCHOST" ]; then 
  echo 'Using remote memcached setting'
  configure_remote_memcached_for_docker
  service mysql stop
else
  service memcached restart
fi

if [ ! -z "$EXITIMMEDIATELY" ]; then
  exit 0
fi

while true; do
    sleep 60
    service hhvm status
    service nginx status
    # service mysql status
    # service memcached status
done
