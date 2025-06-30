[root@tb00ut01 src]# cat passwd_chambers_sync.py 
import os
import json
import time
from mysql import connector


ldif_dir="/opt/ldapsync/sync/"
outputpath=ldif_dir+"chambers/"

if not os.path.exists(outputpath):
    os.makedirs(outputpath)

def load_properties(filepath, sep='=', comment_char='#'):
    props = {}
    with open(filepath, "rt") as f:
        for line in f:
            l = line.strip()
            if l and not l.startswith(comment_char):
                key_value = l.split(sep)
                key = key_value[0].strip()
                value = sep.join(key_value[1:]).strip().strip('"')
                props[key] = value
    return props

prop = load_properties("/opt/usersync/app.env")
config = {
    "host": prop['CMN_DB_URL_PORT'],
    "user": prop['CMN_DB_USER'],
    "password": prop['CMN_DB_PSSWD'],
    "database": prop['CMN_DB_NAME'],
}

CHAMBER_0_LDAP_URL = prop['CHAMBER_0_LDAP_URL'].split(":")[0]
base_pwd = prop['LDAP_PW_BASE']
hostname = os.popen("hostname").read()
prefix=hostname[:2]
chm0pass= os.popen("openssl passwd -1 -salt "+prefix+"00 \""+base_pwd+"\"").read()
passarr=chm0pass.split("$")
RegionalLDAPPW=passarr[len(passarr) -1].replace("\n","")
RegionalLDAPUser="cn=directory manager"
ldif_file_list=[]
system_users_dn=["uid=prochost,ou=people,o=cadence.com","uid=projadm,ou=people,o=cadence.com","uid=appshost,ou=people,o=cadence.com","uid=ccops,ou=people,o=cadence.com","uid=cliomgr,ou=people,o=cadence.com","uid=svnadmin,ou=people,o=cadence.com"]


def connect_to_mysql(attempts=2, delay=2):
    attempt = 1
    # Implement a reconnection routine
    while attempt < attempts + 1:
        try:
            return connector.connect(**config)
        except (connector.Error, IOError) as err:
            if (attempts is attempt):
                # Attempts to reconnect failed; returning None
                print("Failed to connect, exiting without a connection: %s", err)
                return None
            print(
                "Connection failed: %s. Retrying (%d/%d)...",
                err,
                attempt,
                attempts-1,
            )
            # progressive reconnect delay
            time.sleep(delay ** attempt)
            attempt += 1
    return None

def get_chamber(chamber_name):
    data={}
    try:
        
        cnx = connect_to_mysql()
        if cnx and cnx.is_connected():
            with cnx.cursor(dictionary=True) as cursor:
                result = cursor.execute('select * from Chamber where Name ="{}"'.format(chamber_name))                  
                rows = cursor.fetchall()                
            cnx.close()
            if len(rows)==0:
                print(" Reason: chamber not found")                        
            data=rows[0]
        else:
            print("Could not connect in function %s " % (sys._getframe().f_code.co_name))
                 

    except Exception as e:          
        print("Exception in function %s : %s" % (sys._getframe().f_code.co_name,e))
       
    else:
        return data

