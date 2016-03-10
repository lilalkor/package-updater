#!/bin/bash
#set -u

# Usage text
usage_text=$(cat << EOF
Usage: `basename $0` -p <package> [-r] [-v version]...

Script to detect OS and update package by name.
Package is needed, all other keys are optional.
    
    -p\tpackage name, can be anything, if version is not forced
    -r\trestart all services after successful update
    -v\tforce exact version, you need to provide correct package name for used OS
    -o\tforce os (format is \$os\$major_version, i.e. Debian8, CentOS7, Ubuntu14, etc.)
    -h\tdisplay that help
    
Other parameters are for technical needs, usage in other scripts, etc.

    -c\tuse given CTID
    -l\tcreate log file, minimal screen output provided
EOF
)

# Enables writing to log, minimal screen output
enable_logging()
{
    if [ "$LOGGING" == "1" ]; then
        if [ ${CTID} ]; then
            LOG_FILE=/root/${CTID}-${PACKAGE}.log
        else
            LOG_FILE=/root/${PACKAGE}.log
        fi
        exec 1<&-
        exec 1<>$LOG_FILE
        exec 2>&1
    fi
}

# Parsing arguments recieved
check_args()
{
    if [ $# -eq 0 ]; then
        echo -e "$usage_text"
        exit 0
    fi
    while getopts "hlrRp:v:o:c:" opt; do
        case $opt in
            p )
                PACKAGE=$OPTARG
            ;;
            v )
                FORCE_VERSION='1'
                FORCED_VERSION=$OPTARG
            ;;
            r )
                RESTART_NEEDED='1'
            ;;
            R )
                ONLY_RESTART='1'
            ;;
            l )
                LOGGING='1'
            ;;
            o )
                FORCE_OS='1'
                FORCED_OS=$OPTARG
            ;;
            c )
                CTID=$OPTARG  
            ;;
            h )
                echo -e "$usage_text"
                exit 0
            ;;
            \? )
                echo "Invalid option: -$OPTARG" >&2
                exit 1
            ;;
            : )
                echo "Option -$OPTARG requires an argument." >&2
                exit 1
          ;;
      esac
    done
}

# Exit function
finish()
{
    local result=$1
    case $result in
        OK )
            echo -e "RESULT: ${TXT_GRN}OK${TXT_RST}"; exit 0
        ;;
        NOTOK )
            echo -e "RESULT: ${TXT_RED}FAIL${TXT_RST}"; exit 1
        ;;
        * )
            echo -e "RESULT: ${TXT_YLW}UNKNOWN${TXT_RST}"; exit 2
        ;;
    esac
}

# Check package manager
detect_package_manager()
{
    local dpkg=""
    local rpm=""
    local dpkg=`which dpkg >/dev/null 2>&1; echo $?`
    local rpm=`which rpm >/dev/null 2>&1; echo $?`
    local result=`echo "$dpkg$rpm"`
    case $result in
        01 )
            package_manager='dpkg'
        ;;
        10 )
            package_manager='rpm'
        ;;
        00 )
            echo 'You have both dpkg and rpm? Hello, Dr. Frankenstein!'
            finish NOTOK
        ;;
        11 )
            echo "You don't have neither dpkg, nor rpm. We don't know, what to do here. Exiting."
            finish NOTOK
        ;;
        * )
            echo "We couldn't detect package manager. Exiting"
            finish NOTOK
        ;;
    esac
}

# OS to package manager hash
verify_package_manager()
{
    # Do not check package manager, if we need only restart services, mainly because of bash 4.0
    if [ $ONLY_RESTART -eq 1 ]; then
        return
    fi

    local os=$1
    local -A os_to_pm_hash
    os_to_pm_hash["Debian"]="dpkg"
    os_to_pm_hash["Ubuntu"]="dpkg"
    os_to_pm_hash["CentOS"]="rpm"
    
    local os_name=`echo ${os} | tr -d [:digit:]` 
    if [ ${os_to_pm_hash[$os_name]-} ]; then
        if [ ! "${os_to_pm_hash[$os_name]}" == "$package_manager" ]; then
            echo "Your have $package_manager on ${os}. We can't do anything here. Exiting."
            finish NOTOK 
        fi
    else
        echo "We don't know, what package manager is needed for your OS. You have $package_manager on ${os}. Exiting."
        finish NOTOK
    fi
}

