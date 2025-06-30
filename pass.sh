[root@tb00ut01 src]# cat  passwd_ldapsync.sh
#!/bin/bash
source /opt/usersync/app.env
rootdir="/opt/ldapsync"
binpath="/opt/ldapsync/bin"
logpath=$rootdir"/logs"
syncpath=$rootdir"/sync"
dt=`date "+%Y_%b_%d_%T"`
logile="ldappasswdsync.log"
#corportae LDAP details
CorporateLDAP=`echo $CORPORATE_LDAP_URL| cut -d ":" -f 1`
#Regional LDAP details
RegionalLDAP=`echo $CHAMBER_0_LDAP_URL| cut -d ":" -f 1`
REGIONAL_SITE=`hostname | cut -c 1-4` 
RegionalLDAPPW=`openssl passwd -1 -salt $REGIONAL_SITE $LDAP_PW_BASE |cut -d "$" -f4`

VCAD_BASEDN="ou=customers,ou=vcad,ou=services,o=cadence.com"
CORPEMP_BASEDN="ou=people,o=cadence.com"
CorporateLDAPUser="uid=ldapbind,ou=Groups,o=cadence.com"
RegionalLDAPUser="cn=directory manager"

CorpVCADLDIF="CorpPasswdVCAD.ldif"
RegVCADLDIF="RegPasswdVCAD.ldif"
OutVCADLDIF="OutPasswdVCAD.ldif"

CorpEMPLDIF="CorpPasswdEMP.ldif"
RegEMPLDIF="RegPasswdEMP.ldif"
OutEmpLDIF="OutPasswdEmp.ldif"

#ADMIN="mana@cadence.com arul@cadence.com nishant@cadence.com"


sping() {

                OT=`/usr/bin/ping -c1 $1 > /dev/null; echo $?`
                if [[ "$OT" != 0 ]];then
                                echo "$dt : ERROR Server $1 not reachable.... Alerting & Exit !!!" >> $logpath/$logile
                                echo ""|mail -s "Failed: LDAP SYNC Server not reachable : $1 : Exiting !!!" $ADMIN
                                exit 101
                else
                                echo "$dt : Success Server $1 is reacheable...." >> $logpath/$logile
                fi
}

createLDIF() {
                local ldapHost=$1
                local ldapUser=$2
                local ldapPw=$3
                local basedn=$4
                local ldifFile=$5
                local vcadaccess=$6
                echo "ldapHost=$ldapHost ,  ldapUser=$ldapUser  , basedn=$basedn,  ldifFile=$ldifFile , vcadaccess=$vcadaccess"

                echo "$dt : Generating source server cooperate LDIF !!!" >> $logpath/$logile
                if [[ $vcadaccess ]] ; then
                    echo "Inside vcadaccess "
                    /usr/bin/ldapsearch -x -o ldif-wrap=no -h "$ldapHost" -D "$ldapUser" -b "$basedn" -w "$ldapPw"  "VCADaccess=*" -LLL userPassword   > $logpath/$ldifFile
                else
                    echo "else vcadaccess"
                    /usr/bin/ldapsearch -x -o ldif-wrap=no -h "$ldapHost" -D "$ldapUser" -b "$basedn" -w "$ldapPw" -LLL userPassword > $logpath/$ldifFile
                fi
                if test -f $logpath/$ldifFile; then
                                echo "$dt :LDIF generated ( $ldifFile )with total DNs : `grep "^dn" $logpath/$ldifFile|wc -l`" >> $logpath/$logile
                else
                                echo "$dt : ERROR Failed to generate  LDIFF" >> $logpath/$logile
                                #echo ""|mail -s "Failed to generate Corporate Server VCAD Tree  LDIF : $SourceServer : Exiting !!!" $ADMIN
                                exit 102
                fi

}

diffLDIF() {
                local source=$1
                local destination=$2
                local out=$3
                echo "$dt : Generating DIFF $out LDIF" >> $logpath/$logile
                $binpath/ldif-diff -o $logpath/$out -s $logpath/$destination -t $logpath/$source -e $binpath/system_users.ldif
                if test -f $logpath/$out; then
                echo "$dt : DIFF $out LDIF generated with total DNs : `grep "^dn" $logpath/$out|wc -l`" >> $logpath/$logile

        else
                echo "$dt : ERROR Failed to generate DIFF LDIF" >> $logpath/$logile
                #echo ""|mail -s "Failed to generate DIFF LDIF for VCAD Sync ... Exiting !!!" $ADMIN
                exit 105
        fi
}