def update_password(path):
    print(path)
    passFile = open(path, 'r')
    output = passFile.read()
    alldnswithdel = output.split("dn:")
    filtereddn=[]
    dnforsearch=[]
    chambersDict={}
    alldns=[]
    
    ## Change format as sometime LDAP will give error if add comes first before delete .So safeside using replace
    #current format 
    #        changeType:modify                            changeType:modify
    #        add: userpasswd                              replace: userpasswd
    #        userpasswd : <xyz>          =====>           userpasswd : <xyz> 
    #         -
    #         delete :userpasswd
    #         userpasswd:<passwd>
    #
    
    
    for dnwithdel in alldnswithdel:
        splitdn=dnwithdel.split("\n-\ndelete")
        alldns.append(splitdn[0])

    for dn in alldns:
        if "changetype: modify" in dn:
            dn = dn.replace("add: userPassword","replace: userPassword")
            ndn = dn.replace("ou=customers,ou=vcad,ou=services,o=cadence.com","ou=people,o=cadence.com")
            filtereddn.append("dn:"+ndn)
            splitdn=dn.split("\n")
            dnforsearch.append(splitdn[0].strip())

    for i in range(0,len(dnforsearch)):
        ldapcmd ="ldapsearch -x -o ldif-wrap=no -h "+CHAMBER_0_LDAP_URL+" -p 389 -D \""+RegionalLDAPUser+"\"  -w \""+RegionalLDAPPW+"\" -b  \""+dnforsearch[i]+"\" -LLL VCADaccess"
        cmdout = os.popen(ldapcmd).read()
        lines=cmdout.split("\n")
        for l in lines:
            if "VCADaccess:" in l:
                chmname=l.replace("VCADaccess:","").strip()
                if not (prefix in chmname):
                    continue

                if (prefix+"00" == chmname):
                    continue

                if chmname in chambersDict:
                    chambersDict[chmname].append(filtereddn[i])
                else:
                    chambersDict[chmname]=[]
                    chambersDict[chmname].append(filtereddn[i])
        
        if dnforsearch[i] in system_users_dn:
            for cdir in os.listdir("/var/yp/src/"):
                print("File is %s",cdir)
                if not (prefix in cdir):
                    continue
                if cdir in chambersDict:
                    chambersDict[cdir].append(filtereddn[i])
                else:
                    chambersDict[cdir]=[]
                    chambersDict[cdir].append(filtereddn[i])
      

    modifyCmdArr=[]
    modifyCCCmdArr=[]
    for key in chambersDict:

        if not os.path.isfile("/var/yp/src/"+key+"/.sync"):
            continue

        f = open(outputpath+key+".ldif", "w")
        f.write("\n\n".join(chambersDict[key])+"\n")
        f.close()               

        ldaphost=key+"ls01"
        ldappasscmd="openssl passwd -1 -salt "+key+" \""+base_pwd+"\""
        cmdout = os.popen(ldappasscmd).read()
        passarr=cmdout.split("$")
        ldappass=passarr[len(passarr) -1].replace("\n","")

        modifyCmd="ldapmodify -h "+ldaphost+" -p 389  -x -v -c -D  \"cn=directory manager\" -w \""+ldappass+"\" -f "+outputpath+key+".ldif"
        modifyCmdArr.append(modifyCmd)
        
        #check if it is CC 
        chamber = get_chamber(key)
        #print(chamber)
        if chamber:
            if chamber['chamberType'] == "mvpcc" and chamber['ccLsdjIP'] and  chamber['ccChamber']:            
                ccldappasscmd="openssl passwd -1 -salt "+chamber['ccChamber']+" \""+base_pwd+"\""
                cccmdout = os.popen(ccldappasscmd).read()
                ccpassarr=cccmdout.split("$")
                ccldappass=ccpassarr[len(ccpassarr) -1].replace("\n","")
                ccmodifyCmd="ldapmodify -h "+chamber['ccLsdjIP']+" -p 389  -x -v -c -D  \"cn=directory manager\" -w \""+ccldappass+"\" -f "+outputpath+key+".ldif" 
                ccmodifyCmd="timeout 10 "+ ccmodifyCmd
                modifyCCCmdArr.append(ccmodifyCmd)           
            else:
                print("CC side lsdj ip not available")
    

    #print(" && ".join(modifyCmdArr))
    cmdout = os.popen(" && ".join(modifyCmdArr)).read()
    #print(cmdout)
    if modifyCCCmdArr:
        #print("Modify command CC")
        #print(modifyCCCmdArr) 
        cccmdout = os.popen(" && ".join(modifyCCCmdArr)).read()
        print(cccmdout)
            
    
    cmdout = os.popen("rm -rf "+path).read()
    #print(cmdout)
    cmdout = os.popen("rm -rf "+outputpath+"*.ldif").read()
    #print(cmdout)

for file in os.listdir(ldif_dir):
    if file.endswith(".ldif"):
        update_password(os.path.join(ldif_dir, file))
[root@tb00ut01 src]# 