# Detect OS
detect_os()
{
    # Echo CTID if set
    if [ $CTID ]; then
        echo -e "CTID:\t$CTID"
    fi

    # Use forced OS if any
    if [ $FORCE_OS -eq 1 ]; then
        OS=$FORCED_OS
        echo -e "Forced OS:\t$OS"
        return
    fi

    local issue_file='/etc/issue'
    local os_release_file='/etc/os-release'
    local redhat_release_file='/etc/redhat-release'

    # First of all, trying os-relese file
    if [ -f $os_release_file ]; then
        local name=`grep '^NAME=' $os_release_file | awk -F'[" ]' '{print $2}'`
        local version=`grep '^VERSION_ID=' $os_release_file | awk -F'[". ]' '{print $2}'`
        OS=`echo "${name}${version}"`
        verify_package_manager $OS
        echo -e "OS:\t${TXT_YLW}${OS}${TXT_RST}"
    else
        # If not, trying redhat-release file (mainly because of bitrix-env)
        if [ -f $redhat_release_file ]; then
            OS=`head -1 /etc/redhat-release | sed -re 's/([A-Za-z]+)[^0-9]*([0-9]+).*$/\1\2/'`
            verify_package_manager $OS
            echo -e "OS:\t${TXT_YLW}${OS}${TXT_RST}"        
        else
            # Else, trying issue file
            if [ -f $issue_file ]; then
                OS=`head -1 $issue_file | sed -re 's/([A-Za-z]+)[^0-9]*([0-9]+).*$/\1\2/'` 
                verify_package_manager $OS
                echo -e "OS:\t${TXT_YLW}${OS}${TXT_RST}"
            else
                # If none of that files worked, exit
                echo -e "${TXT_RED}Cannot detect OS. Exiting now"'!'"${TXT_RST}"
                finish NOTOK
            fi
        fi
    fi
}

# Exit if bash is older then 4.0
check_bash_version()
{
    local bash_version=`echo $BASH_VERSION| awk -F. '{print $1}'`
    if [ $bash_version -lt 4 ]; then
        echo -e "Old bash ($BASH_VERSION). 4.0 or newer needed."
        finish NOTOK
    fi
}

# Filling os -> safe_version hash
# You need to create file ${package}.list accecible via http on $download_url
# Format:
#   OS:package_name:safe_version
#   OS2:package_name2:safe_version2
#
# Example:
#   File URL:
#   http://domain.com/lists/glibc.list
#
#   File contents:
#   Debian8:libc6:2.19-18+deb8u3
#   Debian7:libc6:2.13-38+deb7u10
#   Debian6:libc6:2.11.3-4+deb6u11
#   Ubuntu14:libc6:2.19-0ubuntu6.7
#   Ubuntu12:libc6:2.15-0ubuntu10.13
#   CentOS7:glibc:2.17-106.el7_2.4
#   CentOS6:glibc:2.12-1.166.el6_7.7
#
find_safe_version()
{
    local os=$1
    local package=$2

    # Use forced version if any
    if [ $FORCE_VERSION -eq 1 ]; then
        SAFE_VERSION=$FORCED_VERSION
        PACKAGE_NAME=$package
        return
    fi
 
    local -A safe_version_hash
    local -A package_name_hash
    local hash_os
    local hash_pkg
    local hash_version

    local list=(`wget -q -O- ${download_url}${package}.list`)
    for line in ${list[@]}; do
        IFS=':' read hash_os hash_pkg hash_version <<< "$line"
        package_name_hash["$hash_os"]="$hash_pkg"
        safe_version_hash["$hash_os"]="$hash_version"
    done

    if [ ${package_name_hash[$os]-} ]; then
        PACKAGE_NAME=${package_name_hash[$os]}
    else
        PACKAGE_NAME='nil'
    fi

    if [ ${safe_version_hash[$os]-} ]; then
        SAFE_VERSION=${safe_version_hash[$os]}
    else
        SAFE_VERSION='nil'
    fi
}
    
# Selecting action to restart services
select_restart_action()
{
    local os=$1

    case $os in
        Debian8 | CentOS7 )
            RESTART_ACTION='systemctl'
        ;;
        Debian* | Ubuntu* )
            systemctl=`which systemctl >/dev/null 2>&1; echo $?`
            service=`which service >/dev/null 2>&1; echo $?`
            

            RESTART_ACTION='service'
        ;;
        CentOS* )
            RESTART_ACTION='chkconfig'
        ;;
        * )
            RESTART_ACTION='exit'
        ;;
    esac
}