modify() {
                local difffile=$1
                WC=`grep "^# No differences" $logpath/$difffile|wc -l`
                if  [[ "$WC" == 1 ]];then
                    echo "$dt : No changes found in Source and Target $difffile LDIF ... " >> $logpath/$logile
                    #exit 104
                else
                    echo "$dt : Modifying LDAP Destination Server $RegionalLDAP with `grep "^dn" $logpath/$difffile|wc -l` changes... " >> $logpath/$logile
                    /usr/bin/ldapmodify -c -xh $RegionalLDAP -D "$RegionalLDAPUser" -w $RegionalLDAPPW -f $logpath/$difffile > $logpath/ldapmodify_passwd.log 2>&1
                    OT_mod=`echo $?`
                    if [[ "$OT_mod" == 0 ]];then
                                    echo "$dt : Modification succesful at Destination Server" >> $logpath/$logile
                                    #cat $logpath/ldapmodify.log|mail -s "LDAP SYNC : `grep '^dn' $logpath/$difffile|wc -l` records updated from $SourceServer to $RegionalLDAP"
                    else
                                    echo "$dt : Modification failed with errors please check $logpath/ldapmodify.log" >> $logpath/$logile
                                    #cat $logpath/ldapmodify.log|mail -s "LDAP SYNC : `grep '^dn' $logpath/DIFF.ldif|wc -l` records updated from $SourceServer to $DestServer" $ADMIN
                                    #echo ""|mail -s "Failed: VCAD LDAP SYNC Modification with errors please check $logpath/ldapmodify-$dt.log" $ADMIN
                    fi
                fi
}

rotate() {
                echo "$dt : Rotating files to $dt timestamp" >> $logpath/$logile
                rm $logpath/$CorpVCADLDIF $logpath/$CorpEMPLDIF   
                rm $logpath/$RegVCADLDIF $logpath/$RegEMPLDIF            
                cp $logpath/$OutVCADLDIF $syncpath/$dt-$OutVCADLDIF
                cp $logpath/$OutEmpLDIF $syncpath/$dt-$OutEmpLDIF
                mv $logpath/$OutVCADLDIF $logpath/$dt-$OutVCADLDIF
                mv $logpath/$OutEmpLDIF $logpath/$dt-$OutEmpLDIF
                echo "$dt : Rotation completed & script completed successfully @ `date`" >> $logpath/$logile
}


if [[ `pgrep -f "/bin/bash $0"` != "$$" ]]; then
        echo "Another instance of shell already exist! Exiting"
        exit
fi

#Calling functions
#sping $SourceServer
#sping $DestServer
dts=`date "+%Y_%b_%d_%T"`
startDate=`date "+%s"`
echo "Starting time $dts"

####Create LDIF Files for Processing
#Create VCAD Tree LDIF from Cooperate LDAP
createLDIF "$CorporateLDAP" "$CorporateLDAPUser" "$CORPORATE_LDAP_BIND_PW" "$VCAD_BASEDN" "$CorpVCADLDIF"
#Create VCAD Tree LDIF from Regional LDAP
createLDIF "$RegionalLDAP" "$RegionalLDAPUser" "$RegionalLDAPPW" "$VCAD_BASEDN" "$RegVCADLDIF"
#Create Employee Tree LDIF from Cooperate LDAP
createLDIF "$CorporateLDAP" "$CorporateLDAPUser" "$CORPORATE_LDAP_BIND_PW" "$CORPEMP_BASEDN" "$CorpEMPLDIF" "vcadaccess"
#Create Employee Tree LDIF from Regional LDAP
createLDIF "$RegionalLDAP" "$RegionalLDAPUser" "$RegionalLDAPPW" "$CORPEMP_BASEDN" "$RegEMPLDIF"


######Find Difference
diffLDIF "$CorpVCADLDIF" "$RegVCADLDIF" "$OutVCADLDIF"
diffLDIF "$CorpEMPLDIF" "$RegEMPLDIF" "$OutEmpLDIF"

modify $OutVCADLDIF
modify $OutEmpLDIF

#Rotate
rotate

dte=`date "+%Y_%b_%d_%T"`
echo "End time $dte"
endDate=`date "+%s"`
DIFF=$(($endDate-$startDate))
echo "Duration: $(($DIFF / 3600 )) hours $((($DIFF % 3600) / 60)) minutes $(($DIFF % 60)) seconds"
