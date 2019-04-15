#!/bin/bash

set -ex

function reset_remote_db() {
  local __u="ctf"
  local __p="ctf"
  local __user=$DB_USER
  local __pwd=$DB_PASSWORD
  local __db=$DB_NAME
  local __path="/root/database"
  if [ ! -z $DB_SCHEMA_PATH ]; then
      local __path="$DB_SCHEMA_PATH"
  fi

  echo "Dropping DB - $__db"
  mysql -u "$__user" --password="$__pwd" -h $DB_HOST -e "DROP DATABASE IF EXISTS \`$__db\`;"

  echo "Creating DB - $__db"
  mysql -u "$__user" --password="$__pwd" -h $DB_HOST -e "CREATE DATABASE IF NOT EXISTS \`$__db\`;"

  echo "Importing schema to remotedb..."
  cp $__path/schema.sql $__path/remoteschema.sql
  if [ ! -z "$DB_NAME" ]; then
    sed -i 's/fbctf/${var.databasename}/g' /opt/fbctf/database/remoteschema.sql
  fi
  mysql -u "$__user" --password="$__pwd" -h $DB_HOST "$__db" -e "source $__path/remoteschema.sql;"

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
  echo ""
}

## EC2 instances randomly provision public elastic ip so we will need to create A record first.
# if [[ -e /root/tmp/certbot.sh ]]; then
#     /bin/bash /root/tmp/certbot.sh
# fi

if [[ -e /var/run/hhvm/sock ]]; then
        chown www-data:www-data /var/run/hhvm/sock
fi

chown -R mysql:mysql /var/lib/mysql
chown -R mysql:mysql /var/run/mysqld
chown -R mysql:mysql /var/log/mysql
chown -R www-data:www-data /var/www/fbctf

service hhvm restart
service nginx restart

function configure_remote_db() {
  if [ ! -z "$RESET_DB" ]; then
     reset_remote_db
  fi
  echo "update settings.ini configuration with remote mysql address"
  sed -i "s/DB_HOST = '127.0.0.1'/DB_HOST = '$DB_HOST'/g" /var/www/fbctf/settings.ini
  sed -i "s/DB_NAME = 'fbctf'/DB_NAME = '$DB_NAME'/g" /var/www/fbctf/settings.ini
  sed -i "s/DB_USERNAME = 'ctf'/DB_USERNAME = '$DB_USER'/g" /var/www/fbctf/settings.ini
  sed -i "s/DB_PASSWORD = 'ctf'/DB_PASSWORD = '$DB_PASSWORD'/g" /var/www/fbctf/settings.ini
}

if [ ! -z "$DB_HOST" ] && [ ! -z "$DB_NAME" ] && [ ! -z "$DB_USER" ] && [ ! -z "$DB_PASSWORD" ] ; then 
  echo 'Using remote db setting'
  configure_remote_db
  service mysql stop
else
  service mysql restart
fi

function configure_remote_memcached() {
  echo "update settings.ini configuration with memcached address"
  sed -i "s/MC_HOST\[\] = 'MCHOST'/MC_HOST\[\] = '$MCHOST'/g" /var/www/fbctf/settings.ini
}

if [ ! -z "$MCHOST" ]; then 
  echo 'Using remote memcached setting'
  configure_remote_memcached
  service memcached stop
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
    if [ -z "$MCHOST" ]; then 
       service memcached status
    fi
    if [ -z "$DB_HOST" ]; then 
      service mysql status
    fi
done
