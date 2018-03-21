#!/bin/sh
# cpanel - src/tools/cpanel-dynamic-dns.sh        Copyright(c) 2012 cPanel, Inc.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

# Tested Configurations
# RedHat EL 4,5,6
# CentOS 4,5,6
# OpenWRT (w/openssl installed)

# Configuration should be done in the configuration files
# or it can be manually set here

#
# CONTACT_EMAIL is the email address that will be contacted upon failure
#
CONTACT_EMAIL=""

#
# DOMAIN and SUBDOMAIN are the domain that should get its A entry updated
# SUBDOMAIN can be left blank if you wish to update the root domain
#
DOMAIN=""
SUBDOMAIN=""

#
# CPANEL_SERVER is the hostname or ip address to connect to
#
CPANEL_SERVER=""

#
# CPANEL_USER and CPANEL_PASS are the username and password for your
# cPanel Account
#
CPANEL_USER=""
CPANEL_PASS=""

#
#  QUIET supresses all information messages (not errors)
#  set to 0 or 1
#
QUIET=""

# Program starts here
banner ()
{
   if [ "$QUIET" != "1" ]; then
      echo "=="
      echo "== cPanel Dyanmic DNS Updater $VERSION"
      echo "=="
      echo "==  Updating domain $SUBDOMAIN$DOMAIN"
      echo "=="
      echo $CFGMESSAGE1
      echo $CFGMESSAGE2
      echo "=="
   fi
}

exit_timeout ()
{
   ALARMPID=""
   if [ "$QUIET" != "1" ]; then
      echo "The operation timed out while connecting to $LAST_CONNECT_HOST"
   fi
   notify_failure "Timeout" "Connection Timeout" "Timeout while connecting to $LAST_CONNECT_HOST"
   exit
}

setup_timeout ()
{
   (sleep $TIMEOUT; kill -ALRM $PARENTPID) &
   ALARMPID=$!
   trap exit_timeout SIGALRM
}

setup_vars ()
{
   
   VERSION="2.1"
   APINAME=""
   PARENTPID=$$
   HOMEDIR=`echo ~`
   LAST_CONNECT_HOST=""
   FAILURE_NOTIFY_INTERVAL="14400"
   PERMIT_ROOT_EXECUTION="0"
   NOTIFY_FAILURE="1"
   TIMEOUT="120"
   BASEDIR="cpdyndns"
}

setup_config_vars ()
{

   if [ "$SUBDOMAIN" == "" ]; then
      APINAME="$DOMAIN."
   else
      APINAME="$SUBDOMAIN"
      SUBDOMAIN="$SUBDOMAIN."
   fi
   LAST_RUN_FILE="$HOMEDIR/.$BASEDIR/$SUBDOMAIN$DOMAIN.lastrun"
   LAST_FAIL_FILE="$HOMEDIR/.$BASEDIR/$SUBDOMAIN$DOMAIN.lastfail"
}

load_config ()
{
   if [ -e "/etc/$BASEDIR.conf" ]; then
      chmod 0600 /etc/$BASEDIR.conf
      . /etc/$BASEDIR.conf
      CFGMESSAGE1="== /etc/$BASEDIR.conf is being used for configuration"
   else
      CFGMESSAGE1="== /etc/$BASEDIR.conf does not exist"
   fi
   if [ -e "$HOMEDIR/etc/$BASEDIR.conf" ]; then
      chmod 0600 $HOMEDIR/etc/$BASEDIR.conf
      . $HOMEDIR/etc/$BASEDIR.conf
      CFGMESSAGE2="== $HOMEDIR/etc/$BASEDIR.conf is being used for configuration"
   else
      CFGMESSAGE2="== $HOMEDIR/etc/$BASEDIR.conf does not exist"
   fi
}

create_dirs ()
{
   if [ ! -e "$HOMEDIR/.$BASEDIR" ]; then
      mkdir -p "$HOMEDIR/.$BASEDIR"
      chmod 0700 "$HOMEDIR/.$BASEDIR"
   fi
}

fetch_myaddress ()
{
   if [ "$QUIET" != "1" ]; then
      echo -n "Determining IP Address..."
   fi
   LAST_CONNECT_HOST="myip.cpanel.net"
   MYADDRESS=`echo -e "GET /v1.0/ HTTP/1.0\r\nHost: myip.cpanel.net\r\nConnection: close\r\n\r\n" | openssl s_client -quiet -connect myip.cpanel.net:443 2>/dev/null | tail -1`
   if [ "$QUIET" != "1" ]; then
      echo -n $MYADDRESS
      echo "...Done"
   fi
   if [ "$MYADDRESS" == "" ]; then
      if [ "$QUIET" != "1" ]; then
         echo "Failed to determine IP Address (via https://www.cpanel.net/myip/)"
      fi
      terminate
   fi
   return
}

