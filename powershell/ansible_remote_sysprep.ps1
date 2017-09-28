# This script is used to make a Windows machine 'Ansible ready' by installing/
# configuring all required Pre-requisites, this includes:-
#
# - Chocolatey (used to install .Net Framework and Powershell)
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
# - This script must be run as Administrator.
# - This script MAY reboot the host (depending on what's installed/configured).

# Args:
#   Arg 1       Local account name that Ansible will use to connect
#   Arg 2       Password for the local account that Ansible will use to connect
#
# Usage example: powershell -ExecutionPolicy ByPass -File .\ansible_system_prep.ps1 ansible ansible

# NOTE chocolatey logs located at C:\ProgramData\chocolatey\logs\choco.summary

# input parameters for script (see above)
param (
[Parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
[string]$local_ansible_account_username,

[Parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
[string]$local_ansible_account_password
    )

# variables for script
$script_version                         = "2017092817"
$script_name                            = "ansible_system_prep"
$min_free_disk_space_bytes              = 2000000000 # equates to 2 GB
$current_date_time                      = Get-Date -format "dd-MMM-yyyy HH-mm-ss"
$choco_install_retry_count              = 5
$choco_install_retry_sleep              = 30 # defined in seconds
$os_systemdrive                         = "$Env:SYSTEMDRIVE"
$os_computername                        = "$Env:COMPUTERNAME"
$cpu_idle_time                          = 60 # defined in seconds
$cpu_idle_percentage                    = 20 # defined as a percentage
$reg_path                               = "HKLM:\SOFTWARE\IBM\Cambridge\Nebula"
$reg_path_auto_login                    = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$reg_path_net_framework                 = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\"
$reg_path_choco                         = "HKLM:\SYSTEM\ControlSet001\Control\Session Manager\Environment\"
$reg_path_run_once                      = "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
$powershell_choco_package_name          = "powershell"
$powershell_choco_package_version       = "5.1.14409.20170510"
$powershell_choco_wmf_version           = "5.1.14409.1005"
$net_framework_4_5_2_reg_min_version    = "379893" # taken from here - https://docs.microsoft.com/en-us/dotnet/framework/migration-guide/how-to-determine-which-versions-are-installed
$net_framework_choco_package_name       = "dotnet4.5.2"
$local_ansible_account_group_member     = "Administrators"
$scheduled_task_name                    = "AnsibleSysPrep"
$scheduled_task_group                   = "Administrators"
$scheduled_task_delay_mins              = "10"
$transcript_path                        = "$os_systemdrive\temp"
$transcript_filename                    = "$script_name-log-$current_date_time.txt"
$ansible_configure_remoting_script_url  = "https://raw.githubusercontent.com/ansible/ansible/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"
$ansible_remoting_script_filename       = "ConfigureRemotingForAnsible.ps1"
$ansible_remoting_script_log            = "ansible_remoting-log-$current_date_time.txt"
$ansible_remoting_script_path           = "$transcript_path\$ansible_remoting_script_filename"
$ansible_remoting_script_output         = "$transcript_path\$ansible_remoting_script_log"

# function to create the log folder and set permissions
Function createTranscriptFolder() {

    # create transcript folder
    New-Item -ItemType directory -Path "$transcript_path" -ErrorAction SilentlyContinue | out-null

    # set permissions on transcript folder for group 'Everyone'
    $access_control_list = Get-Acl "$transcript_path"
    $access_rule = New-Object  system.security.accesscontrol.filesystemaccessrule("Everyone","FullControl","Allow")
    $access_control_list.SetAccessRule($access_rule)
    try {
        Set-Acl "$transcript_path" $access_control_list
    }
    catch {
        log("WARNING: Unable to set permissions on '$transcript_path'")
    }

    # verify the folder has been created
    if (Test-Path $transcript_path) {
        try {
            Start-Transcript -path "$transcript_path\$transcript_filename" -Append
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
            exitScript -exit_code 10
        }
        else {
            log("INFO: Last version executed '$current_version' and script version $script_version are different...")
        }
    }
    else {
        log("INFO: No registry value found, looks like we haven't completed the execution of this script before...")
    }
}

# Function to check OS is supported (64 bit only)
Function checkOSArch() {
    log("INFO: Checking OS architecture...")
    try {
        $os_arch = (Get-WmiObject Win32_OperatingSystem -computername $os_computername).OSArchitecture
    }
    catch {
        log("ERROR: Cannot determine OS architecture, exiting...")
        exitScript -exit_code $LastExitCode
    }
    if ($os_arch -ne "64-bit") {
          log("WARNING: OS architecture '$os_arch' is NOT 64-bit, exiting...")
          exitScript -exit_code 20
    }
    log("INFO: PASSED")
}

# Function to check amount of free disk space on OS system drive
Function checkFreeDiskSpace() {
    log("INFO: Checking free space on OS system drive '$os_systemdrive'...")
    try {
        $free_disk_space_bytes = Get-WmiObject Win32_LogicalDisk -ComputerName $os_computername -Filter "DeviceID='$os_systemdrive'" | Foreach-Object {$_.FreeSpace}
    }
    catch {
        log("ERROR: Cannot determine free disk space, exiting...")
        exitScript -exit_code $LastExitCode
    }
    if ($free_disk_space_bytes -lt $min_free_disk_space_bytes) {
          log("WARNING: Free disk space value '$free_disk_space_bytes' is below threshold value '$min_free_disk_space_bytes' for system drive '$os_systemdrive', exiting...")
          exitScript -exit_code 30
    }
    log("INFO: PASSED")
}

# function to check the major version of powershell installed, if it's less
# than 2.x then we cannot currently support it and thus exit.
Function checkPowershellMajorVersion() {
      log("INFO: Checking we have Powershell version 2.x or greater installed...")
      $powershell_current_major_version = "$($PSVersionTable.PSVersion.Major)"

      if([string]::IsNullOrEmpty($powershell_current_major_version)) {
          log("ERROR: Powershell version cannot be detected, assuming unsupported OS, exiting...")
          exitScript -exit_code 40
      }
      ElseIf([Decimal]$powershell_current_major_version -lt 2) {
          log("WARNING: Powershell major version installed '$powershell_current_major_version' is less than the minimum required (ver 2.x), exiting...")
          exitScript -exit_code 50
      }
      log("INFO: PASSED")
}

# function to detect CPU load, when it's below our threshold value (as defined via
# $cpu_idle_percentage) for a period of X seconds (as defined via $cpu_idle_time)
# then we assume windows is ready for operation.
# note there is currently NO way of doing this by looking at services/event log.
Function checkOSReady() {
    log("INFO: Waiting for OS to finish starting before we continue (monitoring CPU load)...")

    Function getCPULoad() {
        $load = Get-WmiObject win32_processor | Measure-Object -property LoadPercentage -Average | Select Average | foreach { $_.Average }
        return [Decimal]$load
    }

    $idle_seconds = 0
    while($idle_seconds -lt $cpu_idle_time) {
        $cpu_current_load_percentage = getCPULoad
        if($cpu_current_load_percentage -lt $cpu_idle_percentage) {
            $idle_seconds += 1
        }
        else {
            $idle_seconds = 0
        }
        Start-Sleep -s 1
    }
    log("INFO: System now ready")
}

# function to check whether we already have chocolatey installed or not
Function checkChocoInstalled() {
    log("INFO: Check if Chocolatey is already installed (used to install Powershell and Net Framework)...")
    $choco_version = (Get-ItemProperty -Path $reg_path_choco -Name 'ChocolateyInstall' -ErrorAction SilentlyContinue).'ChocolateyInstall'
    if([string]::IsNullOrEmpty($choco_version)) {
        log("INFO: Chocolatey NOT installed")
        $script:choco_installed = "false"
    }
    else {
        log("INFO: Chocolatey already installed, skipping")
        $script:choco_installed = "true"
    }
}

# function to bootstrap the install of Chocolatey on the target machine
# note this DOES require that the command prompt is run as an admin
Function chocoBootstrap() {
    if($choco_installed -eq "false") {
        log("INFO: Attempting to bootstrap Chocolatey using Powershell...")
        try {
            Set-ExecutionPolicy Bypass; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        }
        catch {
            log("ERROR: Failed to bootstrap Chocolately, exiting...")
            exitScript -exit_code 80
        }
        log("INFO: SUCCESS")

        log("INFO: Attempting to reload environment variable for PATH (required for choco after install)...")
        try {
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        }
        catch {
            log("ERROR: Failed to reload environment variable for PATH, exiting...")
            exitScript -exit_code 90
        }
        log("INFO: SUCCESS")
    }
}

# Chocolatey sadly doesn't have a retry function, and thus we have to write our
# own, the function below is a simple loop to retry up to the specified count
# defined via $choco_install_retry_count, with a sleep between retries, as defined
# via $choco_install_retry_sleep.
# note default timeout for choco is 2700 seconds
Function chocoInstallPackage() {
    param([string]$choco_package_name, [string]$choco_package_version)

    log("INFO: Attempting to install Chocolatey Package '$choco_package_name'...")

    # set working directory (required to upgrade powershell via chocolatey)
    Set-Location $PSHome

    while($true) {
        if($choco_package_version) {
            log("choco install --yes --force $choco_package_name --version $choco_package_version")
            choco install --yes --force $choco_package_name --version $choco_package_version
        }
        else {
            log("choco install --yes --force $choco_package_name")
            choco install --yes --force $choco_package_name
        }
        if ($LastExitCode -eq 0)
        {
            echo "INFO: Chocolatey Package '$choco_package_name' installed"
            break
        }
        ElseIf ($LastExitCode -eq 3010)
        {
            echo "INFO: Chocolatey Package '$choco_package_name' installed, reboot required"
            break
        }
        else {
            if ($choco_install_retry_count -ne 0) {
                log("INFO: Chocolatey Package '$choco_package_name' failed to install, exit code '$LastExitCode', retrying...")
                $choco_install_retry_count -= 1
            }
            else {
                log("INFO: Chocolatey Package '$choco_package_name' failed to install, exit code '$LastExitCode', retry count exceeded")
                exitScript -exit_code $LastExitCode
            }
        }
        Start-Sleep -s $choco_install_retry_sleep
    }
}

# function to check .Net Framework version, we need to do this as powershell
# v5 requires .Net framework 4.5.2 as a prereq
Function checkNetFrameworkInstalled() {
    log("INFO: Check Net Framework installed is at least 4.5.2...")
    $net_framework_version = (Get-ItemProperty -Path $reg_path_net_framework -Name 'Release' -ErrorAction SilentlyContinue).'Release'

    if([string]::IsNullOrEmpty($net_framework_version)) {
        log("INFO: Net Framework 4.5.2 NOT installed")
        $script:net_framework_4_5_2_installed = "false"
    }
    ElseIf([Decimal]$net_framework_version -ge [Decimal]$net_framework_4_5_2_reg_min_version) {
        log("INFO: Net Framework 4.5.2 or higher currently installed, skipping")
        $script:net_framework_4_5_2_installed = "true"
    }
    else {
        log("INFO: Net Framework 4.5.2 version installed ($net_framework_version) below required version ($net_framework_4_5_2_reg_min_version)")
        $script:net_framework_4_5_2_installed = "false"
    }
}

# function to install .Net Framework v4.5.2 via chocolatey
# note this DOES require that the command prmpt is run as an admin
Function upgradeNetFrameworkUsingChoco() {
    if($net_framework_4_5_2_installed -eq "false") {
        chocoInstallPackage $net_framework_choco_package_name
    }
}

# function to check Powershell version, this is used to skip the upgrade of
# Powershell if it already meats our requirements for Ansible
Function checkPowershellInstalled() {
    log("INFO: Attempting to detect the version of Powershell already installed...")
    $powershell_current_version = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Build).$($PSVersionTable.PSVersion.Revision)"
    $powershell_current_version_compare = $powershell_current_version -replace '[\-\.]', ''
    $powershell_choco_wmf_version_compare = $powershell_choco_wmf_version -replace '[\-\.]', ''

    if([Decimal]$powershell_current_version_compare -ge [Decimal]$powershell_choco_wmf_version_compare) {
        log("INFO: Powershell version installed ($powershell_current_version) is equal to or greater than the version we require ($powershell_choco_wmf_version), skipping")
        $script:powershell_5_1_installed = "true"
    }
    else {
        log("INFO: Powershell version installed ($powershell_current_version) is NOT equal or greater than the version we require ($powershell_choco_wmf_version)")
        $script:powershell_5_1_installed = "false"
    }
}

# function to install Powershell via chocolatey
# note this DOES require that the command prmpt is run as an admin
Function upgradePowershellUsingChoco() {
    if($powershell_5_1_installed -eq "false") {
        chocoInstallPackage $powershell_choco_package_name $powershell_choco_package_version
    }
}

# function to create local account for use with Ansible, note there is no
# Powershell modules to do this prior to Powershell 4.x, thus the use of NET.
Function createLocalAnsibleAccount() {

      log("INFO: Deleting existing local account '$local_ansible_account_username' for use with Ansible...")
      NET USER $local_ansible_account_username /DELETE 2>&1 | out-null

      log("INFO: Creating local account '$local_ansible_account_username' for use with Ansible...")
      NET USER $local_ansible_account_username $local_ansible_account_password /ADD | Out-Null
      if ($LastExitCode -ne 0) {
          log("WARNING: Unable to create local account '$local_ansible_account_username' used for Ansible Remote Connection, exit code is '$LastExitCode' (user account may already exist, or password not strong enough)")
      }
      NET LOCALGROUP $local_ansible_account_group_member $local_ansible_account_username /ADD | Out-Null
      if ($LastExitCode -ne 0) {
          log("WARNING: Unable to add local account '$local_ansible_account_username' to local group '$local_ansible_account_group_member', exit code is '$LastExitCode'")
      }
}

# function to check whether we need to configure the host
Function checkWinRMService() {
    If (!(Get-Service "WinRM")) {
        log("ERROR: Unable to find the WinRM service (unsupported OS?)")
        exitScript -exit_code 60
    }
    If ((Get-Service "WinRM").Status -eq "Running") {
        log("INFO: WinRM looks to be already configured (currently running), skipping Ansible Remoting script")
        $script:winrm_configured = "true"
        exitScript -exit_code 0
    }
    ElseIf ((Get-WmiObject Win32_Service -filter "Name='WinRM'").StartMode -eq "Auto") {
        log("INFO: WinRM looks to be already configured (set to automatic), skipping Ansible Remoting script")
        $script:winrm_configured = "true"
        exitScript -exit_code 0
    }
    else {
        log("INFO: WinRM NOT configured")
        $script:winrm_configured = "false"
    }
}

# function to download the Ansible Remoting script
Function downloadAnsibleRemotingScript() {
      if($winrm_configured -eq "false") {
          log("INFO: Downloading Ansible Remoting script to local machine...")
          try {
              (New-Object System.Net.WebClient).DownloadFile($ansible_configure_remoting_script_url, "$ansible_remoting_script_path")
          }
          catch {
              log("ERROR: Unable to download Ansible Remoting script, exiting...")
              exitScript -exit_code $LastExitCode
          }
          log("INFO: SUCCESS")
      }
}

# function to check if the Scheduled Task to run the Ansible Remoting Preperation
# has already been created.
Function checkScheduledTask() {
    log("INFO: Checking if Scheduled Task to run the Ansible Remoting Preperation script already exists...")
    $script:scheduled_task_exists = "true"

    if($winrm_configured -eq "false") {

        $service = new-object -ComObject("Schedule.Service")
        $service.Connect()
        $get_scheduled_tasks = $service.getfolder("\").gettasks(0)

        foreach ($task_name in ($get_scheduled_tasks | select Name)) {
            if($($task_name.name) -eq "$scheduled_task_name") {
                log("INFO: Scheduled Task does exist")
                exitScript -exit_code 0
            }
        }
        log("INFO: Scheduled Task does NOT exist")
        $script:scheduled_task_exists = "false"
    }
}

# function to create a scheduled task to run the Ansible Remoting Preperation
# script on reboot (run once). We use this mechanism as it does not rely on the
# user logging in and also runs as Administrator.
Function createScheduledTask() {
    $script:scheduled_task_created = "false"

    if($scheduled_task_exists -eq "false") {
          log("INFO: Creating Scheduled Task to run the Ansible Remoting Preperation script '$ansible_remoting_script_path' on startup...")

          $service = new-object -ComObject("Schedule.Service")
          $service.Connect()

          $TaskDefinition = $service.NewTask(0)
          $TaskDefinition.RegistrationInfo.Description = "Run the Ansible Remoting Preperation script"
          $TaskDefinition.Settings.Enabled = $true
          $TaskDefinition.Settings.AllowDemandStart = $true
          $TaskDefinition.Principal.RunLevel = 1 # TASK_RUNLEVEL_HIGHEST
          $TaskDefinition.Settings.ExecutionTimeLimit = "PT0S"

          $triggers = $TaskDefinition.Triggers
          $trigger = $triggers.Create(8) # Creates a 'At startup' trigger
          $trigger.Delay = "PT" + "$scheduled_task_delay_mins" + "M" # delay task for 5 minutes
          $trigger.Enabled = $true

          $Action = $TaskDefinition.Actions.Create(0)
          $action.Path = "Powershell.exe"
          $action.Arguments = "-Noninteractive -ExecutionPolicy Bypass -File $ansible_remoting_script_path"
          $Action = $TaskDefinition.Actions.Create(0)
          $action.Path = "schtasks.exe"
          $action.Arguments = "/Delete /TN $scheduled_task_name /F"

          $rootFolder = $service.GetFolder("\")

          try {
              $rootFolder.RegisterTaskDefinition($scheduled_task_name,$TaskDefinition,6,"$local_ansible_account_username","$local_ansible_account_password",1)
          }
          catch {
              log("ERROR: Failed to create Scheduled Task, exiting...")
              exitScript -exit_code 70
          }
          log("INFO: SUCCESS")
          $script:scheduled_task_created = "true"
    }
}

# function to write the script version to the registry (used to compare script version
# with registry version later on - see function checkScriptVersionInRegistry)
Function writeScriptVersionToRegistry() {
    # create registry path first (required for older Powershell versions)
    New-Item -Path $reg_path -Name "" –Force | out-null
    # create value for registry key
    set-itemproperty -Path $reg_path -Name "$script_name" -value "$script_version" -type String
}

# function to stop transcript with exit code
Function exitScript() {
    Param ([string]$exit_code)

    if($exit_code -eq 0){
        log("INFO: Updating script version '$script_version' in the Registry before exit...")
        writeScriptVersionToRegistry

        if($powershell_5_1_installed -eq "false" -OR $net_framework_4_5_2_installed -eq "false" -OR $scheduled_task_created -eq "true") {
            log("INFO: Restart required, restarting in 5 secs...")
            Start-Sleep -s 5
            log("INFO: Script '$script_name' ended, exit code '$exit_code'")
            log("---------------------------")
            Stop-Transcript
            Restart-Computer -Force
            exit $exit_code
        }
    }

    log("INFO: Script '$script_name' ended, exit code '$exit_code'")
    log("---------------------------")
    Stop-Transcript
    exit $exit_code
}

# function to kick off script by calling functions
Function startScript() {
    createTranscriptFolder

    log("---------------------------")
    log("INFO: Script '$script_name' started")

    checkScriptVersionInRegistry
    checkOSArch
    checkFreeDiskSpace
    checkPowershellMajorVersion
    checkOSReady
    checkWinRMService
    downloadAnsibleRemotingScript
    checkChocoInstalled
    chocoBootstrap
    checkNetFrameworkInstalled
    upgradeNetFrameworkUsingChoco
    checkPowershellInstalled
    upgradePowershellUsingChoco
    createLocalAnsibleAccount
    checkScheduledTask
    createScheduledTask
    exitScript -exit_code 0
}

# Kick off script
startScript
