pre_start_action() {
    if [[ -z "$SLAPD_PASSWORD" ]]; then
	echo >&2 "Error: slapd not configured and SLAPD_PASSWORD not set"
	echo >&2 "Did you forget to add -e SLAPD_PASSWORD=... ?"
	exit 1
    fi
    
    TLS_REQCERT="${TLS_REQCERT:-never}"
    SLAPD_ORG="${SLAPD_ORG:-nodomain}"
    SLAPD_DOMAIN="${SLAPD_DOMAIN:-nodomain}"
    SLAPD_DC="${SLAPD_DC:-dc=nodomain}"
    SLAPD_BACKEND="${SLAPD_BACKEND:-MDB}"
    SLAPD_ALLOW_V2="${SLAPD_ALLOW_V2:-false}"
    SLAPD_PURGE_DB="${SLAPD_PURGE_DB:-false}"
    SLAPD_MOVE_OLD_DB="${SLAPD_MOVE_OLD_DB:-true}"
    SLAPD_BINDUSER="${SLAPD_BINDUSER:-binduser}"
    SLAPD_BINDPWD="${SLAPD_BINDPWD:-bindpassword}"
    SLAPD_BINDGROUP="${SLAPD_BINDGROUP:-bindgroup}"
#    SLAPD_BINDPWD=$(slappasswd -s $SLAPD_BINDPWD)

    # Careful with whitespace here. Leading whitespace in the values
    # can cause the configure script for slapd to hang.
    cat <<-EOF | debconf-set-selections
      slapd slapd/no_configuration  boolean false
      slapd slapd/internal/generated_adminpw password $SLAPD_PASSWORD
      slapd slapd/internal/adminpw password $SLAPD_PASSWORD
      slapd slapd/password1         password $SLAPD_PASSWORD
      slapd slapd/password2         password $SLAPD_PASSWORD
      slapd slapd/domain            string $SLAPD_DOMAIN
      slapd shared/organization     string $SLAPD_ORG
      slapd slapd/allow_ldap_v2     boolean $SLAPD_ALLOW_V2
      slapd slapd/purge_database    boolean $SLAPD_PURGE_DB
      slapd slapd/move_old_database boolean $SLAPD_MOVE_OLD_DB
      slapd slapd/purge_database    boolean $SLAPD_PURGE_DB
      slapd slapd/backend           string $SLAPD_BACKEND
      slapd slapd/dump_database     select when needed
EOF
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive slapd
    service slapd start
    mkdir -p /etc/ldapscripts
    cat > /etc/ldapscripts/ldapscripts.conf <<EOF
SERVER="localhost"
SUFFIX="$SLAPD_DC" # Global suffix
GSUFFIX="ou=groups"        # Groups ou (just under $SUFFIX)
USUFFIX="ou=users"         # Users ou (just under $SUFFIX)
MSUFFIX="ou=machines"      # Machines ou (just under $SUFFIX)
SASLAUTH=""
BINDDN="cn=admin,$SLAPD_DC"
BINDPWDFILE="/etc/ldapscripts/ldapscripts.passwd"
GIDSTART="1000" # Group ID
UIDSTART="1000" # User ID
MIDSTART="2000" # Machine ID
GCLASS="posixGroup"   # Leave "posixGroup" here if not sure !
CREATEHOMES="no"      # Create home directories and set rights ?
PASSWORDGEN="pwgen"
RECORDPASSWORDS="no"
PASSWORDFILE="/var/log/ldapscripts_passwd.log"
LOGFILE="/var/log/ldapscripts.log"
GTEMPLATE="/etc/ldapscripts/ldapaddgroup.template"
UTEMPLATE="/etc/ldapscripts/ldapadduser.template"
MTEMPLATE="/etc/ldapscripts/ldapaddmachine.template"
LDAPSEARCHBIN="/usr/bin/ldapsearch"
LDAPADDBIN="/usr/bin/ldapadd"
LDAPDELETEBIN="/usr/bin/ldapdelete"
LDAPMODIFYBIN="/usr/bin/ldapmodify"
LDAPMODRDNBIN="/usr/bin/ldapmodrdn"
LDAPPASSWDBIN="/usr/bin/ldappasswd"
EOF
    echo -n $SLAPD_PASSWORD > /etc/ldapscripts/ldapscripts.passwd
    chmod 400 /etc/ldapscripts/ldapscripts.passwd
    cat > /etc/ldapscripts/create_users_and_groups.ldif <<EOF
dn: ou=users,$SLAPD_DC
objectClass: organizationalUnit
ou: users

dn: ou=groups,$SLAPD_DC
objectClass: organizationalUnit
ou: groups

dn: ou=machines,$SLAPD_DC
objectClass: organizationalUnit
ou: machines

dn: ou=roles,$SLAPD_DC
objectClass: organizationalUnit
ou: roles

dn: ou=projects,$SLAPD_DC
objectClass: organizationalUnit
ou: projects
EOF
    ldapadd -w $SLAPD_PASSWORD -x -D cn=admin,$SLAPD_DC -f /etc/ldapscripts/create_users_and_groups.ldif
    ldapaddgroup $SLAPD_BINDGROUP
    ldapadduser ${SLAPD_BINDUSER} $SLAPD_BINDGROUP
    ldapsetpasswd ${SLAPD_BINDUSER} $(slappasswd -s ${SLAPD_BINDPWD})
    echo "TLS_REQCERT $TLS_REQCERT" >> /etc/ldap/ldap.conf
    if [ "$TLS_REQCERT" != "never" ]; then
        mkdir -p /etc/ssl/templates /etc/ssl/private /etc/ssl/certs
        cat > /etc/ssl/templates/ca_server.conf <<EOF
cn = LDAP Server CA
ca
cert_signing_key            
EOF
            cat > /etc/ssl/templates/ldap_server.conf <<EOF
organization = "$SLAPD_ORG"
cn = $(hostname -f)
tls_www_server
encryption_key
signing_key
expiration_days = 3652        
EOF
        certtool -p --outfile /etc/ssl/private/ca_server.key
        certtool -s --load-privkey /etc/ssl/private/ca_server.key --template /etc/ssl/templates/ca_server.conf --outfile /etc/ssl/certs/ca_server.pem
        certtool -p --sec-param high --outfile /etc/ssl/private/ldap_server.key
        certtool -c --load-privkey /etc/ssl/private/ldap_server.key --load-ca-certificate /etc/ssl/certs/ca_server.pem --load-ca-privkey /etc/ssl/private/ca_server.key --template /etc/ssl/templates/ldap_server.conf --outfile /etc/ssl/certs/ldap_server.pem
        usermod -aG ssl-cert openldap
        chown :ssl-cert /etc/ssl/private/ldap_server.key
        chmod 640 /etc/ssl/private/ldap_server.key
        
        cat > /etc/ldapscripts/add_certs.ldif <<EOF
dn: cn=config
changetype: modify
add: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ssl/certs/ca_server.pem

add: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ssl/certs/ldap_server.pem

add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ssl/private/ldap_server.key

dn: cn=config
changetype: modify
add: olcSecurity
olcSecurity: tls=1
EOF
        ldapmodify -H ldapi:// -Y EXTERNAL -f /etc/ldapscripts/add_certs.ldif
        ln -s /etc/ssl/certs/ca_server.pem /etc/ssl/certs/ca-certificates.crt
    fi
    kill -TERM `cat /var/run/slapd/slapd.pid`
    echo "Configuration finished."
}

post_start_action() {
    rm /first_run
}
