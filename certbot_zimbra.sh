#!/bin/bash

# author: CJS
# GPLv3 license

NO_NGINX="yes"
RENEW_ONLY="no"
NEW_CERT="no"

## functions
# check executable certbot-auto / certbot / letsencrypt
check_executable () {
	LEB_BIN=$(which certbot-auto)
	if [ -z "$LEB_BIN" ]; then 
		LEB_BIN=$(which certbot)
	fi
	if [ -z "$LEB_BIN" ]; then 
		LEB_BIN=$(which letsencrypt-auto)
	fi

	# No way
	if [ -z "$LEB_BIN" ]; then
		echo "No letsencrypt/certbot binary found in $PATH";
		exit 1;
	fi
}

# version compare from  http://stackoverflow.com/a/24067243/738852
function version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

function bootstrap() {
	if [ ! -x "/opt/zimbra/bin/zmcontrol" ]; then
		echo "/opt/zimbra/bin/zmcontrol not found"
		exit 1;
	fi
	DETECTED_ZIMBRA_VERSION=$(su - zimbra -c '/opt/zimbra/bin/zmcontrol -v' | grep -Po '\d.\d.\d' | head -n 1)
	if [ -z "$DETECTED_ZIMBRA_VERSION" ]; then
		echo "Unable to detect zimbra version"
		exit 1;
	fi
	echo "Detected Zimbra $DETECTED_ZIMBRA_VERSION"
	check_executable

}


# perform the letsencrypt request and prepares the certs
function request_certificate() {
	# If we got no domain from command line try using zimbra hostname
	# FIXME the prompt should be avoided in cron!
	if [ -z "$DOMAIN" ]; then
		ZMHOSTNAME=$(/opt/zimbra/bin/zmhostname)
		while true; do
			read -p "Detected $ZMHOSTNAME as Zimbra domain: use this hostname for certificate request? " yn
		    	case $yn in
				[Yy]* ) DOMAIN=$ZMHOSTNAME; break;;
				[Nn]* ) echo "Please call $(basename $0) --hostname your.host.name"; exit;;
				* ) echo "Please answer yes or no.";;
		    	esac
		done
	fi

	if [ "$RENEW_ONLY" == "yes" ]; then
		return
	fi


	# Request our cert
	$LEB_BIN certonly --standalone -d $DOMAIN
	
	if [ $? -ne 0 ] ; then
		echo "letsencrypt returned an error";
		exit 1;
	fi
}