# Setting commands for different OS
set_commands()
{
    local os=$1
    case $os in
        Debian* | Ubuntu* )
            check_current_version="apt-cache policy \$package_name | sed -n 2p | awk '{print \$NF}'"
            check_candidate_version="apt-cache policy \$package_name | sed -n 3p | awk '{print \$NF}'"
            update_repo="apt-get -qq update"
            update_pkg="DEBIAN_FRONTEND=noninteractive apt-get -qq install \$package_name -y --force-yes"
        ;;
        CentOS* )
            check_current_version="rpm -q \$package_name | head -1 | sed -r -e 's#\w+-(.+)\.\w+#\1#'"
            check_candidate_version="yum -q --enablerepo=updates info glibc | grep -A4 Available | grep -E 'Version|Release' | awk '{print $3}' | xargs | sed -e 's/ /-/'"
            update_repo="yum -q updateinfo"
            update_pkg="yum -q --enablerepo=updates update \$package_name -y"
        ;;
        "" )
            echo -e 'OS is not detected. NEED MANUAL CHECK!'
            finish NOTOK
        ;;
        * )
            echo "OS: ${os}. We don't know how to update it."
            finish OK
        ;;
    esac
}

# Check current installed version
check_installed()
{
    local installed=`eval $check_current_version`
    echo -e "Curr:\t$installed\nSafe:\t$safe_version"

    # Exit, if already safe
    if [ "$installed" == "$safe_version" ]; then
        echo -e 'No update needed!'
        finish OK
    fi

    local short_installed=`echo $installed | awk -F'-' '{print $1}'`
    local short_safe=`echo $safe_version | awk -F'-' '{print $1}'`

    # Exit, if we are updating major version
    if [ ! "$short_installed" == "$short_safe"  ]; then
        echo -e "Version mismatch."
        finish NOTOK
    fi
}

# Updating package info
update_repository()
{
   eval $update_repo
}

# Checking version to be installed
check_cantidate()
{
    local installed=`eval $check_current_version`
    local candidate=`eval $check_candidate_version`
    echo -e "Candidate:\t$candidate"
    local short_installed=`echo $installed | awk -F'-' '{print $1}'`
    local short_candidate=`echo $candidate | awk -F'-' '{print $1}'`
    
    # Exit, if we are updating major version
    if [ ! "$short_installed" == "$short_candidate"  ]; then
        echo -e "Version mismatch."
        finish NOTOK
    fi

    # Exit, if candidate is not safe
    if [ ! "$candidate" == "$safe_version"  ]; then
        echo -e "We can't update to safe version."
        finish NOTOK
    fi
}

# Actially updating package
update_package()
{
    eval $update_pkg
}

# Check result after update
check_updated()
{
    local new_version=`eval $check_current_version`
    echo -e "New:\t$new_version"
    if [ "$new_version" == "$safe_version" ]; then
        echo -e 'Update successful!'
        UPDATE_SUCCESS=1
    else
        echo -e 'Update did not work! NEED MANUAL CHECK!'
        finish NOTOK
    fi
}

# Combining functions to actually perform update
update_action()
{
    local os=$1
    local safe_version=$2
    local package_name=$3
    if [ "$safe_version" == "nil" ]; then
        echo -e "There is no safe version for $os"
        finish OK
    fi
    check_installed
    update_repository
    check_cantidate
    update_package
    check_updated
}

# Restart services if needed
restart_action()
{
    local action=$1

    # Exit if update was not successful
    if [ $UPDATE_SUCCESS -eq 0 ]; then
        return
    fi

    # Exit if restart is not needed
    if [ $RESTART_NEEDED -eq 0 ]; then
        return
    fi

    case $action in
        systemctl )
            systemctl try-restart `systemctl --no-legend --no-pager --state=running --type=service list-units | awk '{print $1}' | xargs`
        ;;
        chkconfig )
            chkconfig  --list | grep on | sed 's/ .*//'| grep -v udev-post | xargs -I {} service {} restart
        ;;
        service )
            service --status-all 2>&1| grep ' + ' | sed 's/.* //' | grep -v pdns | xargs  -I {} service {} --full-restart
        ;;
        exit )
            echo "OS: ${OS}. You need to restart services manually."
            exit
        ;;
        * )
            echo 'No correct action specified!'
        ;;
    esac
}


# Some constants

download_url='http://46.36.223.167/script/'

UPDATE_SUCCESS=0
FORCE_VERSION=0
FORCE_OS=0
RESTART_NEEDED=0
LOGGING=0
ONLY_RESTART=0

TXT_GRN='\e[0;32m'
TXT_RED='\e[0;31m'
TXT_YLW='\e[0;33m'
TXT_RST='\e[0m'


check_args "$@"
if [ $ONLY_RESTART -eq 0 ]; then
    enable_logging
    check_bash_version
    detect_package_manager
    detect_os
    find_safe_version $OS $PACKAGE
    select_restart_action $OS
    set_commands $OS
    update_action $OS $SAFE_VERSION $PACKAGE_NAME
    restart_action $RESTART_ACTION
else
    UPDATE_SUCCESS=1
    RESTART_NEEDED=1
    detect_package_manager
    detect_os 
    select_restart_action $OS
    restart_action $RESTART_ACTION
fi
