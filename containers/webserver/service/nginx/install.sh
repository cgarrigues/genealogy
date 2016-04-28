#!/bin/bash -e
# this script is run during the image build

cp /container/service/nginx/nginx-default /etc/nginx/sites-enabled/default
