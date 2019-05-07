#! /bin/sh
#
# Author: Bert Van Vreckem <bert.vanvreckem@gmail.com>
#
# A non-interactive replacement for mysql_secure_installation
#
# Tested on CentOS 6, CentOS 7, Ubuntu 12.04 LTS (Precise Pangolin), Ubuntu
# 14.04 LTS (Trusty Tahr), Ubuntu 18.04 LTS (Bionic Beaver).

set -o nounset # abort on unbound variable

#{{{ Functions

usage() {
cat << _EOF_

Usage: ${0} "ROOT PASSWORD" "DB USER" "USER PASSWORD" "DOMAIN NAME"

  with "ROOT PASSWORD" the desired password for the database root user.

Use quotes if your password contains spaces or other special characters.
_EOF_
}

# Make sure service has started
while true; do
  netstat -an | grep 3306 > /dev/null 2>&1
  if [ $? -lt 1 ]; then
    echo "Mariadb Service Started!"
    break
  else
    echo "Service not ready, sleeping..."
    sleep 5
  fi
done

# Predicate that returns exit status 0 if the database root password
# is set, a nonzero exit status otherwise.
is_mysql_root_password_set() {
  ! mysqladmin --user=root status > /dev/null 2>&1
}

# Predicate that returns exit status 0 if the mysql(1) command is available,
# nonzero exit status otherwise.
is_mysql_command_available() {
  which mysql > /dev/null 2>&1
}

#}}}
#{{{ Command line parsing

if [ "$#" -ne "4" ]; then
  echo "Expected 2 arguments, got $#" >&2
  usage
  exit 2
fi

#}}}
#{{{ Variables
db_root_password="${1}"
db_user="${2}"
db_user_password="${3}"
domain_name="${4}"
#}}}

# Script proper

dns_server="$(ip route get 1.1.1.1 | awk '{print $7; exit}')"

if ! is_mysql_command_available; then
  echo "The MySQL/MariaDB client mysql(1) is not installed"
  exit 1
fi

if is_mysql_root_password_set; then
  echo "Database root password already set"
  exit 0
fi

echo "Configuring MySQL/MariaDB installation"
mysql --user=root <<_EOF_
  UPDATE mysql.user SET Password=PASSWORD('${db_root_password}') WHERE User='root';
  DELETE FROM mysql.user WHERE User='';
  DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
  DROP DATABASE IF EXISTS test;
  DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
  CREATE DATABASE pdns;
  CREATE DATABASE pdnsadmin;
  GRANT ALL ON pdns.* TO '${db_user}'@'localhost' IDENTIFIED BY '${db_user_password}';
  GRANT ALL ON pdnsadmin.* TO '${db_user}'@'localhost' IDENTIFIED BY '${db_user_password}';
  FLUSH PRIVILEGES;
  USE pdns;
  CREATE TABLE domains (
    id                    INT AUTO_INCREMENT,
    name                  VARCHAR(255) NOT NULL,
    master                VARCHAR(128) DEFAULT NULL,
    last_check            INT DEFAULT NULL,
    type                  VARCHAR(6) NOT NULL,
    notified_serial       INT DEFAULT NULL,
    account               VARCHAR(40) CHARACTER SET 'utf8' DEFAULT NULL,
    PRIMARY KEY (id)
  ) Engine=InnoDB CHARACTER SET 'latin1';

  CREATE UNIQUE INDEX name_index ON domains(name);


  CREATE TABLE records (
    id                    BIGINT AUTO_INCREMENT,
    domain_id             INT DEFAULT NULL,
    name                  VARCHAR(255) DEFAULT NULL,
    type                  VARCHAR(10) DEFAULT NULL,
    content               VARCHAR(64000) DEFAULT NULL,
    ttl                   INT DEFAULT NULL,
    prio                  INT DEFAULT NULL,
    change_date           INT DEFAULT NULL,
    disabled              TINYINT(1) DEFAULT 0,
    ordername             VARCHAR(255) BINARY DEFAULT NULL,
    auth                  TINYINT(1) DEFAULT 1,
    PRIMARY KEY (id)
  ) Engine=InnoDB CHARACTER SET 'latin1';

  CREATE INDEX nametype_index ON records(name,type);
  CREATE INDEX domain_id ON records(domain_id);
  CREATE INDEX ordername ON records (ordername);


  CREATE TABLE supermasters (
    ip                    VARCHAR(64) NOT NULL,
    nameserver            VARCHAR(255) NOT NULL,
    account               VARCHAR(40) CHARACTER SET 'utf8' NOT NULL,
    PRIMARY KEY (ip, nameserver)
  ) Engine=InnoDB CHARACTER SET 'latin1';


  CREATE TABLE comments (
    id                    INT AUTO_INCREMENT,
    domain_id             INT NOT NULL,
    name                  VARCHAR(255) NOT NULL,
    type                  VARCHAR(10) NOT NULL,
    modified_at           INT NOT NULL,
    account               VARCHAR(40) CHARACTER SET 'utf8' DEFAULT NULL,
    comment               TEXT CHARACTER SET 'utf8' NOT NULL,
    PRIMARY KEY (id)
  ) Engine=InnoDB CHARACTER SET 'latin1';

  CREATE INDEX comments_name_type_idx ON comments (name, type);
  CREATE INDEX comments_order_idx ON comments (domain_id, modified_at);


  CREATE TABLE domainmetadata (
    id                    INT AUTO_INCREMENT,
    domain_id             INT NOT NULL,
    kind                  VARCHAR(32),
    content               TEXT,
    PRIMARY KEY (id)
  ) Engine=InnoDB CHARACTER SET 'latin1';

  CREATE INDEX domainmetadata_idx ON domainmetadata (domain_id, kind);


  CREATE TABLE cryptokeys (
    id                    INT AUTO_INCREMENT,
    domain_id             INT NOT NULL,
    flags                 INT NOT NULL,
    active                BOOL,
    content               TEXT,
    PRIMARY KEY(id)
  ) Engine=InnoDB CHARACTER SET 'latin1';

  CREATE INDEX domainidindex ON cryptokeys(domain_id);


  CREATE TABLE tsigkeys (
    id                    INT AUTO_INCREMENT,
    name                  VARCHAR(255),
    algorithm             VARCHAR(50),
    secret                VARCHAR(255),
    PRIMARY KEY (id)
  ) Engine=InnoDB CHARACTER SET 'latin1';

  CREATE UNIQUE INDEX namealgoindex ON tsigkeys(name, algorithm);

  INSERT INTO domains (name, type) values ('${domain_name}', 'NATIVE');
  INSERT INTO domainmetadata (domain_id, kind, content) VALUES (1,'SOA-EDIT-API','DEFAULT');
  INSERT INTO records (domain_id, name, content, type,ttl,prio)
  VALUES (1,'${domain_name}','ns1.${domain_name} hostmaster.${domain_name} 1 10380 3600 604800 3600','SOA',86400,NULL);
  INSERT INTO records (domain_id, name, content, type,ttl,prio)
  VALUES (1,'${domain_name}','ns1.${domain_name}','NS',86400,NULL);
  INSERT INTO records (domain_id, name, content, type,ttl,prio)
  VALUES (1,'ns1.${domain_name}','${dns_server}','A',300,NULL);
_EOF_
