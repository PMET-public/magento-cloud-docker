#!/bin/bash
# cloud integration env use an empty password but the current mariadb will not create a non-root user with an empty password
# see discussion https://github.com/docker-library/mariadb/pull/137
mysql -uroot --password="$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$MYSQL_USER'@'%'; GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_USER'@'%';"

