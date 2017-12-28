#!/bin/bash
echo 'user_data script now performing configuration of the instance'
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
sudo echo "AUTOSCALING EXAMPLE 1.  I am $HOSTNAME" > /usr/share/nginx/html/identity.txt
chmod ogu+r /usr/share/nginx/html/identity.txt