# copies stuff ready for zimbra deployment and test them
function prepare_certificate () {
	# Make zimbra accessible files
	mkdir /opt/zimbra/ssl/letsencrypt 2>/dev/null
	cp /etc/letsencrypt/live/$DOMAIN/* /opt/zimbra/ssl/letsencrypt/
	chown -R zimbra:zimbra /opt/zimbra/ssl/letsencrypt/

	# Now we should have the chain. Let's create the "patched" chain suitable for Zimbra
	cat /etc/letsencrypt/live/$DOMAIN/chain.pem > /opt/zimbra/ssl/letsencrypt/zimbra_chain.pem
	# The cert below comes from https://www.identrust.com/certificates/trustid/root-download-x3.html. It should be better to let the user fetch it?
	cat << EOF >> /opt/zimbra/ssl/letsencrypt/zimbra_chain.pem
-----BEGIN CERTIFICATE-----
MIIDSjCCAjKgAwIBAgIQRK+wgNajJ7qJMDmGLvhAazANBgkqhkiG9w0BAQUFADA/
MSQwIgYDVQQKExtEaWdpdGFsIFNpZ25hdHVyZSBUcnVzdCBDby4xFzAVBgNVBAMT
DkRTVCBSb290IENBIFgzMB4XDTAwMDkzMDIxMTIxOVoXDTIxMDkzMDE0MDExNVow
PzEkMCIGA1UEChMbRGlnaXRhbCBTaWduYXR1cmUgVHJ1c3QgQ28uMRcwFQYDVQQD
Ew5EU1QgUm9vdCBDQSBYMzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
AN+v6ZdQCINXtMxiZfaQguzH0yxrMMpb7NnDfcdAwRgUi+DoM3ZJKuM/IUmTrE4O
rz5Iy2Xu/NMhD2XSKtkyj4zl93ewEnu1lcCJo6m67XMuegwGMoOifooUMM0RoOEq
OLl5CjH9UL2AZd+3UWODyOKIYepLYYHsUmu5ouJLGiifSKOeDNoJjj4XLh7dIN9b
xiqKqy69cK3FCxolkHRyxXtqqzTWMIn/5WgTe1QLyNau7Fqckh49ZLOMxt+/yUFw
7BZy1SbsOFU5Q9D8/RhcQPGX69Wam40dutolucbY38EVAjqr2m7xPi71XAicPNaD
aeQQmxkqtilX4+U9m5/wAl0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNV
HQ8BAf8EBAMCAQYwHQYDVR0OBBYEFMSnsaR7LHH62+FLkHX/xBVghYkQMA0GCSqG
SIb3DQEBBQUAA4IBAQCjGiybFwBcqR7uKGY3Or+Dxz9LwwmglSBd49lZRNI+DT69
ikugdB/OEIKcdBodfpga3csTS7MgROSR6cz8faXbauX+5v3gTt23ADq1cEmv8uXr
AvHRAosZy5Q6XkjEGB5YGV8eAlrwDPGxrancWYaLbumR9YbK+rlmM6pZW87ipxZz
R8srzJmwN0jP41ZL9c8PDHIyh8bwRLtTcm1D9SZImlJnt1ir/md2cXjbDaJWFBM5
JDGFoqgCWjBH4d1QB7wCCZAA62RjYJsWvIjJEubSfZGL+T0yjWW06XyxV3bqxbYo
Ob8VZRzI9neWagqNdwvYkQsEjgfbKbYK7p2CNTUQ
-----END CERTIFICATE-----
EOF

	# Test cert. 8.6 and below must use root
	if version_gt $DETECTED_ZIMBRA_VERSION 8.7; then
		su - zimbra -c '/opt/zimbra/bin/zmcertmgr verifycrt comm /opt/zimbra/ssl/letsencrypt/privkey.pem /opt/zimbra/ssl/letsencrypt/cert.pem /opt/zimbra/ssl/letsencrypt/zimbra_chain.pem'
	else
		/opt/zimbra/bin/zmcertmgr verifycrt comm /opt/zimbra/ssl/letsencrypt/privkey.pem /opt/zimbra/ssl/letsencrypt/cert.pem /opt/zimbra/ssl/letsencrypt/zimbra_chain.pem
	fi
	if [ $? -eq 1 ]; then
		echo "Unable to verify cert!"
		exit 1;
	fi

}

# deploys certificate and restarts zimbra. ASSUMES prepare_certificate has been called already
function deploy_certificate() {
	# Backup old stuff
	cp -a /opt/zimbra/ssl/zimbra /opt/zimbra/ssl/zimbra.$(date "+%Y%.m%.d-%H.%M")

	cp /opt/zimbra/ssl/letsencrypt/privkey.pem /opt/zimbra/ssl/zimbra/commercial/commercial.key
	if version_gt $DETECTED_ZIMBRA_VERSION 8.7; then
		su - zimbra -c '/opt/zimbra/bin/zmcertmgr deploycrt comm /opt/zimbra/ssl/letsencrypt/cert.pem /opt/zimbra/ssl/letsencrypt/zimbra_chain.pem'
	else
		/opt/zimbra/bin/zmcertmgr deploycrt comm /opt/zimbra/ssl/letsencrypt/cert.pem /opt/zimbra/ssl/letsencrypt/zimbra_chain.pem
	fi

	# Finally apply cert!
	su - zimbra -c 'zmcontrol restart'
	# FIXME And hope that everything started fine! :)

}

#deploy cronjob to auto renewal
function install_crontab() {
	echo "Install cronjob to run every 1st day of the month"
	echo "0 2 1 * * certbot-auto renew --post-hook "/root/certbot-zimbra/certbot_zimbra.sh -r -d $(/opt/zimbra/bin/zmhostname)"" >> /etc/crontab
	crontab /etc/crontab
}

function check_user () {
	if [ "$EUID" -ne 0 ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi
}

function usage () {
	cat <<EOF
USAGE: $(basename $0) < -n | -r > [-d my.host.name] [-x] [-w /var/www]
  Options:
	 -n | --new: performs a request for a new certificate
	 -r | --renew: deploys certificate, assuming it has just been renewed

	Optional arguments:"
	 -d | --hostname: hostname being requested. If not passed uses \`zmhostname\`

Author: cjs
Feedback, bugs and PR are welcome on GitHub: askdhaskjd

Disclaimer:
THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM “AS IS” WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE PROGRAM IS WITH YOU. SHOULD THE PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL NECESSARY SERVICING, REPAIR OR CORRECTION.
EOF
}
## end functions

# main flow
# parameters parsing http://stackoverflow.com/a/14203146/738852
while [[ $# -gt 0 ]]; do
	key="$1"

	case $key in
	    -d|--hostname)
	    DOMAIN="$2"
	    shift # past argument
	    ;;
	    -x|--no-nginx)
	    NO_NGINX="yes"
	    ;;
			-n|--new)
	  	NEW_CERT="yes"
	    ;;
			-r|--renew)
	  	RENEW_ONLY="yes"
	    ;;
			-w|--webroot)
	  	WEBROOT="$2"
			shift
	    ;;
	    *)
	  	# unknown option
			usage
			exit 0
	    ;;
	esac
	shift # past argument or value
done

if [ "$NEW_CERT" == "no" ] && [ "$RENEW_ONLY" == "no" ]; then
	usage
	exit 0
fi

# actions
bootstrap
check_user
request_certificate
prepare_certificate
deploy_certificate
install_crontab