load_last_run ()
{
   if [ -e "$LAST_RUN_FILE" ]; then
      . $LAST_RUN_FILE
   fi
}

exit_if_last_address_is_current ()
{
   if [ "$LAST_ADDRESS" == "$MYADDRESS" ]; then
      if [ "$QUIET" != "1" ]; then
         echo "Last update was for $LAST_ADDRESS, and address has not changed."
         echo "If you want to force an update, remove $LAST_RUN_FILE"
      fi
      terminate
   fi
}

generate_auth_string () {
   AUTH_STRING=`echo -n "$CPANEL_USER:$CPANEL_PASS" | openssl enc -base64`
}

fetch_zone () {
   if [ "$QUIET" != "1" ]; then
      echo -n "Fetching zone for $DOMAIN...."
   fi
   LAST_CONNECT_HOST=$CPANEL_SERVER
   REQUEST="GET /xml-api/cpanel?cpanel_xmlapi_module=ZoneEdit&cpanel_xmlapi_func=fetchzone&cpanel_xmlapi_apiversion=2&domain=$DOMAIN HTTP/1.0\r\nConnection: close\r\nAuthorization: Basic $AUTH_STRING\r\nUser-Agent: cpanel-dynamic-dns.sh $VERSION\r\n\r\n\r\n"
   RECORD=""
   LINES=""
   INRECORD=0
   USETHISRECORD=0
   REQUEST_RESULTS=`echo -e "$REQUEST" | openssl s_client -quiet -connect $CPANEL_SERVER:2083 2>/dev/null`
   
   check_results_for_error "$REQUEST_RESULTS" "$REQUEST"
   for LINE in $REQUEST_RESULTS
   do
      if [ "$LINE" == "<record>" ]; then
         INRECORD=1
         continue
      fi
      if [ "$LINE" == "</record>" ]; then
         INRECORD=0
         if [ "$USETHISRECORD" == "2" ]; then
            LINENUM=`echo -e "$RECORD" | grep '<Line>' | awk -F'<' '{print \$2}' | awk -F'>' '{print \$2}'`
            ADDRESS=`echo -e "$RECORD" | grep -i '<address>' | awk -F'<' '{print \$2}' | awk -F'>' '{print \$2}'`
            LINES="$LINES\n$LINENUM=$ADDRESS"
         fi
         USETHISRECORD=0
         RECORD=""
         continue
      fi
      if [ "$LINE" == "<type>A</type>" ]; then
         USETHISRECORD=`expr $USETHISRECORD + 1`
      fi
      if [ "$LINE" == "<name>$SUBDOMAIN$DOMAIN.</name>" ]; then
         USETHISRECORD=`expr $USETHISRECORD + 1`
      fi
      if [ "$INRECORD" == "1" ]; then
         RECORD="$RECORD\n$LINE"
      fi
   done
   
   if [ "$QUIET" != "1" ]; then
      echo "Done"
   fi
}

parse_zone () {
   if [ "$QUIET" != "1" ]; then
      echo -n "Looking for duplicate entries..."
   fi
   FIRSTLINE=""
   REVERSELINES=""
   DUPECOUNT=0
   for LINE in `echo -e $LINES`
   do
      if [ "$LINE" == "" ]; then
         continue
      fi
      if [ "$FIRSTLINE" == "" ]; then
         FIRSTLINE=$LINE
         continue
      fi
      
      DUPECOUNT=`expr $DUPECOUNT + 1`
      REVERSELINES="$LINE\n$REVERSELINES"
   done
   
   if [ "$QUIET" != "1" ]; then
      echo "Found $DUPECOUNT duplicates"
   fi
   for LINE in `echo -e $REVERSELINES`
   do
      if [ "$LINE" == "" ]; then
         continue
      fi
      LINENUM=`echo $LINE | awk -F= '{print $1}'`
      LAST_CONNECT_HOST=$CPANEL_SERVER
      REQUEST="GET /xml-api/cpanel?cpanel_xmlapi_module=ZoneEdit&cpanel_xmlapi_func=remove_zone_record&cpanel_xmlapi_apiversion=2&domain=$DOMAIN&line=$LINENUM HTTP/1.0\r\nConnection: close\r\nAuthorization: Basic $AUTH_STRING\r\nUser-Agent: cpanel-dynamic-dns.sh $VERSION\r\n\r\n\r\n"
      if [ "$QUIET" != "1" ]; then
         echo "Removing Duplicate entry for $SUBDOMAIN$DOMAIN. (line $LINENUM)"
      fi
      RESULT=`echo -e "$REQUEST" | openssl s_client -quiet -connect $CPANEL_SERVER:2083 2>&1`
      check_results_for_error "$RESULT" "$REQUEST"
      if [ "$QUIET" != "1" ]; then
         echo $RESULT
      fi
   done
}

