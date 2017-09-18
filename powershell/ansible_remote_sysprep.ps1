# This script is used to make a Windows machine 'Ansible ready' by installing/
# configuring all required Pre-requisites, this includes:-
#
# - Choclatey (used to install .Net Framework and Powershell)
# - .Net Framework (required for Powershell)
# - Powershell ver 5.x (required for Ansible)
# - WinRM configuration (required for Ansible)
#
# Once this script has been executed then it should be possible to use a
# host with Ansible installed (Linux or Mac) to push packages to the Windows
# target machine that has had this script run on it.
#
# - If you run this script using Powershell ISE and Powershell version
# is <5.x then the transcription module will not be present and thus no log will
# will saved. Either upgrade to Powershell v5.x before running the script or
# run it via Powershell command prompt.
# - This script MUST be run as Administrator.
# - This script MAY reboot the host (depending on what's installed/configured).

# Args:
#   Arg 1       Local account name that Ansible will use to connect
#   Arg 2       Password for the local account that Ansible will use to connect
#
# Usage example: powershell -ExecutionPolicy ByPass -File .\ansible_system_prep.ps1 ansible ansible

# input parameters for script
param (
[Parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
[string]$local_ansible_account_username,

[Parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
[string]$local_ansible_account_password
    )

# variables for script
$script_version                         = "01"
$script_name                            = "ansible_system_prep"
$reg_path                               = "HKLM:\SOFTWARE\IBM\Cambridge\Nebula"
$reg_path_auto_login                    = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$reg_path_net_framework                 = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\"
$reg_path_choco                         = "HKLM:\SYSTEM\ControlSet001\Control\Session Manager\Environment\"
$reg_path_run_once                      = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$powershell_choco_package_name          = "powershell"
$powershell_choco_package_version       = "5.1.14409.20170510"
$powershell_choco_wmf_version_human     = "5.1.14409.1005"
$net_framework_4_5_reg_min_version      = "378389" # taken from here - https://docs.microsoft.com/en-us/dotnet/framework/migration-guide/how-to-determine-which-versions-are-installed
$net_framework_choco_package_name       = "dotnet4.5"
$local_ansible_account_group_member     = "Administrators"
$ansible_configure_remoting_script_url  = "https://raw.githubusercontent.com/ansible/ansible/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"
$ansible_remoting_script_filename       = "ConfigureRemotingForAnsible.ps1"
$current_date_time                      = Get-Date -format "dd-MMM-yyyy HH-mm-ss"
$transript_path                         = "$Env:SYSTEMDRIVE\temp"
$transript_filename                     = "$script_name-log-$current_date_time.txt"

# function to create the log folder and set permissions
Function createTranscriptFolder() {

    # create transcript folder
    New-Item -ItemType directory -Path "$transript_path" -ErrorAction SilentlyContinue | out-null

    # set permissions on transcript folder for group 'Everyone'
    $access_control_list = Get-Acl "$transript_path"
    $access_rule = New-Object  system.security.accesscontrol.filesystemaccessrule("Everyone","FullControl","Allow")
    $access_control_list.SetAccessRule($access_rule)
    try {
        Set-Acl "$transript_path" $access_control_list
    }
    catch {
        log("WARNING: Unable to set permissions on '$transript_path'")
    }

    # verify the folder has been created
    if (Test-Path $transript_path) {
        try {
            Start-Transcript -path "$transript_path\$transript_filename" -Append
        }
        catch {
            log("WARNING: Unable to start transcription (powershell ver <5.x?), log file will not be written")
        }
    }
}

# function to setup logging
Function log($str) {
    $ps_log = ""
    $script:ps_log += "`n$str"
    echo $str
}

# function to compare the script version in the registry with the version
# as defined in this script via variable script_version, if they match then we
# exit, else run.
Function checkScriptVersionInRegistry() {
    log("INFO: Check whether this script has been run previously (registry value)...")
    $current_version = (Get-ItemProperty -Path $reg_path -Name $script_name -ErrorAction SilentlyContinue).$script_name

    if(-NOT [string]::IsNullOrEmpty($current_version)) {
        if ($current_version -eq $script_version) {
            log("WARNING: This script version '$script_version' has already been run on this machine, exiting...")
            exit 2
        }
        else {
            log("INFO: Last version executed '$current_version' and script version $script_version are different, continuing...")
        }
    }
    else {
        log("INFO: No registry value found, looks like we haven't completed the execution of this script before, continuing...")
    }
}

# function to check whether we already have chocolatey installed or not
Function checkChocoInstalled() {
    log("INFO: Check if Chocolatey is already nstalled (used to install Powershell and .Net Frameqwork)...")
    $choco_version = (Get-ItemProperty -Path $reg_path_choco -Name 'ChocolateyInstall' -ErrorAction SilentlyContinue).'ChocolateyInstall'
    if([string]::IsNullOrEmpty($choco_version)) {
        log("INFO: Choclatey not installed, continuing")
        $script:choco_installed = "false"
    }
    else {
        log("INFO: Choclatey already installed, skipping")
        $script:choco_installed = "true"
    }
}

# function to bootstrap the install of Chocolatey on the target machine
# note this DOES require that the command prmpt is run as an admin
Function chocoBootstrap() {
    if($choco_installed -eq "false") {
        log("INFO: Attempting to bootstrap Chocolatey using Powershell...")
        try {
            Set-ExecutionPolicy Bypass; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        }
        catch {
            log("ERROR: Unable to bootstrap Chocolately, exiting...")
            exit 1
        }
    }
}

# function to check .Net Framework version, we need to do this as powershell
# v5 requires .Net framework 4.5 as a prereq
Function checkNetFrameworkInstalled() {
    log("INFO: Check .Net Framework installed is at least 4.5 (prereq for Powershell v5)...")
    $net_framework_version = (Get-ItemProperty -Path $reg_path_net_framework -Name 'Release' -ErrorAction SilentlyContinue).'Release'

    if([string]::IsNullOrEmpty($net_framework_version)) {
        log("INFO: .Net Framework 4.5 not installed, continuing")
        $script:net_framework_4_5_installed = "false"
    }
    ElseIf([Decimal]$net_framework_version -ge [Decimal]$net_framework_4_5_reg_min_version) {
        log("INFO: .Net Framework 4.5 or higher currently installed, skipping")
        $script:net_framework_4_5_installed = "true"
    }
    else {
        log("INFO: .Net Framework 4.5 version installed ($net_framework_version) below required version ($net_framework_4_5_reg_min_version), continuing")
        $script:net_framework_4_5_installed = "false"
    }
}

# function to install .Net Framework v4.5 via chocolatey
# note this DOES require that the command prmpt is run as an admin
Function upgradeNetFrameworkUsingChoco() {
    if($net_framework_4_5_installed -eq "false") {
        log("INFO: Attempting to upgrade/install .Net Framework v4.5 using Chocolatey...")
        choco install -y $net_framework_choco_package_name
        if ($LastExitCode -eq 3010)
        {
            echo "INFO: Chocolatey Package '$net_framework_choco_package_name' requires reboot after install"
        }
        ElseIf ($LastExitCode -ne 0)
        {
            echo "ERROR: Failed to install Chocolatey Package '$net_framework_choco_package_name' error code is '$LastExitCode' (wrong package name?), exiting..."
            exit 1
        }
    }
}

# function to check Powershell version, this is used to skip the upgrade of
# Powershell if it already meats our requirements for Ansible
Function checkPowershellInstalled() {
    log("Attempting to detect the version of Powershell already installed...")
    $powershell_current_version_human = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Build).$($PSVersionTable.PSVersion.Revision)"
    $powershell_current_version_compare = $powershell_current_version_human -replace '[\-\.]', ''
    $powershell_choco_wmf_version_compare = $powershell_choco_wmf_version_human -replace '[\-\.]', ''

    if([string]::IsNullOrEmpty($powershell_current_version_compare)) {
        log("ERROR: Powershell version cannot be detected, unsupported platform detected, exiting...")
        exit 1
    }
    if([Decimal]$powershell_current_version_compare -ge [Decimal]$powershell_choco_wmf_version_compare) {
        log("INFO: Powershell version installed ($powershell_current_version_human) is equal to or greater than the version we require ($powershell_choco_wmf_version_human), skipping")
        $script:powershell_5_1_installed = "true"
    }
    else {
        log("INFO: Powershell version installed ($powershell_current_version_human) is not equal or greater than the version we require ($powershell_choco_wmf_version_human), continuing")
        $script:powershell_5_1_installed = "false"
    }
}

# function to install Powershell via chocolatey
# note this DOES require that the command prmpt is run as an admin
Function upgradePowershellUsingChoco() {
    if($powershell_5_1_installed -eq "false") {
        log("INFO: Attempting to upgrade/install Powershell ver $powershell_choco_wmf_version using Chocolatey...")
        choco install -y $powershell_choco_package_name --version $powershell_choco_package_version
        if ($LastExitCode -eq 3010)
        {
            echo "INFO: Chocolatey Package '$net_framework_choco_package_name' requires reboot after install"
        }
        ElseIf ($LastExitCode -ne 0)
        {
            echo "ERROR: Failed to install Chocolatey Package '$net_framework_choco_package_name' error code is '$LastExitCode' (wrong package name?), exiting..."
            exit 1
        }
    }
}

# function to check whether we need to configure the host
Function checkWinRMService() {
    If (!(Get-Service "WinRM")) {
        log("ERROR: Unable to find the WinRM service (unsupported OS?)")
        exit 1
    }
    ElseIf ((Get-Service "WinRM").Status -eq "Running") {
        log("INFO: WinRM looks to be already configured, skipping Ansible Remoting script")
        $script:winrm_configured = "true"
    }
    else {
        log("INFO: WinRM not configured, continuing to Ansible Remoting script...")
        $script:winrm_configured = "false"
    }
}

# function to download the Ansible Remoting script
Function downloadAnsibleRemotingScript() {
    if($winrm_configured -eq "false") {
        log("INFO: Downloading Ansible Remoting script to local machine...")
        try {
            (New-Object System.Net.WebClient).DownloadFile($ansible_configure_remoting_script_url, "$transript_path\$ansible_remoting_script_filename")
        }
        catch {
            log("ERROR: Unable to download Ansible Remoting script, exiting...")
            exit 1
        }
    }
}

# function to create local account for use with Ansible, note there is no
# Powershell modules to do this prior to Powershell 4.x, thus the use of NET.
Function createLocalAnsibleAccount() {
    if($winrm_configured -eq "false") {
        log("INFO: Creating local account for use with Ansible...")
        NET USER $local_ansible_account_username $local_ansible_account_password /ADD
        if ($LastExitCode -ne 0) {
            log("ERROR: Unable to create local account '$local_ansible_account_username', used for Ansible Remote Connection, exiting...")
            exit 1
        }
        NET LOCALGROUP $local_ansible_account_group_member $local_ansible_account_username /ADD
        if ($LastExitCode -ne 0) {
            log("ERROR: Unable to add local account '$local_ansible_account_username' to local group '$local_ansible_account_group_member', exiting...")
            exit 1
        }
    }
}

# function to auto logon (required to force run of Ansible Remoting Script)
Function configureRegistryForAutomaticLoginOnBootup() {
    if($winrm_configured -eq "false") {
        log("Configuring registry keys to cause '$local_ansible_account_username' to be logged in automatically on bootup")
        if(-Not $dryRun) {
            Set-ItemProperty $reg_path_auto_login "AutoAdminLogon" -Value "1" -type String
            Set-ItemProperty $reg_path_auto_login "DefaultUsername" -Value "$Env:COMPUTERNAME\$local_ansible_account_username" -type String
            Set-ItemProperty $reg_path_auto_login "DefaultPassword" -Value "$local_ansible_account_password" -type String
        }
    }
}

# function to do post installation tasks, such as run script on reboot
Function postInstallTasks() {
    if($winrm_configured -eq "false") {
        log("INFO: Setting Registry to run Ansible Remoting script on restart...")
        set-itemproperty $reg_path_run_once "NextRun" ('C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe -executionPolicy Unrestricted -File ' + "$transript_path\$ansible_remoting_script_filename")
    }
    writeScriptVersionToRegistry
    if($powershell_5_1_installed -eq "false" -OR $net_framework_4_5_installed -eq "false" -OR $winrm_configured -eq "false") {
        log("INFO: Restart required, restarting in 5 secs...")
        Start-Sleep -s 5
        Restart-Computer -Force
    }
}

# function to write the script version to the registry (used to compare script version
# with registry version later on - see function checkScriptVersionInRegistry)
Function writeScriptVersionToRegistry() {
    # create registry path first (required for older Powershell versions)
    New-Item -Path $reg_path -Name "$script_name" –Force | out-null
    # create value for registry key
    set-itemproperty -Path $reg_path -Name "$script_name" -value "$script_version" -type String
}

# function to kick off script by calling other functions
Function startScript() {
    log("---------------------------")
    log("INFO: Script '$script_name' started")
    log("")
    log("WARNING: This script must be run either via Powershell ISE as Administrator or via Powershell command prompt as Administrator.")
    log("")
    log("INFO: If you are running via Powershell command prompt then you will need to issue the following command:-")
    log("'powershell -ExecutionPolicy ByPass -File $script_name.ps1'")
    log("")
    log("INFO: Pausing for 5 seconds...")
    log("")
    Start-Sleep -s 5
    log("INFO: Running functions...")
    log("")

    createTranscriptFolder
    checkScriptVersionInRegistry
    checkChocoInstalled
    chocoBootstrap
    checkNetFrameworkInstalled
    upgradeNetFrameworkUsingChoco
    checkPowershellInstalled
    upgradePowershellUsingChoco
    checkWinRMService
    downloadAnsibleRemotingScript
    createLocalAnsibleAccount
    configureRegistryForAutomaticLoginOnBootup
    postInstallTasks

    log("")
    log("INFO: Script '$script_name' ended")
    log("---------------------------")
}

# Kick off script
startScript
