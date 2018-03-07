# This powershell script ensures that the local github repos on disk
# are in sync with the remote repos on github. This prevents issues when
# using multiple hosts to push/pull commits.

# define github repository root folder
$github_repo_root = "C:\Scripts\Github"

# set up all the environment variables
Write-Host "Setting up GitHub Environment"
. (Resolve-Path "$env:LOCALAPPDATA\GitHub\shell.ps1")

# set up Posh-Git
Write-Host "Setting up Posh-Git"
. (Resolve-Path "$env:github_posh_git\profile.example.ps1")

git config --global credential.helper wincred

# change to root folder
cd $github_repo_root

# iterate over folders issuing a git pull
Get-ChildItem -Recurse -Depth 2 -Force | 
 Where-Object { $_.Mode -match "h" -and $_.FullName -like "*\.git" } |
 ForEach-Object {
    cd $_.FullName
    cd ../
	$current_absolute_path = (Get-Item -Path ".\" -Verbose).FullName
    Write-Host "Updating Github Repo located at $current_absolute_path..."
    git pull
    cd ../
 }

 Write-Host "Script finished"