update_records () {
   
   if [ "$FIRSTLINE" == "" ]; then
      if [ "$QUIET" != "1" ]; then
         echo "Record $SUBDOMAIN$DOMAIN. does not exist.  Setting $SUBDOMAIN$DOMAIN. to $MYADDRESS"
      fi
      LAST_CONNECT_HOST=$CPANEL_SERVER
      REQUEST="GET /xml-api/cpanel?cpanel_xmlapi_module=ZoneEdit&cpanel_xmlapi_func=add_zone_record&cpanel_xmlapi_apiversion=2&domain=$DOMAIN&name=$APINAME&type=A&address=$MYADDRESS&ttl=300 HTTP/1.0\r\nConnection: close\r\nAuthorization: Basic $AUTH_STRING\r\nUser-Agent: cpanel-dynamic-dns.sh $VERSION\r\n\r\n\r\n"
      RESULT=`echo -e "$REQUEST" | openssl s_client -quiet -connect $CPANEL_SERVER:2083 2>&1`
      check_results_for_error "$RESULT" "$REQUEST"
   else
      ADDRESS=`echo $FIRSTLINE | awk -F= '{print $2}'`
      LINENUM=`echo $FIRSTLINE | awk -F= '{print $1}'`
      
      if [ "$ADDRESS" == "$MYADDRESS" ]; then
         if [ "$QUIET" != "1" ]; then
            echo "Record $SUBDOMAIN$DOMAIN. already exists in zone on line $LINENUM of the $DOMAIN zone."
            echo "Not updating as its already set to $ADDRESS"
            echo "LAST_ADDRESS=\"$MYADDRESS\"" > $LAST_RUN_FILE
         fi
         terminate
      fi
      if [ "$QUIET" != "1" ]; then
         echo "Record $SUBDOMAIN$DOMAIN. already exists in zone on line $LINENUM with address $ADDRESS.   Updating to $MYADDRESS"
      fi
      LAST_CONNECT_HOST=$CPANEL_SERVER
      REQUEST="GET /xml-api/cpanel?cpanel_xmlapi_module=ZoneEdit&cpanel_xmlapi_func=edit_zone_record&cpanel_xmlapi_apiversion=2&Line=$FIRSTLINE&domain=$DOMAIN&name=$APINAME&type=A&address=$MYADDRESS&ttl=300 HTTP/1.0\r\nConnection: close\r\nAuthorization: Basic $AUTH_STRING\r\nUser-Agent: cpanel-dynamic-dns.sh $VERSION\r\n\r\n\r\n"
      RESULT=`echo -e "$REQUEST" | openssl s_client -quiet -connect $CPANEL_SERVER:2083 2>&1`
      check_results_for_error "$RESULT" "$REQUEST"
   fi
   
   
   if [ "`echo $RESULT | grep newserial`" ]; then
      if [ "$QUIET" != "1" ]; then
         echo "Record updated ok"
      fi
      echo "LAST_ADDRESS=\"$MYADDRESS\""  > $LAST_RUN_FILE
   else
      if [ "$QUIET" != "1" ]; then
         echo "Failed to update record"
         echo $RESULT
      fi
   fi
   
}

