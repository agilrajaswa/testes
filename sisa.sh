#!/bin/bash

echo
echo "##############################"
echo "Configuring PHP-FPM pool for LibreNMS"
echo "##############################"

# Pastikan file pool www.conf ada
if [ ! -f /etc/php/8.3/fpm/pool.d/www.conf ]; then
    echo "ERROR: /etc/php/8.3/fpm/pool.d/www.conf not found!"
    exit 1
fi

cp /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's/user = www-data/user = librenms/' /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's/group = www-data/group = librenms/' /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's/\[www\]/\[librenms\]/' /etc/php/8.3/fpm/pool.d/librenms.conf
sed -i 's|listen = /run/php/php8.3-fpm.sock|listen = /run/php-fpm-librenms.sock|' /etc/php/8.3/fpm/pool.d/librenms.conf

echo
echo "##############################"
echo "Configuring Nginx for LibreNMS"
echo "##############################"

# Pastikan WEBSERVERHOSTNAME tidak kosong
if [ -z "$WEBSERVERHOSTNAME" ]; then
    echo "No hostname provided, using default 'localhost'"
    WEBSERVERHOSTNAME="localhost"
fi

cat << EOF > /etc/nginx/conf.d/librenms.conf
server {
 listen      80;
 server_name $WEBSERVERHOSTNAME;
 root        /opt/librenms/html;
 index       index.php;

 charset utf-8;
 gzip on;
 gzip_types text/css application/javascript text/javascript application/x-javascript image/svg+xml text/plain text/xsd text/xsl text/xml image/x-icon;

 location / {
  try_files \$uri \$uri/ /index.php?\$query_string;
 }

 location ~ [^/]\.php(/|$) {
  fastcgi_pass unix:/run/php-fpm-librenms.sock;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  include fastcgi.conf;
 }

 location ~ /\.(?!well-known).* {
  deny all;
 }
}
EOF

echo
echo "####################################"
echo "Removing default Nginx configuration"
echo "####################################"
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

echo
echo "####################################"
echo "Checking Nginx configuration"
echo "####################################"
nginx -t

if [ $? -eq 0 ]; then
    echo "Nginx configuration is OK, restarting services..."
    systemctl restart php8.3-fpm
    systemctl restart nginx
else
    echo "ERROR: Nginx configuration test failed. Fix the config and try again."
    exit 1
fi

echo
echo "#######################"
echo "Setting up lnms command"
echo "#######################"

ln -s /opt/librenms/lnms /usr/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

echo
echo "################"
echo "Configuring SNMP"
echo "################"

cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i 's/RANDOMSTRINGGOESHERE/public/' /etc/snmp/snmpd.conf
curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
chmod +x /usr/bin/distro
systemctl enable snmpd
systemctl restart snmpd

cp /opt/librenms/dist/librenms.cron /etc/cron.d/librenms

echo
echo "#############################"
echo "Setting up LibreNMS scheduler"
echo "#############################"

cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

echo
echo "##################################"
echo "Configuring logrotate for LibreNMS"
echo "##################################"

cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms

echo
echo "####################################"
echo "Installing and configuring syslog-ng"
echo "####################################"
apt-get install -y syslog-ng-core

cat << 'EOF' > /etc/syslog-ng/conf.d/librenms.conf
source s_net {
        tcp(port(514) flags(syslog-protocol));
        udp(port(514) flags(syslog-protocol));
};

destination d_librenms {
        program("/opt/librenms/syslog.php" template ("$HOST||$FACILITY||$PRIORITY||$LEVEL||$TAG||$R_YEAR-$R_MONTH-$R_DAY $R_HOUR:$R_MIN:$R_SEC||$MSG||$PROGRAM\n") template-escape(yes));
};

log {
        source(s_net);
        destination(d_librenms);
};
EOF

chown librenms:librenms /opt/librenms/syslog.php
chmod +x /opt/librenms/syslog.php
systemctl restart syslog-ng

echo
echo "#######################"
echo "Fixing up the .env file"
echo "#######################"

sed -i "s/#DB_HOST=/DB_HOST=localhost/" /opt/librenms/.env
sed -i "s/#DB_DATABASE=/DB_DATABASE=librenms/" /opt/librenms/.env
sed -i "s/#DB_USERNAME=/DB_USERNAME=librenms/" /opt/librenms/.env
sed -i "s/#DB_PASSWORD=/DB_PASSWORD=$DATABASEPASSWORD/" /opt/librenms/.env

echo
echo "#####################"
echo "Fixing log permission"
echo "#####################"

# Tunggu log file muncul
while true; do
  if [ -f /opt/librenms/logs/librenms.log ]; then
    chown librenms:librenms /opt/librenms/logs/librenms.log
    break
  else
    echo "Waiting until log file appears to change permission..."
    sleep 1
  fi
done

echo
echo "LibreNMS installation and configuration complete"
echo "...almost"
echo
echo "#####################################" 
echo "DON'T FORGET TO COME BACK AND DO THIS"
echo "#####################################"
echo
echo "Go and do the web page setup..."
echo "...and then come back and do:"
echo
echo 'su librenms -c "lnms config:set enable_syslog true"'
echo
echo "Then it will be finished."
echo 
echo "Wait until a device has been polled, and then do:"
echo
echo "su librenms -c /opt/librenms/validate.php"

exit 0