check_results_for_error ()
{
   REQUEST_RESULTS="$1"
   REQUEST="$2"
   if [ "`echo $REQUEST_RESULTS | grep '<status>1</status>'`" ]; then
      if [ "$QUIET" != "1" ]; then
         echo -n "success..."
      fi
   else
      INREASON=0
      INSTATUSMSG=0
      MSG=""
      STATUSMSG=""
      
      for LINE in $REQUEST_RESULTS
      do
         if [ "`echo $LINE | grep '<reason>'`" != "" ]; then
            INREASON=1
            INSTATUSMSG=0
            MSG=`echo $LINE | awk -F'>' '{print \$2}'`
            continue
         fi
         if [ "`echo $LINE | grep '</reason>'`" != "" ]; then
            INREASON=0
            MSGADD=`echo $LINE | awk -F'<' '{print \$1}'`
            MSG="$MSG $MSGADD"
            continue
         fi
         if [ "`echo $LINE | grep '<statusmsg>'`" != "" ]; then
            INSTATUSMSG=1
            INREASON=0
            STATUSMSG=`echo $LINE | awk -F'>' '{print \$2}'`
            continue
         fi
         if [ "`echo $LINE | grep '</statusmsg>'`" != "" ]; then
            INSTATUSMSG=0
            MSGADD=`echo $LINE | awk -F'<' '{print \$1}'`
            STATUSMSG="$STATUSMSG $MSGADD"
            continue
         fi
         if [ "$INREASON" == "1" ]; then
            MSG="$MSG $LINE"
         fi
         if [ "$INSTATUSMSG" == "1" ]; then
            STATUSMSG="$STATUSMSG $LINE"
         fi
         
      done
      
      if [ "$MSG" == "" ]; then
         MSG="Unknown Error"
         if [ "$STATUSMSG" == "" ]; then
            STATUSMSG="Please make sure you have the zoneedit, or simplezone edit permission on your account."
         fi
      fi
      if [ "$QUIET" != "1" ]; then
         echo "Request failed with error: $MSG ($STATUSMSG)"
      fi
      notify_failure "$MSG" "$STATUSMSG" "$REQUEST_RESULTS" "$REQUEST"
      terminate
   fi
}

notify_failure ()
{
   MSG="$1"
   STATUSMSG="$2"
   REQUEST_RESULTS="$3"
   CURRENT_TIME=`date +%s`
   LAST_TIME=0
   if [ -e "$LAST_FAIL_FILE" ]; then
      . $LAST_FAIL_FILE
   fi
   TIME_DIFF=`expr $CURRENT_TIME - $LAST_TIME`
   
   if [ "$CONTACT_EMAIL" == "" ]; then
      echo "No contact email address was set.  Cannot send failure notification."
      return
   fi
   
   if [ $TIME_DIFF -gt $FAILURE_NOTIFY_INTERVAL ]; then
      echo "LAST_TIME=$CURRENT_TIME" > $LAST_FAIL_FILE
      
      SUBJECT="Failed to update dynamic DNS for $SUBDOMAIN$DOMAIN. on $CPANEL_SERVER : $MSG ($STATUMSG)"
      if [ -e "/bin/mail" ]; then
         if [ "$QUIET" != "1" ]; then
            echo "sending email notification of failure."
         fi
         echo -e "Status Message: $STATUSMSG\nThe full response was: $REQUEST_RESULTS" | /bin/mail -s "$SUBJECT" $CONTACT_EMAIL
      else
         if [ "$QUIET" != "1" ]; then
            echo "/bin/mail is not available, cannot send notification of failure."
         fi
      fi
   else
      if [ "$QUIET" != "1" ]; then
         echo "skipping notification because a notication was sent $TIME_DIFF seconds ago."
      fi
   fi
}

terminate () {
   if [ "$ALARMPID" != "" ]; then
      kill $ALARMPID
   fi
   exit
}

check_for_root () {
   if [ "$PERMIT_ROOT_EXECUTION" == "1" ]; then
      return
   fi
   if [ "`id -u`" == "0" ]; then
      echo "You should not run this script as root if possible"
      echo "If you really want to run as root please run"
      echo "echo \"PERMIT_ROOT_EXECUTION=1\" >> /etc/$BASEDIR.conf"
      echo "and run this script again"
      terminate
   fi
}

check_config () {
   if [ "$CONTACT_EMAIL" == "" ]; then
      echo "= Warning: no email address set for notifications"
   fi
   if [ "$CPANEL_SERVER" == "" ]; then
      echo "= Error: CPANEL_SERVER must be set in a configuration file"
      exit
   fi
   if [ "$DOMAIN" == "" ]; then
      echo "= Error: DOMAIN must be set in a configuration file"
      exit
   fi
   if [ "$CPANEL_USER" == "" ]; then
      echo "= Error: CPANEL_USER must be set in a configuration file"
      exit
   fi
   if [ "$CPANEL_PASS" == "" ]; then
      echo "= Error: CPANEL_PASS must be set in a configuration file"
      exit
   fi
}

setup_vars
setup_timeout
load_config
setup_config_vars
banner
check_for_root
check_config
fetch_myaddress
create_dirs
load_last_run
exit_if_last_address_is_current
generate_auth_string
fetch_zone
parse_zone
update_records
terminate


